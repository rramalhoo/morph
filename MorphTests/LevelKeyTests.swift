import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Morph

/// An output that behaves like a driver: writes change what reads return, unless told otherwise.
private final class ControlledOutput: AudioOutputSystem, @unchecked Sendable {
    var state: OutputState?
    var rejectsWrites = false
    var ignoresWrites = false
    /// Writes land only after this many reads, like a slow Bluetooth driver.
    var readsBeforeLanding = 0
    var quantize: (Float) -> Float = { $0 }
    private(set) var writeCount = 0
    private var landing: Float?
    private var reads = 0

    init(volume: Float?, muted: Bool = false, canSet: Bool = true, canMute: Bool = true, id: UInt32 = 1) {
        state = OutputState(device: AudioOutputDevice(id: id, uid: "\(id)", name: "Speakers", transport: .builtIn),
                            volume: volume, isMuted: muted, canSetVolume: canSet, canMute: canMute)
    }

    func currentOutput() -> OutputState? {
        if let landing {
            reads += 1
            if reads > readsBeforeLanding {
                state?.volume = landing
                self.landing = nil
            }
        }
        return state
    }

    func outputDevices() -> [AudioOutputDevice] { [] }

    func setVolume(_ volume: Float, device: UInt32) -> Bool {
        writeCount += 1
        guard !rejectsWrites else { return false }
        guard !ignoresWrites else { return true }
        if readsBeforeLanding > 0 {
            landing = quantize(volume)
            reads = 0
        } else {
            state?.volume = quantize(volume)
        }
        return true
    }

    func setMuted(_ muted: Bool, device: UInt32) -> Bool {
        writeCount += 1
        guard !rejectsWrites else { return false }
        if !ignoresWrites { state?.isMuted = muted }
        return true
    }

    func startObserving(onChange: @escaping @Sendable () -> Void) {}
    func stopObserving() {}
}

private final class ControlledBrightness: BrightnessControlling, @unchecked Sendable {
    var value: Float?
    var supported = true
    var ownsPointer = true
    var rejectsWrites = false
    var ignoresWrites = false
    private(set) var writeCount = 0

    init(_ value: Float? = 0.5) { self.value = value }

    var isSupported: Bool { supported }
    func canControl(pointer: CGPoint) -> Bool { supported && ownsPointer }
    func read() -> Float? { value }

    func write(_ value: Float) -> Bool {
        writeCount += 1
        guard !rejectsWrites else { return false }
        if !ignoresWrites { self.value = value }
        return true
    }
}

private final class ControlledTap: LevelKeyTapping, @unchecked Sendable {
    var accepts = true
    private(set) var installCount = 0
    private(set) var removeCount = 0
    private(set) var handler: Handler?
    private(set) var onFailure: (@Sendable () -> Void)?

    var isInstalled: Bool { handler != nil }

    func install(handler: @escaping Handler, onFailure: @escaping @Sendable () -> Void) -> Bool {
        installCount += 1
        guard accepts else { return false }
        self.handler = handler
        self.onFailure = onFailure
        return true
    }

    func remove() {
        removeCount += 1
        handler = nil
    }

    @discardableResult
    func press(_ key: LevelKey, isDown: Bool = true) -> Bool {
        handler?(LevelKeyPress(key: key, isDown: isDown), .none, .zero) ?? false
    }
}

private final class ControlledPermission: AccessibilityPermission, @unchecked Sendable {
    var isTrusted: Bool
    private(set) var requestCount = 0

    init(_ isTrusted: Bool) { self.isTrusted = isTrusted }
    func request() { requestCount += 1 }
}

private let step = LevelKeyEngine.standardStep

@Suite struct LevelKeyParsingTests {
    private func event(key: Int, state: Int) -> Int { key << 16 | state << 8 }

    @Test func readsEveryLevelKey() {
        let cases: [(Int, LevelKey)] = [(0, .volumeUp), (1, .volumeDown), (7, .mute), (2, .brightnessUp), (3, .brightnessDown)]
        for (code, key) in cases {
            #expect(LevelKeyPress(subtype: 8, data1: event(key: code, state: 0xA)) == LevelKeyPress(key: key))
            #expect(LevelKeyPress(subtype: 8, data1: event(key: code, state: 0xB)) == LevelKeyPress(key: key, isDown: false))
        }
    }

