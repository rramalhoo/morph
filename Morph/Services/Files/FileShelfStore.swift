import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

struct ShelfItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    var name: String { url.lastPathComponent }
}

/// References to dropped files. Nothing is copied: the shelf keeps security-scoped bookmarks,
/// which also survive the file being moved or the app restarting.
@MainActor
@Observable
final class FileShelfStore {
    static let capacity = 24
    private static let defaultsKey = "shelf.bookmarks"

    private struct Stored: Codable {
        var id: UUID
        var bookmark: Data
    }

    private(set) var items: [ShelfItem] = []
    /// Reports how many files were added by one drop.
    @ObservationIgnored var onAdded: ((Int) -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var stored: [Stored] = []
    @ObservationIgnored private var scopedURLs: [UUID: URL] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restore()
    }

    @discardableResult
    func add(_ urls: [URL]) -> Int {
        var added = 0
        for url in urls where items.count < Self.capacity {
            guard !items.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }),
                  let bookmark = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                       includingResourceValuesForKeys: nil, relativeTo: nil) else {
                continue
            }
            let id = UUID()
            stored.append(Stored(id: id, bookmark: bookmark))
            activate(url, id: id)
            added += 1
        }
        if added > 0 {
            persist()
            onAdded?(added)
        }
        return added
    }

    func remove(_ item: ShelfItem) {
        release(item.id)
        items.removeAll { $0.id == item.id }
        stored.removeAll { $0.id == item.id }
        persist()
    }

    func removeAll() {
        items.forEach { release($0.id) }
        items = []
        stored = []
        persist()
    }

    func open(_ item: ShelfItem) {
        NSWorkspace.shared.open(item.url)
    }

    func reveal(_ item: ShelfItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func details(for item: ShelfItem) -> String {
        let values = try? item.url.resourceValues(forKeys: [.fileSizeKey, .localizedTypeDescriptionKey])
        let size = values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        return [values?.localizedTypeDescription, size].compactMap { $0 }.joined(separator: " · ")
    }

    private func activate(_ url: URL, id: UUID) {
        if url.startAccessingSecurityScopedResource() { scopedURLs[id] = url }
        items.append(ShelfItem(id: id, url: url))
    }

    private func release(_ id: UUID) {
        scopedURLs.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
    }

    private func restore() {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let saved = try? JSONDecoder().decode([Stored].self, from: data) else { return }

        for entry in saved {
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: entry.bookmark, options: .withSecurityScope,
                                     relativeTo: nil, bookmarkDataIsStale: &isStale),
                  FileManager.default.fileExists(atPath: url.path) else {
                continue
            }
            stored.append(entry)
            activate(url, id: entry.id)
        }
        if stored.count != saved.count { persist() }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
