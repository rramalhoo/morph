import AppKit
import SwiftUI

struct MusicSettingsView: View {
    @Environment(MorphPreferences.self) private var preferences
    @Environment(WaveformService.self) private var waveform

    private var statusText: String {
        switch waveform.status {
        case .off: "Starts when music plays"
        case .connecting: "Connecting"
        case .live: "Following the music"
        case .noSignal: "No audio received. Check the permission below."
        case .unavailable: "Couldn't reach the player's audio"
        }
    }

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section {
                Toggle("Real-time audio visualization", isOn: $preferences.audioVisualization)
                LabeledContent("Status", value: preferences.audioVisualization ? statusText : "Off")
                LabeledContent("Visualization sensitivity") {
                    Slider(value: $preferences.visualizationSensitivity, in: MorphPreferences.sensitivityRange, step: 0.1)
                        .frame(width: 180)
                }
                .disabled(!preferences.audioVisualization)
                Picker("When no audio can be analyzed", selection: $preferences.waveformFallback) {
                    ForEach(WaveformFallback.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Audio Visualization")
            } footer: {
                Text("Morph measures only your music player's sound, live and in memory. Audio is never recorded, saved or sent anywhere, and the microphone isn't used.")
            }
            Section {
                Button("Open Audio Capture Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                }
            } footer: {
                Text("macOS asks the first time music plays. It doesn't tell apps the answer, so a denied permission shows up here as no audio received.")
            }
            Section {
                Toggle("Album artwork ambient colors", isOn: $preferences.ambientColors)
            } footer: {
                Text("A soft light from the cover's main color, behind the player. The island stays black.")
            }
        }
    }
}

struct DevicesSettingsView: View {
    @Environment(MorphPreferences.self) private var preferences
    @Environment(VolumeService.self) private var volume

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section {
                Toggle("AirPods connection activities", isOn: $preferences.deviceActivities)
                Toggle("Peripheral battery status when available", isOn: $preferences.peripheralBattery)
            } footer: {
                Text("Shows a battery level only if macOS provides one through a public API. AirPods usually don't expose it, and then only the connection appears.")
            }
            Section("Connected") {
                if let output = volume.output {
                    LabeledContent("Audio output", value: output.device.name)
                    LabeledContent("Volume", value: output.percentage.map { "\($0)%" } ?? "Controlled by the device")
                }
                ForEach(volume.connectedBluetooth) { device in
                    Label(device.name, systemImage: device.symbol)
                }
            }
        }
    }
}

/// The same controls for volume and brightness.
private struct LevelHUDSection: View {
    let title: String
    @Binding var show: Bool
    @Binding var replace: Bool
    @Binding var showPercentage: Bool
    @Binding var duration: Double
    let isSupported: Bool
    let unsupportedReason: String
    let handedBack: Bool
    let handedBackReason: String
    let footer: String

    @Environment(LevelKeyService.self) private var levelKeys

    private var status: String? {
        guard show, replace, isSupported else { return nil }
        if handedBack { return handedBackReason }
        return switch levelKeys.status {
        case .off: "Inactive for now. macOS handles the keys while Morph is paused, in full screen or locked."
        case .needsPermission: "Waiting for Accessibility permission. macOS handles the keys until then."
        case .active: "Morph handles the keys"
        case .unavailable: "macOS refused the key tap, so it keeps handling the keys"
        }
    }

    var body: some View {
        Section {
            Toggle("Show \(title) HUD", isOn: $show)
            Toggle("Replace macOS \(title) HUD", isOn: $replace)
                .disabled(!show || !isSupported)
                .onChange(of: replace) { _, enabled in
                    if enabled { levelKeys.requestPermission() }
                }
            if !isSupported {
                LabeledContent("Status", value: unsupportedReason)
            } else if let status {
                LabeledContent("Status", value: status)
            }
            if replace, isSupported, levelKeys.status == .needsPermission {
                Button("Open Accessibility Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
            Toggle("Show Percentage", isOn: $showPercentage)
                .disabled(!show)
            LabeledContent("HUD Duration") {
                HStack {
                    Slider(value: $duration, in: MorphPreferences.hudDurationRange, step: 0.1)
                        .frame(width: 150)
                    Text(duration, format: .number.precision(.fractionLength(1)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    + Text(" s").foregroundStyle(.secondary)
                }
            }
            .disabled(!show)
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }
}

struct SystemSettingsView: View {
    @Environment(MorphPreferences.self) private var preferences
    @Environment(VolumeService.self) private var volume
    @Environment(LevelKeyService.self) private var levelKeys

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            LevelHUDSection(title: "Volume", show: $preferences.volumeIndicator, replace: $preferences.replaceVolumeHUD,
                            showPercentage: $preferences.volumeShowsPercentage, duration: $preferences.volumeHUDDuration,
                            isSupported: volume.isControllable,
                            unsupportedReason: "This output has no software volume. macOS handles its keys.",
                            handedBack: levelKeys.volumeHandedBack,
                            handedBackReason: "This output refused a change, so macOS handles its keys",
                            footer: "Replacing needs Accessibility permission. Morph sees only the volume and brightness keys, never typing. If you still see the macOS indicator, that key is reaching macOS: turn this off and on again. Option with a volume key stays with macOS.")
            LevelHUDSection(title: "Brightness", show: $preferences.brightnessIndicator, replace: $preferences.replaceBrightnessHUD,
                            showPercentage: $preferences.brightnessShowsPercentage, duration: $preferences.brightnessHUDDuration,
                            isSupported: levelKeys.brightnessSupported,
                            unsupportedReason: "No built-in display that Morph can control. macOS handles the keys.",
                            handedBack: levelKeys.brightnessHandedBack,
                            handedBackReason: "The display refused a change, so macOS handles the keys",
                            footer: "Replacing also gives the HUD a real level. It uses a private macOS interface, for the built-in display only, because no public one exists; it could stop working after a macOS update, and the keys then return to macOS. Without it, Morph shows only the direction. Control Center's slider and automatic brightness show no HUD.")
            Section {
                Picker("In full screen apps", selection: $preferences.cinemaMode) {
                    ForEach(CinemaMode.allCases) { Text($0.title).tag($0) }
                }
                if preferences.cinemaMode == .automatic {
                    Picker("Automatic cinema mode", selection: $preferences.cinemaAction) {
                        ForEach(CinemaAction.allCases) { Text($0.title).tag($0) }
                    }
                }
                Picker("When full screen is unclear", selection: $preferences.cinemaUncertain) {
                    ForEach(CinemaUncertainBehavior.allCases) { Text($0.title).tag($0) }
                }
                .disabled(preferences.cinemaMode == .normal)
            } header: {
                Text("Cinema Mode")
            } footer: {
                Text("Morph steps back for full screen videos, presentations and games, then returns when you leave. It looks at window positions only, never at what's on screen.")
            }
        }
    }
}
