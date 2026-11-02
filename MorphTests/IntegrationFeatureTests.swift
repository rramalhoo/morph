import IOKit.ps
import AppKit
import Foundation
import Testing
@testable import Morph

@Suite("Gestures")
struct GestureTests {
    private func gesture(_ recognizer: inout IslandGestureRecognizer, dx: CGFloat = 0, dy: CGFloat = 0, steps: Int = 8,
                         start: TimeInterval = 100, duration: TimeInterval = 0.2) -> [IslandGestureRecognizer.Command] {
        var commands = recognizer.process(ScrollInput(deltaX: 0, deltaY: 0, phase: .began, isPrecise: true, time: start))
        for step in 1...steps {
            commands += recognizer.process(ScrollInput(deltaX: dx / CGFloat(steps), deltaY: dy / CGFloat(steps), phase: .changed,
                                                       isPrecise: true, time: start + duration * Double(step) / Double(steps)))
        }
        commands += recognizer.process(ScrollInput(deltaX: 0, deltaY: 0, phase: .ended, isPrecise: true, time: start + duration))
        return commands
    }

    @Test func swipeDirectionsMatchTheSpecification() {
        var recognizer = IslandGestureRecognizer()
        #expect(gesture(&recognizer, dx: 120) == [.next])
        #expect(gesture(&recognizer, dx: -120, start: 200) == [.previous])
    }

    @Test func aLongSwipeFiresOnlyOnce() {
        var recognizer = IslandGestureRecognizer()
        #expect(gesture(&recognizer, dx: 900, steps: 40, duration: 0.6) == [.next])
    }

    @Test func momentumAfterLiftingDoesNothing() {
        var recognizer = IslandGestureRecognizer()
        _ = gesture(&recognizer, dx: 120)
        for index in 0..<30 {
            let input = ScrollInput(deltaX: 40, deltaY: 0, phase: .momentum, isPrecise: true, time: 100.2 + Double(index) * 0.016)
            #expect(recognizer.process(input).isEmpty)
        }
    }

    @Test func aQuickSecondSwipeWaitsOutTheCooldown() {
        var recognizer = IslandGestureRecognizer()
        #expect(gesture(&recognizer, dx: 120, duration: 0.1) == [.next])
        #expect(gesture(&recognizer, dx: 120, start: 100.15, duration: 0.1).isEmpty)
        #expect(gesture(&recognizer, dx: 120, start: 101, duration: 0.1) == [.next])
    }

    @Test func slowOrShortMovementIsNotASwipe() {
        var recognizer = IslandGestureRecognizer()
        #expect(gesture(&recognizer, dx: 40).isEmpty, "Too short")
        #expect(gesture(&recognizer, dx: 100, start: 200, duration: 2).isEmpty, "Too slow")
    }

    @Test func aDiagonalDoesNothing() {
        var recognizer = IslandGestureRecognizer()
        #expect(gesture(&recognizer, dx: 100, dy: 100).isEmpty)
    }

    @Test func verticalAdjustsVolumeContinuouslyAndAddsUp() {
        var recognizer = IslandGestureRecognizer()
        let commands = gesture(&recognizer, dy: 80)
        let total = commands.reduce(0) { sum, command in
            if case .volume(let step) = command { return sum + step }
            return sum
        }
        #expect(total == 20)
        #expect(commands.count > 1)
    }

    @Test func eachDirectionCanBeTurnedOff() {
        var recognizer = IslandGestureRecognizer()
        recognizer.horizontalEnabled = false
        #expect(gesture(&recognizer, dx: 120).isEmpty)
        recognizer.verticalEnabled = false
        #expect(gesture(&recognizer, dy: 80, start: 200).isEmpty)
    }

    @Test func sensitivityMovesTheThreshold() {
        var recognizer = IslandGestureRecognizer()
        recognizer.sensitivity = 2
        #expect(gesture(&recognizer, dx: 40) == [.next])
    }

