import CoreGraphics
import Foundation
import Testing
@testable import Morph

@Suite("Activity rules")
@MainActor
struct ActivityRuleTests {
    private let scheduler = ManualScheduler()

    @Test func nothingButACriticalAlertAppearsDuringADrag() {
        let manager = ActivityManager(scheduler: scheduler)
        manager.setInteracting(true)
        manager.present(.timerCompleted(duration: 1))
        manager.present(.outputVolume(percentage: 40, muted: false))
        #expect(manager.current == nil)
        manager.present(.batteryCritical(percentage: 3))
        #expect(manager.current?.priority == .critical)
    }

    @Test func whatWaitedAppearsWhenTheDragEnds() {
        let manager = ActivityManager(scheduler: scheduler)
        manager.setInteracting(true)
        manager.present(.timerCompleted(duration: 1))
        manager.setInteracting(false)
        #expect(manager.current?.dedupeKey == "timer")
    }

    @Test func aDragLeavesWhatIsShowingAlone() {
        let manager = ActivityManager(scheduler: scheduler)
        manager.present(.batteryLow(percentage: 15))
        manager.setInteracting(true)
        #expect(manager.current != nil)
    }

    @Test func aLevelClosesOnceAfterAFastBurst() {
        let manager = ActivityManager(scheduler: scheduler)
        var seen = Set<UUID>()
        for step in 0..<40 {
            manager.present(.outputVolume(percentage: step, muted: false))
            seen.insert(manager.current!.id)
            scheduler.advance(by: .milliseconds(30))
        }
        #expect(seen.count == 1, "One activity for one continuous change")
        scheduler.advance(by: IslandActivity.levelHold)
        #expect(manager.current == nil)
    }

    @Test func eventsAreDeduplicatedWhileWaiting() {
        let manager = ActivityManager(scheduler: scheduler)
        manager.present(.batteryCritical(percentage: 3))
        for _ in 0..<5 { manager.present(.timerCompleted(duration: 1)) }
        #expect(manager.pendingCount == 1)
    }

    @Test func everyLevelIsTheSameShape() {
        let layout = IslandLayout(notch: CGSize(width: 179, height: 32), size: .regular)
        let contents: [IslandActivity.Content] = [
            .outputVolume(percentage: 0, muted: false), .outputVolume(percentage: 100, muted: false),
            .outputVolume(percentage: 40, muted: true), .brightness(increased: true, percentage: 50),
            .brightness(increased: false, percentage: nil), .volumeChanged(percentage: 10),
        ]
        let sizes = Set(contents.map { layout.islandSize(for: .activity(IslandActivity($0, at: scheduler.now))).debugDescription })
        #expect(sizes.count == 1, "Moving between them can't change the island's height")
    }

    @Test func anOutputWithoutSoftwareVolumeShowsNoLevel() {
        let device = AudioOutputDevice(id: 1, uid: "hdmi", name: "TV", transport: .hdmi)
        var detector = OutputChangeDetector()
        _ = detector.process(OutputState(device: device, volume: nil, isMuted: nil, canSetVolume: false, canMute: false))
        let events = detector.process(OutputState(device: device, volume: nil, isMuted: true, canSetVolume: false, canMute: false))
        #expect(events.isEmpty, "No value is ever invented for it")
    }

    @Test func limitsStayInRange() {
        #expect(IslandActivity.Content.outputVolume(percentage: 0, muted: false).level == 0)
        #expect(IslandActivity.Content.outputVolume(percentage: 100, muted: false).level == 1)
    }
}

@Suite("Island with new modules")
@MainActor
struct IslandModuleTests {
    private let scheduler = ManualScheduler()

    private func make() -> (IslandController, FocusService, LiveActivityStore, ActivityManager) {
        let preferences = MorphPreferences(defaults: makeDefaults())
        let activities = ActivityManager(scheduler: scheduler)
        let timers = TimerService(scheduler: scheduler)
        let media = MediaController(providers: [], events: StubMediaEvents(), scheduler: scheduler)
        let volume = VolumeService(system: StubOutputSystem(), scheduler: scheduler)
        let focus = FocusService(scheduler: scheduler, defaults: makeDefaults())
        let store = LiveActivityStore(scheduler: scheduler)
        let island = IslandController(preferences: preferences, activities: activities, timers: timers, media: media,
                                      volume: volume, scheduler: scheduler, focus: focus, external: store)
        return (island, focus, store, activities)
    }

