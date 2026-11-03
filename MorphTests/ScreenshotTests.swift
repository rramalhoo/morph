import AppKit
import Foundation
import Testing
@testable import Morph

@Suite("Screenshot detection")
struct ScreenshotDetectorTests {
    private func entry(_ name: String, _ capture: Bool = true) -> ScreenshotFolderEntry {
        ScreenshotFolderEntry(name: name, isScreenCapture: capture)
    }

    @Test func whatWasAlreadyThereIsNeverNew() {
        var detector = ScreenshotDetector()
        #expect(detector.process([entry("old.png")]) == nil)
        #expect(detector.process([entry("old.png")]) == nil)
    }

    @Test func aNewCaptureIsFound() {
        var detector = ScreenshotDetector()
        _ = detector.process([])
        #expect(detector.process([entry("Captura de Tela.png")])?.name == "Captura de Tela.png", "No filename assumptions")
    }

    @Test func otherImagesAreIgnored() {
        var detector = ScreenshotDetector()
        _ = detector.process([])
        #expect(detector.process([entry("photo.png", false), entry("Screenshot lookalike.png", false)]) == nil)
    }

    @Test func hiddenFilesInProgressAreIgnoredUntilRenamed() {
        var detector = ScreenshotDetector()
        _ = detector.process([])
        #expect(detector.process([entry(".Screenshot.png")]) == nil)
        #expect(detector.process([entry("Screenshot.png")])?.name == "Screenshot.png")
    }

    @Test func aBurstShowsOnce() {
        var detector = ScreenshotDetector()
        _ = detector.process([])
        #expect(detector.process([entry("a.png"), entry("b.png")])?.name == "b.png")
        #expect(detector.process([entry("a.png"), entry("b.png")]) == nil)
    }
}

/// Real files, a real `DispatchSource` and the real attribute.
@Suite("Screenshot service", .serialized)
@MainActor
struct ScreenshotServiceTests {
    private let scheduler = SystemScheduler()
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("morph-\(UUID().uuidString)")

    private func makeImage(_ name: String, marked: Bool) throws {
        let image = NSImage(size: CGSize(width: 40, height: 30), flipped: false) { rect in
            NSColor.systemPink.setFill()
            rect.fill()
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let data = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        // Written under a hidden name and renamed, as macOS does.
        let temporary = folder.appendingPathComponent(".\(name)")
        try data.write(to: temporary)
        if marked {
            var value = Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74, 0x30, 0x30, 0x09, 0x08, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1,
                              0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9])
            let result = value.withUnsafeMutableBytes {
                setxattr(temporary.path, "com.apple.metadata:kMDItemIsScreenCapture", $0.baseAddress, $0.count, 0, 0)
            }
            try #require(result == 0)
        }
        try FileManager.default.moveItem(at: temporary, to: folder.appendingPathComponent(name))
    }

    private func subject() throws -> ScreenshotService {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return ScreenshotService(scheduler: scheduler)
    }

    @Test func aRealScreenshotFileBecomesAPreview() async throws {
        let service = try subject()
        defer { service.stop(); try? FileManager.default.removeItem(at: folder) }
        var captured: ScreenshotPreview?
        service.onCaptured = { captured = $0 }
        #expect(service.watch(folder))
        try await Task.sleep(for: .milliseconds(100))

        try makeImage("Captura de Tela 2026.png", marked: true)
        await waitUntil { captured != nil }
        #expect(captured?.name == "Captura de Tela 2026.png")
        #expect(service.thumbnail != nil)
        #expect(service.status == .watching(folder.lastPathComponent))
    }

    @Test func anImageWithoutTheMarkIsLeftAlone() async throws {
        let service = try subject()
        defer { service.stop(); try? FileManager.default.removeItem(at: folder) }
        var captured: ScreenshotPreview?
        service.onCaptured = { captured = $0 }
        service.watch(folder)
        try await Task.sleep(for: .milliseconds(100))
        try makeImage("photo.png", marked: false)
        try await Task.sleep(for: .milliseconds(500))
        #expect(captured == nil)
    }

    @Test func nothingShowsWhileLockedAndThePreviewGoesAway() async throws {
        let service = try subject()
        defer { service.stop(); try? FileManager.default.removeItem(at: folder) }
        var count = 0
        service.onCaptured = { _ in count += 1 }
        service.watch(folder)
        try await Task.sleep(for: .milliseconds(100))
        try makeImage("one.png", marked: true)
        await waitUntil { count == 1 }

        service.setSessionActive(false)
        #expect(service.current == nil)
        #expect(service.thumbnail == nil, "The image is gone from memory, not only hidden")
        try makeImage("two.png", marked: true)
        try await Task.sleep(for: .milliseconds(500))
        #expect(count == 1)

        service.setSessionActive(true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(count == 1, "A capture from while locked isn't shown after unlocking")
    }

    @Test func offMeansNoWatcher() {
        let service = ScreenshotService(scheduler: scheduler)
        service.apply(enabled: false, bookmark: nil)
        #expect(service.status == .off)
        service.apply(enabled: true, bookmark: nil)
        #expect(service.status == .needsFolder, "No folder is assumed, not even the Desktop")
        service.apply(enabled: true, bookmark: Data([1, 2, 3]))
        #expect(service.status == .folderUnavailable)
    }

    @Test func theMarkOnARealScreenshotIsRecognizedIfOneExists() throws {
        // Only meaningful where a screenshot exists: documents that the attribute is the real one.
        let desktop = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
        let files = (try? FileManager.default.contentsOfDirectory(at: desktop, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "png" && file.lastPathComponent.hasPrefix("Screenshot") {
            #expect(ScreenshotService.isScreenCapture(file))
        }
    }
}

@Suite("Screenshot activity")
@MainActor
struct ScreenshotActivityTests {
    private let scheduler = ManualScheduler()
    private let preview = ScreenshotPreview(url: URL(fileURLWithPath: "/tmp/a.png"))

    @Test func itStaysWhileThePointerIsOnIt() {
        let manager = ActivityManager(scheduler: scheduler)
        var isInside = true
        manager.shouldExtend = { _ in isInside }
        manager.present(.screenshot(preview), duration: .seconds(6))
        scheduler.advance(by: .seconds(30))
        #expect(manager.current != nil)
        isInside = false
        scheduler.advance(by: .seconds(1))
        #expect(manager.current == nil)
    }

    @Test func durationFollowsThePreferenceNotActivityScale() {
        let manager = ActivityManager(scheduler: scheduler)
        manager.durationScale = 1.6
        manager.present(.screenshot(preview), duration: .seconds(6))
        scheduler.advance(by: .seconds(6))
        #expect(manager.current == nil)
    }

    @Test func aVolumeKeyInterruptsItAndItComesBack() {
        let manager = ActivityManager(scheduler: scheduler)
        manager.present(.screenshot(preview), duration: .seconds(6))
        manager.present(.outputVolume(percentage: 40, muted: false))
        #expect(manager.current?.presentation == .level)
        scheduler.advance(by: IslandActivity.levelHold)
        #expect(manager.current?.presentation == .screenshot)
    }

    @Test func itNeverEntersTheRecentList() {
        let manager = ActivityManager(scheduler: scheduler)
        manager.present(.screenshot(preview))
        #expect(manager.recent.isEmpty, "No history by default")
    }
}
