import Foundation
import Observation

/// Watches the one folder the user chose for downloads, and turns what `DownloadDetector` sees
/// into transfers. Directory events wake it; while a partial file is being written, it also
/// looks once a second, because a growing file doesn't change its folder.
@MainActor
@Observable
final class DownloadFolderMonitor {
    enum Status: Equatable, Sendable {
        case off
        case needsFolder
        case watching(String)
        case folderUnavailable
    }

    private static let debounce = Duration.milliseconds(300)
    private static let sampleInterval = Duration.seconds(1)
    private nonisolated static let attribute = "com.apple.quarantine"

    private(set) var status = Status.off
    /// A finished file and whether AirDrop delivered it.
    @ObservationIgnored var onArrival: ((URL, Bool) -> Void)?

    @ObservationIgnored private let transfers: TransferManager
    @ObservationIgnored private let scheduler: any Scheduling
    @ObservationIgnored private let queue = DispatchQueue(label: "com.athene.morph.downloads", qos: .utility)
    @ObservationIgnored private var detector = DownloadDetector()
    @ObservationIgnored private var source: (any DispatchSourceFileSystemObject)?
    @ObservationIgnored private var folder: URL?
    @ObservationIgnored private var scopedFolder: URL?
    @ObservationIgnored private var bookmark: Data?
    @ObservationIgnored private var scanWork: (any ScheduledWork)?
    @ObservationIgnored private var sampleWork: (any ScheduledWork)?
    @ObservationIgnored private var generation = 0

    init(transfers: TransferManager, scheduler: any Scheduling) {
        self.transfers = transfers
        self.scheduler = scheduler
    }

    /// Matches the settings. Calling it again with the same values does nothing.
    func apply(enabled: Bool, bookmark newBookmark: Data?) {
        guard enabled else {
            stop()
            status = .off
            bookmark = nil
            return
        }
        guard let newBookmark else {
            stop()
            status = .needsFolder
            bookmark = nil
            return
        }
        guard newBookmark != bookmark || source == nil else { return }
        bookmark = newBookmark
        stop()

        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: newBookmark, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            status = .folderUnavailable
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        guard watch(url) else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            status = .folderUnavailable
            return
        }
        if scoped { scopedFolder = url }
    }

    @discardableResult
    func watch(_ url: URL) -> Bool {
        let descriptor = Darwin.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return false }
        source = Self.makeSource(descriptor: descriptor, queue: queue) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.scheduleScan() }
            }
        }
        folder = url
        detector.reset()
        status = .watching(url.lastPathComponent)
        scan()
        return true
    }

    func stop() {
        generation += 1
        source?.cancel()
        source = nil
        scopedFolder?.stopAccessingSecurityScopedResource()
        scopedFolder = nil
        folder = nil
        scanWork?.cancel()
        scanWork = nil
        sampleWork?.cancel()
        sampleWork = nil
        detector.reset()
        transfers.abandon(source: .watchedFolder)
    }

    private func scheduleScan() {
        scanWork?.cancel()
        scanWork = scheduler.schedule(after: Self.debounce) { [weak self] in self?.scan() }
    }

    private func scan() {
        guard let folder else { return }
        let (current, detector) = (generation, detector)
        queue.async { [weak self] in
            let entries = Self.list(folder, detailsFor: detector.needsDetails)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(entries, in: folder, generation: current) }
            }
        }
    }

    func receive(_ entries: [DownloadFolderEntry], in folder: URL, generation current: Int? = nil) {
        guard current == nil || current == generation else { return }
        for change in detector.process(entries) { apply(change, in: folder) }
        sampleWork?.cancel()
        sampleWork = nil
        // Only while something is actually downloading. Idle, the folder costs nothing.
        if detector.activeCount > 0 {
            sampleWork = scheduler.schedule(after: Self.sampleInterval) { [weak self] in self?.scan() }
        }
    }

    private func apply(_ change: DownloadChange, in folder: URL) {
        switch change {
        case .started(let id, let name, let bytes, let total):
            try? transfers.begin(Transfer(id: id, kind: .download, name: name, source: .watchedFolder,
                                          state: bytes > 0 ? .transferring : .pending, bytes: bytes, totalBytes: total))
        case .progressed(let id, let name, let bytes, let total):
            try? transfers.update(id: id, bytes: bytes, totalBytes: total, name: name)
        case .finished(let id, let name):
            let url = folder.appendingPathComponent(name)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            try? transfers.finish(id: id, bytes: size, fileURL: url, name: name)
        case .vanished(let id):
            try? transfers.finish(id: id, state: .unknown)
        case .arrived(let name, let size, let isAirDrop):
            let url = folder.appendingPathComponent(name)
            transfers.record(Transfer(id: "arrival-\(name)-\(Int(Date.now.timeIntervalSince1970))",
                                      kind: isAirDrop ? .airDropReceive : .download, name: name,
                                      source: .watchedFolder, fileURL: url, state: .completed, bytes: size))
            onArrival?(url, isAirDrop)
        }
    }

    private nonisolated static func makeSource(descriptor: Int32, queue: DispatchQueue,
                                               onChange: @escaping @Sendable () -> Void) -> any DispatchSourceFileSystemObject {
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: queue)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        return source
    }

    /// Top level only. Details are read just for names the detector hasn't seen, plus partials.
    private nonisolated static func list(_ folder: URL, detailsFor needsDetails: (String) -> Bool) -> [DownloadFolderEntry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.sorted().map { name in
            guard needsDetails(name) else { return DownloadFolderEntry(name: name, size: 0) }
            let url = folder.appendingPathComponent(name)
            var entry = DownloadFolderEntry(name: name, size: size(of: url), quarantine: quarantine(of: url))
            if name.hasSuffix(".download") { entry.expectedSize = safariExpectedSize(url) }
            return entry
        }
    }

    private nonisolated static func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        guard values?.isDirectory == true else { return Int64(values?.fileSize ?? 0) }
        // A Safari partial is a bundle; the bytes are in the file inside it.
        let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return contents.filter { $0.lastPathComponent != "Info.plist" }
            .reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Safari records the expected size in the partial's own Info.plist. Undocumented, so it's
    /// only used when present and sensible; otherwise the download has no percentage.
    private nonisolated static func safariExpectedSize(_ url: URL) -> Int64? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let total = (plist["DownloadEntryProgressTotalToLoad"] as? NSNumber)?.int64Value, total > 0 else { return nil }
        return total
    }

    private nonisolated static func quarantine(of url: URL) -> QuarantineMarker? {
        let length = getxattr(url.path, attribute, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard getxattr(url.path, attribute, &buffer, length, 0, 0) == length else { return nil }
        return QuarantineMarker(String(decoding: buffer, as: UTF8.self))
    }
}
