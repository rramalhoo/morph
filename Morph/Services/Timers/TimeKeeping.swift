import Foundation

/// A countdown stored as an end instant, never as a tally of UI ticks, so it can't drift.
/// `ContinuousClock` keeps counting through sleep, matching what a kitchen timer would do.
struct CountdownTimer: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case running(endsAt: ContinuousClock.Instant)
        case paused(remaining: Duration)
        case finished
    }

    private(set) var duration: Duration = .zero
    private(set) var phase = Phase.idle

    var isRunning: Bool {
        if case .running = phase { true } else { false }
    }

    var isPaused: Bool {
        if case .paused = phase { true } else { false }
    }

    func remaining(at now: ContinuousClock.Instant) -> Duration {
        switch phase {
        case .idle: duration
        case .running(let end): max(.zero, now.duration(to: end))
        case .paused(let remaining): remaining
        case .finished: .zero
        }
    }

    mutating func start(_ duration: Duration, at now: ContinuousClock.Instant) {
        guard duration > .zero else { return }
        self.duration = duration
        phase = .running(endsAt: now.advanced(by: duration))
    }

    mutating func pause(at now: ContinuousClock.Instant) {
        guard isRunning else { return }
        phase = .paused(remaining: remaining(at: now))
    }

    mutating func resume(at now: ContinuousClock.Instant) {
        guard case .paused(let remaining) = phase else { return }
        phase = .running(endsAt: now.advanced(by: remaining))
    }

    mutating func reset() {
        phase = .idle
    }

    /// Returns true if this call is what finished the timer.
    mutating func complete(at now: ContinuousClock.Instant) -> Bool {
        guard case .running(let end) = phase, now >= end else { return false }
        phase = .finished
        return true
    }
}

/// Monotonic elapsed time: closed intervals plus the open one, computed from the clock on demand.
struct Stopwatch: Equatable, Sendable {
    private(set) var accumulated: Duration = .zero
    private(set) var startedAt: ContinuousClock.Instant?

    var isRunning: Bool { startedAt != nil }

    func elapsed(at now: ContinuousClock.Instant) -> Duration {
        guard let startedAt else { return accumulated }
        return accumulated + startedAt.duration(to: now)
    }

    mutating func start(at now: ContinuousClock.Instant) {
        guard startedAt == nil else { return }
        startedAt = now
    }

    mutating func pause(at now: ContinuousClock.Instant) {
        guard startedAt != nil else { return }
        accumulated = elapsed(at: now)
        startedAt = nil
    }

    mutating func reset() {
        accumulated = .zero
        startedAt = nil
    }
}