    @Test func leavesOtherSystemKeysAlone() {
        for code in [16, 17, 19, 20, 21, 22] {
            #expect(LevelKeyPress(subtype: 8, data1: event(key: code, state: 0xA)) == nil, "Key \(code)")
        }
    }

    /// The path a real event takes, off the main thread as it does on the tap's thread.
    @Test func decodesARealSystemDefinedEvent() async throws {
        let original = try #require(NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                                       windowNumber: 0, context: nil, subtype: 8,
                                                       data1: event(key: 1, state: 0xA), data2: -1))
        let cgEvent = try #require(original.cgEvent)
        nonisolated(unsafe) let unsafeEvent = cgEvent
        let press = await Task.detached { () -> LevelKeyPress? in
            guard let system = NSEvent(cgEvent: unsafeEvent), system.type == .systemDefined else { return nil }
            return LevelKeyPress(subtype: system.subtype.rawValue, data1: system.data1)
        }.value
        #expect(press == LevelKeyPress(key: .volumeDown))
    }
}

@Suite struct LevelKeyEngineTests {
    private func engine(_ output: ControlledOutput = ControlledOutput(volume: 0.5),
                        _ brightness: ControlledBrightness = ControlledBrightness(),
                        policy: LevelKeyPolicy = LevelKeyPolicy(volume: true, brightness: true)) -> LevelKeyEngine {
        var engine = LevelKeyEngine(output: output, brightness: brightness, settle: {})
        engine.policy = policy
        return engine
    }

    private func press(_ engine: inout LevelKeyEngine, _ key: LevelKey, _ modifiers: LevelKeyModifiers = .none) -> LevelKeyDecision {
        engine.handle(LevelKeyPress(key: key), modifiers: modifiers, pointer: .zero)
    }

    @Test func volumeUpChangesTheRealValueBeforeConsuming() {
        let output = ControlledOutput(volume: 0.5)
        var subject = engine(output)
        #expect(press(&subject, .volumeUp) == .consume(.volume(percentage: 56, muted: false)))
        #expect(output.state?.volume == 0.5 + step)
    }

    @Test func volumeDownChangesTheRealValueBeforeConsuming() {
        let output = ControlledOutput(volume: 0.5)
        var subject = engine(output)
        #expect(press(&subject, .volumeDown) == .consume(.volume(percentage: 44, muted: false)))
        #expect(output.state?.volume == 0.5 - step)
    }

    @Test func stepsLandOnTheSameGridAsTheSystem() {
        let output = ControlledOutput(volume: 0.44)
        var subject = engine(output)
        _ = press(&subject, .volumeUp)
        #expect(output.state?.volume == 0.5)
    }

    @Test func fineStepsWithShiftAndOption() {
        let output = ControlledOutput(volume: 0.5)
        var subject = engine(output)
        _ = press(&subject, .volumeUp, LevelKeyModifiers(shift: true, option: true))
        #expect(output.state?.volume == 0.5 + LevelKeyEngine.fineStep)
    }

    @Test func muteTogglesBothWaysAndKeepsTheLevel() {
        let output = ControlledOutput(volume: 0.5)
        var subject = engine(output)
        #expect(press(&subject, .mute) == .consume(.volume(percentage: 50, muted: true)))
        #expect(output.state?.isMuted == true)
        #expect(press(&subject, .mute) == .consume(.volume(percentage: 50, muted: false)))
        #expect(output.state?.volume == 0.5)
    }

    @Test func raisingTheVolumeUnmutes() {
        let output = ControlledOutput(volume: 0.5, muted: true)
        var subject = engine(output)
        #expect(press(&subject, .volumeUp) == .consume(.volume(percentage: 56, muted: false)))
    }

    @Test func reachingZeroMutes() {
        let output = ControlledOutput(volume: step)
        var subject = engine(output)
        #expect(press(&subject, .volumeDown) == .consume(.volume(percentage: 0, muted: true)))
        #expect(output.state?.isMuted == true)
    }

