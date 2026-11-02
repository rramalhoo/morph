import CoreGraphics
import Foundation

/// What to do with a key event. Anything other than `consume` reaches macOS.
enum LevelKeyDecision: Equatable, Sendable {
    case pass
    /// The change is applied and confirmed. Key-ups consume without an update.
    case consume(LevelUpdate?)
    /// The change didn't take, so the key goes to macOS and this control stops being intercepted.
    case handBack(isBrightness: Bool)
}

/// Applies a key's real effect and proves it worked before the event may be swallowed. A key is
/// never consumed on the hope that a change will land later.
///
/// Runs on the event tap's thread, so it must stay quick: a tap that stalls delays input.
struct LevelKeyEngine: Sendable {
    static let standardStep: Float = 1.0 / 16
    static let fineStep: Float = 1.0 / 64
    private static let tolerance: Float = 0.002

    var policy = LevelKeyPolicy.off

    private let output: any AudioOutputSystem
    private let brightness: any BrightnessControlling
    /// Some drivers report a new value slightly after accepting it.
    private let settle: @Sendable () -> Void

    private var rejectedOutput: UInt32?
    private var brightnessRejected = false
    private var consumedDowns: Set<LevelKey> = []
    /// Devices can quantize a request. Stepping from what was asked keeps steps even.
    private var lastVolume: (device: UInt32, requested: Float, reported: Float)?

    init(output: any AudioOutputSystem, brightness: any BrightnessControlling,
         settle: @escaping @Sendable () -> Void = { usleep(30_000) }) {
        self.output = output
        self.brightness = brightness
        self.settle = settle
    }

    mutating func clearOutputRejection() {
        rejectedOutput = nil
        lastVolume = nil
    }

    mutating func clearBrightnessRejection() {
        brightnessRejected = false
    }

    mutating func handle(_ press: LevelKeyPress, modifiers: LevelKeyModifiers, pointer: CGPoint) -> LevelKeyDecision {
        // An up must follow its down: macOS shouldn't see half of a key press.
        guard press.isDown else { return consumedDowns.remove(press.key) != nil ? .consume(nil) : .pass }

        let decision = decide(press.key, modifiers: modifiers, pointer: pointer)
        if case .consume = decision {
            consumedDowns.insert(press.key)
        } else {
            consumedDowns.remove(press.key)
        }
        return decision
    }

    private mutating func decide(_ key: LevelKey, modifiers: LevelKeyModifiers, pointer: CGPoint) -> LevelKeyDecision {
        guard !modifiers.belongsToSystem else { return .pass }
        let step = modifiers.isFine ? Self.fineStep : Self.standardStep
        switch key {
        case .volumeUp: return adjustVolume(direction: 1, step: step)
        case .volumeDown: return adjustVolume(direction: -1, step: step)
        case .mute: return toggleMute()
        case .brightnessUp: return adjustBrightness(direction: 1, step: step, pointer: pointer)
        case .brightnessDown: return adjustBrightness(direction: -1, step: step, pointer: pointer)
        }
    }

    private static func next(from value: Float, direction: Float, step: Float) -> Float {
        (((value / step).rounded() + direction) * step).clamped(to: 0...1)
    }

    // MARK: - Volume

    /// The output, if it's one Morph may and can control right now.
    private func controllableOutput() -> OutputState? {
        guard policy.volume, let state = output.currentOutput(), state.canSetVolume, state.volume != nil,
              state.device.id != rejectedOutput else { return nil }
        return state
    }

    private mutating func adjustVolume(direction: Float, step: Float) -> LevelKeyDecision {
        guard let state = controllableOutput(), let current = state.volume else { return .pass }
        let device = state.device.id

        var base = current
        if let last = lastVolume, last.device == device, abs(last.reported - current) <= Self.tolerance {
            base = last.requested
        }
        let target = Self.next(from: base, direction: direction, step: step)

        if state.effectivelyMuted, target > 0, state.canMute, !output.setMuted(false, device: device) {
            return rejectOutput(device)
        }

        var reported = current
        if abs(target - current) > Self.tolerance {
            guard output.setVolume(target, device: device),
                  let confirmed = confirmVolume(device: device, from: current, target: target) else {
                return rejectOutput(device)
            }
            reported = confirmed
        }
        lastVolume = (device, target, reported)

        // Reaching zero mutes, as the system's own keys do.
        if target == 0, state.canMute, !state.effectivelyMuted {
            output.setMuted(true, device: device)
        }
        let muted = output.currentOutput()?.isMuted ?? state.isMuted ?? false
        return .consume(.volume(percentage: Self.percentage(reported), muted: muted))
    }

    private func confirmVolume(device: UInt32, from: Float, target: Float) -> Float? {
        for attempt in 0..<2 {
            if attempt > 0 { settle() }
            guard let state = output.currentOutput(), state.device.id == device, let value = state.volume else { continue }
            let reachedTarget = abs(value - target) <= Self.tolerance
            let movedTowardTarget = target > from ? value > from + Self.tolerance : value < from - Self.tolerance
            if reachedTarget || movedTowardTarget { return value }
        }
        return nil
    }

    private mutating func toggleMute() -> LevelKeyDecision {
        guard let state = controllableOutput(), state.canMute, let volume = state.volume else { return .pass }
        let device = state.device.id
        let muted = !state.effectivelyMuted

        guard output.setMuted(muted, device: device) else { return rejectOutput(device) }
        for attempt in 0..<2 {
            if attempt > 0 { settle() }
            if output.currentOutput()?.isMuted == muted {
                return .consume(.volume(percentage: Self.percentage(volume), muted: muted))
            }
        }
        return rejectOutput(device)
    }

    private mutating func rejectOutput(_ device: UInt32) -> LevelKeyDecision {
        rejectedOutput = device
        lastVolume = nil
        return .handBack(isBrightness: false)
    }

    // MARK: - Brightness

    private mutating func adjustBrightness(direction: Float, step: Float, pointer: CGPoint) -> LevelKeyDecision {
        guard policy.brightness, !brightnessRejected, brightness.canControl(pointer: pointer) else { return .pass }
        guard let current = brightness.read() else { return rejectBrightness() }
        let target = Self.next(from: current, direction: direction, step: step)

        guard abs(target - current) > Self.tolerance else {
            return .consume(.brightness(percentage: Self.percentage(current), increased: direction > 0))
        }
        guard brightness.write(target) else { return rejectBrightness() }

        for attempt in 0..<2 {
            if attempt > 0 { settle() }
            if let value = brightness.read(), abs(value - target) <= Self.tolerance {
                return .consume(.brightness(percentage: Self.percentage(value), increased: direction > 0))
            }
        }
        return rejectBrightness()
    }

    private mutating func rejectBrightness() -> LevelKeyDecision {
        brightnessRejected = true
        return .handBack(isBrightness: true)
    }

    private static func percentage(_ value: Float) -> Int {
        Int((value * 100).rounded())
    }
}
