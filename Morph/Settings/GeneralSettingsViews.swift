import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    @Environment(MorphPreferences.self) private var preferences
    @Environment(LaunchAtLoginService.self) private var launchAtLogin

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section {
                Toggle("Enable Morph", isOn: $preferences.isEnabled)
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled || launchAtLogin.requiresApproval },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                if launchAtLogin.requiresApproval {
                    LabeledContent("Waiting for approval in Login Items") {
                        Button("Open System Settings", action: launchAtLogin.openSystemSettings)
                    }
                }
                if let error = launchAtLogin.lastError {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            }
            Section {
                Toggle("Show menu bar icon", isOn: $preferences.showMenuBarIcon)
                Toggle("Show Dock icon", isOn: $preferences.showDockIcon)
            } footer: {
                Text("With the menu bar icon hidden, right-click the island or open Morph again from Applications to reach these settings.")
            }
        }
    }
}

struct AppearanceSettingsView: View {
    @Environment(MorphPreferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section("Island") {
                Picker("Island size", selection: $preferences.islandSize) {
                    ForEach(IslandSizePreference.allCases) { Text($0.title).tag($0) }
                }
                Picker("Accent color", selection: $preferences.accent) {
                    ForEach(AccentPreference.allCases) { accent in
                        Text(accent.title).tag(accent)
                    }
                }
            }
            Section("Motion") {
                Picker("Animation intensity", selection: $preferences.animationIntensity) {
                    ForEach(AnimationIntensity.allCases) { Text($0.title).tag($0) }
                }
                Picker("Reduce motion", selection: $preferences.reducedMotion) {
                    ForEach(ReducedMotionPreference.allCases) { Text($0.title).tag($0) }
                }
                Picker("Activity display duration", selection: $preferences.activityDuration) {
                    ForEach(ActivityDurationPreference.allCases) { Text($0.title).tag($0) }
                }
            }
        }
    }
}

struct BehaviorSettingsView: View {
    @Environment(MorphPreferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section("Interaction") {
                Toggle("Expand on hover", isOn: $preferences.hoverExpansion)
                Toggle("Open panel on click", isOn: $preferences.clickToExpand)
                LabeledContent("Dismissal delay") {
                    HStack {
                        Slider(value: $preferences.dismissalDelay, in: MorphPreferences.dismissalDelayRange, step: 0.05)
                            .frame(width: 180)
                        Text(preferences.dismissalDelay, format: .number.precision(.fractionLength(2)))
                            .monospacedDigit()
                        Text("s")
                    }
                }
            }
            Section {
                Toggle("Horizontal swipes change tracks", isOn: $preferences.horizontalSwipes)
                Toggle("Vertical swipes change volume", isOn: $preferences.verticalSwipes)
                LabeledContent("Gesture sensitivity") {
                    Slider(value: $preferences.gestureSensitivity, in: MorphPreferences.sensitivityRange, step: 0.1)
                        .frame(width: 180)
                }
            } header: {
                Text("Gestures")
            } footer: {
                Text("Two fingers on the trackpad, or the wheel on a mouse, while the pointer is over the island. Swipe left for the next track, right for the previous one.")
            }
        }
    }
}

struct ModulesSettingsView: View {
    @Environment(MorphPreferences.self) private var preferences
    @Environment(MediaController.self) private var media
    @Environment(BatteryService.self) private var battery

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section("Music") {
                Toggle("Music", isOn: $preferences.musicEnabled)
                Picker("Player", selection: $preferences.mediaSource) {
                    ForEach(MediaSourcePreference.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!preferences.musicEnabled)
                ForEach(MediaProviderKind.allCases) { kind in
                    LabeledContent(kind.displayName) {
                        playerStatus(kind)
                    }
                }
            }
            Section("Battery") {
                Toggle("Battery", isOn: $preferences.batteryEnabled)
                if battery.snapshot == nil {
                    Text("No internal battery detected.").foregroundStyle(.secondary)
                }
                Stepper("Low battery alert at \(preferences.lowBatteryThreshold)%",
                        value: $preferences.lowBatteryThreshold, in: 10...50, step: 5)
                    .disabled(!preferences.batteryEnabled)
            }
            Section("Timer") {
                Toggle("Timer and stopwatch", isOn: $preferences.timerEnabled)
                Toggle("Also send a notification when a timer ends", isOn: $preferences.timerNotifications)
                    .disabled(!preferences.timerEnabled)
            }
            Section("File Shelf") {
                Toggle("File shelf", isOn: $preferences.shelfEnabled)
            }
            Section("Activities") {
                Toggle("Activities", isOn: $preferences.activitiesEnabled)
                Toggle("Show timers and music beside the notch", isOn: $preferences.liveActivitiesEnabled)
            }
            QuickActionsSection()
        }
    }

    @ViewBuilder
    private func playerStatus(_ kind: MediaProviderKind) -> some View {
        switch media.availability[kind] {
        case .needsAuthorization:
            Button("Allow Access") { media.authorize(kind) }
        case .denied:
            Button("Open Privacy Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
            }
        case let state?:
            Text(state.summary).foregroundStyle(.secondary)
        case nil:
            Text(preferences.musicEnabled ? "Checking" : "Off").foregroundStyle(.secondary)
        }
    }
}