    @Test func zeroIsAValidLimitAndStillAnswers() {
        let output = ControlledOutput(volume: 0, muted: true)
        var subject = engine(output)
        #expect(press(&subject, .volumeDown) == .consume(.volume(percentage: 0, muted: true)))
        #expect(output.writeCount == 0)
    }

    @Test func maximumIsAValidLimitAndStillAnswers() {
        let output = ControlledOutput(volume: 1)
        var subject = engine(output)
        #expect(press(&subject, .volumeUp) == .consume(.volume(percentage: 100, muted: false)))
        #expect(output.writeCount == 0)
    }

    @Test func tenRapidPressesEachMoveOneStep() {
        let output = ControlledOutput(volume: 0.25)
        var subject = engine(output)
        let results = (0..<10).map { _ in press(&subject, .volumeUp) }
        #expect(results.allSatisfy { if case .consume = $0 { true } else { false } })
        #expect(output.state?.volume == 0.25 + 10 * step)
    }

    @Test func aQuantizingDeviceStillStepsEvenly() {
        let output = ControlledOutput(volume: 0.5)
        output.quantize = { ($0 * 20).rounded(.down) / 20 }
        var subject = engine(output)
        for _ in 0..<4 { _ = press(&subject, .volumeUp) }
        #expect(output.state?.volume == 0.75, "Stepping from read-backs alone would fall behind")
    }

    @Test func aSlowDriverIsGivenAMoment() {
        let output = ControlledOutput(volume: 0.5)
        output.readsBeforeLanding = 1
        var subject = engine(output)
        #expect(press(&subject, .volumeUp) == .consume(.volume(percentage: 56, muted: false)))
    }

    @Test func anExternalChangeIsFollowed() {
        let output = ControlledOutput(volume: 0.5)
        var subject = engine(output)
        _ = press(&subject, .volumeUp)
        output.state?.volume = 0.25
        _ = press(&subject, .volumeUp)
        #expect(output.state?.volume == 0.25 + step)
    }

    // MARK: - Falling back

    @Test func aRefusedWriteReleasesTheKeyAndStopsIntercepting() {
        let output = ControlledOutput(volume: 0.5)
        output.rejectsWrites = true
        var subject = engine(output)
        #expect(press(&subject, .volumeUp) == .handBack(isBrightness: false))
        #expect(output.writeCount == 1)
        #expect(press(&subject, .volumeUp) == .pass, "Doesn't keep trying")
        #expect(output.writeCount == 1)
    }

    @Test func aWriteThatChangesNothingReleasesTheKey() {
        let output = ControlledOutput(volume: 0.5)
        output.ignoresWrites = true
        var subject = engine(output)
        #expect(press(&subject, .volumeDown) == .handBack(isBrightness: false))
    }

    @Test func aMuteThatDoesNotTakeReleasesTheKey() {
        let output = ControlledOutput(volume: 0.5)
        output.ignoresWrites = true
        var subject = engine(output)
        #expect(press(&subject, .mute) == .handBack(isBrightness: false))
    }

    @Test func anotherOutputGetsAFreshStart() {
        let output = ControlledOutput(volume: 0.5)
        output.rejectsWrites = true
        var subject = engine(output)
        _ = press(&subject, .volumeUp)
        output.rejectsWrites = false
        #expect(press(&subject, .volumeUp) == .pass)
        subject.clearOutputRejection()
        #expect(press(&subject, .volumeUp) == .consume(.volume(percentage: 56, muted: false)))
    }

    @Test func aRejectionOnlyCoversThatDevice() {
        let output = ControlledOutput(volume: 0.5, id: 1)
        output.rejectsWrites = true
        var subject = engine(output)
        _ = press(&subject, .volumeUp)
        output.rejectsWrites = false
        output.state?.device = AudioOutputDevice(id: 2, uid: "2", name: "AirPods", transport: .bluetooth)
        #expect(press(&subject, .volumeUp) == .consume(.volume(percentage: 56, muted: false)))
    }

