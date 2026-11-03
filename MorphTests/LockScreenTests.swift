import Foundation
import Testing
@testable import Morph

@MainActor
final class StubSessionSignals: SessionSignalSource {
    var receive: (@MainActor (SessionSignal) -> Void)?

    func start(_ receive: @escaping @MainActor (SessionSignal) -> Void) { self.receive = receive }
    func stop() { receive = nil }
    func send(_ signal: SessionSignal) { receive?(signal) }
}

final class StubSessionProbe: SessionProbing, @unchecked Sendable {
    var isScreenLocked: Bool? = false
}

final class StubNotificationCenter: NotificationCentering, @unchecked Sendable {
    var status = NotificationAuthorization.authorized
    var grants = true
    var requests = 0
    var added: [NotificationRequest] = []
    var removed: [String] = []

    func authorization() async -> NotificationAuthorization { status }
    func requestAuthorization() async -> Bool {
        requests += 1
        status = grants ? .authorized : .denied
        return grants
    }
    func add(_ request: NotificationRequest) async -> Bool { added.append(request); return true }
    func remove(identifiers: [String]) { removed += identifiers }
}

@Suite("Lock screen state machine")
struct LockScreenStateMachineTests {
    @Test func lockConcealsThenSettles() {
        var machine = LockScreenStateMachine()
        #expect(machine.handle(.screenLocked, isLocked: true) == [.conceal, .scheduleSettle])
        #expect(machine.state == .locking)
        #expect(machine.settleElapsed(generation: machine.generation) == [.suspend])
        #expect(machine.state == .locked)
    }

    @Test func unlockRestoresThenRevealsWithWelcome() {
        var machine = LockScreenStateMachine(initiallyLocked: true)
        #expect(machine.handle(.screenUnlocked, isLocked: false) == [.restore, .scheduleReturn])
        #expect(machine.state == .unlocking)
        #expect(machine.returnElapsed(generation: machine.generation) == [.reveal(welcome: true)])
        #expect(machine.state == .active)
    }

    @Test func duplicateSignalsDoNothing() {
        var machine = LockScreenStateMachine()
        _ = machine.handle(.screenLocked, isLocked: true)
        #expect(machine.handle(.screenLocked, isLocked: true).isEmpty)
        _ = machine.handle(.screenUnlocked, isLocked: false)
        #expect(machine.handle(.screenUnlocked, isLocked: false).isEmpty)
    }

    @Test func invalidTransitionsAreIgnored() {
        var machine = LockScreenStateMachine()
        #expect(machine.handle(.screenUnlocked, isLocked: false).isEmpty)
        #expect(machine.settleElapsed(generation: machine.generation).isEmpty)
        #expect(machine.returnElapsed(generation: machine.generation).isEmpty)
        #expect(machine.handle(.systemDidWake, isLocked: false).isEmpty)
        #expect(machine.state == .active)
    }

    @Test func aDarkDisplayAloneIsNotALock() {
        var machine = LockScreenStateMachine()
        #expect(machine.handle(.displaysDidSleep, isLocked: false).isEmpty)
        #expect(machine.handle(.displaysDidSleep, isLocked: nil).isEmpty)
        #expect(machine.state == .active)
    }

    @Test func sleepSuspendsAndWakeWithoutLockHasNoWelcome() {
        var machine = LockScreenStateMachine()
        #expect(machine.handle(.systemWillSleep, isLocked: false) == [.conceal, .suspend])
        #expect(machine.state == .suspended)
        #expect(machine.handle(.systemDidWake, isLocked: false) == [.restore, .reveal(welcome: false)])
        #expect(machine.state == .active)
    }

    @Test func wakeIntoLockStaysLockedUntilUnlock() {
        var machine = LockScreenStateMachine()
        _ = machine.handle(.systemWillSleep, isLocked: false)
        #expect(machine.handle(.systemDidWake, isLocked: true).isEmpty)
        #expect(machine.state == .locked)
        #expect(machine.handle(.screenUnlocked, isLocked: false) == [.restore, .scheduleReturn])
    }

    @Test func wakeWithoutAnAnswerProbesOnceAndDoesNotInventALock() {
        var machine = LockScreenStateMachine()
        _ = machine.handle(.systemWillSleep, isLocked: false)
        #expect(machine.handle(.systemDidWake, isLocked: nil) == [.scheduleProbe])
        #expect(machine.state == .unknown)
        #expect(machine.probeElapsed(generation: machine.generation, isLocked: nil) == [.restore, .reveal(welcome: false)])
        #expect(machine.state == .active)
    }

