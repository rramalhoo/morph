import Foundation
import Observation

/// Every persisted setting. Backed by an injected `UserDefaults` so tests use a throwaway suite.
@MainActor
@Observable
final class MorphPreferences {
    nonisolated static let automaticDisplay = "automatic"
    nonisolated static let dismissalDelayRange: ClosedRange<Double> = 0.1...2.0
    nonisolated static let sensitivityRange: ClosedRange<Double> = 0.5...2.0
    nonisolated static let hudDurationRange: ClosedRange<Double> = 0.6...3.0
    nonisolated static let defaultHUDDuration = 1.2

    private enum Key: String, CaseIterable {
        case isEnabled, showMenuBarIcon, showDockIcon
        case islandSize, animationIntensity, accent, reducedMotion
        case hoverExpansion, clickToExpand, dismissalDelay, fullscreenBehavior
        case musicEnabled, batteryEnabled, timerEnabled, shelfEnabled, activitiesEnabled
        case liveActivitiesEnabled, mediaSource, timerNotifications, lowBatteryThreshold
        case selectedDisplay, calibration, quickActions
        case cinemaMode, cinemaAction, cinemaUncertain
        case audioVisualization, ambientColors, visualizationSensitivity, waveformFallback
        case deviceActivities, peripheralBattery
        case horizontalSwipes, verticalSwipes, gestureSensitivity
        case volumeIndicator, brightnessIndicator, activityDuration
        case replaceVolumeHUD, volumeShowsPercentage, volumeHUDDuration
        case replaceBrightnessHUD, brightnessShowsPercentage, brightnessHUDDuration
    }

    // General
    var isEnabled = true { didSet { store(isEnabled, .isEnabled) } }
    var showMenuBarIcon = true { didSet { store(showMenuBarIcon, .showMenuBarIcon) } }
    var showDockIcon = false { didSet { store(showDockIcon, .showDockIcon) } }

    // Appearance
    var islandSize = IslandSizePreference.regular { didSet { store(islandSize.rawValue, .islandSize) } }
    var animationIntensity = AnimationIntensity.standard { didSet { store(animationIntensity.rawValue, .animationIntensity) } }
    var accent = AccentPreference.neutral { didSet { store(accent.rawValue, .accent) } }
    var reducedMotion = ReducedMotionPreference.system { didSet { store(reducedMotion.rawValue, .reducedMotion) } }

    // Behavior
    var hoverExpansion = true { didSet { store(hoverExpansion, .hoverExpansion) } }
    var clickToExpand = true { didSet { store(clickToExpand, .clickToExpand) } }
    var dismissalDelay = 0.35 { didSet { store(dismissalDelay, .dismissalDelay) } }
    var cinemaMode = CinemaMode.automatic { didSet { store(cinemaMode.rawValue, .cinemaMode) } }
    var cinemaAction = CinemaAction.hide { didSet { store(cinemaAction.rawValue, .cinemaAction) } }
    var cinemaUncertain = CinemaUncertainBehavior.stayVisible { didSet { store(cinemaUncertain.rawValue, .cinemaUncertain) } }
    var horizontalSwipes = true { didSet { store(horizontalSwipes, .horizontalSwipes) } }
    var verticalSwipes = true { didSet { store(verticalSwipes, .verticalSwipes) } }
    var gestureSensitivity = 1.0 { didSet { store(gestureSensitivity, .gestureSensitivity) } }
    var activityDuration = ActivityDurationPreference.standard { didSet { store(activityDuration.rawValue, .activityDuration) } }

    // Modules
    var musicEnabled = true { didSet { store(musicEnabled, .musicEnabled) } }
    var batteryEnabled = true { didSet { store(batteryEnabled, .batteryEnabled) } }
    var timerEnabled = true { didSet { store(timerEnabled, .timerEnabled) } }
    var shelfEnabled = true { didSet { store(shelfEnabled, .shelfEnabled) } }
    var activitiesEnabled = true { didSet { store(activitiesEnabled, .activitiesEnabled) } }
    var liveActivitiesEnabled = true { didSet { store(liveActivitiesEnabled, .liveActivitiesEnabled) } }
    var mediaSource = MediaSourcePreference.automatic { didSet { store(mediaSource.rawValue, .mediaSource) } }
    var timerNotifications = false { didSet { store(timerNotifications, .timerNotifications) } }
    var lowBatteryThreshold = 20 { didSet { store(lowBatteryThreshold, .lowBatteryThreshold) } }
    var audioVisualization = true { didSet { store(audioVisualization, .audioVisualization) } }
    var ambientColors = true { didSet { store(ambientColors, .ambientColors) } }
    var visualizationSensitivity = 1.0 { didSet { store(visualizationSensitivity, .visualizationSensitivity) } }
    var waveformFallback = WaveformFallback.staticIcon { didSet { store(waveformFallback.rawValue, .waveformFallback) } }
    var deviceActivities = true { didSet { store(deviceActivities, .deviceActivities) } }
    var peripheralBattery = true { didSet { store(peripheralBattery, .peripheralBattery) } }
    var volumeIndicator = true { didSet { store(volumeIndicator, .volumeIndicator) } }
    var brightnessIndicator = true { didSet { store(brightnessIndicator, .brightnessIndicator) } }
    var replaceVolumeHUD = false { didSet { store(replaceVolumeHUD, .replaceVolumeHUD) } }
    var volumeShowsPercentage = true { didSet { store(volumeShowsPercentage, .volumeShowsPercentage) } }
    var volumeHUDDuration = MorphPreferences.defaultHUDDuration { didSet { store(volumeHUDDuration, .volumeHUDDuration) } }
    var replaceBrightnessHUD = false { didSet { store(replaceBrightnessHUD, .replaceBrightnessHUD) } }
    var brightnessShowsPercentage = true { didSet { store(brightnessShowsPercentage, .brightnessShowsPercentage) } }
    var brightnessHUDDuration = MorphPreferences.defaultHUDDuration { didSet { store(brightnessHUDDuration, .brightnessHUDDuration) } }

