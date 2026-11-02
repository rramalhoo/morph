import Foundation
import Testing
@testable import Morph

@Suite("Activity queue")
struct ActivityQueueTests {
    private let t0 = ContinuousClock.now

    private func activity(_ content: IslandActivity.Content, offset: Duration = .zero) -> IslandActivity {
        IslandActivity(content, at: t0.advanced(by: offset))
    }

    @Test func presentsWhenEmpty() {
        var queue = ActivityQueue()
        #expect(queue.enqueue(activity(.filesAdded(count: 1))) == .presented)
        #expect(queue.current != nil)
    }

    @Test func batteryWarningInterruptsDecorativeMusic() {
        var queue = ActivityQueue()
        queue.enqueue(activity(.nowPlaying(title: "A", artist: "B")))
        #expect(queue.enqueue(activity(.batteryLow(percentage: 19))) == .presented)
        #expect(queue.current?.dedupeKey == "battery-alert")
        #expect(queue.pending.isEmpty, "Music doesn't ask to resume")
    }

    @Test func lowerPriorityWaitsItsTurn() {
        var queue = ActivityQueue()
        queue.enqueue(activity(.batteryLow(percentage: 19)))
        #expect(queue.enqueue(activity(.filesAdded(count: 1))) == .queued)
        queue.finishCurrent(at: t0)
        #expect(queue.current?.dedupeKey == "files")
    }

    @Test func interruptedActivityResumes() {
        var queue = ActivityQueue()
        queue.enqueue(activity(.timerCompleted(duration: 60)))
        queue.enqueue(activity(.batteryCritical(percentage: 4)))
        #expect(queue.current?.priority == .critical)
        queue.finishCurrent(at: t0)
        #expect(queue.current?.dedupeKey == "timer")
    }

    @Test func pendingIsOrderedByPriorityThenAge() {
        var queue = ActivityQueue()
        queue.enqueue(activity(.batteryCritical(percentage: 4)))
        queue.enqueue(activity(.nowPlaying(title: "A", artist: "B")))
        queue.enqueue(activity(.filesAdded(count: 1), offset: .seconds(1)))
        queue.enqueue(activity(.powerDisconnected(percentage: 50), offset: .milliseconds(500)))
        #expect(queue.pending.map(\.dedupeKey) == ["power", "files", "now-playing"])
    }

    @Test func duplicatesMergeIntoTheShowingActivity() {
        var queue = ActivityQueue()
        queue.enqueue(activity(.powerConnected(percentage: 50, charging: true)))
        let id = queue.current?.id
        #expect(queue.enqueue(activity(.powerDisconnected(percentage: 51))) == .refreshedCurrent)
        #expect(queue.current?.id == id)
        #expect(queue.current?.content == .powerDisconnected(percentage: 51))
        #expect(queue.pending.isEmpty)
    }

    @Test func duplicatesMergeIntoPending() {
        var queue = ActivityQueue()
        queue.enqueue(activity(.batteryCritical(percentage: 4)))
        queue.enqueue(activity(.filesAdded(count: 1)))
        #expect(queue.enqueue(activity(.filesAdded(count: 3))) == .refreshedPending)
        #expect(queue.pending.count == 1)
        #expect(queue.pending.first?.content == .filesAdded(count: 3))
    }

    @Test func staleActivitiesAreDropped() {
        var queue = ActivityQueue()
        queue.enqueue(activity(.batteryCritical(percentage: 4)))
        queue.enqueue(activity(.nowPlaying(title: "A", artist: "B")))
        queue.finishCurrent(at: t0.advanced(by: .seconds(30)))
        #expect(queue.current == nil)
        #expect(queue.pending.isEmpty)
    }

    @Test func holdingSuppressesLowPriorityButNotAlerts() {
        var queue = ActivityQueue()
        queue.setHeld(true, at: t0)
        #expect(queue.enqueue(activity(.filesAdded(count: 1))) == .queued)
        #expect(queue.current == nil)
        #expect(queue.enqueue(activity(.batteryLow(percentage: 19))) == .presented)
    }

    @Test func holdingPullsVisibleLowPriorityOffScreen() {
        var queue = ActivityQueue()
        queue.enqueue(activity(.fullyChargedForTest))
        queue.setHeld(true, at: t0)
        #expect(queue.current == nil)
        queue.setHeld(false, at: t0)
        #expect(queue.current?.content == .fullyCharged)
    }