    @Test func anOutputWithoutSoftwareVolumeStaysWithMacOS() {
        let output = ControlledOutput(volume: nil, canSet: false, canMute: false)
        var subject = engine(output)
        #expect(press(&subject, .volumeUp) == .pass)
        #expect(press(&subject, .mute) == .pass)
        #expect(output.writeCount == 0)
    }

    @Test func aReadOnlyVolumeStaysWithMacOS() {
        var subject = engine(ControlledOutput(volume: 0.5, canSet: false))
        #expect(press(&subject, .volumeUp) == .pass)
    }

    @Test func combinationsWithTheirOwnMeaningStayWithMacOS() {
        let output = ControlledOutput(volume: 0.5)
        var subject = engine(output)
        #expect(press(&subject, .volumeUp, LevelKeyModifiers(option: true)) == .pass, "Opens Sound settings")
        #expect(press(&subject, .volumeUp, LevelKeyModifiers(commandOrControl: true)) == .pass)
        #expect(output.writeCount == 0)
    }

    @Test func aDisabledPolicyTouchesNothing() {
        let (output, brightness) = (ControlledOutput(volume: 0.5), ControlledBrightness())
        var subject = engine(output, brightness, policy: .off)
        for key in [LevelKey.volumeUp, .volumeDown, .mute, .brightnessUp, .brightnessDown] {
            #expect(press(&subject, key) == .pass)
        }
        #expect(output.writeCount == 0)
        #expect(brightness.writeCount == 0)
    }

    @Test func thePoliciesAreIndependent() {
        var volumeOnly = engine(policy: LevelKeyPolicy(volume: true))
        #expect(press(&volumeOnly, .brightnessUp) == .pass)
        var brightnessOnly = engine(policy: LevelKeyPolicy(brightness: true))
        #expect(press(&brightnessOnly, .volumeUp) == .pass)
    }

    @Test func aKeyUpFollowsItsKeyDown() {
        var subject = engine()
        _ = press(&subject, .volumeUp)
        #expect(subject.handle(LevelKeyPress(key: .volumeUp, isDown: false), modifiers: .none, pointer: .zero) == .consume(nil))
        #expect(subject.handle(LevelKeyPress(key: .volumeUp, isDown: false), modifiers: .none, pointer: .zero) == .pass)
    }

    @Test func aKeyMacOSReceivedKeepsItsKeyUp() {
        var subject = engine(policy: .off)
        _ = press(&subject, .volumeUp)
        #expect(subject.handle(LevelKeyPress(key: .volumeUp, isDown: false), modifiers: .none, pointer: .zero) == .pass)
    }

    // MARK: - Brightness

    @Test func brightnessUpAndDownChangeTheRealValue() {
        let brightness = ControlledBrightness(0.5)
        var subject = engine(ControlledOutput(volume: 0.5), brightness)
        #expect(press(&subject, .brightnessUp) == .consume(.brightness(percentage: 56, increased: true)))
        #expect(press(&subject, .brightnessDown) == .consume(.brightness(percentage: 50, increased: false)))
        #expect(brightness.value == 0.5)
    }

    @Test func brightnessLimitsAreValidAndStillAnswer() {
        let low = ControlledBrightness(0)
        var subject = engine(ControlledOutput(volume: 0.5), low)
        #expect(press(&subject, .brightnessDown) == .consume(.brightness(percentage: 0, increased: false)))
        #expect(low.writeCount == 0)

        let high = ControlledBrightness(1)
        var other = engine(ControlledOutput(volume: 0.5), high)
        #expect(press(&other, .brightnessUp) == .consume(.brightness(percentage: 100, increased: true)))
        #expect(high.writeCount == 0)
    }

    @Test func anUnsupportedDisplayStaysWithMacOS() {
        let brightness = ControlledBrightness()
        brightness.supported = false
        var subject = engine(ControlledOutput(volume: 0.5), brightness)
        #expect(press(&subject, .brightnessUp) == .pass)
        #expect(brightness.writeCount == 0)
    }

