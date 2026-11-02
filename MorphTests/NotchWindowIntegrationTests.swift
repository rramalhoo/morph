import AppKit
import SwiftUI
import Testing
@testable import Morph

/// Everything the island needs, wired as the app wires it but with stubbed media and manual time.
@MainActor
private struct Fixture {
    let scheduler = ManualScheduler()
    let preferences = MorphPreferences(defaults: makeDefaults())
    let shelf = FileShelfStore(defaults: makeDefaults())
    let battery = BatteryService(reader: FixedBattery())
    let provider = StubMediaProvider(.appleMusic)
    let activities: ActivityManager
    let timers: TimerService
    let media: MediaController
    let output = StubOutputSystem()
    let volume: VolumeService
    let levelKeys: LevelKeyService
    let capture = StubAudioCapture()
    let waveform: WaveformService
    let ambient = AmbientColorService()
    let island: IslandController

    init() {
        activities = ActivityManager(scheduler: scheduler)
        timers = TimerService(scheduler: scheduler)
        media = MediaController(providers: [provider], events: StubMediaEvents(), scheduler: scheduler)
        volume = VolumeService(system: output, scheduler: scheduler)
        let brightness = DisplayServicesBrightness()
        levelKeys = LevelKeyService(tap: SystemLevelKeyTap(), permission: SystemAccessibilityPermission(),
                                    engine: LevelKeyEngine(output: output, brightness: brightness),
                                    brightness: brightness, scheduler: scheduler)
        waveform = WaveformService(capture: capture, scheduler: scheduler)
        island = IslandController(preferences: preferences, activities: activities, timers: timers,
                                  media: media, volume: volume, scheduler: scheduler)
        battery.refresh()
    }

    var view: some View {
        IslandRootView(onOpenSettings: {}, onPause: {}, onQuit: {})
            .environment(island)
            .environment(preferences)
            .environment(media)
            .environment(volume)
            .environment(waveform)
            .environment(ambient)
            .environment(battery)
            .environment(timers)
            .environment(activities)
            .environment(shelf)
    }
}

private struct FixedBattery: PowerSourceReading {
    func read() -> BatterySnapshot? {
        BatterySnapshot(percentage: 85, isCharging: true, isOnExternalPower: true, isCharged: false,
                        minutesToEmpty: nil, minutesToFull: 48)
    }
}

/// Real panels compete for key focus and screen position, so nothing in here may overlap.
@Suite("Real windows", .serialized)
@MainActor
struct RealWindowTests {}

extension RealWindowTests {
/// Runs against the real `NSPanel` on this Mac's real screens.
@Suite("Notch window")
@MainActor
struct NotchWindowIntegrationTests {
    private func panels() -> [IslandPanel] {
        NSApp.windows.compactMap { $0 as? IslandPanel }.filter(\.isVisible)
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(700))
    }

    @Test func panelFollowsTheIslandAndTearsDownCleanly() async throws {
        let fixture = Fixture()
        let controller = NotchWindowController(island: fixture.island, preferences: fixture.preferences, shelf: fixture.shelf) {
            fixture.view
        }
        controller.show()
        defer { controller.hide() }
        await settle()

        let panel = try #require(panels().last)
        let geometry = try #require(fixture.island.geometry)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.level == .statusBar)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(!panel.canBecomeKey)
        let idle = geometry.panelFrame(for: fixture.island.layout.panelSize(for: .idle))
        #expect(panel.frame == idle, "Idle: only the housing is covered")

        fixture.island.send(.clicked)
        await settle()
        let expanded = geometry.panelFrame(for: fixture.island.layout.panelSize(for: .expanded(.home)))
        #expect(panel.frame == expanded)
        #expect(panel.frame.maxY == geometry.screenFrame.maxY)

        // A pointer panel never takes key focus from the active app.
        #expect(!panel.isKeyWindow)

        fixture.island.send(.escapePressed)
        await settle()
        #expect(panel.frame == idle)
    }

    @Test func repeatedExpansionEndsAtRestWithTheRightFrame() async throws {
        let fixture = Fixture()
        let controller = NotchWindowController(island: fixture.island, preferences: fixture.preferences, shelf: fixture.shelf) {
            fixture.view
        }
        controller.show()
        defer { controller.hide() }
        await settle()

        let panel = try #require(panels().last)
        let geometry = try #require(fixture.island.geometry)
        for _ in 0..<25 {
            fixture.island.send(.clicked)
            await Task.yield()
            fixture.island.send(.escapePressed)
            await Task.yield()
        }
        await settle()
        #expect(panel.frame == geometry.panelFrame(for: fixture.island.layout.panelSize(for: .idle)))
    }