    @Test func userSwitchSuspendsAndReturnWelcomes() {
        var machine = LockScreenStateMachine()
        #expect(machine.handle(.sessionResigned, isLocked: false) == [.conceal, .suspend])
        #expect(machine.handle(.sessionActivated, isLocked: false) == [.restore, .scheduleReturn])
    }

    @Test func staleTimedStepsAreIgnoredAfterQuickCycles() {
        var machine = LockScreenStateMachine()
        _ = machine.handle(.screenLocked, isLocked: true)
        let lockGeneration = machine.generation
        _ = machine.handle(.screenUnlocked, isLocked: false)
        let firstUnlock = machine.generation
        _ = machine.handle(.screenLocked, isLocked: true)
        #expect(machine.settleElapsed(generation: lockGeneration).isEmpty)
        #expect(machine.returnElapsed(generation: firstUnlock).isEmpty)
        #expect(machine.state == .locking)
    }
}

@Suite("Lock screen coordinator")
@MainActor
struct LockScreenCoordinatorTests {
    private func make() -> (LockScreenCoordinator, StubSessionSignals, StubSessionProbe, ManualScheduler, [String]) {
        let (signals, probe, scheduler) = (StubSessionSignals(), StubSessionProbe(), ManualScheduler())
        return (LockScreenCoordinator(signals: signals, probe: probe, scheduler: scheduler), signals, probe, scheduler, [])
    }

    @Test func fullCycleCallsEachStepOnce() {
        let (coordinator, signals, probe, scheduler, _) = make()
        var steps: [String] = []
        coordinator.onConceal = { steps.append("conceal") }
        coordinator.onSuspend = { steps.append("suspend") }
        coordinator.onRestore = { steps.append("restore") }
        coordinator.onReveal = { steps.append("reveal \($0.welcome)") }
        coordinator.start()

        probe.isScreenLocked = true
        signals.send(.screenLocked)
        signals.send(.screenLocked)
        scheduler.advance(by: .seconds(1))
        #expect(coordinator.state == .locked)

        probe.isScreenLocked = false
        signals.send(.screenUnlocked)
        signals.send(.screenUnlocked)
        scheduler.advance(by: .seconds(1))
        #expect(coordinator.state == .active)
        #expect(steps == ["conceal", "suspend", "restore", "reveal true"])
    }

    @Test func rapidUnlocksRevealOnce() {
        let (coordinator, signals, probe, scheduler, _) = make()
        var reveals = 0
        coordinator.onReveal = { _ in reveals += 1 }
        coordinator.start()
        for _ in 0..<4 {
            probe.isScreenLocked = true
            signals.send(.screenLocked)
            probe.isScreenLocked = false
            signals.send(.screenUnlocked)
            scheduler.advance(by: .milliseconds(100))
        }
        scheduler.advance(by: .seconds(1))
        #expect(reveals == 1)
        #expect(coordinator.returnCount == 1)
    }

    @Test func launchBehindTheLockStartsConcealed() {
        let (coordinator, _, probe, _, _) = make()
        probe.isScreenLocked = true
        var concealed = false
        coordinator.onConceal = { concealed = true }
        coordinator.start()
        #expect(coordinator.state == .locked)
        #expect(concealed)
    }

    @Test func awayTimeIsReported() {
        let (coordinator, signals, probe, scheduler, _) = make()
        var away: Duration?
        coordinator.onReveal = { away = $0.awayFor }
        coordinator.start()
        probe.isScreenLocked = true
        signals.send(.screenLocked)
        scheduler.advance(by: .seconds(120))
        probe.isScreenLocked = false
        signals.send(.screenUnlocked)
        scheduler.advance(by: .seconds(1))
        #expect(away.map { $0 >= .seconds(120) } == true)
    }
}

@Suite("Lock screen activities and island")
@MainActor
struct LockScreenActivityTests {
    @Test func lockDropsPrivateActivitiesAndKeepsImportantOnes() {
        let scheduler = ManualScheduler()
        let activities = ActivityManager(scheduler: scheduler)
        activities.present(.nowPlaying(title: "Song", artist: "Artist"))
        activities.present(.timerCompleted(duration: 60))
        activities.setSuppressed(true)
        #expect(activities.current == nil)
        #expect(!activities.isActive(dedupeKey: "now-playing"))
        #expect(activities.isActive(dedupeKey: "timer"))
    }

