import AppKit
import SwiftUI

/// Composition root: builds the object graph, wires services into activities, and starts or stops
/// everything as Morph is enabled, paused or put to sleep.
@MainActor
final class AppCoordinator {
    let preferences = MorphPreferences()
    private let scheduler = SystemScheduler()
    private let battery = BatteryService()
    private let shelf = FileShelfStore()
    private let launchAtLogin = LaunchAtLoginService()
    private let notifications = TimerNotificationService()
    private let focusNotifications = TimerNotificationService(identifier: "com.athene.morph.focus")
    private let activities: ActivityManager
    private let timers: TimerService
    private let media: MediaController
    private let volume: VolumeService
    private let brightness: BrightnessService
    private let levelKeys: LevelKeyService
    private let displayBrightness = DisplayServicesBrightness()
    private let waveform: WaveformService
    private let focus: FocusService
    private let screenshots: ScreenshotService
    private let externalActivities: LiveActivityStore
    private let liveAPI: LiveAPIService
    private let deviceBattery: DeviceBatteryService
    private let ambient = AmbientColorService()
    private let peripherals: any PeripheralBatteryReading = PowerSourcePeripheralReader()
    private let island: IslandController

    private var quickActions: QuickActionRunner!
    private var window: NotchWindowController!
    private var statusItem: StatusItemController!
    private var settings: SettingsWindowController!
    private var cinema: CinemaService!

    private var loops: [ObservationLoop] = []
    private var workspaceTokens: [any NSObjectProtocol] = []
    private var sessionTokens: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    /// Asleep, locked or switched away: the island can't answer, so macOS keeps the keys.
    private var levelKeysSuspended = false
    private var isPaused = false
    private var lastConnectionChange: ContinuousClock.Instant?
    private var batteryWork: (any ScheduledWork)?

    private var isActive: Bool { preferences.isEnabled && !isPaused }

    init() {
        activities = ActivityManager(scheduler: scheduler)
        timers = TimerService(scheduler: scheduler)
        focus = FocusService(scheduler: scheduler)
        screenshots = ScreenshotService(scheduler: scheduler)
        externalActivities = LiveActivityStore(scheduler: scheduler)
        liveAPI = LiveAPIService(store: externalActivities, tokens: KeychainTokenStore(), scheduler: scheduler)
        deviceBattery = DeviceBatteryService(reader: SystemPeripheralInventory(), scheduler: scheduler)

        let runner = OSAScriptRunner()
        let probe = WorkspaceApplicationProbe()
        media = MediaController(
            providers: [
                ScriptedMediaProvider(dialect: .appleMusic, runner: runner, applications: probe),
                ScriptedMediaProvider(dialect: .spotify, runner: runner, applications: probe),
            ],
            events: SystemMediaEvents(),
            scheduler: scheduler
        )
        let output = CoreAudioOutputSystem()
        volume = VolumeService(system: output, scheduler: scheduler)
        brightness = BrightnessService(scheduler: scheduler)
        levelKeys = LevelKeyService(tap: SystemLevelKeyTap(), permission: SystemAccessibilityPermission(),
                                    engine: LevelKeyEngine(output: output, brightness: displayBrightness),
                                    brightness: displayBrightness, scheduler: scheduler)
        waveform = WaveformService(capture: ProcessTapCapture(), scheduler: scheduler)
        island = IslandController(preferences: preferences, activities: activities, timers: timers,
                                  media: media, volume: volume, scheduler: scheduler,
                                  focus: focus, external: externalActivities)

        quickActions = QuickActionRunner(
            preferences: preferences,
            startTimer: { [weak self] in self?.startTimer($0) },
            openSettings: { [weak self] in self?.openSettings() },
            reportFailure: { [weak self] in self?.activities.present(.actionFailed(message: $0)) }
        )
        window = NotchWindowController(island: island, preferences: preferences, shelf: shelf) { [unowned self] in
            islandView
        }
        settings = SettingsWindowController { [unowned self] in settingsView }
        cinema = CinemaService(preferences: preferences, scheduler: scheduler) { [weak self] in
            self?.window.currentDisplayArea
        }
        statusItem = StatusItemController(
            onToggle: { [weak self] in self?.island.toggleFromMenu() },
            onSettings: { [weak self] in self?.openSettings() },
            onPause: { [weak self] in self?.togglePause() },
            onAbout: { [weak self] in self?.showAbout() },
            isPaused: { [weak self] in self?.isPaused ?? false }
        )
    }

