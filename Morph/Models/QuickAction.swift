import Foundation

enum TogglablePreference: String, Codable, CaseIterable, Hashable, Sendable {
    case hoverExpansion, liveActivities

    var title: String {
        switch self {
        case .hoverExpansion: "Hover Expansion"
        case .liveActivities: "Live Activities"
        }
    }
}

enum QuickAction: Codable, Hashable, Identifiable, Sendable {
    case openApplication(bundleIdentifier: String, name: String)
    case startTimer(seconds: Int)
    case openSettings
    case togglePreference(TogglablePreference)

    static let defaults: [QuickAction] = [
        .startTimer(seconds: 300),
        .togglePreference(.hoverExpansion),
        .openSettings,
    ]

    /// How many fit in the expanded panel.
    static let limit = 4

    var id: Self { self }

    var title: String {
        switch self {
        case .openApplication(_, let name): "Open \(name)"
        case .startTimer(let seconds): "Start \(TimeFormat.clock(TimeInterval(seconds))) Timer"
        case .openSettings: "Morph Settings"
        case .togglePreference(let preference): "Toggle \(preference.title)"
        }
    }

    var symbol: String {
        switch self {
        case .openApplication: "app.badge"
        case .startTimer: "timer"
        case .openSettings: "gearshape"
        case .togglePreference: "switch.2"
        }
    }
}
