import Observation

/// Re-runs `body` whenever an `@Observable` property it read changes.
/// This is how AppKit controllers follow model state without polling.
@MainActor
final class ObservationLoop {
    private var isActive = true
    private let body: @MainActor () -> Void

    init(_ body: @escaping @MainActor () -> Void) {
        self.body = body
        run()
    }

    func invalidate() {
        isActive = false
    }

    private func run() {
        guard isActive else { return }
        withObservationTracking {
            body()
        } onChange: { [weak self] in
            Task { @MainActor in self?.run() }
        }
    }
}
