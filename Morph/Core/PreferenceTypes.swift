import CoreGraphics
import Foundation

enum IslandSizePreference: String, CaseIterable, Identifiable, Sendable {
    case compact, regular, large

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum AnimationIntensity: String, CaseIterable, Identifiable, Sendable {
    case subtle, standard, expressive

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum ReducedMotionPreference: String, CaseIterable, Identifiable, Sendable {
    case system, always, never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Follow System"
        case .always: "Always Reduce"
        case .never: "Never Reduce"
        }
    }
}

enum AccentPreference: String, CaseIterable, Identifiable, Sendable {
    case neutral, white, blue, mint, orange, pink

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum CinemaMode: String, CaseIterable, Identifiable, Sendable {
    case normal, compact, hidden, automatic

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// What Automatic does in full screen.
enum CinemaAction: String, CaseIterable, Identifiable, Sendable {
    case compact, hide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: "Reduce"
        case .hide: "Hide"
        }
    }
}

/// What to do when the windows on screen don't clearly say full screen or not.
enum CinemaUncertainBehavior: String, CaseIterable, Identifiable, Sendable {
    case stayVisible, compact, hide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stayVisible: "Stay Visible"
        case .compact: "Reduce"
        case .hide: "Hide"
        }
    }
}

enum WaveformFallback: String, CaseIterable, Identifiable, Sendable {
    case staticIcon, decorative

    var id: String { rawValue }

    var title: String {
        switch self {
        case .staticIcon: "Static Icon"
        case .decorative: "Decorative Motion (not synced)"
        }
    }
}

enum ActivityDurationPreference: String, CaseIterable, Identifiable, Sendable {
    case short, standard, long

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var scale: Double {
        switch self {
        case .short: 0.7
        case .standard: 1
        case .long: 1.6
        }
    }
}

enum MediaSourcePreference: String, CaseIterable, Identifiable, Sendable {
    case automatic, appleMusic, spotify

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .appleMusic: "Apple Music"
        case .spotify: "Spotify"
        }
    }
}

/// How far one volume or brightness key press moves the level, in whole percentage points.
enum VolumeStep: String, CaseIterable, Identifiable, Sendable {
    case two, five, ten

    var id: String { rawValue }
    var points: Int {
        switch self {
        case .two: 2
        case .five: 5
        case .ten: 10
        }
    }
    var title: String { "\(points)%" }

    /// The next multiple of `step` past `percentage` in `direction`, so a level off the grid
    /// lands on it rather than keeping its offset. Whole numbers, so no float drift.
    static func next(from percentage: Int, direction: Int, step: Int) -> Int {
        let level = percentage.clamped(to: 0...100)
        let target = direction > 0 ? (level / step + 1) * step : ((level + step - 1) / step - 1) * step
        return target.clamped(to: 0...100)
    }
}

/// Manual correction applied on top of the geometry macOS reports.
struct NotchCalibration: Codable, Equatable, Sendable {
    var offsetX: CGFloat = 0
    var widthDelta: CGFloat = 0
    var heightDelta: CGFloat = 0

    static let zero = NotchCalibration()
}
