import CoreGraphics
import Foundation

/// One scroll event from the island's own view. Deltas are normalized to the fingers, whatever the
/// natural scrolling setting: positive means moving left, or up.
struct ScrollInput: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case began, changed, ended
        /// macOS coasting after the fingers lifted. Not a gesture.
        case momentum
        /// No gesture phases at all: a wheel mouse.
        case discrete
    }

    var deltaX: CGFloat
    var deltaY: CGFloat
    var phase: Phase
    var isPrecise: Bool
    var time: TimeInterval
}

/// Turns two-finger scrolling over the island into commands. It only sees events delivered to the
/// island's window, so nothing is captured globally, and Mission Control's three- and four-finger
/// swipes are never involved.
struct IslandGestureRecognizer: Sendable {
    enum Command: Equatable, Sendable {
        case next, previous
        case volume(Int)
    }

    private enum Axis { case horizontal, vertical }

    private static let swipeDistance: CGFloat = 70
    private static let swipeSpeed: CGFloat = 180
    /// Movement needed before deciding which way the fingers are going.
    private static let axisLockDistance: CGFloat = 10
    /// One axis must clearly dominate, so a diagonal scroll does nothing.
    private static let axisRatio: CGFloat = 1.4
    private static let cooldown: TimeInterval = 0.45

    var horizontalEnabled = true
    var verticalEnabled = true
    var sensitivity: CGFloat = 1

    private var axis: Axis?
    private var totalX: CGFloat = 0
    private var totalY: CGFloat = 0
    private var startTime: TimeInterval = 0
    private var hasFired = false
    private var nextAllowedSwipe: TimeInterval = 0
    private var volumeSteps = VolumeScrollAccumulator()

    mutating func process(_ input: ScrollInput) -> [Command] {
        switch input.phase {
        case .momentum:
            return []
        case .began:
            reset(at: input.time)
            return track(input)
        case .changed:
            return track(input)
        case .ended:
            axis = nil
            return []
        case .discrete:
            return handleWheel(input)
        }
    }

    private mutating func reset(at time: TimeInterval) {
        axis = nil
        totalX = 0
        totalY = 0
        startTime = time
        hasFired = false
    }

    private mutating func track(_ input: ScrollInput) -> [Command] {
        totalX += input.deltaX
        totalY += input.deltaY

        var volumeDelta = input.deltaY
        if axis == nil {
            axis = lockedAxis()
            // Movement before the lock still counts toward the volume.
            if axis == .vertical { volumeDelta = totalY }
        }

        switch axis {
        case .horizontal: return swipe(at: input.time)
        case .vertical: return volume(delta: volumeDelta, isPrecise: input.isPrecise)
        case nil: return []
        }
    }

    private func lockedAxis() -> Axis? {
        let (x, y) = (abs(totalX), abs(totalY))
        guard max(x, y) >= Self.axisLockDistance else { return nil }
        if x >= y * Self.axisRatio { return .horizontal }
        if y >= x * Self.axisRatio { return .vertical }
        return nil
    }

    /// Fires at most once per gesture, however far the fingers keep going.
    private mutating func swipe(at time: TimeInterval) -> [Command] {
        guard horizontalEnabled, !hasFired, time >= nextAllowedSwipe,
              abs(totalX) >= Self.swipeDistance / sensitivity else { return [] }
        let elapsed = time - startTime
        guard elapsed <= 0 || abs(totalX) / CGFloat(elapsed) >= Self.swipeSpeed else { return [] }
        return [fireSwipe(forward: totalX > 0, at: time)]
    }

    private mutating func fireSwipe(forward: Bool, at time: TimeInterval) -> Command {
        hasFired = true
        nextAllowedSwipe = time + Self.cooldown
        return forward ? .next : .previous
    }

    private mutating func volume(delta: CGFloat, isPrecise: Bool) -> [Command] {
        guard verticalEnabled else { return [] }
        let step = volumeSteps.add(deltaY: delta * sensitivity, isPrecise: isPrecise)
        return step == 0 ? [] : [.volume(step)]
    }

    /// A wheel has no gesture to bound a swipe, so tilting relies on the cooldown alone.
    private mutating func handleWheel(_ input: ScrollInput) -> [Command] {
        if input.deltaX != 0, abs(input.deltaX) >= abs(input.deltaY) {
            guard horizontalEnabled, input.time >= nextAllowedSwipe else { return [] }
            return [fireSwipe(forward: input.deltaX > 0, at: input.time)]
        }
        return volume(delta: input.deltaY, isPrecise: input.isPrecise)
    }
}
