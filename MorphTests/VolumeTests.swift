import Foundation
import Testing
@testable import Morph

private let speakers = AudioOutputDevice(id: 1, uid: "BuiltInSpeakerDevice", name: "Speakers", transport: .builtIn)
private let airPods = AudioOutputDevice(id: 2, uid: "AA-BB-CC-DD-EE-FF:output", name: "My AirPods Pro", transport: .bluetooth)
private let hdmi = AudioOutputDevice(id: 3, uid: "hdmi", name: "TV", transport: .hdmi)

private func state(_ device: AudioOutputDevice = speakers, volume: Float? = 0.5, muted: Bool? = false, settable: Bool = true) -> OutputState {
    OutputState(device: device, volume: volume, isMuted: muted, canSetVolume: settable, canMute: muted != nil)
}

@Suite("Output volume")
struct OutputDetectionTests {
    @Test func firstReadingIsNotAChange() {
        var detector = OutputChangeDetector()
        #expect(detector.process(state()).isEmpty)
    }

    @Test func volumeAndMuteChangesAreReported() {
        var detector = OutputChangeDetector()
        _ = detector.process(state(volume: 0.5))
        #expect(detector.process(state(volume: 0.5625)) == [.levelChanged(state(volume: 0.5625))])
        #expect(detector.process(state(volume: 0.5625, muted: true)) == [.levelChanged(state(volume: 0.5625, muted: true))])
    }

    @Test func driverJitterBelowOnePercentIsIgnored() {
        var detector = OutputChangeDetector()
        _ = detector.process(state(volume: 0.5))
        #expect(detector.process(state(volume: 0.5001)).isEmpty)
    }

    @Test func switchingDeviceIsNeverAVolumeChange() {
        var detector = OutputChangeDetector()
        _ = detector.process(state(volume: 0.2))
        #expect(detector.process(state(airPods, volume: 0.8)) == [.deviceChanged(airPods)])
    }

    @Test func outputsWithoutSoftwareVolumeNeverReportALevel() {
        var detector = OutputChangeDetector()
        _ = detector.process(state(hdmi, volume: nil, muted: nil, settable: false))
        #expect(detector.process(state(hdmi, volume: nil, muted: false, settable: false)).isEmpty)
        #expect(state(hdmi, volume: nil).percentage == nil)
    }

    @Test func wakingDoesNotCountAsAChange() {
        var detector = OutputChangeDetector()
        _ = detector.process(state(volume: 0.2))
        detector.resync()
        #expect(detector.process(state(volume: 0.9)).isEmpty)
    }

    @Test func bluetoothOutputsAppearAndDisappear() {
        var tracker = BluetoothOutputTracker()
        #expect(tracker.process([speakers, airPods]).isEmpty, "Already connected at launch")
        #expect(tracker.process([speakers]) == [.disconnected(airPods)])
        #expect(tracker.process([speakers, airPods]) == [.connected(airPods)])
        #expect(tracker.connected == [airPods])
    }

    @Test func wiredOutputsAreNotTracked() {
        var tracker = BluetoothOutputTracker()
        _ = tracker.process([speakers])
        #expect(tracker.process([speakers, hdmi]).isEmpty)
    }

    @Test func addressComesFromTheDeviceNotItsName() {
        #expect(airPods.bluetoothAddress == "AA:BB:CC:DD:EE:FF")
        #expect(speakers.bluetoothAddress == nil)
        #expect(airPods.symbol == "airpodspro")
    }

    @Test func iconFollowsTheLevel() {
        func symbol(_ percentage: Int, muted: Bool = false) -> String {
            IslandActivity.Content.outputVolume(percentage: percentage, muted: muted).symbol
        }
        #expect(symbol(50, muted: true) == "speaker.slash.fill")
        #expect(symbol(0) == "speaker.fill")
        #expect(symbol(20) == "speaker.wave.1.fill")
        #expect(symbol(50) == "speaker.wave.2.fill")
        #expect(symbol(90) == "speaker.wave.3.fill")
        #expect(IslandActivity.Content.outputVolume(percentage: 50, muted: true).level == 0)
    }