    @Test func aDisplayMacOSControlsItselfKeepsItsKeys() {
        let brightness = ControlledBrightness()
        brightness.ownsPointer = false
        var subject = engine(ControlledOutput(volume: 0.5), brightness)
        #expect(press(&subject, .brightnessDown) == .pass)
    }

    @Test func aRefusedBrightnessReleasesTheKeyUntilDisplaysChange() {
        let brightness = ControlledBrightness()
        brightness.rejectsWrites = true
        var subject = engine(ControlledOutput(volume: 0.5), brightness)
        #expect(press(&subject, .brightnessUp) == .handBack(isBrightness: true))
        brightness.rejectsWrites = false
        #expect(press(&subject, .brightnessUp) == .pass)
        subject.clearBrightnessRejection()
        #expect(press(&subject, .brightnessUp) == .consume(.brightness(percentage: 56, increased: true)))
    }

    @Test func anIgnoredBrightnessWriteReleasesTheKey() {
        let brightness = ControlledBrightness()
        brightness.ignoresWrites = true
        var subject = engine(ControlledOutput(volume: 0.5), brightness)
        #expect(press(&subject, .brightnessDown) == .handBack(isBrightness: true))
    }

    @Test func anUnreadableBrightnessReleasesTheKey() {
        var subject = engine(ControlledOutput(volume: 0.5), ControlledBrightness(nil))
        #expect(press(&subject, .brightnessUp) == .handBack(isBrightness: true))
    }

    @Test func aRefusalOfOneControlLeavesTheOtherAlone() {
        let output = ControlledOutput(volume: 0.5)
        output.rejectsWrites = true
        var subject = engine(output, ControlledBrightness())
        _ = press(&subject, .volumeUp)
        #expect(press(&subject, .brightnessUp) == .consume(.brightness(percentage: 56, increased: true)))
    }
}

@MainActor
@Suite struct LevelKeyServiceTests {
    private let scheduler = ManualScheduler()
    private let tap = ControlledTap()
    private let output = ControlledOutput(volume: 0.5)
    private let display = ControlledBrightness()
    private let both = LevelKeyPolicy(volume: true, brightness: true)

    private func service(trusted: Bool = true) -> (LevelKeyService, ControlledPermission) {
        let permission = ControlledPermission(trusted)
        let subject = LevelKeyService(tap: tap, permission: permission,
                                      engine: LevelKeyEngine(output: output, brightness: display, settle: {}),
                                      brightness: display, scheduler: scheduler)
        return (subject, permission)
    }

    @Test func nothingIsTappedUntilAskedFor() {
        let (subject, _) = service()
        subject.apply(.off)
        #expect(tap.installCount == 0)
        #expect(subject.status == .off)
    }

    @Test func installsOnceHoweverOftenAPolicyArrives() {
        let (subject, _) = service()
        subject.apply(both)
        subject.apply(both)
        subject.apply(LevelKeyPolicy(volume: true))
        #expect(tap.installCount == 1, "No duplicate interception")
        #expect(subject.status == .active)
    }

    @Test func turningEverythingOffRemovesTheTap() {
        let (subject, _) = service()
        subject.apply(both)
        subject.apply(.off)
        #expect(!tap.isInstalled)
        #expect(subject.status == .off)
        #expect(scheduler.pendingCount == 0, "Nothing keeps running")
    }

    @Test func deniedPermissionLeavesKeysWithMacOSAndWaits() {
        tap.accepts = false
        let (subject, permission) = service(trusted: false)
        subject.apply(both)
        #expect(subject.status == .needsPermission)
        #expect(!tap.isInstalled)

        tap.accepts = true
        permission.isTrusted = true
        scheduler.advance(by: .seconds(3))
        #expect(subject.status == .active, "Granting needs no relaunch")
    }

    @Test func retriesBackOffRatherThanPollingForever() {
        tap.accepts = false
        let (subject, _) = service(trusted: false)
        subject.apply(both)
        scheduler.advance(by: .seconds(60))
        let quick = tap.installCount
        scheduler.advance(by: .seconds(60))
        #expect(tap.installCount - quick <= 4)
        subject.apply(.off)
        #expect(scheduler.pendingCount == 0)
    }

