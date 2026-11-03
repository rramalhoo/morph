import Foundation
import Testing
@testable import Morph

@Suite("Pomodoro")
@MainActor
struct PomodoroTests {
    private let scheduler = ManualScheduler()

    private func service(defaults: UserDefaults = makeDefaults(), wallClock: @escaping () -> Date = { .now }) -> FocusService {
        let service = FocusService(scheduler: scheduler, defaults: defaults, wallClock: wallClock)
        service.configuration = FocusConfiguration()
        return service
    }

    @Test func defaultsAreTheClassicOnes() {
        let preferences = MorphPreferences(defaults: makeDefaults())
        #expect(preferences.focusMinutes == 25)
        #expect(preferences.shortBreakMinutes == 5)
        #expect(preferences.longBreakMinutes == 15)
    }

    @Test func noDriftAcrossManySmallTicks() {
        let subject = service()
        subject.startFocus()
        for _ in 0..<1499 { scheduler.advance(by: .seconds(1)) }
        #expect(subject.session.timer.remaining(at: scheduler.now) == .seconds(1))
    }

    @Test func aFocusSessionEndsAndGoesToABreak() {
        let subject = service()
        var finished: [FocusPhase] = []
        subject.onFinished = { finished.append($0) }
        subject.startFocus()
        scheduler.advance(by: .seconds(25 * 60))
        #expect(finished == [.focus])
        #expect(subject.session.phase == .shortBreak)
        #expect(subject.session.timer.isRunning)
        #expect(subject.session.completedFocus == 1)
    }

    @Test func withoutAutoBreakItStops() {
        let subject = service()
        subject.configuration.autoBreak = false
        subject.startFocus()
        scheduler.advance(by: .seconds(25 * 60))
        #expect(!subject.session.isActive)
        #expect(subject.session.completedFocus == 1)
    }

    @Test func theFourthSessionEarnsALongBreak() {
        let subject = service()
        subject.configuration.autoBreak = false
        for round in 1...3 {
            subject.startFocus()
            scheduler.advance(by: .seconds(25 * 60))
            subject.start(.shortBreak)
            scheduler.advance(by: .seconds(5 * 60))
            #expect(subject.session.completedFocus == round)
        }
        subject.configuration.autoBreak = true
        subject.startFocus()
        scheduler.advance(by: .seconds(25 * 60))
        #expect(subject.session.phase == .longBreak)
        scheduler.advance(by: .seconds(15 * 60))
        #expect(subject.session.completedFocus == 0)
        #expect(!subject.session.isActive)
    }

    @Test func pausingStopsTimeAndResumingContinuesIt() {
        let subject = service()
        var finished = 0
        subject.onFinished = { _ in finished += 1 }
        subject.startFocus()
        scheduler.advance(by: .seconds(60))
        subject.pause()
        scheduler.advance(by: .seconds(3600))
        #expect(finished == 0)
        #expect(subject.session.timer.remaining(at: scheduler.now) == .seconds(24 * 60))
        subject.resume()
        scheduler.advance(by: .seconds(24 * 60))
        #expect(finished == 1)
    }

    @Test func stoppingCancelsEverything() {
        let subject = service()
        var notified: [Duration?] = []
        var finished = 0
        subject.onFinished = { _ in finished += 1 }
        subject.onNotificationChange = { remaining, _ in notified.append(remaining) }
        subject.startFocus()
        subject.stop()
        scheduler.advance(by: .seconds(3600))
        #expect(finished == 0)
        #expect(notified == [.seconds(1500), nil])
        #expect(!subject.isQuiet)
    }

    @Test func skippingMovesOnWithoutAnnouncing() {
        let subject = service()
        var finished = 0
        subject.onFinished = { _ in finished += 1 }
        subject.startFocus()
        subject.skip()
        #expect(subject.session.phase == .shortBreak)
        #expect(finished == 0)
    }

    @Test func aSessionSurvivesARelaunch() {
        let defaults = makeDefaults()
        let start = Date(timeIntervalSince1970: 1000)
        var clock = start
        let first = service(defaults: defaults) { clock }
        first.startFocus()

        clock = start.addingTimeInterval(600)
        let second = service(defaults: defaults) { clock }
        second.restore()
        #expect(second.session.timer.isRunning)
        #expect(second.session.timer.remaining(at: scheduler.now) == .seconds(900))
        #expect(second.session.timer.duration == .seconds(1500))
        #expect(second.session.fraction(at: scheduler.now) == 0.4)
    }

    @Test func aPausedSessionSurvivesARelaunchAtTheSamePoint() {
        let defaults = makeDefaults()
        let first = service(defaults: defaults)
        first.startFocus()
        scheduler.advance(by: .seconds(100))
        first.pause()
        let second = service(defaults: defaults)
        second.restore()
        #expect(second.session.timer.isPaused)
        #expect(second.session.timer.remaining(at: scheduler.now) == .seconds(1400))
    }

    @Test func aSessionThatEndedWhileClosedIsNotResurrected() {
        let defaults = makeDefaults()
        let start = Date(timeIntervalSince1970: 1000)
        var clock = start
        let first = service(defaults: defaults) { clock }
        first.startFocus()
        clock = start.addingTimeInterval(4000)
        let second = service(defaults: defaults) { clock }
        var finished = 0
        second.onFinished = { _ in finished += 1 }
        second.restore()
        #expect(!second.session.isActive)
        #expect(finished == 0)
    }

    @Test func morphFocusIsSeparateAndRemembered() {
        let defaults = makeDefaults()
        let first = service(defaults: defaults)
        #expect(!first.isQuiet)
        first.setMorphFocus(true)
        #expect(first.isQuiet)
        let second = service(defaults: defaults)
        second.restore()
        #expect(second.isMorphFocusOn)
    }

    @Test func aFocusPhaseIsQuietAndABreakIsNot() {
        let subject = service()
        subject.startFocus()
        #expect(subject.isQuiet)
        subject.start(.shortBreak)
        #expect(!subject.isQuiet)
    }
}
