import Foundation
import Testing
@testable import Morph

@Suite("Preferences")
@MainActor
struct PreferencesTests {
    @Test func defaultsAreSensible() {
        let preferences = MorphPreferences(defaults: makeDefaults())
        #expect(preferences.isEnabled)
        #expect(preferences.hoverExpansion)
        #expect(!preferences.showDockIcon)
        #expect(preferences.selectedDisplay == MorphPreferences.automaticDisplay)
        #expect(preferences.quickActions == QuickAction.defaults)
    }

    @Test func everyKindOfValueSurvivesARelaunch() {
        let defaults = makeDefaults()
        let first = MorphPreferences(defaults: defaults)
        first.hoverExpansion = false
        first.islandSize = .large
        first.accent = .mint
        first.dismissalDelay = 1.25
        first.cinemaMode = .compact
        first.visualizationSensitivity = 1.5
        first.horizontalSwipes = false
        first.activityDuration = .long
        first.waveformFallback = .decorative
        first.lowBatteryThreshold = 30
        first.selectedDisplay = "ABC"
        first.calibration = NotchCalibration(offsetX: 1.5, widthDelta: -2, heightDelta: 3)
        first.quickActions = [.openApplication(bundleIdentifier: "com.apple.Safari", name: "Safari"), .startTimer(seconds: 90)]

        let second = MorphPreferences(defaults: defaults)
        #expect(second.hoverExpansion == false)
        #expect(second.islandSize == .large)
        #expect(second.accent == .mint)
        #expect(second.dismissalDelay == 1.25)
        #expect(second.cinemaMode == .compact)
        #expect(second.visualizationSensitivity == 1.5)
        #expect(second.horizontalSwipes == false)
        #expect(second.activityDuration == .long)
        #expect(second.waveformFallback == .decorative)
        #expect(second.lowBatteryThreshold == 30)
        #expect(second.selectedDisplay == "ABC")
        #expect(second.calibration == NotchCalibration(offsetX: 1.5, widthDelta: -2, heightDelta: 3))
        #expect(second.quickActions.count == 2)
    }

    @Test func resetRestoresDefaultsAndPersistsThem() {
        let defaults = makeDefaults()
        let preferences = MorphPreferences(defaults: defaults)
        preferences.accent = .pink
        preferences.calibration.offsetX = 5
        preferences.reset()
        #expect(preferences.accent == .neutral)
        #expect(preferences.calibration == .zero)
        #expect(MorphPreferences(defaults: defaults).accent == .neutral)
    }

    @Test func existingFullScreenChoiceSurvivesTheUpdate() {
        let shown = makeDefaults()
        shown.set("show", forKey: "fullscreenBehavior")
        #expect(MorphPreferences(defaults: shown).cinemaMode == .normal)

        let hidden = makeDefaults()
        hidden.set("hide", forKey: "fullscreenBehavior")
        let migrated = MorphPreferences(defaults: hidden)
        #expect(migrated.cinemaMode == .automatic)
        #expect(migrated.cinemaAction == .hide)
    }

    @Test func corruptValuesFallBackInsteadOfCrashing() {
        let defaults = makeDefaults()
        defaults.set("not-a-size", forKey: "islandSize")
        defaults.set(99.0, forKey: "dismissalDelay")
        defaults.set(Data([1, 2, 3]), forKey: "quickActions")
        let preferences = MorphPreferences(defaults: defaults)
        #expect(preferences.islandSize == .regular)
        #expect(preferences.dismissalDelay == MorphPreferences.dismissalDelayRange.upperBound)
        #expect(preferences.quickActions == QuickAction.defaults)
    }

    @Test func quickActionsRunForReal() async {
        let preferences = MorphPreferences(defaults: makeDefaults())
        var started: Duration?
        var settingsOpened = false
        var failure: String?
        let runner = QuickActionRunner(
            preferences: preferences,
            startTimer: { started = $0 },
            openSettings: { settingsOpened = true },
            openApplication: { _ in false },
            reportFailure: { failure = $0 }
        )
        runner.run(.startTimer(seconds: 90))
        #expect(started == .seconds(90))
        runner.run(.openSettings)
        #expect(settingsOpened)
        runner.run(.togglePreference(.hoverExpansion))
        #expect(!preferences.hoverExpansion)
        runner.run(.openApplication(bundleIdentifier: "x", name: "Nope"))
        await Task.yield()
        await Task.yield()
        #expect(failure == "Nope couldn't be opened")
    }
}