    @Test func aTrustedButRefusedTapIsReportedAsUnavailable() {
        tap.accepts = false
        let (subject, _) = service(trusted: true)
        subject.apply(both)
        #expect(subject.status == .unavailable)
    }

    @Test func aFailedTapGivesTheKeysBackAndStaysOff() async {
        let (subject, _) = service()
        subject.apply(both)
        tap.onFailure?()
        await waitUntil { subject.status == .unavailable }
        #expect(!tap.isInstalled)
        subject.apply(both)
        #expect(!tap.isInstalled, "Same conditions, same failure")
        subject.apply(.off)
        subject.apply(both)
        #expect(tap.isInstalled, "Waking or a new session tries again")
    }

    @Test func revokedPermissionRemovesTheTap() {
        let (subject, permission) = service()
        subject.apply(both)
        permission.isTrusted = false
        scheduler.advance(by: .seconds(30))
        #expect(!tap.isInstalled)
        #expect(subject.status == .needsPermission)
    }

    @Test func aSandboxThatCantConfirmTrustDoesNotTearDownAWorkingTap() {
        let (subject, _) = service(trusted: false)
        subject.apply(both)
        #expect(subject.status == .active)
        scheduler.advance(by: .seconds(90))
        #expect(tap.isInstalled)
    }

    @Test func sleepingAndWakingReinstalls() {
        let (subject, _) = service()
        subject.apply(both)
        subject.apply(.off)
        subject.apply(both)
        #expect(tap.installCount == 2)
        #expect(tap.removeCount == 1)
        #expect(tap.isInstalled)
    }

    @Test func aHandledKeyReachesTheHUDAndIsSwallowed() async {
        let (subject, _) = service()
        var updates: [LevelUpdate] = []
        subject.onUpdate = { update, _, _ in updates.append(update) }
        subject.apply(both)
        #expect(tap.press(.volumeUp))
        await waitUntil { !updates.isEmpty }
        #expect(updates == [.volume(percentage: 56, muted: false)])
    }

    @Test func alternatingKeysUpdateEachControlOnItsOwn() async {
        let (subject, _) = service()
        var updates: [LevelUpdate] = []
        subject.onUpdate = { update, _, _ in updates.append(update) }
        subject.apply(both)
        tap.press(.volumeUp)
        tap.press(.brightnessUp)
        tap.press(.volumeUp)
        tap.press(.brightnessDown)
        await waitUntil { updates.count == 4 }
        #expect(updates == [.volume(percentage: 56, muted: false), .brightness(percentage: 56, increased: true),
                            .volume(percentage: 63, muted: false), .brightness(percentage: 50, increased: false)])
    }

    @Test func aRefusalIsReportedAndClearedByNewHardware() async {
        let (subject, _) = service()
        subject.apply(both)
        output.rejectsWrites = true
        #expect(!tap.press(.volumeUp), "The event goes through to macOS")
        await waitUntil { subject.volumeHandedBack }
        #expect(subject.volumeHandedBack)
        #expect(subject.status == .active, "Brightness keeps working")

        output.rejectsWrites = false
        subject.outputDidChange()
        #expect(!subject.volumeHandedBack)
        #expect(tap.press(.volumeUp))
    }

    @Test func displayChangesRecheckSupport() {
        let (subject, _) = service()
        subject.refreshSupport()
        #expect(subject.brightnessSupported)
        display.supported = false
        subject.displaysDidChange()
        #expect(!subject.brightnessSupported)
    }

    @Test func thePromptAppearsOnlyWhenPermissionIsMissing() {
        let (trusted, permission) = service(trusted: true)
        trusted.requestPermission()
        #expect(permission.requestCount == 0)
        let (untrusted, other) = service(trusted: false)
        untrusted.requestPermission()
        #expect(other.requestCount == 1)
    }

    /// The real thing: without Accessibility, macOS refuses the tap and nothing changes.
    @Test func theRealTapFailsCleanlyWithoutPermission() throws {
        try #require(!AXIsProcessTrustedForTests)
        let tap = SystemLevelKeyTap()
        let installed = tap.install(handler: { _, _, _ in false }, onFailure: {})
        #expect(!installed)
        tap.remove()
    }
}