    @Test func timerCompletingWhileLockedShowsAfterUnlock() {
        let scheduler = ManualScheduler()
        let activities = ActivityManager(scheduler: scheduler)
        activities.setSuppressed(true)
        activities.present(.timerCompleted(duration: 60))
        #expect(activities.current == nil)
        activities.setSuppressed(false)
        #expect(activities.current?.dedupeKey == "timer")
    }

    @Test func expiredActivitiesAreNotRecreated() {
        let scheduler = ManualScheduler()
        let activities = ActivityManager(scheduler: scheduler)
        activities.setSuppressed(true)
        activities.present(.focusFinished(.focus))
        scheduler.advance(by: .seconds(600))
        activities.setSuppressed(false)
        #expect(activities.current == nil)
    }

    @Test func welcomeYieldsToLevelAndOutranksTimer() {
        let welcome = IslandActivity(.welcome(WelcomeContent(greeting: .morning, date: .now)), at: .now)
        #expect(welcome.priority > .timer)
        #expect(welcome.priority < .level)
        #expect(welcome.content.isPrivate)
        #expect(!welcome.content.appearsInRecent)
    }

    @Test func concealedIslandShowsOnlyTheNotch() {
        let scheduler = ManualScheduler()
        let preferences = MorphPreferences(defaults: makeDefaults())
        let activities = ActivityManager(scheduler: scheduler)
        let island = IslandController(preferences: preferences, activities: activities, timers: TimerService(scheduler: scheduler),
                                      media: MediaController(providers: [], events: StubMediaEvents(), scheduler: scheduler),
                                      volume: VolumeService(system: StubOutputSystem(), scheduler: scheduler), scheduler: scheduler)
        island.send(.openRequested)
        island.isFileDragActive = true
        island.setConcealed(true)
        #expect(island.presentation == .idle)
        #expect(island.mode == .idle)
        #expect(!island.isFileDragActive)
        island.setConcealed(false)
        #expect(island.presentation == .idle)
    }

    @Test func welcomeLayoutIsFixedAndFitsTheCanvas() {
        let layout = IslandLayout(notch: CGSize(width: 185, height: 32), size: .regular)
        let short = IslandActivity(.welcome(WelcomeContent(greeting: .morning, date: .now)), at: .now)
        let full = IslandActivity(.welcome(WelcomeContent(greeting: .evening, date: .now,
                                                          battery: .init(percentage: 80, isCharging: true, symbol: "battery.100percent.bolt"),
                                                          music: .init(title: "A", artist: "B", isPlaying: true))), at: .now)
        let size = layout.islandSize(for: .activity(short))
        #expect(size == layout.islandSize(for: .activity(full)))
        #expect(size.width <= IslandLayout.canvas.width && size.height <= IslandLayout.canvas.height)
    }
}

@Suite("Welcome")
struct WelcomeTests {
    @Test func greetingFollowsTheHourAndShortAbsences() {
        #expect(WelcomeGreeting.resolve(hour: 8, awayFor: nil) == .morning)
        #expect(WelcomeGreeting.resolve(hour: 14, awayFor: .seconds(7200)) == .afternoon)
        #expect(WelcomeGreeting.resolve(hour: 22, awayFor: nil) == .evening)
        #expect(WelcomeGreeting.resolve(hour: 3, awayFor: nil) == .evening)
        #expect(WelcomeGreeting.resolve(hour: 14, awayFor: .seconds(300)) == .welcomeBack)
    }

    @Test func greetingUsesThePreferredLanguage() {
        #expect(WelcomeGreeting.morning.text(languages: ["pt-BR"]) == "Bom dia")
        #expect(WelcomeGreeting.welcomeBack.text(languages: ["pt-BR"]) == "Bem-vindo de volta")
        #expect(WelcomeGreeting.evening.text(languages: ["ja-JP", "es-ES"]) == "Buenas noches")
        #expect(WelcomeGreeting.afternoon.text(languages: ["ja-JP"]) == "Good afternoon")
    }

    private let policy = WelcomePolicy(integrationEnabled: true, welcomeEnabled: true, activitiesEnabled: true,
                                       islandIdle: true, cinemaNormal: true, currentPriority: nil)

