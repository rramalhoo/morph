import Foundation
import Observation

/// Every transfer Morph knows about, from any source. One place decides what counts as new,
/// what's a duplicate, and when an update is worth telling the island about.
@MainActor
@Observable
final class TransferManager {
    enum Event: Equatable, Sendable {
        case started(Transfer)
        case progressed(Transfer)
        case finished(Transfer)
    }

    enum Failure: Error, Equatable {
        case notFound, alreadyFinished, tooMany, notCancellable
    }

    static let maximumActive = 16
    /// Progress reaches the island at most this often per transfer. State changes always do.
    static let publishInterval = Duration.milliseconds(500)
    /// Even with no history kept, a finished transfer stays long enough to be seen.
    static let minimumLinger = Duration.seconds(10)

    /// Active first, newest first within each group.
    private(set) var transfers: [Transfer] = []
    /// How long finished transfers stay in the panel. Memory only; nothing is written to disk.
    @ObservationIgnored var historyDuration = Duration.seconds(15 * 60) {
        didSet { prune() }
    }
    @ObservationIgnored var onEvent: ((Event) -> Void)?

    @ObservationIgnored private let scheduler: any Scheduling
    @ObservationIgnored private var meters: [String: TransferSpeedMeter] = [:]
    @ObservationIgnored private var lastPublished: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var finishedAt: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var pruneWork: (any ScheduledWork)?

    init(scheduler: any Scheduling) {
        self.scheduler = scheduler
    }

    var active: [Transfer] { transfers.filter { !$0.isOver } }
    var recent: [Transfer] { transfers.filter(\.isOver) }

    func transfer(id: String) -> Transfer? { transfers.first { $0.id == id } }

    /// A repeat of a live transfer updates it; a repeat of a finished one is ignored.
    @discardableResult
    func begin(_ transfer: Transfer) throws -> Transfer {
        if let existing = self.transfer(id: transfer.id) {
            guard !existing.isOver else { throw Failure.alreadyFinished }
            return try update(id: transfer.id, bytes: transfer.bytes, totalBytes: transfer.totalBytes, state: transfer.state)
        }
        guard active.count < Self.maximumActive else { throw Failure.tooMany }
        var started = transfer
        if started.state == .pending, started.bytes > 0 { started.state = .transferring }
        meters[started.id, default: TransferSpeedMeter()].sample(bytes: started.bytes, at: scheduler.now)
        transfers.insert(started, at: 0)
        sort()
        lastPublished[started.id] = scheduler.now
        onEvent?(.started(started))
        return started
    }

    @discardableResult
    func update(id: String, bytes: Int64? = nil, totalBytes: Int64? = nil, state: TransferState? = nil,
                name: String? = nil) throws -> Transfer {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { throw Failure.notFound }
        var transfer = transfers[index]
        guard !transfer.isOver else { throw Failure.alreadyFinished }
        if let state, state.isFinished { return try finish(id: id, state: state, bytes: bytes) }

        let previousState = transfer.state
        if let name { transfer.name = name }
        if let totalBytes { transfer.totalBytes = totalBytes > 0 ? totalBytes : nil }
        if let bytes {
            transfer.bytes = max(0, bytes)
            meters[id, default: TransferSpeedMeter()].sample(bytes: transfer.bytes, at: scheduler.now)
            if transfer.state == .pending { transfer.state = .transferring }
        }
        if let state { transfer.state = state }
        transfer.speed = transfer.state == .transferring ? meters[id]?.speed : nil
        guard transfer != transfers[index] else { return transfer }
        transfers[index] = transfer

        let now = scheduler.now
        let due = lastPublished[id].map { $0.duration(to: now) >= Self.publishInterval } ?? true
        if due || transfer.state != previousState {
            lastPublished[id] = now
            onEvent?(.progressed(transfer))
        }
        return transfer
    }

    @discardableResult
    func finish(id: String, state: TransferState = .completed, bytes: Int64? = nil, error: String? = nil,
                fileURL: URL? = nil, name: String? = nil) throws -> Transfer {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { throw Failure.notFound }
        var transfer = transfers[index]
        guard !transfer.isOver else { throw Failure.alreadyFinished }
        // Unknown is an honest ending too: the source went quiet without saying how it ended.
        transfer.state = state.isFinished || state == .unknown ? state : .completed
        if let bytes { transfer.bytes = max(0, bytes) }
        if transfer.state == .completed, transfer.totalBytes == nil, transfer.bytes > 0 { transfer.totalBytes = transfer.bytes }
        transfer.error = transfer.state == .failed ? (error ?? "Failed") : nil
        if let fileURL { transfer.fileURL = fileURL }
        if let name { transfer.name = name }
        transfer.speed = nil
        transfer.finishedAt = .now
        transfers[index] = transfer
        meters[id] = nil
        lastPublished[id] = nil
        finishedAt[id] = scheduler.now
        sort()
        onEvent?(.finished(transfer))
        schedulePrune()
        return transfer
    }

    /// Only for transfers Morph itself controls. Anything else isn't Morph's to stop.
    func cancel(id: String) throws {
        guard let transfer = transfer(id: id) else { throw Failure.notFound }
        guard transfer.canCancel else { throw Failure.notCancellable }
        try finish(id: id, state: .cancelled)
    }

    /// A one-shot finished transfer, for things learned about only once done.
    @discardableResult
    func record(_ transfer: Transfer) -> Transfer? {
        guard self.transfer(id: transfer.id) == nil else { return nil }
        var pending = transfer
        pending.state = .transferring
        transfers.insert(pending, at: 0)
        return try? finish(id: transfer.id, state: transfer.state.isFinished ? transfer.state : .completed,
                           bytes: transfer.bytes, error: transfer.error, fileURL: transfer.fileURL)
    }

    /// Transfers a source can no longer report on end as unknown rather than vanishing silently.
    func abandon(source: TransferSource) {
        for transfer in active where transfer.source == source {
            try? finish(id: transfer.id, state: .unknown)
        }
    }

    func clearHistory() {
        transfers.removeAll(where: \.isOver)
        finishedAt = [:]
    }

    func removeAll() {
        transfers = []
        meters = [:]
        lastPublished = [:]
        finishedAt = [:]
        pruneWork?.cancel()
        pruneWork = nil
    }

    private func sort() {
        transfers.sort { lhs, rhs in
            if lhs.isOver != rhs.isOver { return !lhs.isOver }
            return (lhs.finishedAt ?? lhs.startedAt) > (rhs.finishedAt ?? rhs.startedAt)
        }
    }

    private var linger: Duration { max(historyDuration, Self.minimumLinger) }

    private func prune() {
        let now = scheduler.now
        let expired = finishedAt.filter { $0.value.duration(to: now) >= linger }.map(\.key)
        guard !expired.isEmpty else { return schedulePrune() }
        transfers.removeAll { expired.contains($0.id) }
        expired.forEach { finishedAt[$0] = nil }
        schedulePrune()
    }

    private func schedulePrune() {
        pruneWork?.cancel()
        pruneWork = nil
        guard let oldest = finishedAt.values.min() else { return }
        let due = max(.zero, linger - oldest.duration(to: scheduler.now))
        pruneWork = scheduler.schedule(after: due) { [weak self] in self?.prune() }
    }
}
