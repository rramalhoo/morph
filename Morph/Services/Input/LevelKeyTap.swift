import AppKit
import CoreGraphics
import os

/// The source of key events. Separate so the rules around it can be tested without a real tap.
protocol LevelKeyTapping: AnyObject, Sendable {
    typealias Handler = @Sendable (LevelKeyPress, LevelKeyModifiers, CGPoint) -> Bool

    /// `handler` runs on the tap's thread and returns whether to swallow the event. `onFailure`
    /// means the tap gave up, and macOS has every key again. Returns false if macOS refused.
    func install(handler: @escaping Handler, onFailure: @escaping @Sendable () -> Void) -> Bool
    func remove()
}

/// A head-of-stream tap for `NX_SYSDEFINED` events only. It never sees typing.
///
/// It lives on its own thread so a busy main thread can't delay media keys. When the process ends
/// for any reason, the window server drops the tap, so no state outlives Morph and no cleanup is
/// needed for macOS to get its keys back.
final class SystemLevelKeyTap: LevelKeyTapping, @unchecked Sendable {
    private let session = OSAllocatedUnfairLock<LevelKeyTapSession?>(uncheckedState: nil)

    func install(handler: @escaping Handler, onFailure: @escaping @Sendable () -> Void) -> Bool {
        remove()
        let tapSession = LevelKeyTapSession(handler: handler, onFailure: onFailure)
        let info = Unmanaged.passRetained(tapSession)
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(1) << levelKeyEventType,
                                           callback: levelKeyTapCallback, userInfo: info.toOpaque()) else {
            info.release()
            return false
        }
        tapSession.run(port: port, release: info)
        session.withLockUnchecked { $0 = tapSession }
        return true
    }

    func remove() {
        let current = session.withLockUnchecked { state -> LevelKeyTapSession? in
            defer { state = nil }
            return state
        }
        current?.stop()
    }
}

private let levelKeyEventType: CGEventMask = 14 // NX_SYSDEFINED

private func levelKeyTapCallback(_: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                 info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let info else { return .passUnretained(event) }
    let session = Unmanaged<LevelKeyTapSession>.fromOpaque(info).takeUnretainedValue()
    return session.process(type, event) ? nil : .passUnretained(event)
}

private final class LevelKeyTapSession: @unchecked Sendable {
    private static let timeoutLimit = 3
    private static let timeoutWindow = Duration.seconds(60)

    private let handler: LevelKeyTapping.Handler
    private let onFailure: @Sendable () -> Void
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    private var timeouts: [ContinuousClock.Instant] = []

    init(handler: @escaping LevelKeyTapping.Handler, onFailure: @escaping @Sendable () -> Void) {
        self.handler = handler
        self.onFailure = onFailure
    }

    /// Returns once the tap is live.
    func run(port: CFMachPort, release: Unmanaged<LevelKeyTapSession>) {
        self.port = port
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            guard let port = self.port else { return }
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)
            runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            CFRunLoopRun()
            // Taken apart on the thread that uses it, once it can no longer deliver anything.
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFMachPortInvalidate(port)
            release.release()
        }
        thread.name = "com.athene.morph.level-keys"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    func stop() {
        guard let port, let runLoop else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFRunLoopStop(runLoop)
    }

    /// Returns whether to swallow the event.
    func process(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout:
            recoverFromTimeout()
            return false
        case .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        default:
            return autoreleasepool { handle(event) }
        }
    }

    private func handle(_ event: CGEvent) -> Bool {
        guard let system = NSEvent(cgEvent: event), system.type == .systemDefined,
              let press = LevelKeyPress(subtype: system.subtype.rawValue, data1: system.data1) else { return false }
        let flags = event.flags
        let modifiers = LevelKeyModifiers(shift: flags.contains(.maskShift), option: flags.contains(.maskAlternate),
                                          commandOrControl: flags.contains(.maskCommand) || flags.contains(.maskControl))
        return handler(press, modifiers, event.location)
    }

    /// macOS disables a tap that answers too slowly. Once is a hiccup; repeatedly means this tap
    /// is hurting input, so macOS keeps the keys until something changes.
    private func recoverFromTimeout() {
        let now = ContinuousClock.now
        timeouts = timeouts.filter { $0.duration(to: now) < Self.timeoutWindow } + [now]
        if timeouts.count < Self.timeoutLimit, let port {
            CGEvent.tapEnable(tap: port, enable: true)
        } else {
            onFailure()
        }
    }
}