    @Test func cancellingShowingActivityPromotesNext() {
        var queue = ActivityQueue()
        let first = activity(.batteryLow(percentage: 19))
        queue.enqueue(first)
        queue.enqueue(activity(.filesAdded(count: 1)))
        #expect(queue.cancel(id: first.id, at: t0) == true)
        #expect(queue.current?.dedupeKey == "files")
    }

    @Test func cancellingPendingLeavesCurrentAlone() {
        var queue = ActivityQueue()
        queue.enqueue(activity(.batteryLow(percentage: 19)))
        let waiting = activity(.filesAdded(count: 1))
        queue.enqueue(waiting)
        #expect(queue.cancel(id: waiting.id, at: t0) == true)
        #expect(queue.current?.dedupeKey == "battery-alert")
        #expect(queue.pending.isEmpty)
        #expect(queue.cancel(id: UUID(), at: t0) == false)
    }

    @Test func capacityDropsTheLeastImportant() {
        var queue = ActivityQueue()
        queue.enqueue(activity(.batteryCritical(percentage: 4)))
        for index in 0..<20 {
            var item = activity(.filesAdded(count: index))
            item.dedupeKey = "item-\(index)"
            queue.enqueue(item)
        }
        #expect(queue.pending.count == ActivityQueue.capacity)
    }
}

private extension IslandActivity.Content {
    static var fullyChargedForTest: Self { .fullyCharged }
}

@Suite("Activity manager")
@MainActor
struct ActivityManagerTests {
    private let scheduler = ManualScheduler()

    @Test func dismissesAfterItsOwnDuration() {
        let manager = ActivityManager(scheduler: scheduler)
        manager.present(.filesAdded(count: 1))
        scheduler.advance(by: .milliseconds(1999))
        #expect(manager.current != nil)
        scheduler.advance(by: .milliseconds(1))
        #expect(manager.current == nil)
    }

    @Test func refreshingRestartsTheTimer() {
        let manager = ActivityManager(scheduler: scheduler)
        manager.present(.filesAdded(count: 1))
        scheduler.advance(by: .milliseconds(1500))
        manager.present(.filesAdded(count: 2))
        scheduler.advance(by: .milliseconds(1500))
        #expect(manager.current?.content == .filesAdded(count: 2))
        scheduler.advance(by: .milliseconds(500))
        #expect(manager.current == nil)
    }

    @Test func nextActivityRunsItsFullDurationAfterPromotion() {
        let manager = ActivityManager(scheduler: scheduler)
        manager.present(.batteryLow(percentage: 19))
        manager.present(.fullyCharged)
        scheduler.advance(by: .seconds(6))
        #expect(manager.current?.content == .fullyCharged)
        scheduler.advance(by: .milliseconds(3999))
        #expect(manager.current != nil)
        scheduler.advance(by: .milliseconds(1))
        #expect(manager.current == nil)
    }

    @Test func cancellationStopsTheDismissTimer() {
        let manager = ActivityManager(scheduler: scheduler)
        manager.present(.batteryCritical(percentage: 4))
        let id = manager.current!.id
        manager.cancel(id: id)
        #expect(manager.current == nil)
        #expect(scheduler.pendingCount == 0)
    }

    @Test func cancelMatchingClearsBothShowingAndQueued() {
        let manager = ActivityManager(scheduler: scheduler)
        manager.present(.powerConnected(percentage: 50, charging: true))
        manager.cancel(matching: .fullyCharged)
        #expect(manager.current == nil)
    }

    @Test func historyIsBoundedAndNewestFirst() {
        let manager = ActivityManager(scheduler: scheduler)
        for index in 0..<10 {
            manager.present(.filesAdded(count: index))
        }
        #expect(manager.recent.count == ActivityManager.historyLimit)
        #expect(manager.recent.first?.content == .filesAdded(count: 9))
    }

    @Test func volumeUpdatesMergeAndStayOutOfHistory() {
        let manager = ActivityManager(scheduler: scheduler)
        for level in [10, 20, 30] { manager.present(.volumeChanged(percentage: level)) }
        #expect(manager.current?.content == .volumeChanged(percentage: 30))
        #expect(manager.recent.isEmpty)
        #expect(manager.pendingCount == 0)
    }

    @Test func heldActivityDoesNotTimeOutBehindThePanel() {
        let manager = ActivityManager(scheduler: scheduler)
        manager.setHeld(true)
        manager.present(.fullyCharged)
        #expect(manager.current == nil)
        scheduler.advance(by: .seconds(10))
        manager.setHeld(false)
        #expect(manager.current?.content == .fullyCharged)
    }
}