    @Test func aMouseWheelStillWorks() {
        var recognizer = IslandGestureRecognizer()
        let up = ScrollInput(deltaX: 0, deltaY: 3, phase: .discrete, isPrecise: false, time: 1)
        #expect(recognizer.process(up) == [.volume(6)])
        let tilt = ScrollInput(deltaX: 1, deltaY: 0, phase: .discrete, isPrecise: false, time: 2)
        #expect(recognizer.process(tilt) == [.next])
        #expect(recognizer.process(tilt).isEmpty, "Held tilt repeats, and must not skip tracks")
    }
}

@Suite("Cinema mode")
struct CinemaTests {
    /// Measured on a 13" MacBook Air: menu bar 33pt, Dock at the bottom.
    private let display = DisplayArea(bounds: CGRect(x: 0, y: 0, width: 1470, height: 956),
                                      usable: CGRect(x: 0, y: 33, width: 1470, height: 838))
    /// The same Mac with no Dock on this display.
    private let dockless = DisplayArea(bounds: CGRect(x: 0, y: 0, width: 1470, height: 956),
                                       usable: CGRect(x: 0, y: 33, width: 1470, height: 923))
    /// A real full screen window on that Mac, below the camera housing.
    private let belowNotch = CGRect(x: 0, y: 33, width: 1470, height: 923)
    /// What the green button's zoom gives with the Dock visible.
    private let maximized = CGRect(x: 0, y: 33, width: 1470, height: 838)

    private func window(_ pid: pid_t = 10, layer: Int = 0, bounds: CGRect) -> WindowSample {
        WindowSample(ownerPID: pid, layer: layer, bounds: bounds, alpha: 1)
    }

    private func evidence(_ windows: [WindowSample], on area: DisplayArea? = nil, frontmost: pid_t? = 10) -> FullscreenEvidence {
        FullscreenDetector.evaluate(windows: windows, display: area ?? display, frontmostPID: frontmost, ownPID: 1)
    }

    @Test func fullScreenBelowTheNotchIsRecognized() {
        // The real sample also includes a 32pt title bar strip, which must not confuse it.
        #expect(evidence([window(bounds: CGRect(x: 0, y: 33, width: 1470, height: 32)), window(bounds: belowNotch)]) == .fullscreen)
    }

    @Test func aWindowOverTheWholeDisplayIsFullScreen() {
        #expect(evidence([window(bounds: display.bounds)]) == .fullscreen)
    }

    @Test func aMaximizedWindowIsNot() {
        #expect(evidence([window(bounds: maximized)]) == .none)
    }

    @Test func withNoDockTheSameShapeIsOnlyUncertain() {
        #expect(evidence([window(bounds: belowNotch)], on: dockless) == .uncertain)
    }

    @Test func anotherDisplaysFullScreenIsIgnored() {
        #expect(evidence([window(bounds: CGRect(x: 1470, y: 0, width: 1920, height: 1080))]) == .none)
    }

    @Test func morphsOwnWindowsNeverCount() {
        #expect(evidence([window(1, bounds: display.bounds)], frontmost: 1) == .none)
    }

    @Test func aFullScreenWindowFromABackgroundAppIsUncertain() {
        #expect(evidence([window(20, bounds: belowNotch)]) == .uncertain)
    }

    @Test func systemChromeAboveNormalWindowsIsIgnored() {
        #expect(evidence([window(30, layer: 20, bounds: display.bounds)]) == .none, "The Dock owns windows like this")
    }

    @Test func aFrontmostAppDrawingAboveTheNormalLayerIsUncertain() {
        #expect(evidence([window(layer: 25, bounds: display.bounds)]) == .uncertain)
    }

    @Test func clearEvidenceOutranksAnUncertainWindowListedFirst() {
        #expect(evidence([window(20, bounds: belowNotch), window(bounds: belowNotch)]) == .fullscreen)
    }

