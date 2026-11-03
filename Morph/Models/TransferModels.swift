import Foundation

enum TransferKind: String, Codable, CaseIterable, Sendable {
    case download
    case upload
    /// A file that arrived with AirDrop, identified after it landed.
    case airDropReceive
    /// A share handed to macOS's AirDrop service.
    case airDropSend

    var isAirDrop: Bool { self == .airDropReceive || self == .airDropSend }

    var symbol: String {
        switch self {
        case .download: "arrow.down"
        case .upload: "arrow.up"
        case .airDropReceive, .airDropSend: "airdrop"
        }
    }

    var title: String {
        switch self {
        case .download: "Download"
        case .upload: "Upload"
        case .airDropReceive: "AirDrop"
        case .airDropSend: "AirDrop"
        }
    }
}

enum TransferState: String, Codable, CaseIterable, Sendable {
    case pending, transferring, paused, completed, failed, cancelled, unknown

    var isFinished: Bool { self == .completed || self == .failed || self == .cancelled }
}

/// Where a transfer was learned about. Decides what Morph may do with it.
enum TransferSource: String, Codable, Sendable {
    /// A partial file in the folder the user chose to share with Morph.
    case watchedFolder
    /// A script or app, through the local API.
    case liveAPI
    /// Started by Morph itself.
    case morph
}

/// One transfer, as far as it's known. Nothing here is estimated beyond what the samples show:
/// no total means no percentage, and no movement means no speed.
struct Transfer: Identifiable, Equatable, Sendable {
    let id: String
    var kind: TransferKind
    var name: String
    var source: TransferSource
    /// The finished file, when Morph can open it.
    var fileURL: URL?
    var state: TransferState
    var bytes: Int64
    var totalBytes: Int64?
    /// Bytes per second, smoothed. Nil until two samples apart in time disagree.
    var speed: Double?
    var error: String?
    var startedAt: Date
    var finishedAt: Date?

    init(id: String, kind: TransferKind, name: String, source: TransferSource, fileURL: URL? = nil,
         state: TransferState = .pending, bytes: Int64 = 0, totalBytes: Int64? = nil, startedAt: Date = .now) {
        self.id = id
        self.kind = kind
        self.name = name
        self.source = source
        self.fileURL = fileURL
        self.state = state
        self.bytes = bytes
        self.totalBytes = totalBytes
        self.startedAt = startedAt
    }

    /// Only with a known, positive total.
    var progress: Double? {
        if state == .completed { return 1 }
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(bytes) / Double(totalBytes)))
    }

    var remaining: Duration? {
        guard state == .transferring, let speed, speed > 0, let totalBytes, totalBytes > bytes else { return nil }
        return .seconds(Double(totalBytes - bytes) / speed)
    }

    /// Finished, or given up on. Either way it no longer changes.
    var isOver: Bool { finishedAt != nil }

    /// Morph can only stop what it started.
    var canCancel: Bool { source == .morph && !isOver }

    var canOpen: Bool { state == .completed && fileURL != nil }

    var symbol: String {
        switch state {
        case .completed: "checkmark"
        case .failed: "exclamationmark"
        case .cancelled: "xmark"
        default: kind.symbol
        }
    }

    /// The one line under the name: what's known, in the order it matters.
    var detail: String {
        switch state {
        case .pending: return "Waiting"
        case .paused: return "Paused"
        case .unknown: return "Status unknown"
        case .cancelled: return "Cancelled"
        case .failed: return error ?? "Failed"
        case .completed:
            switch kind {
            case .airDropReceive: return "Received with AirDrop"
            case .airDropSend: return "Sent with AirDrop"
            case .download: return totalBytes.map(TransferFormat.bytes) ?? "Downloaded"
            case .upload: return "Uploaded"
            }
        case .transferring:
            var parts: [String] = []
            if let totalBytes, totalBytes > 0 {
                parts.append("\(TransferFormat.bytes(bytes)) of \(TransferFormat.bytes(totalBytes))")
            } else if bytes > 0 {
                parts.append(TransferFormat.bytes(bytes))
            } else if kind.isAirDrop {
                parts.append(kind == .airDropSend ? "Sending" : "Receiving")
            }
            if let speed { parts.append(TransferFormat.speed(speed)) }
            if let remaining { parts.append(TransferFormat.remaining(remaining)) }
            return parts.isEmpty ? "In progress" : parts.joined(separator: " · ")
        }
    }
}

enum TransferFormat {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        "\(ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file))/s"
    }

    static func remaining(_ duration: Duration) -> String {
        let seconds = Int(duration.timeInterval.rounded(.up))
        if seconds < 60 { return "\(seconds) s left" }
        if seconds < 3600 { return "\(seconds / 60) min left" }
        return "\(seconds / 3600) h \(seconds % 3600 / 60) min left"
    }
}

/// Speed from byte counts over time. Smoothed, so one slow sample doesn't swing the estimate.
struct TransferSpeedMeter: Sendable {
    private static let smoothing = 0.3
    /// Samples closer than this say more about timer jitter than about speed.
    private static let minimumInterval = 0.25

    private var last: (bytes: Int64, at: ContinuousClock.Instant)?
    private(set) var speed: Double?

    mutating func sample(bytes: Int64, at now: ContinuousClock.Instant) {
        guard let last else {
            self.last = (bytes, now)
            return
        }
        let elapsed = last.at.duration(to: now).timeInterval
        guard elapsed >= Self.minimumInterval else { return }
        // Restarted or rewound: the old samples no longer describe this transfer.
        guard bytes >= last.bytes else {
            self.last = (bytes, now)
            speed = nil
            return
        }
        let instant = Double(bytes - last.bytes) / elapsed
        speed = speed.map { $0 + Self.smoothing * (instant - $0) } ?? instant
        self.last = (bytes, now)
    }
}
