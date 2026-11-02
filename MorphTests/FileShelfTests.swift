import Foundation
import Testing
@testable import Morph

@Suite("File shelf")
@MainActor
struct FileShelfTests {
    private func temporaryFile(_ name: String = "note.txt") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data("hello".utf8).write(to: url)
        return url
    }

    @Test func keepsAReferenceNotACopyAndSurvivesARelaunch() throws {
        let defaults = makeDefaults()
        let url = try temporaryFile()
        let shelf = FileShelfStore(defaults: defaults)
        var reported = 0
        shelf.onAdded = { reported = $0 }
        #expect(shelf.add([url]) == 1)
        #expect(reported == 1)
        #expect(shelf.items.first?.url == url)

        let restored = FileShelfStore(defaults: defaults)
        #expect(restored.items.map(\.name) == ["note.txt"])
    }

    @Test func ignoresDuplicates() throws {
        let url = try temporaryFile()
        let shelf = FileShelfStore(defaults: makeDefaults())
        shelf.add([url])
        #expect(shelf.add([url]) == 0)
        #expect(shelf.items.count == 1)
    }

    @Test func removalPersists() throws {
        let defaults = makeDefaults()
        let shelf = FileShelfStore(defaults: defaults)
        shelf.add([try temporaryFile()])
        shelf.remove(shelf.items[0])
        #expect(FileShelfStore(defaults: defaults).items.isEmpty)
    }

    @Test func deletedFilesDropOutOnRestore() throws {
        let defaults = makeDefaults()
        let url = try temporaryFile()
        FileShelfStore(defaults: defaults).add([url])
        try FileManager.default.removeItem(at: url)
        #expect(FileShelfStore(defaults: defaults).items.isEmpty)
    }
}