    func start() {
        wireEvents()
        observeSleep()
        observeSession()
        levelKeys.refreshSupport()
        applyFocusConfiguration()
        focus.restore()
        loops = [
            ObservationLoop { [weak self] in self?.applyEnabledState() },
            ObservationLoop { [weak self] in self?.applyModules() },
            ObservationLoop { [weak self] in self?.applyAppPresence() },
            ObservationLoop { [weak self] in self?.applyWaveformDemand() },
            ObservationLoop { [weak self] in self?.applyAmbientColor() },
            ObservationLoop { [weak self] in self?.applyCinema() },
            ObservationLoop { [weak self] in self?.applyLevelKeys() },
            ObservationLoop { [weak self] in self?.applyFocusConfiguration() },
            ObservationLoop { [weak self] in self?.applyScreenshots() },
            ObservationLoop { [weak self] in self?.applyLiveAPI() },
            ObservationLoop { [weak self] in self?.applyDeviceBattery() },
        ]
    }

    func stop() {
        loops.forEach { $0.invalidate() }
        loops = []
        workspaceTokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceTokens = []
        sessionTokens.forEach { $0.center.removeObserver($0.token) }
        sessionTokens = []
        levelKeys.apply(.off)
        stopServices()
        window.hide()
        statusItem.setVisible(false)
    }

    func openSettings() {
        launchAtLogin.refresh()
        levelKeys.refreshSupport()
        media.requestRefresh()
        settings.show()
    }

    func resumeAndOpenSettings() {
        if isPaused { togglePause() }
        openSettings()
    }

    // MARK: - Views

    private var islandView: some View {
        IslandRootView(
            onOpenSettings: { [weak self] in self?.openSettings() },
            onPause: { [weak self] in self?.togglePause() },
            onQuit: { NSApp.terminate(nil) }
        )
        .environment(island)
        .environment(preferences)
        .environment(media)
        .environment(volume)
        .environment(waveform)
        .environment(ambient)
        .environment(battery)
        .environment(timers)
        .environment(activities)
        .environment(shelf)
        .environment(focus)
        .environment(screenshots)
        .environment(externalActivities)
        .environment(deviceBattery)
        .environment(\.quickActionRunner, quickActions)
    }

    private var settingsView: some View {
        SettingsRootView(diagnostics: { [weak self] in self?.diagnosticsReport() ?? "" })
            .environment(island)
            .environment(preferences)
            .environment(media)
            .environment(volume)
            .environment(levelKeys)
            .environment(waveform)
            .environment(battery)
            .environment(launchAtLogin)
            .environment(screenshots)
            .environment(liveAPI)
            .environment(externalActivities)
            .environment(focus)
            .environment(deviceBattery)
    }

    // MARK: - Wiring

    private func wireEvents() {
        battery.onEvent = { [weak self] event in self?.handle(event) }
        media.onPlaybackStarted = { [weak self] snapshot in
            guard let self, let track = snapshot.track else { return }
            self.present(.nowPlaying(title: track.title, artist: track.artist))
        }
        media.onCommandFailed = { [weak self] message in
            self?.activities.present(.actionFailed(message: message))
        }
        volume.onOutputEvent = { [weak self] event in self?.handle(event) }
        volume.onConnectionEvent = { [weak self] event in self?.handle(event) }
        cinema.onChange = { [weak self] state in self?.island.update(cinema: state) }
        brightness.onChange = { [weak self] increased, percentage in
            guard self?.preferences.brightnessIndicator == true else { return }
            self?.presentLevel(.brightness(increased: increased, percentage: percentage))
        }
        brightness.onVolumeKey = { [weak self] in self?.presentCurrentVolume() }
        levelKeys.onUpdate = { [weak self] update, press, modifiers in
            self?.handle(update, press: press, modifiers: modifiers)
        }
        media.onVolumeChanged = { [weak self] volume in
            guard let self, self.preferences.volumeIndicator, !self.island.mode.isExpanded else { return }
            self.presentLevel(.volumeChanged(percentage: volume))
        }
        timers.onCompleted = { [weak self] duration in
            self?.present(.timerCompleted(duration: duration.timeInterval))
        }
        timers.onNotificationChange = { [weak self] remaining in
            guard let self else { return }
            if let remaining, self.preferences.timerNotifications {
                self.notifications.schedule(after: remaining)
            } else {
                self.notifications.cancel()
            }
        }
        shelf.onAdded = { [weak self] count in self?.present(.filesAdded(count: count)) }
        focus.onFinished = { [weak self] phase in self?.activities.present(.focusFinished(phase)) }
        focus.onNotificationChange = { [weak self] remaining, title in
            guard let self else { return }
            if let remaining, self.preferences.focusNotifications {
                self.focusNotifications.schedule(after: remaining, title: title)
            } else {
                self.focusNotifications.cancel()
            }
        }
        screenshots.onCaptured = { [weak self] preview in
            guard let self, self.preferences.activitiesEnabled else { return }
            self.activities.present(.screenshot(preview), duration: .seconds(self.preferences.screenshotDuration))
        }
        activities.shouldExtend = { [weak self] activity in
            guard let self, activity.presentation == .screenshot else { return false }
            return self.island.isPointerInside || self.screenshots.isDragging && self.island.isExportingDrag
        }
        externalActivities.onChange = { [weak self] change in
            guard let self else { return }
            switch change {
            case .started(let activity): self.present(.external(activity))
            case .finished(let activity):
                if activity.state == .success || activity.state == .failed { self.present(.external(activity)) }
            }
        }
        deviceBattery.onLow = { [weak self] reading in
            guard let percentage = reading.percentage else { return }
            self?.present(.peripheralLow(name: reading.name, percentage: percentage))
        }
    }