    @Test @MainActor func realCoreAudioOutputReadsAndStopsCleanly() async {
        let system = CoreAudioOutputSystem()
        let output = system.currentOutput()
        print("Output: \(output.map { "\($0.device.name), \($0.device.transport), \($0.percentage.map(String.init) ?? "no volume"), muted \(String(describing: $0.isMuted)), settable \($0.canSetVolume)" } ?? "none")")
        if let percentage = output?.percentage { #expect((0...100).contains(percentage)) }
        for device in system.outputDevices() { #expect(!device.uid.isEmpty) }
        system.startObserving {}
        system.stopObserving()
        system.stopObserving()
    }
}

@Suite("Volume service")
@MainActor
struct VolumeServiceTests {
    private let scheduler = ManualScheduler()
    private let system = StubOutputSystem()

    @Test func settingMovesTheRealOutputAndClamps() async {
        let service = VolumeService(system: system, scheduler: scheduler)
        service.apply(state(), devices: [])
        service.setVolume(1.4)
        #expect(service.output?.volume == 1)
        await waitUntil { !system.writes.isEmpty }
        #expect(system.writes == ["volume 1.0"])
    }

    @Test func outputsThatCantBeSetFallBack() {
        let service = VolumeService(system: system, scheduler: scheduler)
        service.apply(state(hdmi, volume: nil, muted: nil, settable: false), devices: [])
        #expect(!service.isControllable)
        #expect(service.adjustVolume(byPercent: 5) == false)
    }

    @Test func muteTogglesAgainstTheDevice() async {
        let service = VolumeService(system: system, scheduler: scheduler)
        service.apply(state(), devices: [])
        service.toggleMute()
        #expect(service.output?.effectivelyMuted == true)
        await waitUntil { !system.writes.isEmpty }
        #expect(system.writes == ["muted true"])
    }

    @Test func eventsReachTheCoordinatorInOrder() {
        let service = VolumeService(system: system, scheduler: scheduler)
        var events: [OutputEvent] = []
        var connections: [DeviceConnectionEvent] = []
        service.onOutputEvent = { events.append($0) }
        service.onConnectionEvent = { connections.append($0) }
        service.apply(state(), devices: [speakers])
        service.apply(state(airPods), devices: [speakers, airPods])
        #expect(connections == [.connected(airPods)])
        #expect(events == [.deviceChanged(airPods)])
    }

    @Test func stoppingStopsObserving() async {
        let service = VolumeService(system: system, scheduler: scheduler)
        service.start()
        #expect(system.isObserving)
        service.stop()
        await waitUntil { !system.isObserving }
        #expect(!system.isObserving)
        #expect(scheduler.pendingCount == 0)
    }
}

@Suite("Level activities")
@MainActor
struct LevelActivityTests {
    private let scheduler = ManualScheduler()

    @Test func rapidChangesUpdateOneActivityWithoutStacking() {
        let manager = ActivityManager(scheduler: scheduler)
        manager.present(.outputVolume(percentage: 10, muted: false))
        let id = manager.current?.id
        for level in stride(from: 16, through: 76, by: 6) {
            scheduler.advance(by: .milliseconds(90))
            manager.present(.outputVolume(percentage: level, muted: false))
        }
        #expect(manager.current?.id == id, "Same identity means no crossfade and no size change")
        #expect(manager.current?.content == .outputVolume(percentage: 76, muted: false))
        #expect(manager.pendingCount == 0)
        #expect(manager.recent.isEmpty)
    }

    @Test func volumeAndBrightnessShareOneSlot() {
        let manager = ActivityManager(scheduler: scheduler)
        manager.present(.outputVolume(percentage: 40, muted: false))
        manager.present(.brightness(increased: true, percentage: nil))
        #expect(manager.current?.content == .brightness(increased: true, percentage: nil))
        #expect(manager.pendingCount == 0)
    }

    @Test func priorityOrderMatchesTheSpecification() {
        func priority(_ content: IslandActivity.Content) -> ActivityPriority {
            IslandActivity(content, at: scheduler.now).priority
        }
        let external = ExternalActivity(id: "a", title: "A", symbol: "timer", state: .running, requestedPriority: .high, expiresAt: scheduler.now)
        let order = [priority(.batteryCritical(percentage: 3)),
                     priority(.trackSkipped(forward: true)),
                     priority(.outputVolume(percentage: 1, muted: false)),
                     priority(.screenshot(ScreenshotPreview(url: URL(fileURLWithPath: "/tmp/a.png")))),
                     priority(.timerCompleted(duration: 1)),
                     priority(.external(external)),
                     priority(.powerConnected(percentage: 50, charging: true)),
                     priority(.nowPlaying(title: "", artist: ""))]
        #expect(order == order.sorted(by: >))
        #expect(Set(order.map(\.rawValue)).count == order.count)
    }

    @Test func volumeDoesNotInterruptACriticalAlert() {
        let manager = ActivityManager(scheduler: scheduler)
        manager.present(.batteryCritical(percentage: 3))
        manager.present(.outputVolume(percentage: 40, muted: false))
        #expect(manager.current?.priority == .critical)
    }

    @Test func aFinishedTimerComesBackAfterVolume() {
        let manager = ActivityManager(scheduler: scheduler)
        manager.present(.timerCompleted(duration: 60))
        manager.present(.outputVolume(percentage: 40, muted: false))
        #expect(manager.current?.dedupeKey == "level")
        scheduler.advance(by: .milliseconds(1480))
        #expect(manager.current?.dedupeKey == "timer")
    }

    @Test func durationPreferenceScalesOnlyAutomaticActivities() {
        let manager = ActivityManager(scheduler: scheduler)
        manager.durationScale = 2
        manager.present(.filesAdded(count: 1))
        scheduler.advance(by: .seconds(3))
        #expect(manager.current != nil)
        scheduler.advance(by: .seconds(1))
        #expect(manager.current == nil)
    }
}
