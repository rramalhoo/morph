import Testing
@testable import Morph

@Suite("Countdown")
struct CountdownTests {
    private let t0 = ContinuousClock.now

    @Test func remainingComesFromTheClockNotFromTicks() {
        var timer = CountdownTimer()
        timer.start(.seconds(60), at: t0)
        #expect(timer.remaining(at: t0.advanced(by: .milliseconds(12_345))) == .milliseconds(47_655))
    }

    @Test func pauseFreezesAndResumeContinues() {
        var timer = CountdownTimer()
        timer.start(.seconds(60), at: t0)
        timer.pause(at: t0.advanced(by: .seconds(10)))
        #expect(timer.remaining(at: t0.advanced(by: .seconds(500))) == .seconds(50))
        timer.resume(at: t0.advanced(by: .seconds(500)))
        #expect(timer.remaining(at: t0.advanced(by: .seconds(530))) == .seconds(20))
    }

    @Test func neverGoesNegative() {
        var timer = CountdownTimer()
        timer.start(.seconds(1), at: t0)
        #expect(timer.remaining(at: t0.advanced(by: .seconds(5))) == .zero)
    }

    @Test func completesOnceAndOnlyAtTheEnd() {
        var timer = CountdownTimer()
        timer.start(.seconds(1), at: t0)
        #expect(timer.complete(at: t0) == false)
        #expect(timer.complete(at: t0.advanced(by: .seconds(1))) == true)
        #expect(timer.complete(at: t0.advanced(by: .seconds(2))) == false)
        #expect(timer.phase == .finished)
    }

    @Test func zeroDurationDoesNotStart() {
        var timer = CountdownTimer()
        timer.start(.zero, at: t0)
        #expect(timer.phase == .idle)
    }

    @Test func resetReturnsToIdle() {
        var timer = CountdownTimer()
        timer.start(.seconds(5), at: t0)
        timer.reset()
        #expect(timer.phase == .idle)
    }
}

@Suite("Stopwatch")
struct StopwatchTests {
    private let t0 = ContinuousClock.now

    @Test func accumulatesAcrossPauses() {
        var watch = Stopwatch()
        watch.start(at: t0)
        watch.pause(at: t0.advanced(by: .seconds(3)))
        #expect(watch.elapsed(at: t0.advanced(by: .seconds(100))) == .seconds(3))
        watch.start(at: t0.advanced(by: .seconds(100)))
        #expect(watch.elapsed(at: t0.advanced(by: .milliseconds(101_500))) == .milliseconds(4500))
    }

    @Test func startingTwiceKeepsTheOriginalInstant() {
        var watch = Stopwatch()
        watch.start(at: t0)
        watch.start(at: t0.advanced(by: .seconds(5)))
        #expect(watch.elapsed(at: t0.advanced(by: .seconds(10))) == .seconds(10))
    }

    @Test func resetClears() {
        var watch = Stopwatch()
        watch.start(at: t0)
        watch.reset()
        #expect(!watch.isRunning)
        #expect(watch.elapsed(at: t0.advanced(by: .seconds(1))) == .zero)
    }
}

@Suite("Timer service")
@MainActor
struct TimerServiceTests {
    private let scheduler = ManualScheduler()

    @Test func firesCompletionExactlyOnce() {
        let service = TimerService(scheduler: scheduler)
        var completions: [Duration] = []
        service.onCompleted = { completions.append($0) }
        service.startCountdown(.seconds(10))
        scheduler.advance(by: .seconds(9))
        #expect(completions.isEmpty)
        scheduler.advance(by: .seconds(5))
        #expect(completions == [.seconds(10)])
        #expect(service.countdown.phase == .finished)
    }

    @Test func pauseStopsCompletionAndResumeKeepsRemainingTime() {
        let service = TimerService(scheduler: scheduler)
        var completed = false
        service.onCompleted = { _ in completed = true }
        service.startCountdown(.seconds(10))
        scheduler.advance(by: .seconds(4))
        service.pauseCountdown()
        scheduler.advance(by: .seconds(60))
        #expect(!completed)
        service.resumeCountdown()
        scheduler.advance(by: .seconds(5))
        #expect(!completed)
        scheduler.advance(by: .seconds(1))
        #expect(completed)
    }

    @Test func resetCancelsPendingCompletion() {
        let service = TimerService(scheduler: scheduler)
        var completed = false
        service.onCompleted = { _ in completed = true }
        service.startCountdown(.seconds(10))
        service.resetCountdown()
        scheduler.advance(by: .seconds(60))
        #expect(!completed)
        #expect(scheduler.pendingCount == 0)
    }

    @Test func restartingReplacesThePreviousTimer() {
        let service = TimerService(scheduler: scheduler)
        var count = 0
        service.onCompleted = { _ in count += 1 }
        service.startCountdown(.seconds(5))
        scheduler.advance(by: .seconds(1))
        service.startCountdown(.seconds(30))
        scheduler.advance(by: .seconds(10))
        #expect(count == 0)
        scheduler.advance(by: .seconds(20))
        #expect(count == 1)
    }

    @Test func notificationFollowsTheTimer() {
        let service = TimerService(scheduler: scheduler)
        var events: [Duration?] = []
        service.onNotificationChange = { events.append($0) }
        service.startCountdown(.seconds(10))
        service.pauseCountdown()
        #expect(events == [.seconds(10), nil])
    }

    @Test func formatting() {
        #expect(TimeFormat.clock(65) == "1:05")
        #expect(TimeFormat.clock(3723) == "1:02:03")
        #expect(TimeFormat.countdown(59.2) == "1:00")
        #expect(TimeFormat.stopwatch(7.45) == "0:07.4")
    }
}
