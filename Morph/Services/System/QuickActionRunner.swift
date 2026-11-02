import AppKit

/// Runs a configured quick action. Dependencies are closures so each kind of action is testable.
@MainActor
final class QuickActionRunner {
    private let preferences: MorphPreferences
    private let startTimer: (Duration) -> Void
    private let openSettings: () -> Void
    private let openApplication: (String) async -> Bool
    private let reportFailure: (String) -> Void

    init(preferences: MorphPreferences,
         startTimer: @escaping (Duration) -> Void,
         openSettings: @escaping () -> Void,
         openApplication: @escaping (String) async -> Bool = QuickActionRunner.launch,
         reportFailure: @escaping (String) -> Void) {
        self.preferences = preferences
        self.startTimer = startTimer
        self.openSettings = openSettings
        self.openApplication = openApplication
        self.reportFailure = reportFailure
    }

    func run(_ action: QuickAction) {
        switch action {
        case .openApplication(let bundleIdentifier, let name):
            Task {
                if await !openApplication(bundleIdentifier) {
                    reportFailure("\(name) couldn't be opened")
                }
            }
        case .startTimer(let seconds):
            startTimer(.seconds(seconds))
        case .openSettings:
            openSettings()
        case .togglePreference(.hoverExpansion):
            preferences.hoverExpansion.toggle()
        case .togglePreference(.liveActivities):
            preferences.liveActivitiesEnabled.toggle()
        }
    }

    private static func launch(_ bundleIdentifier: String) async -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return false }
        return (try? await NSWorkspace.shared.openApplication(at: url, configuration: .init())) != nil
    }
}
