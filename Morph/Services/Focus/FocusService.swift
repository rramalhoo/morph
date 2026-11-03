import Foundation
import Observation

/// Pomodoro sessions, and Morph Focus: a quiet mode that belongs to Morph alone. macOS offers no
/// appropriate way to read the system's Focus, so Morph Focus neither reflects nor changes it.
@MainActor
@Observable
final class FocusService {
    private static let defaultsKey = "focus.session"

    private struct Saved: Codable {
        var phase: FocusPhase
        var completedFocus: Int
        var totalSeconds: Double
        /// Wall clock, because the monotonic clock doesn't survive a relaunch.
        var endsAt: Date?
        var remainingSeconds: Double?
        var morphFocus: Bool
    }

    private(set) var session = PomodoroSession()
    /// Turned on by hand. See `isQuiet` for what it does.
    private(set) var isMorphFocusOn = false

    var configuration = FocusConfiguration()

    @ObservationIgnored var onFinished: ((FocusPhase) -> Void)?
    /// Fires with the remaining time and a title when a notification should be armed, and with nil to cancel.
    @ObservationIgnored var onNotificationChange: ((Duration?, String) -> Void)?

    @ObservationIgnored private let scheduler: any Scheduling
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let wallClock: () -> Date
    @ObservationIgnored private var completionWork: (any ScheduledWork)?

    init(scheduler: any Scheduling, defaults: UserDefaults = .standard, wallClock: @escaping () -> Date = { .now }) {
        self.scheduler = scheduler
        self.defaults = defaults
        self.wallClock = wallClock
    }

    var now: ContinuousClock.Instant { scheduler.now }

    /// During this, only things that matter may appear: routine activities stay out of the island.
    var isQuiet: Bool {
        isMorphFocusOn || (session.isActive && session.phase == .focus)
    }

    func startFocus() { start(.focus) }

    func start(_ phase: FocusPhase) {
        session.start(phase, configuration: configuration, at: scheduler.now)
        arm()
        save()
    }

    func pause() {
        session.pause(at: scheduler.now)
        disarm()
        save()
    }

    func resume() {
        session.resume(at: scheduler.now)
        arm()
        save()
    }

    func stop() {
        session.stop()
        disarm()
        save()
    }

    /// Moves on as if the running phase had ended, without the announcement.
    func skip() {
        guard session.isActive else { return }
        let next = session.finish(configuration: configuration)
        disarm()
        start(next)
    }

    func setMorphFocus(_ on: Bool) {
        isMorphFocusOn = on
        save()
    }

    private func arm() {
        guard session.timer.isRunning else { return }
        let remaining = session.timer.remaining(at: scheduler.now)
        completionWork?.cancel()
        completionWork = scheduler.schedule(after: remaining) { [weak self] in self?.finish() }
        onNotificationChange?(remaining, "\(session.phase.title) finished")
    }

    private func disarm() {
        completionWork?.cancel()
        completionWork = nil
        onNotificationChange?(nil, "")
    }

    private func finish() {
        completionWork = nil
        let finished = session.phase
        let next = session.finish(configuration: configuration)
        onFinished?(finished)
        if finished == .focus, configuration.autoBreak {
            start(next)
        } else {
            save()
        }
    }

    // MARK: - Persistence

    func restore() {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        isMorphFocusOn = saved.morphFocus

        let remaining: Double
        if let end = saved.endsAt {
            remaining = end.timeIntervalSince(wallClock())
        } else if let paused = saved.remainingSeconds {
            remaining = paused
        } else {
            return
        }
        // A phase that ended while Morph was closed is simply over. It's too late to announce it.
        guard remaining > 0 else {
            save()
            return
        }
        session.restore(phase: saved.phase, completedFocus: saved.completedFocus, total: .seconds(saved.totalSeconds),
                        remaining: .seconds(remaining), isPaused: saved.endsAt == nil, at: scheduler.now)
        arm()
    }

    private func save() {
        let timer = session.timer
        let remaining = timer.remaining(at: scheduler.now).timeInterval
        let saved = Saved(phase: session.phase, completedFocus: session.completedFocus,
                          totalSeconds: timer.duration.timeInterval,
                          endsAt: timer.isRunning ? wallClock().addingTimeInterval(remaining) : nil,
                          remainingSeconds: timer.isPaused ? remaining : nil, morphFocus: isMorphFocusOn)
        defaults.set(try? JSONEncoder().encode(saved), forKey: Self.defaultsKey)
    }
}
