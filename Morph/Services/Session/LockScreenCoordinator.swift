import AppKit
import CoreGraphics
import Observation
import os

/// Delivers session signals. Separate so the coordinator can be driven from tests.
@MainActor
protocol SessionSignalSource: AnyObject {
    func start(_ receive: @escaping @MainActor (SessionSignal) -> Void)
    func stop()
}

/// The session's own answer to "is the screen locked", when it gives one.
protocol SessionProbing: Sendable {
    var isScreenLocked: Bool? { get }
}

/// `CGSessionCopyCurrentDictionary` is public. Its lock key isn't documented, but it's what the
/// window server reports: present and true while locked, absent otherwise. No dictionary at all
/// means no answer.
struct CGSessionProbe: SessionProbing {
    var isScreenLocked: Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}

/// Public workspace notifications, plus the long-standing distributed lock notifications. Morph
/// only listens: nothing here touches the lock screen.
@MainActor
final class SystemSessionSignals: SessionSignalSource {
    private var tokens: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

    func start(_ receive: @escaping @MainActor (SessionSignal) -> Void) {
        guard tokens.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let events: [(NotificationCenter, Notification.Name, SessionSignal)] = [
            (distributed, Notification.Name("com.apple.screenIsLocked"), .screenLocked),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), .screenUnlocked),
            (workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionResigned),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification, .sessionActivated),
            (workspace, NSWorkspace.willSleepNotification, .systemWillSleep),
            (workspace, NSWorkspace.didWakeNotification, .systemDidWake),
            (workspace, NSWorkspace.screensDidSleepNotification, .displaysDidSleep),
            (workspace, NSWorkspace.screensDidWakeNotification, .displaysDidWake),
        ]
        for (center, name, signal) in events {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { receive(signal) }
            }
            tokens.append((center, token))
        }
    }

    func stop() {
        tokens.forEach { $0.center.removeObserver($0.token) }
        tokens = []
    }
}

/// How the user came back.
struct SessionReturn: Equatable, Sendable {
    /// They unlocked or switched back, rather than the Mac just waking.
    var welcome: Bool
    /// How long the session was private, if known.
    var awayFor: Duration?
}

/// Follows lock, unlock, sleep and user switching, and tells the rest of Morph when to hide,
/// pause, come back and say hello. One owner for all of it, so the steps can't race each other.
@MainActor
@Observable
final class LockScreenCoordinator {
    static let settleDelay = Duration.milliseconds(450)
    static let returnDelay = Duration.milliseconds(350)
    static let probeDelay = Duration.seconds(2)

    private(set) var state = SessionState.active
    private(set) var returnCount = 0

    /// Called in order. A step may run more than once over a session, never twice in a row.
    @ObservationIgnored var onConceal: (() -> Void)?
    @ObservationIgnored var onSuspend: (() -> Void)?
    @ObservationIgnored var onRestore: (() -> Void)?
    @ObservationIgnored var onReveal: ((SessionReturn) -> Void)?

    @ObservationIgnored private var machine = LockScreenStateMachine()
    @ObservationIgnored private var work: (any ScheduledWork)?
    @ObservationIgnored private var privateSince: ContinuousClock.Instant?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private let signals: any SessionSignalSource
    @ObservationIgnored private let probe: any SessionProbing
    @ObservationIgnored private let scheduler: any Scheduling
    @ObservationIgnored private let log = Logger(subsystem: "com.athene.morph", category: "Session")

    init(signals: any SessionSignalSource, probe: any SessionProbing, scheduler: any Scheduling) {
        self.signals = signals
        self.probe = probe
        self.scheduler = scheduler
    }

    /// A launch behind the lock screen starts concealed.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        if probe.isScreenLocked == true {
            machine = LockScreenStateMachine(initiallyLocked: true)
            perform([.conceal, .suspend])
        }
        signals.start { [weak self] signal in self?.receive(signal) }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        signals.stop()
        work?.cancel()
        work = nil
    }

    func receive(_ signal: SessionSignal) {
        let effects = machine.handle(signal, isLocked: probe.isScreenLocked)
        log.info("\(String(describing: signal), privacy: .public) -> \(String(describing: self.machine.state), privacy: .public)")
        perform(effects)
    }

    private func perform(_ effects: [SessionEffect]) {
        let next = machine.state
        if next != state {
            if state.isPrivate, !next.isPrivate { privateSince = scheduler.now }
            state = next
        }
        for effect in effects {
            switch effect {
            case .conceal: onConceal?()
            case .suspend: onSuspend?()
            case .restore: onRestore?()
            case .reveal(let welcome):
                returnCount += 1
                let away = privateSince.map { $0.duration(to: scheduler.now) }
                privateSince = nil
                onReveal?(SessionReturn(welcome: welcome, awayFor: away))
            case .scheduleSettle:
                schedule(after: Self.settleDelay) { $0.settleElapsed(generation: $1) }
            case .scheduleReturn:
                schedule(after: Self.returnDelay) { $0.returnElapsed(generation: $1) }
            case .scheduleProbe:
                let probe = probe
                schedule(after: Self.probeDelay) { $0.probeElapsed(generation: $1, isLocked: probe.isScreenLocked) }
            }
        }
    }

    /// One timed step at a time; each one names the generation it belongs to.
    private func schedule(after delay: Duration,
                          _ step: @escaping (inout LockScreenStateMachine, Int) -> [SessionEffect]) {
        work?.cancel()
        let generation = machine.generation
        work = scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            self.work = nil
            self.perform(step(&self.machine, generation))
        }
    }
}
