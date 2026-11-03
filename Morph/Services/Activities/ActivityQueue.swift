import Foundation

/// The pure scheduling rules for activities. `ActivityManager` adds timers on top.
///
/// - The highest priority activity wins. Within a priority, the oldest goes first.
/// - An activity sharing a `dedupeKey` with a live or queued one replaces it in place.
/// - A strictly higher priority interrupts what's showing; the interrupted activity returns to the
///   queue only if it asks to.
/// - While held (the user is in the island), only `.timer` and above may present.
/// - While a control is being dragged, only `.critical` may present, and nothing is taken away.
/// - Queued activities that waited past `maximumWait` are dropped rather than shown late.
struct ActivityQueue: Sendable {
    enum Outcome: Equatable, Sendable {
        case presented
        case queued
        /// Merged into the showing activity; its timer should restart.
        case refreshedCurrent
        case refreshedPending
    }

    static let capacity = 8

    private(set) var current: IslandActivity?
    private(set) var pending: [IslandActivity] = []
    private(set) var isHeld = false
    private(set) var isInteracting = false

    private func canPresent(_ activity: IslandActivity) -> Bool {
        if isInteracting { return activity.priority >= .critical }
        return !isHeld || activity.priority >= .timer
    }

    @discardableResult
    mutating func enqueue(_ activity: IslandActivity) -> Outcome {
        if let showing = current, showing.dedupeKey == activity.dedupeKey {
            current = activity.keeping(id: showing.id)
            return .refreshedCurrent
        }

        if let index = pending.firstIndex(where: { $0.dedupeKey == activity.dedupeKey }) {
            pending[index] = activity
            sortPending()
            return .refreshedPending
        }

        guard canPresent(activity) else {
            insert(activity)
            return .queued
        }

        guard let showing = current else {
            current = activity
            return .presented
        }

        guard activity.priority > showing.priority else {
            insert(activity)
            return .queued
        }

        if showing.resumesAfterInterruption { insert(showing) }
        current = activity
        return .presented
    }

    /// Ends the showing activity and promotes the next one.
    mutating func finishCurrent(at now: ContinuousClock.Instant) {
        current = nil
        promote(at: now)
    }

    /// Promotes the next eligible activity if nothing is showing.
    mutating func promote(at now: ContinuousClock.Instant) {
        guard current == nil else { return }
        pending.removeAll { $0.timestamp.duration(to: now) > $0.maximumWait }
        guard let index = pending.firstIndex(where: canPresent) else { return }
        current = pending.remove(at: index)
    }

    /// Returns whether anything was removed.
    @discardableResult
    mutating func cancel(id: UUID, at now: ContinuousClock.Instant) -> Bool {
        if current?.id == id {
            finishCurrent(at: now)
            return true
        }
        let count = pending.count
        pending.removeAll { $0.id == id }
        return pending.count != count
    }

    mutating func cancel(dedupeKey: String, at now: ContinuousClock.Instant) {
        pending.removeAll { $0.dedupeKey == dedupeKey }
        if current?.dedupeKey == dedupeKey { finishCurrent(at: now) }
    }

    mutating func removeAll() {
        current = nil
        pending = []
    }

    mutating func setHeld(_ held: Bool, at now: ContinuousClock.Instant) {
        guard held != isHeld else { return }
        isHeld = held
        if held {
            guard let showing = current, showing.priority < .timer else { return }
            if showing.resumesAfterInterruption { insert(showing) }
            current = nil
        } else {
            promote(at: now)
        }
    }

    mutating func setInteracting(_ interacting: Bool, at now: ContinuousClock.Instant) {
        guard interacting != isInteracting else { return }
        isInteracting = interacting
        if !interacting { promote(at: now) }
    }

    private mutating func insert(_ activity: IslandActivity) {
        pending.append(activity)
        sortPending()
        if pending.count > Self.capacity { pending.removeLast() }
    }

    private mutating func sortPending() {
        pending.sort { lhs, rhs in
            lhs.priority != rhs.priority ? lhs.priority > rhs.priority : lhs.timestamp < rhs.timestamp
        }
    }
}

private extension IslandActivity {
    func keeping(id: UUID) -> IslandActivity {
        var copy = IslandActivity(content, at: timestamp, id: id)
        copy.priority = priority
        copy.presentation = presentation
        copy.duration = duration
        copy.dismissal = dismissal
        copy.dedupeKey = dedupeKey
        copy.resumesAfterInterruption = resumesAfterInterruption
        copy.maximumWait = maximumWait
        return copy
    }
}
