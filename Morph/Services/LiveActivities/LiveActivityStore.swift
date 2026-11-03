import Foundation
import Observation

/// The activities other apps have open. Each one has an expiry, so a script that dies can't leave
/// anything on the island.
@MainActor
@Observable
final class LiveActivityStore {
    enum Change: Equatable, Sendable {
        case started(ExternalActivity)
        case finished(ExternalActivity)
    }

    enum Failure: Error, Equatable {
        case alreadyExists, notFound, tooMany
    }

    /// Ordered as the sender asked, then oldest first.
    private(set) var activities: [ExternalActivity] = []

    @ObservationIgnored var onChange: ((Change) -> Void)?

    @ObservationIgnored private let scheduler: any Scheduling
    @ObservationIgnored private var expiryWork: (any ScheduledWork)?

    init(scheduler: any Scheduling) {
        self.scheduler = scheduler
    }

    var featured: ExternalActivity? { activities.first }

    func create(_ payload: LiveActivityPayload) throws -> ExternalActivity {
        guard let id = payload.id, let title = payload.title else { throw LiveActivityValidationError.invalid("id and title are required") }
        guard !activities.contains(where: { $0.id == id }) else { throw Failure.alreadyExists }
        guard activities.count < LiveActivityLimits.maximumActive else { throw Failure.tooMany }
        let activity = ExternalActivity(id: id, title: title, subtitle: payload.subtitle,
                                        symbol: payload.symbol ?? LiveActivityLimits.icons["activity"]!,
                                        progress: payload.progress, state: payload.state ?? .running,
                                        requestedPriority: payload.priority ?? .normal,
                                        expiresAt: scheduler.now.advanced(by: .seconds(payload.duration ?? LiveActivityLimits.defaultDuration)))
        activities.append(activity)
        sort()
        rearm()
        onChange?(.started(activity))
        return activity
    }

    func update(id: String, with payload: LiveActivityPayload) throws -> ExternalActivity {
        guard let index = activities.firstIndex(where: { $0.id == id }) else { throw Failure.notFound }
        guard payload.id == nil || payload.id == id else { throw LiveActivityValidationError.invalid("id can't change") }
        var activity = activities[index]
        if let title = payload.title { activity.title = title }
        if let subtitle = payload.subtitle { activity.subtitle = subtitle }
        if let symbol = payload.symbol { activity.symbol = symbol }
        if let progress = payload.progress { activity.progress = progress }
        if let state = payload.state { activity.state = state }
        if let priority = payload.priority { activity.requestedPriority = priority }
        // Every update buys more time, up to what was asked for or the default.
        activity.expiresAt = scheduler.now.advanced(by: .seconds(payload.duration ?? LiveActivityLimits.defaultDuration))
        activities[index] = activity
        sort()
        rearm()
        return activity
    }

    func end(id: String) throws {
        guard let index = activities.firstIndex(where: { $0.id == id }) else { throw Failure.notFound }
        let activity = activities.remove(at: index)
        rearm()
        onChange?(.finished(activity))
    }

    /// Turning the API off takes everything with it, with no announcements.
    func removeAll() {
        activities = []
        expiryWork?.cancel()
        expiryWork = nil
    }

    private func sort() {
        // `sort` isn't stable, so ties keep their order through their existing position.
        let order = Dictionary(uniqueKeysWithValues: activities.enumerated().map { ($1.id, $0) })
        activities.sort { lhs, rhs in
            lhs.requestedPriority.rank != rhs.requestedPriority.rank
                ? lhs.requestedPriority.rank > rhs.requestedPriority.rank
                : order[lhs.id, default: 0] < order[rhs.id, default: 0]
        }
    }

    private func rearm() {
        expiryWork?.cancel()
        expiryWork = nil
        guard let next = activities.map(\.expiresAt).min() else { return }
        expiryWork = scheduler.schedule(after: max(.zero, scheduler.now.duration(to: next))) { [weak self] in
            self?.expire()
        }
    }

    private func expire() {
        let now = scheduler.now
        activities.removeAll { $0.expiresAt <= now }
        rearm()
    }
}
