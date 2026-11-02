import Foundation
import Observation

/// View model for the island. Owns the state machine, turns its effects into timers, and resolves
/// mode, activities and live state into the one thing on screen.
enum IslandKeyCommand: Equatable, Sendable {
    case previousTab, nextTab, playPause

    init?(keyCode: UInt16) {
        switch keyCode {
        case 123: self = .previousTab
        case 124: self = .nextTab
        case 49: self = .playPause
        default: return nil
        }
    }
}

/// Turns scroll deltas into whole volume percentages, keeping the remainder between events.
struct VolumeScrollAccumulator: Sendable {
    private static let pointsPerPercent: CGFloat = 4
    private static let percentPerLine: CGFloat = 2

    private var remainder: CGFloat = 0

    mutating func add(deltaY: CGFloat, isPrecise: Bool) -> Int {
        remainder += isPrecise ? deltaY / Self.pointsPerPercent : deltaY * Self.percentPerLine
        let whole = remainder.rounded(.towardZero)
        remainder -= whole
        return Int(whole)
    }
}

@MainActor
@Observable
final class IslandController {
    private static let hoverIntent = Duration.milliseconds(80)

    private(set) var mode = IslandMode.idle
    private(set) var geometry: NotchGeometry?
    var selectedTab = ExpandedTab.home
    var showsCalibrationGuide = false
    /// A file is being dragged somewhere on screen, so the island offers itself as a target.
    var isFileDragActive = false
    /// Set from the window arrangement: full screen apps ask the island to step back.
    private(set) var cinema = CinemaState.normal

    @ObservationIgnored private var machine = IslandStateMachine()
    @ObservationIgnored private var hoverWork: (any ScheduledWork)?
    @ObservationIgnored private var collapseWork: (any ScheduledWork)?
    @ObservationIgnored private var gestures = IslandGestureRecognizer()

    private let preferences: MorphPreferences
    private let activities: ActivityManager
    private let timers: TimerService
    private let media: MediaController
    private let volume: VolumeService
    private let scheduler: any Scheduling

    init(preferences: MorphPreferences, activities: ActivityManager, timers: TimerService,
         media: MediaController, volume: VolumeService, scheduler: any Scheduling) {
        self.preferences = preferences
        self.activities = activities
        self.timers = timers
        self.media = media
        self.volume = volume
        self.scheduler = scheduler
    }

    var layout: IslandLayout {
        IslandLayout(notch: geometry?.notchSize ?? CGSize(width: NotchGeometry.virtualNotchWidth, height: 32),
                     size: preferences.islandSize, showsCalibrationGuide: showsCalibrationGuide)
    }

    var presentation: IslandPresentation {
        switch mode {
        case .expanded:
            return .expanded(resolvedTab)
        case .hover:
            // A minimal activity is shorter than hover, and shrinking would drop the pointer off the
            // island. Hover shows volume itself.
            if let activity = activities.current, activity.priority >= .timer, activity.presentation == .banner {
                return .activity(activity)
            }
            return isFileDragActive ? .dropTarget : .hover
        case .idle:
            if cinema != .normal {
                if let activity = activities.current, activity.priority >= .high { return .activity(activity) }
                return .idle
            }
            if isFileDragActive, preferences.shelfEnabled { return .dropTarget }
            if let activity = activities.current { return .activity(activity) }
            if let live = liveContent { return .live(live) }
            return .idle
        }
    }

    /// Hidden means off screen, unless something critical has to be seen anyway.
    var shouldShowPanel: Bool {
        cinema != .hidden || activities.current?.priority == .critical
    }

    func update(cinema state: CinemaState) {
        guard state != cinema else { return }
        cinema = state
        if state != .normal, !mode.isExpanded { send(.reset) }
    }

    var availableTabs: [ExpandedTab] {
        ExpandedTab.allCases.filter { tab in
            switch tab {
            case .home: true
            case .timers: preferences.timerEnabled
            case .shelf: preferences.shelfEnabled
            }
        }
    }