private var AXIsProcessTrustedForTests: Bool { SystemAccessibilityPermission().isTrusted }

@MainActor
@Suite struct LevelPolicyPreferenceTests {
    private func preferences() -> MorphPreferences {
        let subject = MorphPreferences(defaults: makeDefaults())
        subject.replaceVolumeHUD = true
        subject.replaceBrightnessHUD = true
        return subject
    }

    @Test func replacementIsOffUntilChosen() {
        let subject = MorphPreferences(defaults: makeDefaults())
        #expect(subject.levelKeyPolicy(canShow: true) == .off)
    }

    @Test func eachReplacementIsIndependent() {
        let subject = preferences()
        subject.replaceBrightnessHUD = false
        #expect(subject.levelKeyPolicy(canShow: true) == LevelKeyPolicy(volume: true))
    }

    @Test func aHiddenHUDNeverTakesKeys() {
        let subject = preferences()
        #expect(subject.levelKeyPolicy(canShow: false) == .off, "Paused, in cinema, locked or asleep")
        subject.volumeIndicator = false
        #expect(subject.levelKeyPolicy(canShow: true) == LevelKeyPolicy(brightness: true))
        subject.activitiesEnabled = false
        #expect(subject.levelKeyPolicy(canShow: true) == .off)
    }

    @Test func settingsPersistAndClamp() {
        let defaults = makeDefaults()
        let subject = MorphPreferences(defaults: defaults)
        subject.replaceBrightnessHUD = true
        subject.volumeShowsPercentage = false
        subject.brightnessHUDDuration = 2.4
        defaults.set(99.0, forKey: "volumeHUDDuration")
        let reloaded = MorphPreferences(defaults: defaults)
        #expect(reloaded.replaceBrightnessHUD)
        #expect(!reloaded.volumeShowsPercentage)
        #expect(reloaded.brightnessHUDDuration == 2.4)
        #expect(reloaded.volumeHUDDuration == MorphPreferences.hudDurationRange.upperBound)
        #expect(reloaded.brightnessShowsPercentage)
    }
}

@MainActor
@Suite struct LevelHUDPresentationTests {
    private let scheduler = ManualScheduler()

    @Test func tenRapidChangesStayOneActivity() {
        let manager = ActivityManager(scheduler: scheduler)
        manager.present(.outputVolume(percentage: 10, muted: false))
        let id = manager.current?.id
        for level in 1...10 {
            scheduler.advance(by: .milliseconds(120))
            manager.present(.outputVolume(percentage: 10 + level, muted: false))
            #expect(manager.current?.id == id, "Same activity, so nothing rebuilds")
            #expect(!manager.isConcluding)
        }
        #expect(manager.current?.content == .outputVolume(percentage: 20, muted: false))
        #expect(manager.pendingCount == 0)
    }

    @Test func eachChangeRestartsTheCountdown() {
        let manager = ActivityManager(scheduler: scheduler)
        manager.present(.outputVolume(percentage: 10, muted: false))
        for level in 0..<6 {
            scheduler.advance(by: .milliseconds(1000))
            manager.present(.outputVolume(percentage: level, muted: false))
        }
        #expect(manager.current != nil, "Six seconds in, and it never closed")
    }

    @Test func holdsThenConcludesThenCloses() {
        let manager = ActivityManager(scheduler: scheduler)
        manager.present(.outputVolume(percentage: 40, muted: false))
        scheduler.advance(by: .milliseconds(1199))
        #expect(!manager.isConcluding)
        scheduler.advance(by: .milliseconds(1))
        #expect(manager.isConcluding)
        #expect(manager.current != nil)
        scheduler.advance(by: IslandActivity.levelFade)
        #expect(manager.current == nil)
        #expect(!manager.isConcluding)
    }

    @Test func aChangeWhileConcludingReturnsToFullEmphasis() {
        let manager = ActivityManager(scheduler: scheduler)
        manager.present(.outputVolume(percentage: 40, muted: false))
        scheduler.advance(by: .milliseconds(1300))
        #expect(manager.isConcluding)
        manager.present(.outputVolume(percentage: 45, muted: false))
        #expect(!manager.isConcluding)
    }