    @Test func fullscreenPreferenceChangesCollectionBehavior() async throws {
        let fixture = Fixture()
        let controller = NotchWindowController(island: fixture.island, preferences: fixture.preferences, shelf: fixture.shelf) {
            fixture.view
        }
        controller.show()
        defer { controller.hide() }
        await settle()

        let panel = try #require(panels().last)
        #expect(!panel.collectionBehavior.contains(.fullScreenAuxiliary))
        fixture.preferences.cinemaMode = .normal
        await settle()
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    @Test func calibrationMovesTheLivePanel() async throws {
        let fixture = Fixture()
        let controller = NotchWindowController(island: fixture.island, preferences: fixture.preferences, shelf: fixture.shelf) {
            fixture.view
        }
        controller.show()
        defer { controller.hide() }
        await settle()

        let panel = try #require(panels().last)
        let before = panel.frame
        fixture.preferences.calibration = NotchCalibration(offsetX: 6)
        await settle()
        #expect(panel.frame.minX == before.minX + 6)
    }

    /// No window of any app can become key while the session is locked.
    @Test(.enabled(if: !sessionIsLocked)) func keyboardOpenTakesKeyAndEscapeReleasesIt() async throws {
        let fixture = Fixture()
        let controller = NotchWindowController(island: fixture.island, preferences: fixture.preferences, shelf: fixture.shelf) {
            fixture.view
        }
        controller.show()
        defer { controller.hide() }
        await settle()

        let panel = try #require(panels().last)
        fixture.island.toggleFromMenu()
        await settle()
        withKnownIssue("Another app can hold focus on a Mac in use", isIntermittent: true) {
            #expect(panel.isKeyWindow)
        }
        panel.cancelOperation(nil)
        await settle()
        #expect(fixture.island.mode == .idle)
        #expect(!panel.isKeyWindow)
    }

    @Test func hideRemovesThePanel() async {
        let fixture = Fixture()
        let controller = NotchWindowController(island: fixture.island, preferences: fixture.preferences, shelf: fixture.shelf) {
            fixture.view
        }
        let before = panels().count
        controller.show()
        await settle()
        #expect(panels().count == before + 1)
        controller.hide()
        #expect(panels().count == before)
    }
}

/// Real `NSEvent`s through `NSPanel.sendEvent`, so AppKit and SwiftUI hit testing both take part.
/// Nothing leaves the process, which is why this needs no Accessibility permission.
@Suite("Island interaction")
@MainActor
struct IslandInteractionTests {
    private func showPanel(_ fixture: Fixture) async throws -> (NotchWindowController, IslandPanel) {
        let controller = NotchWindowController(island: fixture.island, preferences: fixture.preferences, shelf: fixture.shelf) {
            fixture.view
        }
        controller.show()
        try? await Task.sleep(for: .milliseconds(300))
        let visible = NSApp.windows.compactMap { $0 as? IslandPanel }.filter(\.isVisible)
        let panel = try #require(visible.last)
        return (controller, panel)
    }

    /// `point` is measured from the panel's top-left corner.
    private func click(_ panel: IslandPanel, at point: CGPoint) async {
        let location = CGPoint(x: point.x, y: panel.frame.height - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            panel.sendEvent(event)
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(650))
    }

    @Test func clickingTheIslandOpensItAndClickingATabSwitchesIt() async throws {
        let fixture = Fixture()
        let (controller, panel) = try await showPanel(fixture)
        defer { controller.hide() }

        await click(panel, at: CGPoint(x: panel.frame.width / 2, y: 16))
        await settle()
        #expect(fixture.island.mode == .expanded(.pointer))
        #expect(!panel.isKeyWindow, "A pointer click must not take focus")

        // Tabs start at the left edge of the header: inset 14 + padding 8, then 28pt buttons 4pt apart.
        await click(panel, at: CGPoint(x: 22 + 28 + 4 + 14, y: 16))
        await settle()
        #expect(fixture.island.presentation == .expanded(.timers))
    }

    @Test func clickDisabledLeavesTheIslandClosed() async throws {
        let fixture = Fixture()
        fixture.preferences.clickToExpand = false
        let (controller, panel) = try await showPanel(fixture)
        defer { controller.hide() }
        await click(panel, at: CGPoint(x: panel.frame.width / 2, y: 16))
        await settle()
        #expect(fixture.island.mode == .idle)
    }

    @Test func aTimerPresetClickStartsARealCountdown() async throws {
        let fixture = Fixture()
        fixture.island.showTab(.timers)
        let (controller, panel) = try await showPanel(fixture)
        defer { controller.hide() }
        fixture.island.send(.clicked)
        await settle()

        // First preset: card inset 22, card padding 12, near the bottom of the card.
        await click(panel, at: CGPoint(x: 22 + 12 + 14, y: panel.frame.height - 12 - 12 - 12))
        await settle()
        #expect(fixture.timers.countdown.isRunning)
    }

