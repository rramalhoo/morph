import Foundation
import Observation

@MainActor
@Observable
final class TimerService {
    private(set) var countdown = CountdownTimer()
    private(set) var stopwatch = Stopwatch()

    @ObservationIgnored var onCompleted: ((Duration) -> Void)?
    /// Fires with the remaining time when a local notification should be armed, and with `nil` to cancel.
    @ObservationIgnored var onNotificationChange: ((Duration?) -> Void)?

    @ObservationIgnored private var completionWork: (any ScheduledWork)?
    private let scheduler: any Scheduling

    init(scheduler: any Scheduling) {
        self.scheduler = scheduler
    }

    var now: ContinuousClock.Instant { scheduler.now }

    func startCountdown(_ duration: Duration) {
        countdown.start(duration, at: scheduler.now)
        arm(remaining: duration)
    }

    func pauseCountdown() {
        countdown.pause(at: scheduler.now)
        disarm()
    }

    func resumeCountdown() {
        countdown.resume(at: scheduler.now)
        arm(remaining: countdown.remaining(at: scheduler.now))
    }

    func resetCountdown() {
        countdown.reset()
        disarm()
    }

    func startStopwatch() { stopwatch.start(at: scheduler.now) }
    func pauseStopwatch() { stopwatch.pause(at: scheduler.now) }
    func resetStopwatch() { stopwatch.reset() }

    /// Turning the module off stops whatever is running.
    func stopAll() {
        resetCountdown()
        resetStopwatch()
    }

    private func arm(remaining: Duration) {
        completionWork?.cancel()
        completionWork = scheduler.schedule(after: remaining) { [weak self] in self?.finish() }
        onNotificationChange?(remaining)
    }

    private func disarm() {
        completionWork?.cancel()
        completionWork = nil
        onNotificationChange?(nil)
    }

    private func finish() {
        // The delay can land marginally early relative to the end instant.
        let end = scheduler.now.advanced(by: countdown.remaining(at: scheduler.now))
        guard countdown.complete(at: end) else { return }
        completionWork = nil
        onCompleted?(countdown.duration)
    }
}