    /// A disabled module can't leave the panel stuck on a tab that no longer exists.
    private var resolvedTab: ExpandedTab {
        availableTabs.contains(selectedTab) ? selectedTab : .home
    }

    var liveContent: LiveContent? {
        guard preferences.liveActivitiesEnabled else { return nil }
        if preferences.timerEnabled {
            if timers.countdown.isRunning { return .timer }
            if timers.stopwatch.isRunning { return .stopwatch }
        }
        if preferences.musicEnabled, media.isLive { return .media }
        return nil
    }

    func send(_ event: IslandEvent) {
        machine.hoverEnabled = preferences.hoverExpansion && cinema == .normal
        machine.clickEnabled = preferences.clickToExpand
        let effects = machine.handle(event)
        effects.forEach(perform)
        guard mode != machine.mode else { return }
        mode = machine.mode
        activities.setHeld(mode != .idle)
        // Players don't announce seeks, so opening the panel re-reads the position.
        if mode.isExpanded { media.requestRefresh() }
    }

    /// A click acknowledges an alert that's waiting for one. Anything else opens the panel.
    func handleClick() {
        if let activity = activities.current, !mode.isExpanded {
            activities.cancel(id: activity.id)
            if activity.dismissal == .acknowledge { return }
        }
        send(.clicked)
    }

    /// Two-finger gestures over the island. A slider in use keeps them all to itself, and the
    /// shelf's horizontal scroll isn't a request to change tracks.
    func handleScroll(_ input: ScrollInput) {
        guard !machine.isInteracting, !(mode.isExpanded && resolvedTab == .shelf) else { return }
        gestures.horizontalEnabled = preferences.horizontalSwipes && preferences.musicEnabled
        gestures.verticalEnabled = preferences.verticalSwipes
        gestures.sensitivity = CGFloat(preferences.gestureSensitivity)
        gestures.process(input).forEach(perform)
    }

    private func perform(_ command: IslandGestureRecognizer.Command) {
        switch command {
        case .next, .previous:
            guard media.snapshot?.track != nil else { return }
            let forward = command == .next
            forward ? media.nextTrack() : media.previousTrack()
            activities.present(.trackSkipped(forward: forward))
        case .volume(let step):
            if !volume.adjustVolume(byPercent: step) { media.adjustVolume(by: step) }
        }
    }

    func handle(_ command: IslandKeyCommand) {
        guard mode.isExpanded else { return }
        switch command {
        case .previousTab: moveTab(by: -1)
        case .nextTab: moveTab(by: 1)
        case .playPause: if preferences.musicEnabled { media.playPause() }
        }
    }

    private func moveTab(by offset: Int) {
        let tabs = availableTabs
        guard let index = tabs.firstIndex(of: resolvedTab) else { return }
        selectedTab = tabs[(index + offset + tabs.count) % tabs.count]
    }

    func showTab(_ tab: ExpandedTab) {
        selectedTab = tab
    }

    func toggleFromMenu() {
        send(mode.isExpanded ? .escapePressed : .openRequested)
    }

    func update(geometry: NotchGeometry?) {
        self.geometry = geometry
    }

    private func perform(_ effect: IslandEffect) {
        switch effect {
        case .scheduleHover:
            hoverWork?.cancel()
            hoverWork = scheduler.schedule(after: Self.hoverIntent) { [weak self] in
                self?.send(.hoverDelayElapsed)
            }
        case .cancelHover:
            hoverWork?.cancel()
            hoverWork = nil
        case .scheduleCollapse:
            collapseWork?.cancel()
            collapseWork = scheduler.schedule(after: .seconds(preferences.dismissalDelay)) { [weak self] in
                self?.send(.collapseDelayElapsed)
            }
        case .cancelCollapse:
            collapseWork?.cancel()
            collapseWork = nil
        }
    }
}
