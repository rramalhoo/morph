import AppKit

enum CinemaState: Equatable, Sendable {
    case normal
    /// Only critical alerts appear.
    case compact
    case hidden
}

enum FullscreenEvidence: Equatable, Sendable {
    case none
    /// Something covers the display, but it isn't clearly the app in use going full screen.
    case uncertain
    case fullscreen
}

struct WindowSample: Equatable, Sendable {
    var ownerPID: pid_t
    var layer: Int
    /// In Core Graphics coordinates, origin at the top-left of the primary display.
    var bounds: CGRect
    var alpha: Double
}

/// A display in window-list coordinates.
struct DisplayArea: Equatable, Sendable {
    var bounds: CGRect
    /// The area ordinary windows are limited to: below the menu bar, clear of the Dock.
    var usable: CGRect
}

enum FullscreenDetector {
    /// Tolerance for rounding in reported geometry.
    private static let slack: CGFloat = 1

    /// Window geometry is all this reads, never content. macOS exposes no public "is full screen"
    /// for other apps, and on a notched display a full screen window sits below the camera housing
    /// with the menu bar and wallpaper still listed, so only its shape gives it away:
    ///
    /// - A window over the entire display is full screen.
    /// - A window from the menu bar's edge to the bottom, wider or taller than the usable area, has
    ///   gone where ordinary windows can't. That's how full screen looks below a notch.
    /// - If that same shape fits inside the usable area, as it does with no Dock on this display,
    ///   it may just be maximized. That's uncertain, and the user's fallback decides.
    static func evaluate(windows: [WindowSample], display: DisplayArea, frontmostPID: pid_t?, ownPID: pid_t) -> FullscreenEvidence {
        var evidence = FullscreenEvidence.none
        for window in windows where window.ownerPID != ownPID && window.alpha > 0 {
            let isFrontmost = window.ownerPID == frontmostPID
            let coversAll = covers(window.bounds, display.bounds)
            let reachesBottomEdge = spansBelowMenuBar(window.bounds, display)

            if window.layer > 0 {
                // Games and players sometimes draw above the normal layer. System chrome like the
                // Dock has windows that size too, but it's never the frontmost app.
                if coversAll, isFrontmost { evidence = .uncertain }
            } else if coversAll || reachesBottomEdge {
                guard isFrontmost else {
                    evidence = .uncertain
                    continue
                }
                if coversAll || escapesUsableArea(window.bounds, display) { return .fullscreen }
                evidence = .uncertain
            }
        }
        return evidence
    }

    private static func covers(_ bounds: CGRect, _ display: CGRect) -> Bool {
        abs(bounds.minX - display.minX) <= slack && abs(bounds.minY - display.minY) <= slack
            && bounds.width >= display.width - slack && bounds.height >= display.height - slack
    }

    private static func spansBelowMenuBar(_ bounds: CGRect, _ display: DisplayArea) -> Bool {
        abs(bounds.minX - display.bounds.minX) <= slack && bounds.width >= display.bounds.width - slack
            && bounds.minY <= display.usable.minY + slack && bounds.maxY >= display.bounds.maxY - slack
    }

    private static func escapesUsableArea(_ bounds: CGRect, _ display: DisplayArea) -> Bool {
        bounds.maxY > display.usable.maxY + slack || bounds.width > display.usable.width + slack
    }

    static func resolve(mode: CinemaMode, action: CinemaAction, uncertain: CinemaUncertainBehavior,
                        evidence: FullscreenEvidence) -> CinemaState {
        guard mode != .normal else { return .normal }
        switch evidence {
        case .none:
            return .normal
        case .uncertain:
            return switch uncertain {
            case .stayVisible: .normal
            case .compact: .compact
            case .hide: .hidden
            }
        case .fullscreen:
            return switch mode {
            case .compact: .compact
            case .hidden: .hidden
            case .normal: .normal
            case .automatic: action == .hide ? .hidden : .compact
            }
        }
    }
}

protocol WindowListing: Sendable {
    func onScreenWindows() -> [WindowSample]
}

struct SystemWindowList: WindowListing {
    func onScreenWindows() -> [WindowSample] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsInfo = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo) else { return nil }
            return WindowSample(ownerPID: pid, layer: window[kCGWindowLayer as String] as? Int ?? 0, bounds: bounds,
                                alpha: window[kCGWindowAlpha as String] as? Double ?? 1)
        }
    }
}

/// Re-checks only on system signals. Each signal gets follow-up checks because full-screen animations
/// and game launches finish after their notification. Nothing runs in between.
@MainActor
final class CinemaService {
    private static let followUps: [Duration] = [.milliseconds(900), .milliseconds(2500)]

    var onChange: ((CinemaState) -> Void)?

    private let preferences: MorphPreferences
    private let listing: any WindowListing
    private let scheduler: any Scheduling
    private let displayArea: () -> DisplayArea?
    private var tokens: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    private var followUpWork: [any ScheduledWork] = []
    private var generation = 0
    private(set) var evidence = FullscreenEvidence.none

    init(preferences: MorphPreferences, listing: any WindowListing = SystemWindowList(), scheduler: any Scheduling,
         displayArea: @escaping () -> DisplayArea?) {
        self.preferences = preferences
        self.listing = listing
        self.scheduler = scheduler
        self.displayArea = displayArea
    }

    func start() {
        guard tokens.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification)
        observe(workspace, NSWorkspace.didActivateApplicationNotification)
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification)
        signal()
    }

    func stop() {
        tokens.forEach { $0.center.removeObserver($0.token) }
        tokens = []
        cancelFollowUps()
        generation += 1
        evidence = .none
        onChange?(.normal)
    }

    /// Something changed. Check now and again once it has settled.
    func signal() {
        cancelFollowUps()
        check()
        followUpWork = Self.followUps.map { delay in
            scheduler.schedule(after: delay) { [weak self] in self?.check() }
        }
    }

    func applyPreferences() {
        publish()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.signal() }
        }
        tokens.append((center, token))
    }

    private func cancelFollowUps() {
        followUpWork.forEach { $0.cancel() }
        followUpWork = []
    }

    private func check() {
        guard let display = displayArea() else { return }
        generation += 1
        let current = generation
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let own = ProcessInfo.processInfo.processIdentifier
        let listing = listing
        Task { [weak self] in
            let windows = await Task.detached(priority: .utility) { listing.onScreenWindows() }.value
            guard let self, current == self.generation else { return }
            self.evidence = FullscreenDetector.evaluate(windows: windows, display: display,
                                                        frontmostPID: frontmost, ownPID: own)
            self.publish()
        }
    }

    private func publish() {
        onChange?(FullscreenDetector.resolve(mode: preferences.cinemaMode, action: preferences.cinemaAction,
                                             uncertain: preferences.cinemaUncertain, evidence: evidence))
    }
}
