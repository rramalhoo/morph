import Foundation

/// A pending piece of deferred work.
@MainActor
protocol ScheduledWork: AnyObject {
    func cancel()
}

/// Time source and one-shot delays. Everything time-based in Morph goes through this, so state
/// machines and queues can be driven deterministically from tests.
@MainActor
protocol Scheduling: AnyObject {
    var now: ContinuousClock.Instant { get }

    @discardableResult
    func schedule(after delay: Duration, _ work: @escaping @MainActor () -> Void) -> any ScheduledWork
}

@MainActor
final class SystemScheduler: Scheduling {
    private final class Work: ScheduledWork {
        var task: Task<Void, Never>?

        func cancel() {
            task?.cancel()
            task = nil
        }
    }

    var now: ContinuousClock.Instant { .now }

    @discardableResult
    func schedule(after delay: Duration, _ work: @escaping @MainActor () -> Void) -> any ScheduledWork {
        let handle = Work()
        handle.task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            work()
        }
        return handle
    }
}
