import Foundation

/// Where the user's session stands, as far as Morph can tell from public signals.
enum SessionState: Equatable, Sendable {
    case active
    /// The lock was announced. Private content is already gone; the island is settling.
    case locking
    case locked
    /// The user is back. Services are returning; the island hasn't revealed itself yet.
    case unlocking
    /// Asleep, or switched to another user. Nothing to show and nobody to show it to.
    case suspended
    /// Woke up without a definite answer about the lock. Treated as private until resolved.
    case unknown

    /// Whether private content may be on screen.
    var isPrivate: Bool { self == .active }
}

/// What macOS told Morph. Only the first four are definite; the display signals are ambiguous,
/// since a display can sleep with or without locking the session.
enum SessionSignal: Equatable, Sendable {
    /// `com.apple.screenIsLocked`.
    case screenLocked
    /// `com.apple.screenIsUnlocked`.
    case screenUnlocked
    /// Fast user switching moved away from this session.
    case sessionResigned
    /// Fast user switching came back. macOS authenticates before it does.
    case sessionActivated
    case systemWillSleep
    case systemDidWake
    case displaysDidSleep
    case displaysDidWake
}

enum SessionEffect: Equatable, Sendable {
    /// Drop private content and collapse the island, now.
    case conceal
    /// Stop rendering and anything that has no audience.
    case suspend
    /// Bring services and the window back, still concealed.
    case restore
    /// Show the island again. `welcome` only after the user proved who they are.
    case reveal(welcome: Bool)
    case scheduleSettle
    case scheduleReturn
    /// Asks the session once more, a little later. Never repeated: the answer settles it.
    case scheduleProbe
}

/// The pure rules for lock, unlock, sleep and user switching. `LockScreenCoordinator` adds timers
/// and the real notifications.
///
/// - A lock is only believed from a definite signal or the session's own lock flag, never from a
///   display going dark.
/// - Every timed step carries the generation it was scheduled in. Anything older is ignored, so
///   quick lock and unlock cycles can't stack welcomes or reveal a session that locked again.
/// - Repeating a signal for the state already reached does nothing.
struct LockScreenStateMachine: Sendable {
    private(set) var state: SessionState
    /// Bumped on every state change. Timed steps compare against it.
    private(set) var generation = 0
    private var suspendedForSleep = false

    init(initiallyLocked: Bool? = false) {
        state = initiallyLocked == true ? .locked : .active
    }

    /// `isLocked` is the session's own answer at the moment, when it has one.
    mutating func handle(_ signal: SessionSignal, isLocked: Bool?) -> [SessionEffect] {
        switch signal {
        case .screenLocked:
            return lock()
        case .screenUnlocked:
            return unlock()
        case .sessionResigned:
            suspendedForSleep = false
            return suspend()
        case .sessionActivated:
            guard state == .suspended, !suspendedForSleep else { return [] }
            return isLocked == true ? move(to: .locked) : unlock()
        case .systemWillSleep:
            // Locked stays locked: it's the more useful thing to know on waking.
            guard state != .locked else { return [] }
            suspendedForSleep = true
            return suspend()
        case .systemDidWake:
            guard state == .suspended, suspendedForSleep else { return [] }
            suspendedForSleep = false
            switch isLocked {
            case true?: return move(to: .locked)
            case false?: return wakeUnlocked()
            case nil: return move(to: .unknown) + [.scheduleProbe]
            }
        case .displaysDidSleep:
            return isLocked == true ? lock() : []
        case .displaysDidWake:
            switch (state, isLocked) {
            case (.active, true?): return lock()
            // The unlock notification went missing. The flag is the session's own word.
            case (.locked, false?): return unlock()
            case (.unknown, false?): return wakeUnlocked()
            default: return []
            }
        }
    }

    mutating func settleElapsed(generation scheduled: Int) -> [SessionEffect] {
        guard scheduled == generation, state == .locking else { return [] }
        return move(to: .locked) + [.suspend]
    }

    mutating func returnElapsed(generation scheduled: Int) -> [SessionEffect] {
        guard scheduled == generation, state == .unlocking else { return [] }
        return move(to: .active) + [.reveal(welcome: true)]
    }

    /// No answer twice means no evidence of a lock, and Morph doesn't invent one.
    mutating func probeElapsed(generation scheduled: Int, isLocked: Bool?) -> [SessionEffect] {
        guard scheduled == generation, state == .unknown else { return [] }
        return isLocked == true ? move(to: .locked) : wakeUnlocked()
    }

    private mutating func lock() -> [SessionEffect] {
        switch state {
        case .locking, .locked: return []
        // Already concealed and suspended. Only the name changes.
        case .suspended, .unknown: return move(to: .locked)
        case .active, .unlocking: return move(to: .locking) + [.conceal, .scheduleSettle]
        }
    }

    private mutating func unlock() -> [SessionEffect] {
        switch state {
        case .active, .unlocking: return []
        case .locking, .locked, .suspended, .unknown:
            suspendedForSleep = false
            return move(to: .unlocking) + [.restore, .scheduleReturn]
        }
    }

    private mutating func suspend() -> [SessionEffect] {
        switch state {
        case .suspended: return []
        case .locked, .unknown: return move(to: .suspended)
        case .locking: return move(to: .suspended) + [.suspend]
        case .active, .unlocking: return move(to: .suspended) + [.conceal, .suspend]
        }
    }

    /// Woke without a lock: back to work, but nobody unlocked anything, so no welcome.
    private mutating func wakeUnlocked() -> [SessionEffect] {
        move(to: .active) + [.restore, .reveal(welcome: false)]
    }

    private mutating func move(to next: SessionState) -> [SessionEffect] {
        guard next != state else { return [] }
        state = next
        generation += 1
        return []
    }
}