    // Advanced
    var selectedDisplay = MorphPreferences.automaticDisplay { didSet { store(selectedDisplay, .selectedDisplay) } }
    var calibration = NotchCalibration.zero { didSet { storeJSON(calibration, .calibration) } }
    var quickActions = QuickAction.defaults { didSet { storeJSON(quickActions, .quickActions) } }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isLoading = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func reset() {
        Key.allCases.forEach { defaults.removeObject(forKey: $0.rawValue) }
        load()
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }

        isEnabled = bool(.isEnabled, default: true)
        showMenuBarIcon = bool(.showMenuBarIcon, default: true)
        showDockIcon = bool(.showDockIcon, default: false)
        islandSize = option(.islandSize, default: .regular)
        animationIntensity = option(.animationIntensity, default: .standard)
        accent = option(.accent, default: .neutral)
        reducedMotion = option(.reducedMotion, default: .system)
        hoverExpansion = bool(.hoverExpansion, default: true)
        clickToExpand = bool(.clickToExpand, default: true)
        dismissalDelay = (defaults.object(forKey: Key.dismissalDelay.rawValue) as? Double ?? 0.35)
            .clamped(to: Self.dismissalDelayRange)
        // Older versions stored a show/hide choice. "show" stays as it was; everything else moves
        // to Automatic, which by default hides in full screen as before.
        let legacyShow = defaults.string(forKey: Key.fullscreenBehavior.rawValue) == "show"
        cinemaMode = option(.cinemaMode, default: legacyShow ? .normal : .automatic)
        cinemaAction = option(.cinemaAction, default: .hide)
        cinemaUncertain = option(.cinemaUncertain, default: .stayVisible)
        horizontalSwipes = bool(.horizontalSwipes, default: true)
        verticalSwipes = bool(.verticalSwipes, default: true)
        gestureSensitivity = (defaults.object(forKey: Key.gestureSensitivity.rawValue) as? Double ?? 1).clamped(to: Self.sensitivityRange)
        activityDuration = option(.activityDuration, default: .standard)
        musicEnabled = bool(.musicEnabled, default: true)
        batteryEnabled = bool(.batteryEnabled, default: true)
        timerEnabled = bool(.timerEnabled, default: true)
        shelfEnabled = bool(.shelfEnabled, default: true)
        activitiesEnabled = bool(.activitiesEnabled, default: true)
        liveActivitiesEnabled = bool(.liveActivitiesEnabled, default: true)
        mediaSource = option(.mediaSource, default: .automatic)
        timerNotifications = bool(.timerNotifications, default: false)
        lowBatteryThreshold = defaults.object(forKey: Key.lowBatteryThreshold.rawValue) as? Int ?? 20
        audioVisualization = bool(.audioVisualization, default: true)
        ambientColors = bool(.ambientColors, default: true)
        visualizationSensitivity = (defaults.object(forKey: Key.visualizationSensitivity.rawValue) as? Double ?? 1).clamped(to: Self.sensitivityRange)
        waveformFallback = option(.waveformFallback, default: .staticIcon)
        deviceActivities = bool(.deviceActivities, default: true)
        peripheralBattery = bool(.peripheralBattery, default: true)
        volumeIndicator = bool(.volumeIndicator, default: true)
        brightnessIndicator = bool(.brightnessIndicator, default: true)
        replaceVolumeHUD = bool(.replaceVolumeHUD, default: false)
        volumeShowsPercentage = bool(.volumeShowsPercentage, default: true)
        volumeHUDDuration = hudDuration(.volumeHUDDuration)
        replaceBrightnessHUD = bool(.replaceBrightnessHUD, default: false)
        brightnessShowsPercentage = bool(.brightnessShowsPercentage, default: true)
        brightnessHUDDuration = hudDuration(.brightnessHUDDuration)
        selectedDisplay = defaults.string(forKey: Key.selectedDisplay.rawValue) ?? Self.automaticDisplay
        calibration = json(.calibration) ?? .zero
        quickActions = json(.quickActions) ?? QuickAction.defaults
    }

    private func hudDuration(_ key: Key) -> Double {
        (defaults.object(forKey: key.rawValue) as? Double ?? Self.defaultHUDDuration).clamped(to: Self.hudDurationRange)
    }

    private func bool(_ key: Key, default fallback: Bool) -> Bool {
        defaults.object(forKey: key.rawValue) as? Bool ?? fallback
    }

    private func option<T: RawRepresentable>(_ key: Key, default fallback: T) -> T where T.RawValue == String {
        guard let raw = defaults.string(forKey: key.rawValue) else { return fallback }
        return T(rawValue: raw) ?? fallback
    }

    private func json<T: Decodable>(_ key: Key) -> T? {
        defaults.data(forKey: key.rawValue).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func store(_ value: Any, _ key: Key) {
        guard !isLoading else { return }
        defaults.set(value, forKey: key.rawValue)
    }

    private func storeJSON<T: Encodable>(_ value: T, _ key: Key) {
        guard !isLoading, let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key.rawValue)
    }
}

extension MorphPreferences {
    /// Taking a key is only right when Morph will show the result: a key that disappears into a
    /// hidden HUD is worse than a duplicate one.
    func levelKeyPolicy(canShow: Bool) -> LevelKeyPolicy {
        let willShow = canShow && activitiesEnabled
        return LevelKeyPolicy(volume: willShow && volumeIndicator && replaceVolumeHUD,
                              brightness: willShow && brightnessIndicator && replaceBrightnessHUD)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
