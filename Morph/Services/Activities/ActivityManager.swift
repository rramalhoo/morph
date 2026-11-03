import Foundation
import Observation

@MainActor
@Observable
final class ActivityManager {
    static let historyLimit = 6
    private static let extensionCheck = Duration.seconds(1)

    private(set) var current: IslandActivity?
    private(set) var recent: [ActivityRecord] = []
    /// A level HUD's hold is over and it's easing off before the island closes.
    private(set) var isConcluding = false
    /// The Activity Duration preference. Only activities that dismiss themselves are affected.
    @ObservationIgnored var durationScale = 1.0
    /// Asked when an activity's time is up. Yes keeps it showing and asks again a little later,
    /// which is how a screenshot stays put under the pointer.
    @ObservationIgnored var shouldExtend: ((IslandActivity) -> Bool)?

    @ObservationIgnored private var queue = ActivityQueue()
    @ObservationIgnored private var dismissWork: (any ScheduledWork)?
    @ObservationIgnored private var concludeWork: (any ScheduledWork)?
    @ObservationIgnored private var armedActivityID: UUID?
    private let scheduler: any Scheduling

    init(scheduler: any Scheduling) {
        self.scheduler = scheduler
    }

    var pendingCount: Int { queue.pending.count }

    /// Showing, or waiting to come back.
    func isActive(dedupeKey: String) -> Bool {
        current?.dedupeKey == dedupeKey || queue.pending.contains { $0.dedupeKey == dedupeKey }
    }

    /// `duration` replaces how long a level HUD or a screenshot stays up.
    func present(_ content: IslandActivity.Content, duration: Duration? = nil) {
        var activity = IslandActivity(content, at: scheduler.now)
        if let duration, activity.presentation != .banner, activity.presentation != .minimal { activity.duration = duration }
        let outcome = queue.enqueue(activity)
        record(activity)
        if outcome == .refreshedCurrent { armedActivityID = nil }
        publish()
    }

    /// Acknowledges or dismisses the showing activity.
    func dismissCurrent() {
        queue.finishCurrent(at: scheduler.now)
        publish()
    }

    func cancel(id: UUID) {
        queue.cancel(id: id, at: scheduler.now)
        publish()
    }

    func cancel(matching content: IslandActivity.Content) {
        queue.cancel(dedupeKey: IslandActivity(content, at: scheduler.now).dedupeKey, at: scheduler.now)
        publish()
    }

    func removeAll() {
        queue.removeAll()
        publish()
    }

    /// While the user is in the island, nothing below `.timer` may appear or time out behind them.
    func setHeld(_ held: Bool) {
        queue.setHeld(held, at: scheduler.now)
        publish()
    }

    /// A control is being dragged: nothing but a critical alert may change what's on screen.
    func setInteracting(_ interacting: Bool) {
        queue.setInteracting(interacting, at: scheduler.now)
        publish()
    }

    private func publish() {
        if current != queue.current { current = queue.current }
        guard let showing = queue.current else {
            cancelTimers()
            armedActivityID = nil
            return
        }
        guard armedActivityID != showing.id else { return }
        armedActivityID = showing.id
        cancelTimers()
        let id = showing.id
        let isLevel = showing.presentation == .level
        let scalesWithPreference = showing.dismissal == .automatic && showing.presentation != .level && showing.presentation != .screenshot
        let duration = scalesWithPreference ? showing.duration * durationScale : showing.duration
        dismissWork = scheduler.schedule(after: duration) { [weak self] in
            self?.expire(id: id)
        }
        if isLevel {
            concludeWork = scheduler.schedule(after: max(.zero, duration - IslandActivity.levelFade)) { [weak self] in
                if self?.queue.current?.id == id { self?.isConcluding = true }
            }
        }
    }

    private func cancelTimers() {
        dismissWork?.cancel()
        dismissWork = nil
        concludeWork?.cancel()
        concludeWork = nil
        if isConcluding { isConcluding = false }
    }

    private func expire(id: UUID) {
        guard let showing = queue.current, showing.id == id else { return }
        if shouldExtend?(showing) == true {
            dismissWork = scheduler.schedule(after: Self.extensionCheck) { [weak self] in self?.expire(id: id) }
            return
        }
        queue.finishCurrent(at: scheduler.now)
        publish()
    }

    private func record(_ activity: IslandActivity) {
        guard activity.content.appearsInRecent else { return }
        recent.insert(ActivityRecord(id: activity.id, content: activity.content, date: .now), at: 0)
        if recent.count > Self.historyLimit { recent.removeLast() }
    }
}