    @Test(.enabled(if: !sessionIsLocked)) func keysReachThePanelOnlyAsCommands() async throws {
        let fixture = Fixture()
        let (controller, panel) = try await showPanel(fixture)
        defer { controller.hide() }
        // Opened by click: keyboard mode closes on focus loss, and on a Mac in use another app has focus.
        fixture.island.send(.clicked)
        await settle()

        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: panel.windowNumber, context: nil, characters: "",
                                     charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124)!
        panel.keyDown(with: event)
        #expect(fixture.island.presentation == .expanded(.timers))
    }

    @Test func trackingCoversTheWholePanelAfterItGrows() async throws {
        let fixture = Fixture()
        let (controller, panel) = try await showPanel(fixture)
        defer { controller.hide() }
        let container = try #require(panel.contentView as? IslandContainerView)
        fixture.island.send(.clicked)
        await settle()

        let areas = container.trackingAreas.filter { $0.options.contains(.mouseEnteredAndExited) }
        let area = try #require(areas.first)
        #expect(area.options.contains(.activeAlways))
        #expect(area.options.contains(.inVisibleRect))
        #expect(container.bounds.size == panel.frame.size)

        // The pointer callbacks are what the tracking area drives.
        container.onPointerExited?()
        #expect(fixture.island.mode == .expanded(.pointer))
    }

    @Test func scrollFallsThroughSwiftUIToTheContainerAndChangesVolume() async throws {
        let fixture = Fixture()
        var snapshot = fixture.provider.snapshot(.playing)
        snapshot.volume = 50
        fixture.provider.playback = .success(snapshot)
        fixture.media.start()
        await fixture.media.refresh()

        let (controller, panel) = try await showPanel(fixture)
        defer { controller.hide() }
        let container = try #require(panel.contentView as? IslandContainerView)
        let hosting = try #require(container.subviews.first)

        let cgEvent = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0))
        cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cgEvent.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 40)
        let event = try #require(NSEvent(cgEvent: cgEvent))
        hosting.scrollWheel(with: event)

        let expected = event.isDirectionInvertedFromDevice ? 40 : 60
        #expect(fixture.media.snapshot?.volume == expected)
        fixture.media.stop()
    }

    @Test func droppingAFileGoesThroughTheWindowWiring() async throws {
        let fixture = Fixture()
        let (controller, panel) = try await showPanel(fixture)
        defer { controller.hide() }
        let container = try #require(panel.contentView as? IslandContainerView)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        container.onDragEntered?()
        #expect(fixture.island.presentation == .expanded(.shelf))
        #expect(container.onDrop?([url]) == true)
        #expect(fixture.shelf.items.map(\.url) == [url])
    }
}

/// Puts every settings screen in a real window. A missing environment object is a runtime crash
/// in SwiftUI, so reaching the end of this test is the assertion.
@Suite("Settings")
@MainActor
struct SettingsScreenTests {
    @Test func everyScreenRendersInAWindow() async {
        let fixture = Fixture()
        let launchAtLogin = LaunchAtLoginService()

        func host(_ content: some View) async {
            let root = content
                .environment(fixture.island)
                .environment(fixture.preferences)
                .environment(fixture.media)
                .environment(fixture.volume)
                .environment(fixture.levelKeys)
                .environment(fixture.waveform)
                .environment(fixture.battery)
                .environment(launchAtLogin)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: root)
            window.orderBack(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(150))
            window.orderOut(nil)
        }

        await host(SettingsRootView(diagnostics: { "report" }))
        await host(GeneralSettingsView())
        await host(AppearanceSettingsView())
        await host(BehaviorSettingsView())
        await host(ModulesSettingsView())
        await host(MusicSettingsView())
        await host(DevicesSettingsView())
        await host(SystemSettingsView())
        await host(AdvancedSettingsView(diagnostics: { "report" }))
    }
}

@Suite("System bridges")
@MainActor
struct SystemBridgeTests {
    /// Exercises the real Automation API under the real sandbox. `ask: false` never shows a prompt.
    @Test func automationProbeAnswersWithoutPrompting() async {
        let probe = WorkspaceApplicationProbe()
        let access = await Task.detached { probe.automationAccess(to: MediaProviderKind.appleMusic.bundleIdentifier, ask: false) }.value
        print("Automation access to Music: \(access)")
        #expect(probe.isInstalled(MediaProviderKind.appleMusic.bundleIdentifier))
        #expect(access != .notInstalled)
    }

    @Test func distributedNotificationsReachTheEventSource() async {
        let events = SystemMediaEvents()
        defer { events.stop() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var finished = false
            events.start {
                guard !finished else { return }
                finished = true
                continuation.resume()
            }
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name(MediaProviderKind.spotify.changeNotification),
                object: nil, userInfo: nil, deliverImmediately: true
            )
        }
    }
}