    @Test func aRunningSessionShowsBesideTheNotch() {
        let (island, focus, _, _) = make()
        focus.startFocus()
        #expect(island.presentation == .live(.focus))
        focus.pause()
        #expect(island.presentation == .live(.focus), "Paused is still a session")
        focus.stop()
        #expect(island.presentation == .idle)
    }

    @Test func anExternalActivityShowsOnlyWhileOpen() throws {
        let (island, _, store, _) = make()
        #expect(!island.availableTabs.contains(.activities))
        _ = try store.create(LiveActivityPayload(json: Data(#"{"id":"a","title":"A"}"#.utf8)))
        #expect(island.presentation == .live(.external))
        #expect(island.availableTabs.contains(.activities))
        try store.end(id: "a")
        #expect(island.presentation == .idle)
    }

    @Test func aDraggedControlHoldsActivitiesBack() {
        let (island, _, _, activities) = make()
        island.send(.clicked)
        island.send(.interactionBegan)
        activities.present(.timerCompleted(duration: 1))
        #expect(activities.current == nil)
        island.send(.interactionEnded)
        #expect(activities.current != nil)
    }

    @Test func clickingAScreenshotDoesNotLoseIt() {
        let (island, _, _, activities) = make()
        activities.present(.screenshot(ScreenshotPreview(url: URL(fileURLWithPath: "/tmp/a.png"))))
        island.handleClick()
        #expect(activities.current != nil)
        #expect(!island.mode.isExpanded)
    }
}

@Suite("Seeking")
@MainActor
struct SeekTests {
    private let scheduler = ManualScheduler()
    private let provider = StubMediaProvider(.appleMusic)

    private func started() async -> MediaController {
        provider.playback = .success(provider.snapshot(.paused))
        let controller = MediaController(providers: [provider], events: StubMediaEvents(), scheduler: scheduler)
        controller.start()
        await controller.refresh()
        return controller
    }

    @Test func thePositionMovesAtOnceAndOneCommandIsSent() async {
        let controller = await started()
        controller.seek(to: 120)
        #expect(controller.snapshot?.position == 120)
        await waitUntil { !provider.commands.isEmpty }
        #expect(provider.commands == ["seek 120.0"])
    }

    @Test func theRealStateWinsAfterTheCommand() async {
        let controller = await started()
        controller.seek(to: 120)
        await waitUntil { !provider.commands.isEmpty }
        var real = provider.snapshot(.paused)
        real.position = 118
        provider.playback = .success(real)
        await controller.refresh()
        #expect(controller.snapshot?.position == 118)
    }

    @Test func anOldRefreshCannotUndoASeek() async {
        let controller = await started()
        controller.requestRefresh()
        controller.seek(to: 120)
        scheduler.advance(by: .milliseconds(200))
        #expect(controller.snapshot?.position == 120)
    }

    @Test func aFailedSeekIsCorrected() async {
        let controller = await started()
        provider.commandResult = .failure(.timedOut)
        var failure: String?
        controller.onCommandFailed = { failure = $0 }
        controller.seek(to: 120)
        await waitUntil { failure != nil }
        #expect(failure?.contains("respond") == true)
        scheduler.advance(by: .milliseconds(150))
        await waitUntil { controller.snapshot?.position == 10 }
        #expect(controller.snapshot?.position == 10)
    }

    @Test func whatHasNoTimelineCannotSeek() async {
        var stream = provider.snapshot(.playing)
        stream.track?.duration = nil
        #expect(!stream.canSeek)
        var unknown = provider.snapshot(.playing)
        unknown.position = nil
        #expect(!unknown.canSeek)
        #expect(provider.snapshot(.playing).canSeek)

        provider.playback = .success(stream)
        let controller = MediaController(providers: [provider], events: StubMediaEvents(), scheduler: scheduler)
        controller.start()
        await controller.refresh()
        controller.seek(to: 10)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(provider.commands.isEmpty)
    }
}

@Suite("Artwork palette")
struct PaletteTests {
    private func pixels(_ colors: [(UInt8, UInt8, UInt8)], each: Int) -> [UInt8] {
        colors.flatMap { color in (0..<each).flatMap { _ in [color.0, color.1, color.2, 255] } }
    }

    @Test func twoColorsAreBothFound() throws {
        let palette = try #require(ArtworkPalette.palette(rgba: pixels([(220, 40, 40), (40, 80, 220)], each: 50)))
        #expect(palette.secondary != nil)
        #expect(palette.primary.red > palette.primary.blue || palette.primary.blue > palette.primary.red)
    }

    @Test func oneColorHasNoSecond() throws {
        let palette = try #require(ArtworkPalette.palette(rgba: pixels([(220, 40, 40)], each: 100)))
        #expect(palette.secondary == nil)
    }

    @Test func greyHasNoPalette() {
        #expect(ArtworkPalette.palette(rgba: pixels([(120, 120, 120)], each: 100)) == nil)
    }

    @Test func colorsStayReadableAgainstBlack() throws {
        let palette = try #require(ArtworkPalette.palette(rgba: pixels([(60, 0, 0)], each: 100)))
        #expect(max(palette.primary.red, palette.primary.green, palette.primary.blue) >= 0.6)
    }
}

@Suite("Battery Universe")
struct PowerDeviceTests {
    private let airpods = AudioOutputDevice(id: 2, uid: "AA-BB-CC-DD-EE-FF:output", name: "AirPods Pro", transport: .bluetooth)
    private let mac = BatterySnapshot(percentage: 80, isCharging: false, isOnExternalPower: false, isCharged: false)

    private func list(audio: [AudioOutputDevice] = [], output: String? = nil, peripherals: [PeripheralReading] = [],
                      showsAudio: Bool = true, showsPeripherals: Bool = true) -> [PowerDevice] {
        PowerDevice.list(mac: mac, audio: audio, currentOutputUID: output, peripherals: peripherals,
                         showsAudio: showsAudio, showsPeripherals: showsPeripherals)
    }

    @Test func theMacComesFirst() {
        #expect(list(audio: [airpods]).map(\.name) == ["This Mac", "AirPods Pro"])
    }

    @Test func aDeviceWithoutAReadingHasNoInventedValue() {
        let row = list(audio: [airpods], output: airpods.uid)[1]
        #expect(row.percentage == nil)
        #expect(row.isCharging == nil)
        #expect(row.status == "Connected, audio output")
    }

    @Test func aReadingForThatExactNameIsUsed() {
        let row = list(audio: [airpods], peripherals: [PeripheralReading(name: "AirPods Pro", percentage: 62, isCharging: false)])
        #expect(row.count == 2, "One device, one row")
        #expect(row[1].percentage == 62)
    }

    @Test func aSimilarNameIsNotMatched() {
        let row = list(audio: [airpods], peripherals: [PeripheralReading(name: "AirPods Pro 2", percentage: 62, isCharging: nil)])
        #expect(row[1].percentage == nil)
        #expect(row.count == 3)
    }

    @Test func kindsFollowTheName() {
        #expect(PowerDevice.kind(named: "Magic Keyboard") == .keyboard)
        #expect(PowerDevice.kind(named: "Magic Mouse") == .mouse)
        #expect(PowerDevice.kind(named: "Magic Trackpad") == .trackpad)
        #expect(PowerDevice.kind(named: "Pencil") == .other)
    }

    @Test func preferencesHideGroups() {
        let peripherals = [PeripheralReading(name: "Magic Mouse", percentage: 50, isCharging: nil)]
        #expect(list(audio: [airpods], peripherals: peripherals, showsAudio: false).map(\.name) == ["This Mac", "Magic Mouse"])
        #expect(list(audio: [airpods], peripherals: peripherals, showsPeripherals: false).map(\.name) == ["This Mac", "AirPods Pro"])
    }

    @Test func aPowerSourceBeatsTheRegistryForTheSameName() {
        let merged = SystemPeripheralInventory.merged(
            powerSources: [PeripheralReading(name: "Mouse", percentage: 40, isCharging: true)],
            registry: [PeripheralReading(name: "Mouse", percentage: 41, isCharging: nil),
                       PeripheralReading(name: "Keyboard", percentage: 90, isCharging: nil)])
        #expect(merged.map(\.percentage) == [40, 90])
    }

    @Test func theRealInventoryReadsInsideTheSandbox() {
        // Whatever is connected, this mustn't crash or claim impossible values.
        for reading in SystemPeripheralInventory().read() {
            #expect(reading.percentage.map { (0...100).contains($0) } ?? true)
        }
    }

    @Test func lowAlertsFireOncePerDischarge() {
        var tracker = PeripheralAlertTracker()
        let low = PeripheralReading(name: "Mouse", percentage: 15, isCharging: false)
        #expect(tracker.process([low], threshold: 20) == [low])
        #expect(tracker.process([low], threshold: 20).isEmpty)
        #expect(tracker.process([PeripheralReading(name: "Mouse", percentage: 60, isCharging: true)], threshold: 20).isEmpty)
        #expect(tracker.process([low], threshold: 20) == [low])
    }

    @Test func noReadingNeverAlerts() {
        var tracker = PeripheralAlertTracker()
        #expect(tracker.process([PeripheralReading(name: "Mouse", percentage: nil, isCharging: nil)], threshold: 20).isEmpty)
    }
}

@Suite("Device battery service")
@MainActor
struct DeviceBatteryServiceTests {
    private let scheduler = ManualScheduler()
    private let reader = StubPeripherals()

    private func started() async -> DeviceBatteryService {
        let service = DeviceBatteryService(reader: reader, scheduler: scheduler)
        service.start()
        await waitUntil { reader.readCount == 1 }
        return service
    }

    @Test func nothingTicksUnlessSomethingNeedsIt() async {
        _ = await started()
        #expect(scheduler.pendingCount == 0, "No polling at rest")
    }

    @Test func thePanelTicksOnlyWhileVisible() async {
        let service = await started()
        service.isVisible = true
        #expect(scheduler.pendingCount == 1)
        service.isVisible = false
        #expect(scheduler.pendingCount == 0)
    }

    @Test func openingThePanelRepeatedlyDoesNotHammerTheSystem() async {
        let service = await started()
        for _ in 0..<10 {
            service.isVisible = true
            service.isVisible = false
        }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(reader.readCount == 1)
    }

    @Test func aConnectionAlwaysReads() async {
        let service = await started()
        service.refresh(force: true)
        await waitUntil { reader.readCount == 2 }
        #expect(reader.readCount == 2)
    }

    @Test func stoppingEndsTheTicking() async {
        let service = await started()
        service.alertsEnabled = true
        #expect(scheduler.pendingCount == 1)
        service.stop()
        #expect(scheduler.pendingCount == 0)
    }
}

@Suite("New preferences")
@MainActor
struct NewPreferenceTests {
    @Test func theAPIAndScreenshotsAreOffByDefault() {
        let preferences = MorphPreferences(defaults: makeDefaults())
        #expect(!preferences.liveAPIEnabled)
        #expect(!preferences.screenshotPreviews)
        #expect(preferences.screenshotFolder == nil)
        #expect(preferences.liveAPIPort == MorphPreferences.defaultLiveAPIPort)
    }

    @Test func oldSettingsSurviveTheUpdate() {
        let defaults = makeDefaults()
        defaults.set("mint", forKey: "accent")
        defaults.set(true, forKey: "replaceVolumeHUD")
        let preferences = MorphPreferences(defaults: defaults)
        #expect(preferences.accent == .mint)
        #expect(preferences.replaceVolumeHUD)
    }

    @Test func newSettingsPersistAndAreClamped() {
        let defaults = makeDefaults()
        let first = MorphPreferences(defaults: defaults)
        first.focusMinutes = 50
        first.screenshotFolder = Data([1])
        defaults.set(99_999, forKey: "liveAPIPort")
        defaults.set(0, forKey: "shortBreakMinutes")
        let second = MorphPreferences(defaults: defaults)
        #expect(second.focusMinutes == 50)
        #expect(second.screenshotFolder == Data([1]))
        #expect(second.liveAPIPort == 65_535)
        #expect(second.shortBreakMinutes == 1)
        first.screenshotFolder = nil
        #expect(MorphPreferences(defaults: defaults).screenshotFolder == nil)
    }
}
