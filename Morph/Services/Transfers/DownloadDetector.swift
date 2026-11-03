import Foundation

/// One top-level item in the watched folder, as read on the file queue.
struct DownloadFolderEntry: Equatable, Sendable {
    var name: String
    var size: Int64
    /// From a partial's own bookkeeping, when the browser keeps any. Safari does.
    var expectedSize: Int64? = nil
    /// The `com.apple.quarantine` marker macOS puts on things that arrived from elsewhere. Read
    /// only for new names: the folder's old files are never examined.
    var quarantine: QuarantineMarker? = nil
}

/// `flags;hex time;agent;uuid`. Only the agent and time are used.
struct QuarantineMarker: Equatable, Sendable {
    var agent: String
    var date: Date

    init(agent: String, date: Date) {
        self.agent = agent
        self.date = date
    }

    init?(_ raw: String) {
        let fields = raw.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count >= 3, let seconds = UInt64(fields[1], radix: 16) else { return nil }
        agent = String(fields[2])
        date = Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// AirDrop's own receiving process. Undocumented; if it ever changes, AirDropped files simply
    /// count as downloads rather than being called AirDrop by guesswork.
    var isAirDrop: Bool { agent == "sharingd" }
}

enum DownloadChange: Equatable, Sendable {
    case started(id: String, name: String, bytes: Int64, total: Int64?)
    case progressed(id: String, name: String, bytes: Int64, total: Int64?)
    case finished(id: String, name: String)
    /// The partial vanished with no file to show for it: stopped, cancelled or moved. Unknown.
    case vanished(id: String)
    /// A finished file that arrived whole between two looks.
    case arrived(name: String, size: Int64, isAirDrop: Bool)
}

/// Decides what in a folder listing is a download. The rules are narrow on purpose:
///
/// - In progress means a browser's partial file: `.download` (Safari), `.crdownload` (Chromium
///   browsers) or `.part` (Firefox).
/// - A new finished file only counts if macOS quarantined it moments ago. Files the user copies
///   or saves, or old downloads moved in, aren't downloads.
/// - The first listing is the baseline. Nothing already there is announced, except partials
///   still being written.
struct DownloadDetector: Sendable {
    static let partialSuffixes = [".download", ".crdownload", ".part"]
    /// How recent a quarantine marker must be for a new file to count as just downloaded.
    static let freshness: TimeInterval = 120

    private var known: Set<String>?
    /// Partial name to transfer ID.
    private var partials: [String: String] = [:]
    private var counter = 0

    static func isPartial(_ name: String) -> Bool {
        partialSuffixes.contains { name.hasSuffix($0) && name.count > $0.count }
    }

    /// The finished file's name, when the partial's name says it. Chromium's "Unconfirmed 123"
    /// stage doesn't.
    static func finalName(of partial: String) -> String? {
        guard let suffix = partialSuffixes.first(where: { partial.hasSuffix($0) }) else { return nil }
        let base = String(partial.dropLast(suffix.count))
        return base.hasPrefix("Unconfirmed ") ? nil : base
    }

    var activeCount: Int { partials.count }

    mutating func reset() {
        known = nil
        partials = [:]
    }

    /// Names that need their details read: everything not seen before.
    func needsDetails(_ name: String) -> Bool {
        guard let known else { return Self.isPartial(name) }
        return !known.contains(name) || Self.isPartial(name)
    }

    mutating func process(_ entries: [DownloadFolderEntry], now: Date = .now) -> [DownloadChange] {
        let visible = entries.filter { !$0.name.hasPrefix(".") }
        let names = Set(visible.map(\.name))
        guard let previous = known else {
            known = names
            var started: [DownloadChange] = []
            for entry in visible where Self.isPartial(entry.name) { started.append(start(entry)) }
            return started
        }
        known = names

        var changes: [DownloadChange] = []
        let currentPartials = visible.filter { Self.isPartial($0.name) }
        let gone = partials.keys.filter { !names.contains($0) }.sorted()
        var newPartials = currentPartials.filter { partials[$0.name] == nil }
        var claimed = Set<String>()

        for name in gone {
            guard let id = partials.removeValue(forKey: name) else { continue }
            if let final = Self.finalName(of: name), names.contains(final) {
                claimed.insert(final)
                changes.append(.finished(id: id, name: final))
            } else if gone.count == 1, newPartials.count == 1 {
                // Renamed while still downloading, as Chromium does once the name is known.
                let renamed = newPartials.removeFirst()
                partials[renamed.name] = id
                changes.append(.progressed(id: id, name: Self.displayName(renamed.name), bytes: renamed.size, total: renamed.expectedSize))
            } else if let arrival = visible.first(where: { !previous.contains($0.name) && !Self.isPartial($0.name) && isFresh($0, now) }) {
                claimed.insert(arrival.name)
                changes.append(.finished(id: id, name: arrival.name))
            } else {
                changes.append(.vanished(id: id))
            }
        }

        for entry in newPartials { changes.append(start(entry)) }
        for entry in currentPartials {
            guard let id = partials[entry.name], !changes.contains(where: { $0.id == id }) else { continue }
            changes.append(.progressed(id: id, name: Self.displayName(entry.name), bytes: entry.size, total: entry.expectedSize))
        }

        // Firefox makes the final name as an empty placeholder while it writes the partial.
        let placeholders = Set(partials.keys.compactMap(Self.finalName))
        for entry in visible where !previous.contains(entry.name) && !Self.isPartial(entry.name)
            && !claimed.contains(entry.name) && !placeholders.contains(entry.name) && isFresh(entry, now) {
            changes.append(.arrived(name: entry.name, size: entry.size, isAirDrop: entry.quarantine?.isAirDrop == true))
        }
        return changes
    }

    private func isFresh(_ entry: DownloadFolderEntry, _ now: Date) -> Bool {
        guard let marker = entry.quarantine else { return false }
        return abs(now.timeIntervalSince(marker.date)) <= Self.freshness
    }

    private mutating func start(_ entry: DownloadFolderEntry) -> DownloadChange {
        counter += 1
        let id = "download-\(counter)"
        partials[entry.name] = id
        return .started(id: id, name: Self.displayName(entry.name), bytes: entry.size, total: entry.expectedSize)
    }

    private static func displayName(_ partial: String) -> String {
        finalName(of: partial) ?? "Download"
    }
}

private extension DownloadChange {
    var id: String? {
        switch self {
        case .started(let id, _, _, _), .progressed(let id, _, _, _), .finished(let id, _), .vanished(let id): id
        case .arrived: nil
        }
    }
}