    @Test func invisibleWindowsDoNotCount() {
        var clear = window(bounds: display.bounds)
        clear.alpha = 0
        #expect(evidence([clear]) == .none)
    }

    @Test func modesResolveAsConfigured() {
        func state(_ mode: CinemaMode, _ action: CinemaAction = .hide, _ evidence: FullscreenEvidence = .fullscreen,
                   uncertain: CinemaUncertainBehavior = .stayVisible) -> CinemaState {
            FullscreenDetector.resolve(mode: mode, action: action, uncertain: uncertain, evidence: evidence)
        }
        #expect(state(.normal) == .normal)
        #expect(state(.compact) == .compact)
        #expect(state(.hidden) == .hidden)
        #expect(state(.automatic, .hide) == .hidden)
        #expect(state(.automatic, .compact) == .compact)
        #expect(state(.automatic, .hide, .none) == .normal, "Leaving full screen restores the island")
        #expect(state(.automatic, .hide, .uncertain) == .normal)
        #expect(state(.automatic, .hide, .uncertain, uncertain: .compact) == .compact)
        #expect(state(.automatic, .hide, .uncertain, uncertain: .hide) == .hidden)
    }

    @Test func thisMacsWindowListIsReadableInTheSandbox() {
        #expect(!SystemWindowList().onScreenWindows().isEmpty)
    }
}

@Suite("Cinema and activities")
@MainActor
struct CinemaIslandTests {
    private let scheduler = ManualScheduler()
    private let preferences = MorphPreferences(defaults: makeDefaults())

    private func island() -> (IslandController, ActivityManager, TimerService) {
        let activities = ActivityManager(scheduler: scheduler)
        let timers = TimerService(scheduler: scheduler)
        let media = MediaController(providers: [], events: StubMediaEvents(), scheduler: scheduler)
        let volume = VolumeService(system: StubOutputSystem(), scheduler: scheduler)
        return (IslandController(preferences: preferences, activities: activities, timers: timers, media: media,
                                 volume: volume, scheduler: scheduler), activities, timers)
    }

    @Test func compactSilencesEverythingButSeriousAlerts() {
        let (subject, activities, timers) = island()
        timers.startCountdown(.seconds(60))
        subject.update(cinema: .compact)
        #expect(subject.presentation == .idle)
        activities.present(.outputVolume(percentage: 40, muted: false))
        #expect(subject.presentation == .idle)
        activities.present(.batteryLow(percentage: 10))
        #expect(subject.presentation == .activity(activities.current!))
    }

    @Test func compactDisablesHover() {
        let (subject, _, _) = island()
        subject.update(cinema: .compact)
        subject.send(.pointerEntered)
        scheduler.advance(by: .seconds(1))
        #expect(subject.mode == .idle)
    }

    @Test func hiddenStaysOffScreenExceptForACriticalAlert() {
        let (subject, activities, _) = island()
        subject.update(cinema: .hidden)
        #expect(!subject.shouldShowPanel)
        activities.present(.batteryCritical(percentage: 3))
        #expect(subject.shouldShowPanel)
        subject.update(cinema: .normal)
        activities.removeAll()
        #expect(subject.shouldShowPanel)
    }

    @Test func gesturesDriveTheOutputAndStopForSliders() async {
        let (subject, _, _) = island()
        subject.send(.interactionBegan)
        subject.handleScroll(ScrollInput(deltaX: 200, deltaY: 0, phase: .began, isPrecise: true, time: 1))
        subject.handleScroll(ScrollInput(deltaX: 200, deltaY: 0, phase: .changed, isPrecise: true, time: 1.1))
        subject.send(.interactionEnded)
        subject.handleScroll(ScrollInput(deltaX: 0, deltaY: 0, phase: .began, isPrecise: true, time: 2))
        #expect(subject.mode == .idle)
    }
}

