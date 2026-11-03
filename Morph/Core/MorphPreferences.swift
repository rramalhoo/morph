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
    nonisolated static let screenshotDurationRange: ClosedRange<Double> = 3.0...20.0
    nonisolated static let liveAPIPortRange: ClosedRange<Int> = 1024...65535
    nonisolated static let defaultLiveAPIPort = 47_800
    nonisolated static let deviceRefreshRange: ClosedRange<Int> = 1...30
    nonisolated static let welcomeDurationRange: ClosedRange<Double> = 2.0...6.0
    nonisolated static let defaultWelcomeDuration = 3.5

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
        case replaceVolumeHUD, volumeShowsPercentage, volumeHUDDuration, volumeStep
        case replaceBrightnessHUD, brightnessShowsPercentage, brightnessHUDDuration, brightnessStep
        case waveDiagnostics, nowPlayingPro, progressControls
        case screenshotPreviews, screenshotFolder, screenshotDuration
        case liveAPIEnabled, liveAPIPort
        case focusEnabled, focusMinutes, shortBreakMinutes, longBreakMinutes, focusCycles
        case focusNotifications, focusAutoBreak
        case batteryAudioDevices, peripheralAlerts, deviceRefreshMinutes
        case lockScreenEnabled, lockAnimation, welcomeEnabled, welcomeShowsMusic, welcomeShowsBattery
        case welcomeDuration, welcomeReducedMotion
        case notificationsEnabled, notificationPreviews, lowBatteryNotifications
        case transfersEnabled, showDownloads, showUploads, showAirDrop, monitorDownloads, downloadsFolder
        case transferCompletionAnimation, transferHistoryMinutes
        case continuityEnabled, showContinuityActivities, continuityHidesSensitive
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
    /// On by default so the keys move in exact steps; without permission macOS keeps them.
    var replaceVolumeHUD = true { didSet { store(replaceVolumeHUD, .replaceVolumeHUD) } }
    var volumeShowsPercentage = true { didSet { store(volumeShowsPercentage, .volumeShowsPercentage) } }
    var volumeHUDDuration = MorphPreferences.defaultHUDDuration { didSet { store(volumeHUDDuration, .volumeHUDDuration) } }
    var volumeStep = VolumeStep.five { didSet { store(volumeStep.rawValue, .volumeStep) } }
    var replaceBrightnessHUD = false { didSet { store(replaceBrightnessHUD, .replaceBrightnessHUD) } }
    var brightnessShowsPercentage = true { didSet { store(brightnessShowsPercentage, .brightnessShowsPercentage) } }
    var brightnessHUDDuration = MorphPreferences.defaultHUDDuration { didSet { store(brightnessHUDDuration, .brightnessHUDDuration) } }
    var brightnessStep = VolumeStep.five { didSet { store(brightnessStep.rawValue, .brightnessStep) } }

    var waveDiagnostics = false { didSet { store(waveDiagnostics, .waveDiagnostics) } }
    var nowPlayingPro = true { didSet { store(nowPlayingPro, .nowPlayingPro) } }
    var progressControls = true { didSet { store(progressControls, .progressControls) } }
    var screenshotPreviews = false { didSet { store(screenshotPreviews, .screenshotPreviews) } }
    /// A security-scoped bookmark of the one folder Morph may watch.
    var screenshotFolder: Data? {
        didSet {
            guard !isLoading else { return }
            defaults.set(screenshotFolder, forKey: Key.screenshotFolder.rawValue)
        }
    }
    var screenshotDuration = 6.0 { didSet { store(screenshotDuration, .screenshotDuration) } }
    var liveAPIEnabled = false { didSet { store(liveAPIEnabled, .liveAPIEnabled) } }
    var liveAPIPort = MorphPreferences.defaultLiveAPIPort { didSet { store(liveAPIPort, .liveAPIPort) } }
    var focusEnabled = true { didSet { store(focusEnabled, .focusEnabled) } }
    var focusMinutes = 25 { didSet { store(focusMinutes, .focusMinutes) } }
    var shortBreakMinutes = 5 { didSet { store(shortBreakMinutes, .shortBreakMinutes) } }
    var longBreakMinutes = 15 { didSet { store(longBreakMinutes, .longBreakMinutes) } }
    var focusCycles = 4 { didSet { store(focusCycles, .focusCycles) } }
    var focusNotifications = false { didSet { store(focusNotifications, .focusNotifications) } }
    var focusAutoBreak = true { didSet { store(focusAutoBreak, .focusAutoBreak) } }
    var batteryAudioDevices = true { didSet { store(batteryAudioDevices, .batteryAudioDevices) } }
    var peripheralAlerts = false { didSet { store(peripheralAlerts, .peripheralAlerts) } }
    var deviceRefreshMinutes = 5 { didSet { store(deviceRefreshMinutes, .deviceRefreshMinutes) } }

    // Lock Screen
    var lockScreenEnabled = true { didSet { store(lockScreenEnabled, .lockScreenEnabled) } }
    var lockAnimation = true { didSet { store(lockAnimation, .lockAnimation) } }
    var welcomeEnabled = true { didSet { store(welcomeEnabled, .welcomeEnabled) } }
    var welcomeShowsMusic = true { didSet { store(welcomeShowsMusic, .welcomeShowsMusic) } }
    var welcomeShowsBattery = true { didSet { store(welcomeShowsBattery, .welcomeShowsBattery) } }
    var welcomeDuration = MorphPreferences.defaultWelcomeDuration { didSet { store(welcomeDuration, .welcomeDuration) } }
    var welcomeReducedMotion = false { didSet { store(welcomeReducedMotion, .welcomeReducedMotion) } }

    // Notifications. Each kind still has its own switch; this one can silence them all.
    var notificationsEnabled = true { didSet { store(notificationsEnabled, .notificationsEnabled) } }
    /// Off: notifications say what happened, never which file, device or activity.
    var notificationPreviews = false { didSet { store(notificationPreviews, .notificationPreviews) } }
    var lowBatteryNotifications = false { didSet { store(lowBatteryNotifications, .lowBatteryNotifications) } }

    // Transfers. Downloads are only watched in a folder the user picks.
    var transfersEnabled = true { didSet { store(transfersEnabled, .transfersEnabled) } }
    var showDownloads = true { didSet { store(showDownloads, .showDownloads) } }
    var showUploads = true { didSet { store(showUploads, .showUploads) } }
    var showAirDrop = true { didSet { store(showAirDrop, .showAirDrop) } }
    var monitorDownloads = false { didSet { store(monitorDownloads, .monitorDownloads) } }
    /// A security-scoped bookmark of the downloads folder.
    var downloadsFolder: Data? {
        didSet {
            guard !isLoading else { return }
            defaults.set(downloadsFolder, forKey: Key.downloadsFolder.rawValue)
        }
    }
    var transferCompletionAnimation = true { didSet { store(transferCompletionAnimation, .transferCompletionAnimation) } }
    /// How long finished transfers stay in the panel. Never written to disk.
    var transferHistoryMinutes = 15 { didSet { store(transferHistoryMinutes, .transferHistoryMinutes) } }

    // Continuity. Off until the user pairs something.
    var continuityEnabled = false { didSet { store(continuityEnabled, .continuityEnabled) } }
    var showContinuityActivities = true { didSet { store(showContinuityActivities, .showContinuityActivities) } }
    var continuityHidesSensitive = true { didSet { store(continuityHidesSensitive, .continuityHidesSensitive) } }

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
        replaceVolumeHUD = bool(.replaceVolumeHUD, default: true)
        volumeShowsPercentage = bool(.volumeShowsPercentage, default: true)
        volumeHUDDuration = hudDuration(.volumeHUDDuration)
        volumeStep = option(.volumeStep, default: .five)
        replaceBrightnessHUD = bool(.replaceBrightnessHUD, default: false)
        brightnessShowsPercentage = bool(.brightnessShowsPercentage, default: true)
        brightnessHUDDuration = hudDuration(.brightnessHUDDuration)
        brightnessStep = option(.brightnessStep, default: .five)
        waveDiagnostics = bool(.waveDiagnostics, default: false)
        nowPlayingPro = bool(.nowPlayingPro, default: true)
        progressControls = bool(.progressControls, default: true)
        screenshotPreviews = bool(.screenshotPreviews, default: false)
        screenshotFolder = defaults.data(forKey: Key.screenshotFolder.rawValue)
        screenshotDuration = (defaults.object(forKey: Key.screenshotDuration.rawValue) as? Double ?? 6).clamped(to: Self.screenshotDurationRange)
        liveAPIEnabled = bool(.liveAPIEnabled, default: false)
        liveAPIPort = (defaults.object(forKey: Key.liveAPIPort.rawValue) as? Int ?? Self.defaultLiveAPIPort).clamped(to: Self.liveAPIPortRange)
        focusEnabled = bool(.focusEnabled, default: true)
        focusMinutes = minutes(.focusMinutes, default: 25)
        shortBreakMinutes = minutes(.shortBreakMinutes, default: 5)
        longBreakMinutes = minutes(.longBreakMinutes, default: 15)
        focusCycles = (defaults.object(forKey: Key.focusCycles.rawValue) as? Int ?? 4).clamped(to: 2...8)
        focusNotifications = bool(.focusNotifications, default: false)
        focusAutoBreak = bool(.focusAutoBreak, default: true)
        batteryAudioDevices = bool(.batteryAudioDevices, default: true)
        peripheralAlerts = bool(.peripheralAlerts, default: false)
        deviceRefreshMinutes = (defaults.object(forKey: Key.deviceRefreshMinutes.rawValue) as? Int ?? 5).clamped(to: Self.deviceRefreshRange)
        lockScreenEnabled = bool(.lockScreenEnabled, default: true)
        lockAnimation = bool(.lockAnimation, default: true)
        welcomeEnabled = bool(.welcomeEnabled, default: true)
        welcomeShowsMusic = bool(.welcomeShowsMusic, default: true)
        welcomeShowsBattery = bool(.welcomeShowsBattery, default: true)
        welcomeDuration = (defaults.object(forKey: Key.welcomeDuration.rawValue) as? Double ?? Self.defaultWelcomeDuration)
            .clamped(to: Self.welcomeDurationRange)
        welcomeReducedMotion = bool(.welcomeReducedMotion, default: false)
        notificationsEnabled = bool(.notificationsEnabled, default: true)
        notificationPreviews = bool(.notificationPreviews, default: false)
        lowBatteryNotifications = bool(.lowBatteryNotifications, default: false)
        transfersEnabled = bool(.transfersEnabled, default: true)
        showDownloads = bool(.showDownloads, default: true)
        showUploads = bool(.showUploads, default: true)
        showAirDrop = bool(.showAirDrop, default: true)
        monitorDownloads = bool(.monitorDownloads, default: false)
        downloadsFolder = defaults.data(forKey: Key.downloadsFolder.rawValue)
        transferCompletionAnimation = bool(.transferCompletionAnimation, default: true)
        transferHistoryMinutes = (defaults.object(forKey: Key.transferHistoryMinutes.rawValue) as? Int ?? 15).clamped(to: 0...240)
        continuityEnabled = bool(.continuityEnabled, default: false)
        showContinuityActivities = bool(.showContinuityActivities, default: true)
        continuityHidesSensitive = bool(.continuityHidesSensitive, default: true)
        selectedDisplay = defaults.string(forKey: Key.selectedDisplay.rawValue) ?? Self.automaticDisplay
        calibration = json(.calibration) ?? .zero
        quickActions = json(.quickActions) ?? QuickAction.defaults
    }

    private func minutes(_ key: Key, default fallback: Int) -> Int {
        (defaults.object(forKey: key.rawValue) as? Int ?? fallback).clamped(to: 1...180)
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
                              brightness: willShow && brightnessIndicator && replaceBrightnessHUD,
                              volumeStep: volumeStep, brightnessStep: brightnessStep)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
