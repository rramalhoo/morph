import AppKit
import SwiftUI

struct LockScreenSettingsView: View {
    @Environment(MorphPreferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section {
                Toggle("Enable Lock Screen Integration", isOn: $preferences.lockScreenEnabled)
                Toggle("Animate When Locking", isOn: $preferences.lockAnimation)
                    .disabled(!preferences.lockScreenEnabled)
            } footer: {
                Text("Morph reacts to your Mac locking and unlocking. It never draws on the lock screen: macOS covers every app while locked, and Morph doesn't try to get around that. Whatever this is set to, private content leaves the island the moment the Mac locks.")
            }
            Section {
                Toggle("Welcome Animation After Unlock", isOn: $preferences.welcomeEnabled)
                Toggle("Show Music After Unlock", isOn: $preferences.welcomeShowsMusic)
                Toggle("Show Battery After Unlock", isOn: $preferences.welcomeShowsBattery)
                LabeledContent("Welcome Duration") {
                    HStack {
                        Slider(value: $preferences.welcomeDuration, in: MorphPreferences.welcomeDurationRange, step: 0.5)
                            .frame(width: 150)
                        Text(String(format: "%.1f s", preferences.welcomeDuration)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Toggle("Reduce Welcome Animations", isOn: $preferences.welcomeReducedMotion)
            } header: {
                Text("After Unlock")
            } footer: {
                Text("Shown once per unlock, not after waking without a password, and not while you're using the island or something urgent is showing. Music keeps playing in its own app while the Mac is locked; macOS shows its own controls on the lock screen.")
            }
            .disabled(!preferences.lockScreenEnabled)
        }
    }
}

struct NotificationSettingsView: View {
    @Environment(MorphPreferences.self) private var preferences
    @Environment(NotificationService.self) private var notifications

    private var statusText: String {
        switch notifications.authorization {
        case .authorized: "Allowed"
        case .denied: "Off in System Settings"
        case .notDetermined: "Not asked yet"
        }
    }

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section {
                Toggle("Show Notifications", isOn: $preferences.notificationsEnabled)
                Toggle("Notify When Timer Ends", isOn: $preferences.timerNotifications)
                Toggle("Notify On Focus Session Completion", isOn: $preferences.focusNotifications)
                Toggle("Notify On Low Battery", isOn: $preferences.lowBatteryNotifications)
                Toggle("Allow Sensitive Previews", isOn: $preferences.notificationPreviews)
                LabeledContent("Permission") {
                    HStack {
                        Text(statusText).foregroundStyle(.secondary)
                        if notifications.authorization == .denied {
                            Button("Open System Settings…") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                            }
                        }
                    }
                }
            } footer: {
                Text("Timer and focus notifications are scheduled ahead, so macOS delivers them on time even when the Mac is locked. Battery, device and activity notifications are sent only when the island can't show them. Without sensitive previews, notifications never name a file, device or activity. Whether they appear on the lock screen is decided by macOS and your settings in System Settings › Notifications, not by Morph.")
            }
        }
        .onChange(of: preferences.timerNotifications) { if $1 { notifications.requestAuthorization() } }
        .onChange(of: preferences.focusNotifications) { if $1 { notifications.requestAuthorization() } }
        .onChange(of: preferences.lowBatteryNotifications) { if $1 { notifications.requestAuthorization() } }
        .onAppear { notifications.refreshAuthorization() }
    }
}
