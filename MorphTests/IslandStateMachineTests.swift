import Testing
@testable import Morph

@Suite("Island state machine")
struct IslandStateMachineTests {
    private func hovering() -> IslandStateMachine {
        var machine = IslandStateMachine()
        _ = machine.handle(.pointerEntered)
        _ = machine.handle(.hoverDelayElapsed)
        return machine
    }

    @Test func pointerEntryWaitsForHoverIntent() {
        var machine = IslandStateMachine()
        #expect(machine.handle(.pointerEntered).contains(.scheduleHover))
        #expect(machine.mode == .idle)
        _ = machine.handle(.hoverDelayElapsed)
        #expect(machine.mode == .hover)
    }

    @Test func passingOverTheIslandDoesNotHover() {
        var machine = IslandStateMachine()
        _ = machine.handle(.pointerEntered)
        #expect(machine.handle(.pointerExited).contains(.cancelHover))
        _ = machine.handle(.hoverDelayElapsed)
        #expect(machine.mode == .idle)
    }

    @Test func hoverCanBeDisabled() {
        var machine = IslandStateMachine()
        machine.hoverEnabled = false
        #expect(!machine.handle(.pointerEntered).contains(.scheduleHover))
        _ = machine.handle(.hoverDelayElapsed)
        #expect(machine.mode == .idle)
        _ = machine.handle(.clicked)
        #expect(machine.mode == .expanded(.pointer))
    }

    @Test func clickCanBeDisabled() {
        var machine = hovering()
        machine.clickEnabled = false
        _ = machine.handle(.clicked)
        #expect(machine.mode == .hover)
    }

    @Test func leavingSchedulesCollapseAndReturningCancelsIt() {
        var machine = hovering()
        #expect(machine.handle(.pointerExited).contains(.scheduleCollapse))
        #expect(machine.handle(.pointerEntered).contains(.cancelCollapse))
        _ = machine.handle(.collapseDelayElapsed)
        #expect(machine.mode == .hover)
    }

    @Test func staleCollapseDoesNotCloseWhilePointerInside() {
        var machine = hovering()
        _ = machine.handle(.clicked)
        _ = machine.handle(.collapseDelayElapsed)
        #expect(machine.mode == .expanded(.pointer))
    }

    @Test func activeInteractionHoldsThePanelOpen() {
        var machine = hovering()
        _ = machine.handle(.clicked)
        _ = machine.handle(.interactionBegan)
        #expect(!machine.handle(.pointerExited).contains(.scheduleCollapse))
        _ = machine.handle(.collapseDelayElapsed)
        #expect(machine.mode == .expanded(.pointer))
        #expect(machine.handle(.interactionEnded).contains(.scheduleCollapse))
        _ = machine.handle(.collapseDelayElapsed)
        #expect(machine.mode == .idle)
    }

    @Test func clickingTheOpenPanelClosesIt() {
        var machine = hovering()
        _ = machine.handle(.clicked)
        _ = machine.handle(.clicked)
        #expect(machine.mode == .idle)
    }

    @Test func aClickMidDragDoesNotClose() {
        var machine = hovering()
        _ = machine.handle(.clicked)
        _ = machine.handle(.interactionBegan)
        _ = machine.handle(.clicked)
        #expect(machine.mode == .expanded(.pointer))
    }

    @Test func keyboardOpenIgnoresThePointerUntilEscape() {
        var machine = IslandStateMachine()
        _ = machine.handle(.openRequested)
        _ = machine.handle(.pointerEntered)
        #expect(!machine.handle(.pointerExited).contains(.scheduleCollapse))
        _ = machine.handle(.escapePressed)
        #expect(machine.mode == .idle)
    }

    @Test func keyboardOpenClosesWhenFocusLeaves() {
        var machine = IslandStateMachine()
        _ = machine.handle(.openRequested)
        _ = machine.handle(.focusLost)
        #expect(machine.mode == .idle)
    }

    @Test func focusLossDoesNotClosePointerPanel() {
        var machine = hovering()
        _ = machine.handle(.clicked)
        _ = machine.handle(.focusLost)
        #expect(machine.mode == .expanded(.pointer))
    }

    @Test func fileDragOpensAndHoldsUntilItLeaves() {
        var machine = IslandStateMachine()
        _ = machine.handle(.fileDragEntered)
        #expect(machine.mode == .expanded(.fileDrag))
        _ = machine.handle(.collapseDelayElapsed)
        #expect(machine.mode == .expanded(.fileDrag))
        #expect(machine.handle(.fileDragExited).contains(.scheduleCollapse))
        _ = machine.handle(.collapseDelayElapsed)
        #expect(machine.mode == .idle)
    }

    @Test func resetClearsEverything() {
        var machine = hovering()
        _ = machine.handle(.interactionBegan)
        _ = machine.handle(.reset)
        #expect(machine.mode == .idle)
        #expect(!machine.isPointerInside)
        _ = machine.handle(.pointerEntered)
        _ = machine.handle(.hoverDelayElapsed)
        #expect(machine.mode == .hover)
    }

    @Test func repeatedExpansionAndContractionStaysConsistent() {
        var machine = IslandStateMachine()
        for _ in 0..<500 {
            _ = machine.handle(.pointerEntered)
            _ = machine.handle(.hoverDelayElapsed)
            #expect(machine.mode == .hover)
            _ = machine.handle(.clicked)
            #expect(machine.mode == .expanded(.pointer))
            _ = machine.handle(.interactionBegan)
            _ = machine.handle(.interactionEnded)
            _ = machine.handle(.pointerExited)
            _ = machine.handle(.collapseDelayElapsed)
            #expect(machine.mode == .idle)
        }
    }
}