    /// Battery warnings are never optional. Everything else respects the Activities switch.
    private func present(_ content: IslandActivity.Content) {
        guard preferences.activitiesEnabled else { return }
        // Focus keeps routine activities out, while anything from timers up still gets through.
        if focus.isQuiet, IslandActivity(content, at: scheduler.now).priority < .timer { return }
        activities.present(content)
    }

    private func presentLevel(_ content: IslandActivity.Content) {
        guard preferences.activitiesEnabled else { return }
        let seconds = content.levelKind == .brightness ? preferences.brightnessHUDDuration : preferences.volumeHUDDuration
        activities.present(content, duration: .seconds(seconds))
    }

    /// Shows the output as it stands, which is what a key at either end of the range changes nothing about.
    private func presentCurrentVolume() {
        guard preferences.volumeIndicator, !island.mode.isExpanded, let state = volume.output, let percentage = state.percentage else { return }
        presentLevel(.outputVolume(percentage: percentage, muted: state.effectivelyMuted))
    }

    private func handle(_ update: LevelUpdate, press: LevelKeyPress, modifiers: LevelKeyModifiers) {
        switch update {
        case .volume(let percentage, let muted):
            presentLevel(.outputVolume(percentage: percentage, muted: muted))
            if press.key != .mute { VolumeFeedback.play(modifiers: modifiers) }
        case .brightness(let percentage, let increased):
            presentLevel(.brightness(increased: increased, percentage: percentage))
        }
    }

    private func handle(_ event: BatteryEvent) {
        switch event {
        case .powerConnected(let percentage, let charging):
            present(.powerConnected(percentage: percentage, charging: charging))
        case .powerDisconnected(let percentage):
            present(.powerDisconnected(percentage: percentage))
        case .fullyCharged:
            present(.fullyCharged)
        case .low(let percentage):
            activities.present(.batteryLow(percentage: percentage))
        case .critical(let percentage):
            activities.present(.batteryCritical(percentage: percentage))
        }
    }

    private func handle(_ event: OutputEvent) {
        switch event {
        case .levelChanged(let state):
            guard preferences.volumeIndicator, !island.mode.isExpanded, let percentage = state.percentage else { return }
            presentLevel(.outputVolume(percentage: percentage, muted: state.effectivelyMuted))
        case .deviceChanged(let device):
            levelKeys.outputDidChange()
            // A connect or disconnect has already said this, more usefully.
            if let change = lastConnectionChange, change.duration(to: scheduler.now) < .seconds(3) { return }
            guard preferences.deviceActivities else { return }
            present(.outputChanged(name: device.name, symbol: device.symbol))
        }
    }

    private func handle(_ event: DeviceConnectionEvent) {
        lastConnectionChange = scheduler.now
        batteryWork?.cancel()
        deviceBattery.refresh(force: true)
        guard preferences.deviceActivities else { return }
        switch event {
        case .connected(let device):
            present(.deviceConnected(name: device.name, symbol: device.symbol, battery: peripheralBattery(of: device)))
            // macOS can take a moment to learn the level of something that just connected.
            batteryWork = scheduler.schedule(after: .seconds(2)) { [weak self] in
                guard let self, let battery = self.peripheralBattery(of: device),
                      case .deviceConnected(_, _, nil)? = self.activities.current?.content else { return }
                self.present(.deviceConnected(name: device.name, symbol: device.symbol, battery: battery))
            }
        case .disconnected(let device):
            present(.deviceDisconnected(name: device.name, symbol: device.symbol))
        }
    }