@Suite("Artwork colors")
@MainActor
struct ArtworkColorTests {
    private func pixels(_ colors: [(UInt8, UInt8, UInt8)], each count: Int) -> [UInt8] {
        colors.flatMap { color in (0..<count).flatMap { _ in [color.0, color.1, color.2, 255] } }
    }

    private func solidPNG(red: CGFloat, green: CGFloat, blue: CGFloat) -> Data? {
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context?.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return context?.makeImage().flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
    }

    @Test func theStrongestHueWinsOverAveragingToMud() throws {
        let image = pixels([(220, 30, 30), (20, 20, 20), (240, 240, 240)], each: 100)
        let color = try #require(ArtworkPalette.dominantColor(rgba: image))
        #expect(color.red > color.green * 1.5)
        #expect(color.red > color.blue * 1.5)
    }

    @Test func monochromeCoversGetNoGlow() {
        #expect(ArtworkPalette.dominantColor(rgba: pixels([(20, 20, 20), (240, 240, 240)], each: 100)) == nil)
    }

    @Test func aTinyAccentIsNotTheCoverColor() {
        #expect(ArtworkPalette.dominantColor(rgba: pixels([(0, 0, 0)], each: 500) + pixels([(250, 20, 20)], each: 5)) == nil)
    }

    @Test func vividCoversAreCalmedDown() throws {
        let color = try #require(ArtworkPalette.dominantColor(rgba: pixels([(0, 255, 0)], each: 100)))
        #expect(color.red > 0.15, "Saturation is capped")
        #expect(color.green <= 0.86, "Brightness is capped")
    }

    @Test func realImageDataDecodes() throws {
        let data = try #require(solidPNG(red: 0.1, green: 0.3, blue: 0.9))
        let color = try #require(ArtworkPalette.dominantColor(in: data))
        #expect(color.blue > color.red)
    }

    @Test func eachCoverIsAnalyzedOnceAndCached() async {
        let service = AmbientColorService()
        let data = solidPNG(red: 0.9, green: 0.1, blue: 0.1)!
        service.update(key: "a", artwork: data)
        await waitUntil { service.color != nil }
        let first = service.color
        #expect(first != nil)
        service.update(key: nil, artwork: nil)
        #expect(service.color == nil)
        service.update(key: "a", artwork: Data())
        #expect(service.color == first, "Served from the cache without touching the image")
    }
}

@Suite("Peripheral battery")
struct PeripheralBatteryTests {
    private func source(_ name: String, _ capacity: Int) -> [String: Any] {
        [kIOPSNameKey: name, kIOPSTypeKey: "Accessory Source", kIOPSCurrentCapacityKey: capacity, kIOPSMaxCapacityKey: 100]
    }

    @Test func anExactMatchIsUsed() {
        #expect(PowerSourcePeripheralReader.match([source("My AirPods", 82)], name: "My AirPods") == 82)
    }

    @Test func anotherDevicesBatteryIsNeverUsed() {
        #expect(PowerSourcePeripheralReader.match([source("Magic Mouse", 40)], name: "My AirPods") == nil)
    }

    @Test func ambiguityMeansUnknown() {
        #expect(PowerSourcePeripheralReader.match([source("AirPods", 82), source("AirPods", 30)], name: "AirPods") == nil)
    }

    @Test func theMacsOwnBatteryIsNeverUsed() {
        let own: [String: Any] = [kIOPSNameKey: "AirPods", kIOPSTypeKey: kIOPSInternalBatteryType,
                                  kIOPSCurrentCapacityKey: 99, kIOPSMaxCapacityKey: 100]
        #expect(PowerSourcePeripheralReader.match([own], name: "AirPods") == nil)
    }

    @Test func unknownBatteryMakesNoClaim() {
        #expect(IslandActivity.Content.deviceConnected(name: "AirPods", symbol: "airpods", battery: nil).subtitle == nil)
        #expect(IslandActivity.Content.deviceConnected(name: "AirPods", symbol: "airpods", battery: 82).subtitle == "Battery 82%")
    }
}