/// Renders each state to PNG so the design can be reviewed without a screen capture.
/// Set `MORPH_SNAPSHOT_DIR` on the test run to write them out; otherwise this only proves they render.
@Suite("Rendering")
@MainActor
struct RenderingTests {
    @Test func everyPresentationRenders() async throws {
        let fixture = Fixture()
        fixture.provider.playback = .success(PlaybackSnapshot(
            provider: .appleMusic, state: .playing,
            track: Track(id: "1", title: "Teardrop", artist: "Massive Attack", album: "Mezzanine", duration: 330),
            position: 96, capturedAt: .now, volume: 60
        ))
        let speakers = AudioOutputDevice(id: 1, uid: "built-in", name: "MacBook Air Speakers", transport: .builtIn)
        fixture.volume.apply(OutputState(device: speakers, volume: 0.68, isMuted: false, canSetVolume: true, canMute: true), devices: [speakers])

        let context = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.85, green: 0.3, blue: 0.45, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let cover = try #require(context.makeImage().flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) })
        fixture.provider.artworkResult = .success(cover)
        fixture.island.update(geometry: NotchGeometry.resolve(ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
            visibleFrame: CGRect(x: 0, y: 85, width: 1470, height: 838), safeAreaTop: 32,
            auxiliaryTopLeft: CGRect(x: 0, y: 924, width: 645.5, height: 32),
            auxiliaryTopRight: CGRect(x: 824.5, y: 924, width: 645.5, height: 32), scale: 2
        )))
        fixture.media.start()
        await fixture.media.refresh()
        await waitUntil { fixture.media.artwork != nil }
        fixture.ambient.update(key: "1", artwork: fixture.media.artwork)
        await waitUntil { fixture.ambient.color != nil }

        func render(_ name: String) throws {
            let renderer = ImageRenderer(content: fixture.view.frame(width: IslandLayout.canvas.width, height: IslandLayout.canvas.height)
                .background(Color(red: 0.25, green: 0.3, blue: 0.4)))
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            #expect(image.width == Int(IslandLayout.canvas.width * 2))
            guard let directory = ProcessInfo.processInfo.environment["MORPH_SNAPSHOT_DIR"] else { return }
            let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            try data?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }

        try render("live-media")
        fixture.waveform.update(demand: WaveformDemand(bundleIdentifier: "x", outputUID: "y", trackID: "1"))
        for _ in 0..<5 { await Task.yield() }
        fixture.capture.onLevels?([0.45, 0.7, 1, 0.6, 0.3], true)
        await waitUntil { fixture.waveform.showsRealLevels }
        try render("live-waveform")
        fixture.island.send(.pointerEntered)
        fixture.scheduler.advance(by: .milliseconds(80))
        try render("hover-media")
        fixture.activities.present(.outputVolume(percentage: 68, muted: false))
        try render("hover-volume")
        fixture.activities.dismissCurrent()
        fixture.island.send(.clicked)
        try render("expanded-home-media")
        fixture.island.showTab(.timers)
        fixture.timers.startCountdown(.seconds(300))
        fixture.timers.startStopwatch()
        try render("expanded-timers")
        fixture.activities.present(.brightness(increased: true, percentage: 63))
        try render("expanded-with-level")
        fixture.activities.dismissCurrent()
        fixture.island.showTab(.shelf)
        try render("expanded-shelf-empty")
        fixture.island.send(.escapePressed)
        try render("live-timer")
        fixture.activities.present(.powerConnected(percentage: 85, charging: true))
        try render("activity-minimal")
        fixture.activities.dismissCurrent()
        fixture.activities.present(.outputVolume(percentage: 68, muted: false))
        try render("activity-volume")
        fixture.activities.dismissCurrent()
        fixture.activities.present(.outputVolume(percentage: 0, muted: true))
        try render("activity-volume-muted")
        fixture.activities.dismissCurrent()
        fixture.activities.present(.brightness(increased: true, percentage: 63))
        try render("activity-brightness")
        fixture.activities.dismissCurrent()
        fixture.activities.present(.brightness(increased: true, percentage: nil))
        try render("activity-brightness-direction")
        fixture.activities.dismissCurrent()
        fixture.activities.present(.deviceConnected(name: "AirPods Pro", symbol: "airpodspro", battery: nil))
        try render("activity-airpods")
        fixture.activities.dismissCurrent()
        fixture.activities.present(.batteryLow(percentage: 12))
        try render("activity-banner")
        fixture.activities.dismissCurrent()
        fixture.activities.present(.timerCompleted(duration: 300))
        try render("activity-acknowledge")
        fixture.activities.removeAll()
        fixture.timers.stopAll()
        fixture.media.stop()
        fixture.island.send(.openRequested)
        fixture.island.showTab(.home)
        try render("expanded-home-recent")
    }
}
}
