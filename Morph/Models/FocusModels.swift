import Foundation

enum FocusPhase: String, Codable, Equatable, Sendable {
    case focus, shortBreak, longBreak

    var title: String {
        switch self {
        case .focus: "Focus"
        case .shortBreak: "Short break"
        case .longBreak: "Long break"
        }
    }

    var symbol: String {
        switch self {
        case .focus: "brain.head.profile"
        case .shortBreak: "cup.and.saucer.fill"
        case .longBreak: "figure.walk"
        }
    }
}

struct FocusConfiguration: Equatable, Sendable {
    var focus: Duration = .seconds(25 * 60)
    var shortBreak: Duration = .seconds(5 * 60)
    var longBreak: Duration = .seconds(15 * 60)
    /// Focus sessions before a long break.
    var cycles = 4
    /// Whether a finished focus session goes straight into its break.
    var autoBreak = true

    func duration(of phase: FocusPhase) -> Duration {
        switch phase {
        case .focus: focus
        case .shortBreak: shortBreak
        case .longBreak: longBreak
        }
    }
}

/// A Pomodoro in progress. Time is kept by `CountdownTimer`, the same end instant the timer module
/// uses, so nothing accumulates from UI ticks and it can't drift.
struct PomodoroSession: Equatable, Sendable {
    private(set) var phase = FocusPhase.focus
    private(set) var timer = CountdownTimer()
    /// Finished focus sessions since the last long break.
    private(set) var completedFocus = 0

    var isActive: Bool { timer.isRunning || timer.isPaused }

    func fraction(at now: ContinuousClock.Instant) -> Double {
        let total = timer.duration
        guard total > .zero else { return 0 }
        return (1 - timer.remaining(at: now) / total).clamped(to: 0...1)
    }

    mutating func start(_ phase: FocusPhase, configuration: FocusConfiguration, at now: ContinuousClock.Instant) {
        self.phase = phase
        timer.start(configuration.duration(of: phase), at: now)
    }

    mutating func pause(at now: ContinuousClock.Instant) { timer.pause(at: now) }
    mutating func resume(at now: ContinuousClock.Instant) { timer.resume(at: now) }

    mutating func stop() {
        timer.reset()
        phase = .focus
    }

    /// Records the end of the running phase and says what comes next.
    mutating func finish(configuration: FocusConfiguration) -> FocusPhase {
        timer.reset()
        guard phase == .focus else {
            if phase == .longBreak { completedFocus = 0 }
            return .focus
        }
        completedFocus += 1
        return completedFocus >= configuration.cycles ? .longBreak : .shortBreak
    }

    mutating func restore(phase: FocusPhase, completedFocus: Int, total: Duration, remaining: Duration,
                          isPaused: Bool, at now: ContinuousClock.Instant) {
        self.phase = phase
        self.completedFocus = completedFocus
        timer.restore(total: total, remaining: remaining, isPaused: isPaused, at: now)
    }
}
