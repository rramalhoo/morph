import ApplicationServices
import Foundation
import Observation
import os

protocol AccessibilityPermission: Sendable {
    var isTrusted: Bool { get }
    /// Shows the system's prompt if access hasn't been decided.
    func request()
}

struct SystemAccessibilityPermission: AccessibilityPermission {
    var isTrusted: Bool { AXIsProcessTrusted() }

    func request() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}

/// Decides when Morph may hold the volume and brightness keys, and gives them back whenever that
/// stops being safe.
@MainActor
@Observable
final class LevelKeyService {
    enum Status: Equatable, Sendable {
        case off
        case needsPermission
        case active
        /// Permission looks fine but macOS refused, or the tap failed. macOS keeps the keys.
        case unavailable
    }

    /// Granting Accessibility doesn't notify the app, so this checks until it appears.
    private static let quickRetry = Duration.seconds(3)
    private static let quickRetries = 20
    private static let slowRetry = Duration.seconds(15)
    private static let healthCheck = Duration.seconds(30)

    private(set) var status = Status.off
    /// The current output or display refused a change, so its keys went back to macOS.
    private(set) var volumeHandedBack = false
    private(set) var brightnessHandedBack = false
    private(set) var brightnessSupported = false

    @ObservationIgnored var onUpdate: ((LevelUpdate, LevelKeyPress, LevelKeyModifiers) -> Void)?

    @ObservationIgnored private let tap: any LevelKeyTapping
    @ObservationIgnored private let permission: any AccessibilityPermission
    @ObservationIgnored private let brightness: any BrightnessControlling
    @ObservationIgnored private let scheduler: any Scheduling
    @ObservationIgnored private let engine: OSAllocatedUnfairLock<LevelKeyEngine>
    @ObservationIgnored private var policy = LevelKeyPolicy.off
    @ObservationIgnored private var isInstalled = false
    @ObservationIgnored private var wasTrustedAtInstall = false
    @ObservationIgnored private var retries = 0
    /// Replacement can be on before anyone touched the toggle, so the prompt is offered once a launch.
    @ObservationIgnored private var hasPrompted = false
    @ObservationIgnored private var work: (any ScheduledWork)?

    init(tap: any LevelKeyTapping, permission: any AccessibilityPermission, engine: LevelKeyEngine,
         brightness: any BrightnessControlling, scheduler: any Scheduling) {
        self.tap = tap
        self.permission = permission
        self.engine = OSAllocatedUnfairLock(initialState: engine)
        self.brightness = brightness
        self.scheduler = scheduler
    }

    func apply(_ policy: LevelKeyPolicy) {
        let changed = policy != self.policy
        self.policy = policy
        engine.withLock { $0.policy = policy }

        if policy.isOff {
            removeTap()
            status = .off
        } else if !isInstalled, changed || status == .off {
            retries = 0
            install()
            if status == .needsPermission, !hasPrompted {
                hasPrompted = true
                requestPermission()
            }
        }
    }

    func requestPermission() {
        guard !permission.isTrusted else { return }
        permission.request()
    }

    /// What can be controlled just changed, so an old refusal no longer applies.
    func outputDidChange() {
        engine.withLock { $0.clearOutputRejection() }
        volumeHandedBack = false
    }

    func displaysDidChange() {
        engine.withLock { $0.clearBrightnessRejection() }
        brightnessHandedBack = false
        refreshSupport()
    }

    func refreshSupport() {
        brightnessSupported = brightness.isSupported
    }

    private func install() {
        guard !policy.isOff, !isInstalled else { return }
        work?.cancel()

        let (engine, deliver) = (engine, deliverer())
        let installed = tap.install(handler: { press, modifiers, pointer in
            let decision = engine.withLock { $0.handle(press, modifiers: modifiers, pointer: pointer) }
            deliver(decision, press, modifiers)
            if case .consume = decision { return true }
            return false
        }, onFailure: { [weak self] in
            Task { @MainActor in self?.tapFailed() }
        })

        if installed {
            isInstalled = true
            wasTrustedAtInstall = permission.isTrusted
            status = .active
            scheduleHealthCheck()
        } else {
            status = permission.isTrusted ? .unavailable : .needsPermission
            scheduleRetry()
        }
    }

    private nonisolated func deliverer() -> @Sendable (LevelKeyDecision, LevelKeyPress, LevelKeyModifiers) -> Void {
        { [weak self] decision, press, modifiers in
            guard decision != .pass, decision != .consume(nil) else { return }
            Task { @MainActor in self?.receive(decision, press, modifiers) }
        }
    }

    private func receive(_ decision: LevelKeyDecision, _ press: LevelKeyPress, _ modifiers: LevelKeyModifiers) {
        switch decision {
        case .consume(let update?): onUpdate?(update, press, modifiers)
        case .handBack(let isBrightness):
            if isBrightness { brightnessHandedBack = true } else { volumeHandedBack = true }
        case .pass, .consume(nil): break
        }
    }

    private func removeTap() {
        work?.cancel()
        work = nil
        guard isInstalled else { return }
        tap.remove()
        isInstalled = false
    }

    /// Stays off until the policy, the session or the hardware changes.
    private func tapFailed() {
        guard isInstalled else { return }
        removeTap()
        status = .unavailable
    }

    private func scheduleRetry() {
        retries += 1
        let delay = retries <= Self.quickRetries ? Self.quickRetry : Self.slowRetry
        work = scheduler.schedule(after: delay) { [weak self] in self?.install() }
    }

    /// Revoking access doesn't tell the app either. Without this, the keys could be left with a
    /// tap that no longer has the right to hold them.
    private func scheduleHealthCheck() {
        work = scheduler.schedule(after: Self.healthCheck) { [weak self] in
            guard let self, self.isInstalled else { return }
            if self.wasTrustedAtInstall, !self.permission.isTrusted {
                self.removeTap()
                self.status = .needsPermission
                self.retries = 0
                self.scheduleRetry()
            } else {
                self.scheduleHealthCheck()
            }
        }
    }
}