    @Test func holdFollowsThePreferenceNotActivityDuration() {
        let manager = ActivityManager(scheduler: scheduler)
        manager.durationScale = 1.6
        manager.present(.brightness(increased: true, percentage: 50), hold: .seconds(2))
        scheduler.advance(by: .seconds(2))
        #expect(manager.isConcluding)
        scheduler.advance(by: IslandActivity.levelFade)
        #expect(manager.current == nil)
    }

    @Test func movingBetweenVolumeAndBrightnessKeepsTheSameHUD() {
        let manager = ActivityManager(scheduler: scheduler)
        manager.present(.outputVolume(percentage: 40, muted: false))
        let id = manager.current?.id
        let layout = IslandLayout(notch: CGSize(width: 179, height: 32), size: .regular)
        let first = layout.islandSize(for: .activity(manager.current!))
        for index in 0..<10 {
            manager.present(index.isMultiple(of: 2) ? .brightness(increased: true, percentage: 50)
                                                    : .outputVolume(percentage: 50, muted: false))
            #expect(manager.current?.id == id)
            let presentation = IslandPresentation.activity(manager.current!)
            #expect(layout.islandSize(for: presentation) == first, "No size jump")
            #expect(presentation.contentIdentity == "level")
        }
        #expect(manager.pendingCount == 0)
    }

    @Test func noValueChangesTheIslandSize() {
        let layout = IslandLayout(notch: CGSize(width: 179, height: 32), size: .regular)
        let contents: [IslandActivity.Content] = [
            .outputVolume(percentage: 0, muted: false), .outputVolume(percentage: 9, muted: false),
            .outputVolume(percentage: 100, muted: false), .outputVolume(percentage: 50, muted: true),
            .brightness(increased: false, percentage: 0), .brightness(increased: true, percentage: 100),
        ]
        let sizes = Set(contents.map { layout.islandSize(for: .activity(IslandActivity($0, at: .now))).debugDescription })
        #expect(sizes.count == 1)
    }

    @Test func withoutAReadingThereIsNoBarOrLip() {
        let layout = IslandLayout(notch: CGSize(width: 179, height: 32), size: .regular)
        let content = IslandActivity.Content.brightness(increased: true, percentage: nil)
        #expect(layout.islandSize(for: .activity(IslandActivity(content, at: .now))).height == 32)
    }

    @Test func wavesFillRatherThanSwapSymbols() {
        for level in stride(from: 1, through: 100, by: 9) {
            #expect(IslandActivity.Content.outputVolume(percentage: level, muted: false).levelSymbol == "speaker.wave.3.fill")
        }
        #expect(IslandActivity.Content.outputVolume(percentage: 50, muted: true).levelSymbol == "speaker.slash.fill")
        #expect(IslandActivity.Content.outputVolume(percentage: 0, muted: false).levelSymbol == "speaker.fill")
        #expect(IslandActivity.Content.brightness(increased: false, percentage: 20).levelSymbol == "sun.min.fill")
        #expect(IslandActivity.Content.brightness(increased: false, percentage: 80).levelSymbol == "sun.max.fill")
    }

    @Test func kindsStaySeparate() {
        #expect(IslandActivity.Content.outputVolume(percentage: 1, muted: false).levelKind == .volume)
        #expect(IslandActivity.Content.volumeChanged(percentage: 1).levelKind == .volume)
        #expect(IslandActivity.Content.brightness(increased: true, percentage: nil).levelKind == .brightness)
        #expect(IslandActivity.Content.fullyCharged.levelKind == nil)
    }

    @Test func aMenuOpenPanelIsLeftAloneByALevelChange() {
        let manager = ActivityManager(scheduler: scheduler)
        manager.setHeld(true)
        manager.present(.brightness(increased: true, percentage: 50))
        #expect(manager.current?.presentation == .level, "Visible in the panel's header")
        scheduler.advance(by: .seconds(2))
        #expect(manager.current == nil)
    }
}