@Suite("Island controller")
@MainActor
struct IslandControllerTests {
    private let scheduler = ManualScheduler()
    private let preferences = MorphPreferences(defaults: makeDefaults())

    private func makeController() -> (IslandController, ActivityManager, TimerService) {
        let activities = ActivityManager(scheduler: scheduler)
        let timers = TimerService(scheduler: scheduler)
        let media = MediaController(providers: [], events: StubMediaEvents(), scheduler: scheduler)
        let volume = VolumeService(system: StubOutputSystem(), scheduler: scheduler)
        let island = IslandController(preferences: preferences, activities: activities, timers: timers,
                                      media: media, volume: volume, scheduler: scheduler)
        return (island, activities, timers)
    }

    @Test func hoverAndDismissalRunOnTheConfiguredDelays() {
        let (island, _, _) = makeController()
        preferences.dismissalDelay = 0.5
        island.send(.pointerEntered)
        scheduler.advance(by: .milliseconds(79))
        #expect(island.mode == .idle)
        scheduler.advance(by: .milliseconds(1))
        #expect(island.mode == .hover)
        island.send(.pointerExited)
        scheduler.advance(by: .milliseconds(499))
        #expect(island.mode == .hover)
        scheduler.advance(by: .milliseconds(1))
        #expect(island.mode == .idle)
    }

    @Test func rapidInAndOutNeverLeavesTimersBehind() {
        let (island, _, _) = makeController()
        for _ in 0..<200 {
            island.send(.pointerEntered)
            island.send(.pointerExited)
        }
        scheduler.advance(by: .seconds(5))
        #expect(island.mode == .idle)
        #expect(scheduler.pendingCount == 0)
    }

    @Test func activityYieldsToAnOpenPanelAndHighPriorityBreaksThroughHover() {
        let (island, activities, _) = makeController()
        activities.present(.filesAdded(count: 1))
        #expect(island.presentation == .activity(activities.current!))

        island.send(.pointerEntered)
        scheduler.advance(by: .milliseconds(80))
        #expect(island.presentation == .hover)

        activities.present(.batteryLow(percentage: 19))
        #expect(island.presentation == .activity(activities.current!))

        island.send(.clicked)
        #expect(island.presentation == .expanded(.home))
    }

    @Test func runningTimerShowsLiveContentOnlyWhenEnabled() {
        let (island, _, timers) = makeController()
        timers.startCountdown(.seconds(60))
        #expect(island.presentation == .live(.timer))
        preferences.liveActivitiesEnabled = false
        #expect(island.presentation == .idle)
    }

    @Test func disabledModuleTabFallsBackToHome() {
        let (island, _, _) = makeController()
        island.showTab(.shelf)
        island.send(.openRequested)
        #expect(island.presentation == .expanded(.shelf))
        preferences.shelfEnabled = false
        #expect(island.presentation == .expanded(.home))
        #expect(!island.availableTabs.contains(.shelf))
    }

    @Test func volumeFeedbackDoesNotShrinkTheHoverState() {
        let (island, activities, _) = makeController()
        island.send(.pointerEntered)
        scheduler.advance(by: .milliseconds(80))
        activities.present(.volumeChanged(percentage: 40))
        #expect(island.presentation == .hover)
        island.send(.pointerExited)
        scheduler.advance(by: .seconds(1))
        #expect(island.presentation == .activity(activities.current!))
    }

    @Test func arrowKeysCycleOnlyEnabledTabs() {
        let (island, _, _) = makeController()
        island.handle(.nextTab)
        #expect(island.selectedTab == .home, "Keys do nothing while collapsed")
        island.send(.openRequested)
        island.handle(.nextTab)
        #expect(island.presentation == .expanded(.timers))
        island.handle(.nextTab)
        #expect(island.presentation == .expanded(.battery))
        island.handle(.nextTab)
        #expect(island.presentation == .expanded(.shelf))
        island.handle(.nextTab)
        #expect(island.presentation == .expanded(.home))
        island.handle(.previousTab)
        #expect(island.presentation == .expanded(.shelf))
        preferences.shelfEnabled = false
        island.handle(.nextTab)
        #expect(island.presentation == .expanded(.timers))
    }

    @Test func keyCodesMap() {
        #expect(IslandKeyCommand(keyCode: 123) == .previousTab)
        #expect(IslandKeyCommand(keyCode: 124) == .nextTab)
        #expect(IslandKeyCommand(keyCode: 49) == .playPause)
        #expect(IslandKeyCommand(keyCode: 0) == nil)
    }

    @Test func scrollAccumulatesIntoWholePercentagesInBothDirections() {
        var accumulator = VolumeScrollAccumulator()
        #expect(accumulator.add(deltaY: 3, isPrecise: true) == 0)
        #expect(accumulator.add(deltaY: 1, isPrecise: true) == 1)
        #expect(accumulator.add(deltaY: -8, isPrecise: true) == -2)
        #expect(accumulator.add(deltaY: 1, isPrecise: false) == 2)
    }

    @Test func clickAcknowledgesAnAlertWithoutOpeningThePanel() {
        let (island, activities, _) = makeController()
        activities.present(.timerCompleted(duration: 60))
        island.handleClick()
        #expect(activities.current == nil)
        #expect(island.mode == .idle)
    }

    @Test func clickOnAPassingActivityOpensThePanel() {
        let (island, activities, _) = makeController()
        activities.present(.filesAdded(count: 1))
        island.handleClick()
        #expect(activities.current == nil)
        #expect(island.mode.isExpanded)
    }
}
