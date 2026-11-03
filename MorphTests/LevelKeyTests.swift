import os
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

    private func percentage(_ decision: LevelKeyDecision) -> Int? {
        guard case .consume(.volume(let percentage, _)?) = decision else { return nil }
        return percentage
    }

    @Test func volumeUpChangesTheRealValueBeforeConsuming() {
        let output = ControlledOutput(volume: 0.5)
        var subject = engine(output)
        #expect(press(&subject, .volumeUp) == .consume(.volume(percentage: 55, muted: false)))
        #expect(output.state?.volume == 0.55)
    }

    @Test func volumeDownChangesTheRealValueBeforeConsuming() {
        let output = ControlledOutput(volume: 0.5)
        var subject = engine(output)
        #expect(press(&subject, .volumeDown) == .consume(.volume(percentage: 45, muted: false)))
        #expect(output.state?.volume == 0.45)
    }

    @Test func everyPressUpWalksTheFivePercentGrid() {
        let output = ControlledOutput(volume: 0, muted: true)
        var subject = engine(output)
        let shown = (0..<20).map { _ in percentage(press(&subject, .volumeUp)) }
        #expect(shown == Array(stride(from: 5, through: 100, by: 5)))
        #expect(output.state?.volume == 1)
        #expect(output.state?.isMuted == false)
    }

    @Test func everyPressDownWalksTheFivePercentGrid() {
        let output = ControlledOutput(volume: 1)
        var subject = engine(output)
        let shown = (0..<20).map { _ in percentage(press(&subject, .volumeDown)) }
        #expect(shown == Array(stride(from: 95, through: 0, by: -5)))
        #expect(output.state?.volume == 0)
    }

    @Test func aLevelBetweenStepsMovesToTheNextOneInThatDirection() {
        for (start, key, expected) in [(0.43, LevelKey.volumeUp, 45), (0.43, .volumeDown, 40),
                                       (0.5, .volumeUp, 55), (0.5, .volumeDown, 45),
                                       (0.01, .volumeDown, 0), (0.99, .volumeUp, 100), (0.97, .volumeDown, 95)] {
            let output = ControlledOutput(volume: Float(start))
            var subject = engine(output)
            #expect(percentage(press(&subject, key)) == expected, "\(start) \(key)")
            #expect(output.state?.volume == Float(expected) / 100)
        }
    }

    @Test func theStepFollowsThePolicy() {
        for (step, up, down) in [(VolumeStep.two, 44, 40), (.five, 45, 40), (.ten, 50, 40)] {
            let output = ControlledOutput(volume: 0.42)
            var subject = engine(output, policy: LevelKeyPolicy(volume: true, volumeStep: step))
            #expect(percentage(press(&subject, .volumeUp)) == up, "\(step)")
            output.state?.volume = 0.42
            #expect(percentage(press(&subject, .volumeDown)) == down, "\(step)")
        }
    }

    @Test func aStepChangeTakesEffectOnTheNextPress() {
        let output = ControlledOutput(volume: 0.5)
        var subject = engine(output)
        _ = press(&subject, .volumeUp)
        subject.policy.volumeStep = .ten
        #expect(percentage(press(&subject, .volumeUp)) == 60)
        subject.policy.volumeStep = .two
        #expect(percentage(press(&subject, .volumeUp)) == 62)
    }

    @Test func fineStepsWithShiftAndOption() {
        let output = ControlledOutput(volume: 0.5)
        var subject = engine(output)
        _ = press(&subject, .volumeUp, LevelKeyModifiers(shift: true, option: true))
        #expect(output.state?.volume == 0.51)
    }

    @Test func brightnessMovesOnTheConfiguredGrid() {
        for (step, up, down) in [(VolumeStep.two, 44, 42), (.five, 45, 40), (.ten, 50, 40)] {
            let brightness = ControlledBrightness(0.43)
            var subject = engine(ControlledOutput(volume: 0.5), brightness,
                                 policy: LevelKeyPolicy(brightness: true, brightnessStep: step))
            #expect(press(&subject, .brightnessUp) == .consume(.brightness(percentage: up, increased: true)))
            brightness.value = 0.43
            #expect(press(&subject, .brightnessDown) == .consume(.brightness(percentage: down, increased: false)))
        }
        let brightness = ControlledBrightness(0.5)
        var fine = engine(ControlledOutput(volume: 0.5), brightness)
        #expect(press(&fine, .brightnessUp, LevelKeyModifiers(shift: true, option: true))
                == .consume(.brightness(percentage: 51, increased: true)))
    }

    @MainActor @Test func theBrightnessStepPersistsAndReachesThePolicy() {
        let defaults = makeDefaults()
        let preferences = MorphPreferences(defaults: defaults)
        #expect(preferences.brightnessStep == .five)
        preferences.brightnessStep = .ten
        let reloaded = MorphPreferences(defaults: defaults)
        #expect(reloaded.brightnessStep == .ten)
        #expect(reloaded.levelKeyPolicy(canShow: true).brightnessStep == .ten)
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
        #expect(press(&subject, .volumeUp) == .consume(.volume(percentage: 55, muted: false)))
    }

    @Test func loweringAlsoUnmutesAsTheSystemDoes() {
        let output = ControlledOutput(volume: 0.5, muted: true)
        var subject = engine(output)
        #expect(press(&subject, .volumeDown) == .consume(.volume(percentage: 45, muted: false)))
    }

    @Test func reachingZeroMutes() {
        let output = ControlledOutput(volume: 0.05)
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
        #expect(output.state?.volume == 0.75)
    }

    @Test func rapidAlternatingPressesNeverDrift() {
        let output = ControlledOutput(volume: 0.5)
        var subject = engine(output)
        for _ in 0..<50 {
            _ = press(&subject, .volumeUp)
            _ = press(&subject, .volumeDown)
        }
        #expect(output.state?.volume == 0.5)
    }

    @Test func aQuantizingDeviceStillStepsEvenly() {
        let output = ControlledOutput(volume: 0.5)
        output.quantize = { ($0 * 64).rounded(.down) / 64 }
        var subject = engine(output)
        let shown = (0..<4).map { _ in percentage(press(&subject, .volumeUp)) }
        #expect(shown == [55, 59, 64, 69], "The HUD shows what the device really did")
        #expect(output.state?.volume == 44.0 / 64)
    }

    @Test func aDeviceCoarserThanTheStepMovesToItsNextLevel() {
        let output = ControlledOutput(volume: 0.5)
        output.quantize = { ($0 * 16).rounded() / 16 }
        var subject = engine(output, policy: LevelKeyPolicy(volume: true, volumeStep: .two))
        #expect(press(&subject, .volumeUp) == .consume(.volume(percentage: 56, muted: false)),
                "The HUD shows what the device really did")
        #expect(output.state?.volume == 0.5625)
    }

    @Test func aSlowDriverIsGivenAMoment() {
        let output = ControlledOutput(volume: 0.5)
        output.readsBeforeLanding = 1
        var subject = engine(output)
        #expect(press(&subject, .volumeUp) == .consume(.volume(percentage: 55, muted: false)))
    }

    @Test func anExternalChangeIsFollowed() {
        let output = ControlledOutput(volume: 0.5)
        var subject = engine(output)
        _ = press(&subject, .volumeUp)
        output.state?.volume = 0.25
        _ = press(&subject, .volumeUp)
        #expect(output.state?.volume == 0.3)
        output.state?.volume = 0.43
        _ = press(&subject, .volumeDown)
        #expect(output.state?.volume == 0.4, "An off-grid level set elsewhere joins the grid")
    }

    @Test func anExternalMuteIsRespected() {
        let output = ControlledOutput(volume: 0.5)
        var subject = engine(output)
        output.state?.isMuted = true
        #expect(press(&subject, .mute) == .consume(.volume(percentage: 50, muted: false)))
        #expect(output.state?.volume == 0.5)
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
        #expect(press(&subject, .volumeUp) == .consume(.volume(percentage: 55, muted: false)))
    }

    @Test func aRejectionOnlyCoversThatDevice() {
        let output = ControlledOutput(volume: 0.5, id: 1)
        output.rejectsWrites = true
        var subject = engine(output)
        _ = press(&subject, .volumeUp)
        output.rejectsWrites = false
        output.state?.device = AudioOutputDevice(id: 2, uid: "2", name: "AirPods", transport: .bluetooth)
        #expect(press(&subject, .volumeUp) == .consume(.volume(percentage: 55, muted: false)))
    }

    @Test func aNewDeviceStepsFromItsOwnLevel() {
        let output = ControlledOutput(volume: 0.5, id: 1)
        var subject = engine(output)
        _ = press(&subject, .volumeUp)
        output.state = OutputState(device: AudioOutputDevice(id: 2, uid: "2", name: "AirPods", transport: .bluetooth),
                                   volume: 0.32, isMuted: false, canSetVolume: true, canMute: true)
        #expect(percentage(press(&subject, .volumeUp)) == 35)
        #expect(percentage(press(&subject, .volumeDown)) == 30)
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
        #expect(press(&subject, .brightnessUp) == .consume(.brightness(percentage: 55, increased: true)))
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
        #expect(press(&subject, .brightnessUp) == .consume(.brightness(percentage: 55, increased: true)))
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
        #expect(press(&subject, .brightnessUp) == .consume(.brightness(percentage: 55, increased: true)))
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
        #expect(updates == [.volume(percentage: 55, muted: false)])
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
        #expect(updates == [.volume(percentage: 55, muted: false), .brightness(percentage: 55, increased: true),
                            .volume(percentage: 60, muted: false), .brightness(percentage: 50, increased: false)])
    }

    @Test func theChosenStepReachesTheTap() async {
        let (subject, _) = service()
        var updates: [LevelUpdate] = []
        subject.onUpdate = { update, _, _ in updates.append(update) }
        subject.apply(LevelKeyPolicy(volume: true, volumeStep: .ten))
        tap.press(.volumeUp)
        subject.apply(LevelKeyPolicy(volume: true, volumeStep: .two))
        tap.press(.volumeUp)
        await waitUntil { updates.count == 2 }
        #expect(updates == [.volume(percentage: 60, muted: false), .volume(percentage: 62, muted: false)])
        #expect(tap.installCount == 1, "A step change doesn't reinstall the tap")
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

    @Test func aDefaultOnReplacementAsksForPermissionOnce() {
        tap.accepts = false
        let (subject, permission) = service(trusted: false)
        subject.apply(LevelKeyPolicy(volume: true))
        subject.apply(.off)
        subject.apply(LevelKeyPolicy(volume: true))
        #expect(permission.requestCount == 1)
        tap.accepts = true
        let (trusted, other) = service(trusted: true)
        trusted.apply(LevelKeyPolicy(volume: true))
        #expect(other.requestCount == 0)
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
    /// The outcome depends on whether this Mac has granted Accessibility, and both are checked.
    @Test func theRealTapFollowsThePermission() {
        let tap = SystemLevelKeyTap()
        let installed = tap.install(handler: { _, _, _ in false }, onFailure: {})
        #expect(installed == AXIsProcessTrustedForTests)
        tap.remove()
    }

    /// Posts a real volume key through the window server and checks the tap got it and swallowed
    /// it, with the output unchanged. Off by default: if the tap ever failed, the key would reach
    /// macOS. Run with `TEST_RUNNER_MORPH_LIVE_KEY_TEST=1`.
    @Test func aRealKeyEventReachesTheTapAndIsSwallowed() async throws {
        try #require(AXIsProcessTrustedForTests)
        guard ProcessInfo.processInfo.environment["MORPH_LIVE_KEY_TEST"] != nil else { return }
        let output = CoreAudioOutputSystem()
        let before = output.currentOutput()
        let seen = OSAllocatedUnfairLock(initialState: [LevelKeyPress]())
        let tap = SystemLevelKeyTap()
        let installed = tap.install(handler: { press, _, _ in
            seen.withLock { $0.append(press) }
            return true
        }, onFailure: {})
        #expect(installed)
        defer { tap.remove() }

        for state in [0xA, 0xB] {
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                           context: nil, subtype: 8, data1: (LevelKey.volumeUp.rawValue << 16) | (state << 8), data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
        try await Task.sleep(for: .milliseconds(500))
        print("LIVE-KEY received: \(seen.withLock { $0 })")
        #expect(seen.withLock { $0 } == [LevelKeyPress(key: .volumeUp, isDown: true), LevelKeyPress(key: .volumeUp, isDown: false)])
        #expect(output.currentOutput()?.volume == before?.volume, "Swallowed, so macOS changed nothing")

        // The control: the same key, not swallowed, must move the volume. Otherwise the check above
        // proves nothing.
        tap.remove()
        let device = try #require(before?.device.id)
        let level = try #require(before?.volume)
        defer { output.setVolume(level, device: device) }
        for state in [0xA, 0xB] {
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                           context: nil, subtype: 8, data1: (LevelKey.volumeDown.rawValue << 16) | (state << 8), data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
        try await Task.sleep(for: .milliseconds(500))
        print("LIVE-KEY control: \(level) -> \(output.currentOutput()?.volume ?? -1)")
        #expect(output.currentOutput()?.volume != level, "A key that gets through reaches macOS")
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

    @Test func volumeReplacementIsOnByDefaultInFivePercentSteps() {
        let subject = MorphPreferences(defaults: makeDefaults())
        #expect(subject.replaceVolumeHUD)
        #expect(!subject.replaceBrightnessHUD, "Brightness uses a private interface, so it stays opt-in")
        #expect(subject.levelKeyPolicy(canShow: true) == LevelKeyPolicy(volume: true, volumeStep: .five))
    }

    @Test func turningReplacementOffIsRemembered() {
        let defaults = makeDefaults()
        MorphPreferences(defaults: defaults).replaceVolumeHUD = false
        #expect(MorphPreferences(defaults: defaults).levelKeyPolicy(canShow: true) == .off)
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

    @Test func theVolumeStepPersistsAndReachesThePolicy() {
        let defaults = makeDefaults()
        let subject = MorphPreferences(defaults: defaults)
        #expect(subject.volumeStep == .five)
        subject.replaceVolumeHUD = true
        subject.volumeStep = .two
        let reloaded = MorphPreferences(defaults: defaults)
        #expect(reloaded.volumeStep == .two)
        #expect(reloaded.levelKeyPolicy(canShow: true) == LevelKeyPolicy(volume: true, volumeStep: .two))
        defaults.set("seven", forKey: "volumeStep")
        #expect(MorphPreferences(defaults: defaults).volumeStep == .five, "An unknown value falls back")
        reloaded.reset()
        #expect(reloaded.volumeStep == .five)
    }

    @Test func gridArithmeticIsExact() {
        for step in VolumeStep.allCases.map(\.points) {
            for level in 0...100 {
                let up = VolumeStep.next(from: level, direction: 1, step: step)
                let down = VolumeStep.next(from: level, direction: -1, step: step)
                #expect(up % step == 0 || up == 100)
                #expect(down % step == 0)
                #expect(level == 100 ? up == 100 : (up > level && up - level <= step))
                #expect(level == 0 ? down == 0 : (down < level && level - down <= step))
            }
        }
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
        scheduler.advance(by: IslandActivity.levelHold - IslandActivity.levelFade - .milliseconds(1))
        #expect(!manager.isConcluding)
        scheduler.advance(by: .milliseconds(1))
        #expect(manager.isConcluding)
        #expect(manager.current != nil)
        scheduler.advance(by: IslandActivity.levelFade)
        #expect(manager.current == nil, "Closes 1.2 seconds after the last change")
        #expect(!manager.isConcluding)
    }

    @Test func aChangeWhileConcludingReturnsToFullEmphasis() {
        let manager = ActivityManager(scheduler: scheduler)
        manager.present(.outputVolume(percentage: 40, muted: false))
        scheduler.advance(by: .milliseconds(1000))
        #expect(manager.isConcluding)
        manager.present(.outputVolume(percentage: 45, muted: false))
        #expect(!manager.isConcluding)
    }

    @Test func holdFollowsThePreferenceNotActivityDuration() {
        let manager = ActivityManager(scheduler: scheduler)
        manager.durationScale = 1.6
        manager.present(.brightness(increased: true, percentage: 50), duration: .seconds(2))
        scheduler.advance(by: .seconds(2) - IslandActivity.levelFade)
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

    @Test func withoutAReadingThereIsNoBarButTheShapeHolds() {
        let layout = IslandLayout(notch: CGSize(width: 179, height: 32), size: .regular)
        let content = IslandActivity.Content.brightness(increased: true, percentage: nil)
        #expect(content.level == nil)
        #expect(layout.islandSize(for: .activity(IslandActivity(content, at: .now))).height == 32 + IslandLayout.levelRow)
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