    private func peripheralBattery(of device: AudioOutputDevice) -> Int? {
        preferences.peripheralBattery ? peripherals.percentage(forDeviceNamed: device.name) : nil
    }

    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.island.send(.reset)
                self?.activities.removeAll()
                self?.waveform.stopNow()
                self?.screenshots.setSessionActive(false)
                self?.setLevelKeysSuspended(true)
            }
        })
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.setLevelKeysSuspended(false)
                guard self.isActive else { return }
                self.applyWaveformDemand()
                self.battery.refresh()
                self.media.requestRefresh()
                self.volume.resynchronize()
                if self.preferences.cinemaMode != .normal { self.cinema.signal() }
            }
        })
    }

    /// macOS keeps the keys wherever the island can't show the result: the HUD is the point of
    /// taking them over.
    private func observeSession() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let events: [(NotificationCenter, Notification.Name, Bool)] = [
            (workspace, NSWorkspace.sessionDidResignActiveNotification, true),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification, false),
            (distributed, Notification.Name("com.apple.screenIsLocked"), true),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), false),
        ]
        for (center, name, suspended) in events {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screenshots.setSessionActive(!suspended)
                    if suspended, case .screenshot? = self?.activities.current?.content { self?.activities.dismissCurrent() }
                    self?.setLevelKeysSuspended(suspended)
                }
            }
            sessionTokens.append((center, token))
        }
        let screens = NotificationCenter.default
        sessionTokens.append((screens, screens.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.levelKeys.displaysDidChange() }
        }))
    }

    private func setLevelKeysSuspended(_ suspended: Bool) {
        levelKeysSuspended = suspended
        applyLevelKeys()
    }

    // MARK: - State

    private func applyLevelKeys() {
        let canShow = isActive && !levelKeysSuspended && island.cinema == .normal && island.geometry != nil
        // Reading the private level is part of the same opt-in as the replacement.
        brightness.reader = preferences.replaceBrightnessHUD ? displayBrightness : IOKitBrightnessReader()
        levelKeys.apply(preferences.levelKeyPolicy(canShow: canShow))
    }

    private func applyEnabledState() {
        if isActive {
            window.show()
            startServices()
        } else {
            stopServices()
            window.hide()
        }
    }

    private func applyModules() {
        // Reading each preference subscribes this loop to it.
        let (music, power, timer, source) = (preferences.musicEnabled, preferences.batteryEnabled,
                                             preferences.timerEnabled, preferences.mediaSource)
        battery.lowThreshold = preferences.lowBatteryThreshold
        activities.durationScale = preferences.activityDuration.scale
        let wantsKeys = preferences.brightnessIndicator || preferences.volumeIndicator
        media.source = source
        guard preferences.isEnabled else { return }
        Task { @MainActor [weak self] in
            guard let self, self.isActive else { return }
            music ? self.media.start() : self.media.stop()
            power ? self.battery.start() : self.battery.stop()
            wantsKeys ? self.brightness.start() : self.brightness.stop()
            if !timer { self.timers.stopAll() }
        }
    }

    /// Bars are the only consumer, so capture exists only while they're showing live music.
    private func applyWaveformDemand() {
        waveform.sensitivity = Float(preferences.visualizationSensitivity)
        let isShowing = island.presentation == .live(.media)
        // Moving bars are what Reduce Motion turns off, so the static icon needs no capture.
        let reduced = MorphMotion.resolve(preferences, systemReduced: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion).reduced
        guard preferences.audioVisualization, !reduced, isShowing, media.snapshot?.isPlaying == true,
              let provider = media.snapshot?.provider, let track = media.snapshot?.track,
              let outputUID = volume.output?.device.uid else {
            if !preferences.audioVisualization || reduced { waveform.stopNow() } else { waveform.update(demand: nil) }
            return
        }
        waveform.update(demand: WaveformDemand(bundleIdentifier: provider.bundleIdentifier,
                                               outputUID: outputUID, trackID: track.id))
    }

    private func applyAmbientColor() {
        guard preferences.ambientColors else {
            ambient.update(key: nil, artwork: nil)
            return
        }
        ambient.update(key: media.snapshot?.track?.id, artwork: media.artwork)
    }

    private func applyCinema() {
        let mode = preferences.cinemaMode
        _ = (preferences.cinemaAction, preferences.cinemaUncertain)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if mode == .normal || !self.isActive {
                self.cinema.stop()
            } else {
                self.cinema.start()
                self.cinema.applyPreferences()
            }
        }
    }

    private func applyFocusConfiguration() {
        focus.configuration = FocusConfiguration(focus: .seconds(preferences.focusMinutes * 60),
                                                 shortBreak: .seconds(preferences.shortBreakMinutes * 60),
                                                 longBreak: .seconds(preferences.longBreakMinutes * 60),
                                                 cycles: preferences.focusCycles, autoBreak: preferences.focusAutoBreak)
    }

    private func applyScreenshots() {
        screenshots.apply(enabled: preferences.screenshotPreviews && preferences.isEnabled, bookmark: preferences.screenshotFolder)
        // The image lives only as long as its activity. Anything that ended it lets it go.
        if screenshots.current != nil, !activities.isActive(dedupeKey: "screenshot") { screenshots.clear() }
    }

    private func applyLiveAPI() {
        liveAPI.apply(enabled: preferences.liveAPIEnabled && isActive,
                      port: preferences.liveAPIPort.clamped(to: MorphPreferences.liveAPIPortRange))
    }

    private func applyDeviceBattery() {
        deviceBattery.alertsEnabled = preferences.peripheralAlerts
        deviceBattery.lowThreshold = preferences.lowBatteryThreshold
        deviceBattery.refreshInterval = .seconds(preferences.deviceRefreshMinutes * 60)
    }

    private func applyAppPresence() {
        statusItem.setVisible(preferences.showMenuBarIcon)
        settings.setDockIconVisible(preferences.showDockIcon)
    }

    private func startServices() {
        if preferences.batteryEnabled { battery.start() }
        if preferences.musicEnabled { media.start() }
        volume.start()
        if preferences.brightnessIndicator || preferences.volumeIndicator { brightness.start() }
        deviceBattery.start()
    }

    private func stopServices() {
        battery.stop()
        media.stop()
        volume.stop()
        brightness.stop()
        waveform.stopNow()
        cinema.stop()
        deviceBattery.stop()
        screenshots.clear()
        activities.removeAll()
    }

    private func togglePause() {
        isPaused.toggle()
        applyEnabledState()
        applyLevelKeys()
        applyLiveAPI()
        if !isPaused { applyCinema() }
        statusItem.refresh()
    }

    private func startTimer(_ duration: Duration) {
        timers.startCountdown(duration)
        island.showTab(.timers)
    }

    private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "morph.",
            .credits: NSAttributedString(string: "Your Mac. More alive."),
        ])
    }

    // MARK: - Diagnostics

    private func diagnosticsReport() -> String {
        let bundle = Bundle.main.infoDictionary
        var lines = [
            "Morph \(bundle?["CFBundleShortVersionString"] as? String ?? "?") (\(bundle?["CFBundleVersion"] as? String ?? "?"))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "State: \(isActive ? "active" : "paused"), mode \(island.mode)",
        ]
        if let display = window.currentDisplay {
            lines.append("Display: \(display.name) (notch \(display.hasNotch ? "yes" : "no"), built-in \(display.isBuiltIn ? "yes" : "no"))")
        }
        if let metrics = window.currentMetrics {
            lines.append("Screen: \(metrics.frame), scale \(metrics.scale), safe area top \(metrics.safeAreaTop)")
        }
        if let geometry = island.geometry {
            lines.append("Notch rect: \(geometry.notchRect)")
        }
        lines.append("Calibration: \(preferences.calibration)")
        lines.append("Battery: \(battery.snapshot.map { "\($0.percentage)%, \($0.statusText)" } ?? "none")")
        for kind in MediaProviderKind.allCases {
            lines.append("\(kind.displayName): \(media.availability[kind]?.summary ?? "not checked")")
        }
        if let error = media.lastError {
            lines.append("Last media error: \(error)")
        }
        if let output = volume.output {
            lines.append("Output: \(output.device.name) (\(output.device.transport)), volume \(output.percentage.map { "\($0)%" } ?? "not reported"), settable \(output.canSetVolume)")
        }
        lines.append("Level keys: \(levelKeys.status), volume handed back \(levelKeys.volumeHandedBack), brightness handed back \(levelKeys.brightnessHandedBack), brightness supported \(levelKeys.brightnessSupported)")
        lines.append("Waveform: \(waveform.diagnostics)")
        lines.append("Screenshots: \(screenshots.status)")
        lines.append("Live API: \(liveAPI.status), \(externalActivities.activities.count) open, \(liveAPI.handledCount) requests, \(liveAPI.rejectedCount) rejected")
        lines.append("Focus: \(focus.session.isActive ? focus.session.phase.title : "off"), Morph Focus \(focus.isMorphFocusOn)")
        lines.append("Peripherals: \(deviceBattery.peripherals.count) with a known battery")
        lines.append("Cinema: \(island.cinema), evidence \(cinema.evidence)")
        lines.append("Launch at login: \(launchAtLogin.status.rawValue)")
        return lines.joined(separator: "\n")
    }
}