    @Test func welcomeOnlyAfterAnUnlock() {
        #expect(policy.allows(SessionReturn(welcome: true)))
        #expect(!policy.allows(SessionReturn(welcome: false)))
    }

    @Test func welcomeStaysAwayWhenBusyOrOff() {
        var busy = policy
        busy.islandIdle = false
        #expect(!busy.allows(SessionReturn(welcome: true)))
        var critical = policy
        critical.currentPriority = .critical
        #expect(!critical.allows(SessionReturn(welcome: true)))
        var off = policy
        off.welcomeEnabled = false
        #expect(!off.allows(SessionReturn(welcome: true)))
        var timer = policy
        timer.currentPriority = .timer
        #expect(timer.allows(SessionReturn(welcome: true)))
    }
}

@Suite("Notifications")
@MainActor
struct NotificationServiceTests {
    private func make(_ status: NotificationAuthorization = .authorized) async -> (NotificationService, StubNotificationCenter, ManualScheduler) {
        let center = StubNotificationCenter()
        center.status = status
        let scheduler = ManualScheduler()
        let service = NotificationService(center: center, scheduler: scheduler)
        service.settings = NotificationSettings(enabled: true, previews: false, timer: true, focus: true, lowBattery: true, deviceAlerts: true)
        service.refreshAuthorization()
        await waitUntil { service.authorization == status }
        return (service, center, scheduler)
    }

    @Test func authorizedNotificationIsDelivered() async {
        let (service, center, _) = await make()
        #expect(service.post(MorphNotification(kind: .timer, identifier: "t", title: "Timer finished", delay: .seconds(60))) == .sent)
        await waitUntil { !center.added.isEmpty }
        #expect(center.added.first?.delay == .seconds(60))
        #expect(center.removed.contains("t"))
    }

    @Test func deniedNotificationIsHeldBackWithoutAsking() async {
        let (service, center, _) = await make(.denied)
        #expect(service.post(MorphNotification(kind: .lowBattery, identifier: "b", title: "Battery low")) == .denied)
        service.requestAuthorization()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(center.added.isEmpty)
        #expect(center.requests == 0)
    }

    @Test func undecidedAsksOnceThenDelivers() async {
        let (service, center, _) = await make(.notDetermined)
        service.post(MorphNotification(kind: .timer, identifier: "t", title: "Timer finished"))
        await waitUntil { !center.added.isEmpty }
        #expect(center.requests == 1)
        #expect(service.authorization == .authorized)
    }

    @Test func previewsAreOffByDefault() async {
        let (service, center, _) = await make()
        service.post(MorphNotification(kind: .deviceAlert, identifier: "d", title: "Device battery low", detail: "AirPods: 10%"))
        await waitUntil { !center.added.isEmpty }
        #expect(center.added.first?.body == nil)

        service.settings.previews = true
        service.post(MorphNotification(kind: .deviceAlert, identifier: "e", title: "Device battery low", detail: "AirPods: 10%"))
        await waitUntil { center.added.count == 2 }
        #expect(center.added.last?.body == "AirPods: 10%")
    }

    @Test func repeatsAreRateLimited() async {
        let (service, _, scheduler) = await make()
        let alert = MorphNotification(kind: .lowBattery, identifier: "b", title: "Battery low")
        #expect(service.post(alert) == .sent)
        #expect(service.post(alert) == .rateLimited)
        scheduler.advance(by: .seconds(11 * 60))
        #expect(service.post(alert) == .sent)
    }

    @Test func switchesAreRespected() async {
        let (service, _, _) = await make()
        service.settings.lowBattery = false
        #expect(service.post(MorphNotification(kind: .lowBattery, identifier: "b", title: "x")) == .disabled)
        service.settings.lowBattery = true
        service.settings.enabled = false
        #expect(service.post(MorphNotification(kind: .timer, identifier: "t", title: "x")) == .disabled)
    }
}

@Suite("Lock screen preferences")
@MainActor
struct LockScreenPreferencesTests {
    @Test func defaultsAndPersistence() {
        let defaults = makeDefaults()
        let first = MorphPreferences(defaults: defaults)
        #expect(first.lockScreenEnabled && first.welcomeEnabled && !first.notificationPreviews)
        first.welcomeDuration = 5
        first.lockAnimation = false
        first.notificationPreviews = true
        let second = MorphPreferences(defaults: defaults)
        #expect(second.welcomeDuration == 5)
        #expect(!second.lockAnimation)
        #expect(second.notificationPreviews)
    }
}
