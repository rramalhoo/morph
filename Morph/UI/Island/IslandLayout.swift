import CoreGraphics

enum ExpandedTab: String, CaseIterable, Identifiable, Sendable {
    case home, timers, focus, battery, activities, transfers, shelf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .timers: "Timers"
        case .focus: "Focus"
        case .battery: "Battery"
        case .activities: "Activities"
        case .transfers: "Transfers"
        case .shelf: "File Shelf"
        }
    }

    var symbol: String {
        switch self {
        case .home: "square.grid.2x2.fill"
        case .timers: "timer"
        case .focus: "brain.head.profile"
        case .battery: "battery.75percent"
        case .activities: "dot.radiowaves.left.and.right"
        case .transfers: "arrow.up.arrow.down"
        case .shelf: "tray.full.fill"
        }
    }
}

/// Ongoing state shown beside the notch while nothing else is going on.
enum LiveContent: Equatable, Sendable {
    case timer
    case stopwatch
    case media
    case focus
    case external
    /// An activity from a paired iPhone.
    case continuity
}

enum IslandPresentation: Equatable, Sendable {
    case idle
    case live(LiveContent)
    case hover
    case dropTarget
    case activity(IslandActivity)
    case expanded(ExpandedTab)
}

/// Every island size is computed here, so the window frame and SwiftUI always agree.
struct IslandLayout: Equatable, Sendable {
    struct Corners: Equatable, Sendable {
        var top: CGFloat
        var bottom: CGFloat
    }

    /// The fixed SwiftUI surface. Large enough for the biggest island plus the calibration guide.
    static let canvas = CGSize(width: 720, height: 340)
    static let calibrationMargin: CGFloat = 4
    static let levelEar: CGFloat = 72
    /// The row under the camera. One height for every level, so moving between volume and
    /// brightness, or reaching mute, can't change the island's shape.
    static let levelRow: CGFloat = 26
    static let screenshotSize = CGSize(width: 420, height: 112)
    /// One size for both phases of the welcome, so changing what it says never changes its shape.
    static let welcomeSize = CGSize(width: 400, height: 64)
    /// One row of text and a bar, wide enough that a long name and its speed both fit.
    static let transferSize = CGSize(width: 400, height: 50)

    var notch: CGSize
    var size: IslandSizePreference
    var showsCalibrationGuide = false

    private var expandedSize: CGSize {
        switch size {
        case .compact: CGSize(width: 500, height: 212)
        case .regular: CGSize(width: 560, height: 228)
        case .large: CGSize(width: 640, height: 252)
        }
    }

    func islandSize(for presentation: IslandPresentation) -> CGSize {
        let result: CGSize
        switch presentation {
        case .idle:
            result = notch
        case .live(let content):
            result = content == .media ? earSize(ear: 40) : earSize(ear: 72)
        case .hover:
            result = CGSize(width: max(notch.width + 128, 320), height: notch.height + 36)
        case .dropTarget:
            result = CGSize(width: max(notch.width + 180, 380), height: notch.height + 72)
        case .activity(let activity):
            switch activity.presentation {
            case .minimal: result = earSize(ear: 124)
            case .banner: result = CGSize(width: max(notch.width + 180, 380), height: notch.height + 52)
            case .level: result = CGSize(width: notch.width + 2 * Self.levelEar, height: notch.height + Self.levelRow)
            case .screenshot:
                result = CGSize(width: max(notch.width + 200, Self.screenshotSize.width), height: notch.height + Self.screenshotSize.height)
            case .welcome:
                result = CGSize(width: max(notch.width + 220, Self.welcomeSize.width), height: notch.height + Self.welcomeSize.height)
            case .transfer:
                result = CGSize(width: max(notch.width + 200, Self.transferSize.width), height: notch.height + Self.transferSize.height)
            }
        case .expanded:
            result = expandedSize
        }
        return result
    }

    /// The panel frame needed for a presentation, including room for the guide.
    func panelSize(for presentation: IslandPresentation) -> CGSize {
        let island = islandSize(for: presentation)
        guard showsCalibrationGuide, presentation == .idle else { return island }
        return CGSize(width: island.width + 2 * Self.calibrationMargin, height: island.height + Self.calibrationMargin)
    }

    func corners(for presentation: IslandPresentation) -> Corners {
        switch presentation {
        case .idle: Corners(top: 0, bottom: 10)
        case .live: Corners(top: 8, bottom: 12)
        case .hover: Corners(top: 10, bottom: 18)
        case .dropTarget: Corners(top: 12, bottom: 22)
        case .activity(let activity):
            switch activity.presentation {
            case .minimal: Corners(top: 8, bottom: 14)
            case .banner: Corners(top: 12, bottom: 22)
            case .level: Corners(top: 8, bottom: 16)
            case .screenshot: Corners(top: 12, bottom: 22)
            case .welcome: Corners(top: 12, bottom: 24)
            case .transfer: Corners(top: 12, bottom: 22)
            }
        case .expanded: Corners(top: 14, bottom: 26)
        }
    }

    private func earSize(ear: CGFloat) -> CGSize {
        CGSize(width: notch.width + 2 * ear, height: notch.height)
    }
}
