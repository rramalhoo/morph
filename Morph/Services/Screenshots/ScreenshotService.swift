import AppKit
import Foundation
import ImageIO
import Observation

/// A screenshot on offer. The image itself stays in `ScreenshotService`.
struct ScreenshotPreview: Equatable, Sendable {
    let url: URL
    var name: String { url.lastPathComponent }
}

/// One file in the watched folder.
struct ScreenshotFolderEntry: Equatable, Sendable {
    var name: String
    var isScreenCapture: Bool
}

/// Picks out new screenshots from successive listings of a folder. Pure, so the rules can be tested.
///
/// A listing taken when watching starts is only a baseline, because nothing in it is new. macOS
/// marks every capture with `kMDItemIsScreenCapture`, which works in any language and any filename
/// format, and keeps other images landing in the folder from being treated as screenshots.
struct ScreenshotDetector: Sendable {
    private var known: Set<String>?

    mutating func reset() {
        known = nil
    }

    /// The newest screenshot to appear since the last listing. Listings arrive in name order, and
    /// default names hold the time, but a burst simply shows its last one.
    mutating func process(_ entries: [ScreenshotFolderEntry]) -> ScreenshotFolderEntry? {
        let visible = entries.filter { !$0.name.hasPrefix(".") }
        defer { known = Set(visible.map(\.name)) }
        guard let known else { return nil }
        return visible.last { !known.contains($0.name) && $0.isScreenCapture }
    }
}

/// Watches the one folder the user chose, and nothing else, for new screenshots. Images stay in
/// memory for as long as the preview shows and are never saved, listed or sent anywhere.
@MainActor
@Observable
final class ScreenshotService {
    enum Status: Equatable, Sendable {
        case off
        case needsFolder
        case watching(String)
        case folderUnavailable
    }

    private static let debounce = Duration.milliseconds(200)
    private nonisolated static let thumbnailSize = 640
    private nonisolated static let attribute = "com.apple.metadata:kMDItemIsScreenCapture"

    private(set) var status = Status.off
    private(set) var current: ScreenshotPreview?
    private(set) var thumbnail: NSImage?
    /// A drag has started from the preview, and it must stay put until the drag ends.
    var isDragging = false

    @ObservationIgnored var onCaptured: ((ScreenshotPreview) -> Void)?

    @ObservationIgnored private let scheduler: any Scheduling
    @ObservationIgnored private let queue = DispatchQueue(label: "com.athene.morph.screenshots", qos: .utility)
    @ObservationIgnored private var detector = ScreenshotDetector()
    @ObservationIgnored private var source: (any DispatchSourceFileSystemObject)?
    @ObservationIgnored private var folder: URL?
    @ObservationIgnored private var scopedFolder: URL?
    @ObservationIgnored private var bookmark: Data?
    @ObservationIgnored private var scanWork: (any ScheduledWork)?
    @ObservationIgnored private var isSessionActive = true
    @ObservationIgnored private var generation = 0

    init(scheduler: any Scheduling) {
        self.scheduler = scheduler
    }

    /// Makes the watcher match the settings. Calling it again with the same values does nothing.
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
        if !watch(url) {
            if scoped { url.stopAccessingSecurityScopedResource() }
            status = .folderUnavailable
            return
        }
        if scoped { scopedFolder = url }
    }

    /// Test seam and the shared end of `apply`. Returns false if the folder can't be opened.
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
        detector.reset()
        clear()
    }

    /// What's on screen after the lock is no one's business, so previews end there.
    func setSessionActive(_ active: Bool) {
        guard active != isSessionActive else { return }
        isSessionActive = active
        generation += 1
        detector.reset()
        if active { scan() } else { clear() }
    }

    func clear() {
        current = nil
        thumbnail = nil
        isDragging = false
    }

    // MARK: - Actions

    func copy() {
        guard let current else { return }
        let board = NSPasteboard.general
        board.clearContents()
        var items: [any NSPasteboardWriting] = [current.url as NSURL]
        if let image = NSImage(contentsOf: current.url) { items.append(image) }
        board.writeObjects(items)
    }

    func open() {
        guard let current else { return }
        NSWorkspace.shared.open(current.url)
    }

    func reveal() {
        guard let current else { return }
        NSWorkspace.shared.activateFileViewerSelecting([current.url])
    }

    // MARK: - Watching

    private func scheduleScan() {
        scanWork?.cancel()
        scanWork = scheduler.schedule(after: Self.debounce) { [weak self] in self?.scan() }
    }

    private func scan() {
        guard let folder, isSessionActive else { return }
        let current = generation
        queue.async { [weak self] in
            let entries = Self.list(folder)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(entries, in: folder, generation: current) }
            }
        }
    }

    private func receive(_ entries: [ScreenshotFolderEntry], in folder: URL, generation current: Int) {
        guard current == generation, isSessionActive, let entry = detector.process(entries) else { return }
        load(ScreenshotPreview(url: folder.appendingPathComponent(entry.name)), generation: current)
    }

    private func load(_ preview: ScreenshotPreview, generation current: Int) {
        queue.async { [weak self] in
            guard let image = Self.makeThumbnail(preview.url) else { return }
            let size = CGSize(width: image.width, height: image.height)
            let box = UncheckedImage(image: image)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, current == self.generation, self.isSessionActive else { return }
                    self.show(preview, thumbnail: NSImage(cgImage: box.image, size: size))
                }
            }
        }
    }

    /// Nonisolated on purpose: these handlers run on `queue`, and a closure formed in a main actor
    /// method would inherit that isolation and trap there.
    private nonisolated static func makeSource(descriptor: Int32, queue: DispatchQueue,
                                               onChange: @escaping @Sendable () -> Void) -> any DispatchSourceFileSystemObject {
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: queue)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        return source
    }

    func show(_ preview: ScreenshotPreview, thumbnail: NSImage) {
        self.thumbnail = thumbnail
        current = preview
        onCaptured?(preview)
    }

    /// Top level only: the folder's subfolders aren't part of what the user chose to share.
    private nonisolated static func list(_ folder: URL) -> [ScreenshotFolderEntry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.sorted().map { name in
            ScreenshotFolderEntry(name: name, isScreenCapture: !name.hasPrefix(".") && isScreenCapture(folder.appendingPathComponent(name)))
        }
    }

    /// Reading the marker needs nothing from Spotlight, which may not have indexed the file yet.
    nonisolated static func isScreenCapture(_ url: URL) -> Bool {
        getxattr(url.path, attribute, nil, 0, 0, 0) > 0
    }

    private nonisolated static func makeThumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailSize,
        ] as CFDictionary)
    }
}

/// `CGImage` is immutable, which makes the hand-over between queues safe.
private struct UncheckedImage: @unchecked Sendable {
    let image: CGImage
}
