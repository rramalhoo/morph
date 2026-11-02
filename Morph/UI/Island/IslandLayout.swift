import CoreGraphics

enum ExpandedTab: String, CaseIterable, Identifiable, Sendable {
    case home, timers, shelf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .timers: "Timers"
        case .shelf: "File Shelf"
        }
    }

    var symbol: String {
        switch self {
        case .home: "square.grid.2x2.fill"
        case .timers: "timer"
        case .shelf: "tray.full.fill"
        }
    }
}

/// Ongoing state shown beside the notch while nothing else is going on.
enum LiveContent: Equatable, Sendable {
    case timer
    case stopwatch
    case media
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
    static let levelLip: CGFloat = 16

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
            case .level: result = levelSize(for: activity.content)
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
            }
        case .expanded: Corners(top: 14, bottom: 26)
        }
    }

    /// Ears for the icon and value, and a lip below the camera for the bar: the middle of the
    /// notch itself can't show anything. Without a real reading there's no bar and no lip.
    private func levelSize(for content: IslandActivity.Content) -> CGSize {
        CGSize(width: notch.width + 2 * Self.levelEar, height: notch.height + (content.level == nil ? 0 : Self.levelLip))
    }

    private func earSize(ear: CGFloat) -> CGSize {
        CGSize(width: notch.width + 2 * ear, height: notch.height)
    }
}
