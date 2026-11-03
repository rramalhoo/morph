import AppKit
import SwiftUI

struct ScreenshotSettingsView: View {
    @Environment(MorphPreferences.self) private var preferences
    @Environment(ScreenshotService.self) private var screenshots

    private var statusText: String {
        switch screenshots.status {
        case .off: "Off"
        case .needsFolder: "Choose the folder your screenshots are saved to"
        case .watching(let name): "Watching \(name)"
        case .folderUnavailable: "Can't read that folder. Choose it again."
        }
    }

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section {
                Toggle("Show screenshot previews", isOn: $preferences.screenshotPreviews)
                LabeledContent("Status", value: statusText)
                LabeledContent("Watched folder") {
                    Button("Choose Folder…", action: chooseFolder)
                }
                LabeledContent("Preview duration") {
                    HStack {
                        Slider(value: $preferences.screenshotDuration, in: MorphPreferences.screenshotDurationRange, step: 1)
                            .frame(width: 150)
                        Text("\(Int(preferences.screenshotDuration)) s").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .disabled(!preferences.screenshotPreviews)
            } footer: {
                Text("macOS doesn't tell apps where it saves screenshots. Press Command-Shift-5 and look under Options to see the folder, then choose the same one here. Morph watches only that folder, and only for files macOS marks as screenshots. Previews stay in memory, are never saved or sent, and end when the screen locks. With the floating thumbnail on, macOS saves the file a few seconds after the capture, and captures sent to the clipboard create no file for Morph to see.")
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch Folder"
        // The sandbox's own home isn't what the user knows as Desktop.
        if let home = getpwuid(getuid())?.pointee.pw_dir {
            panel.directoryURL = URL(fileURLWithPath: String(cString: home)).appendingPathComponent("Desktop")
        }
        guard panel.runModal() == .OK, let url = panel.url,
              let bookmark = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                   includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        preferences.screenshotFolder = bookmark
    }
}

struct FocusSettingsView: View {
    @Environment(MorphPreferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section {
                Toggle("Focus sessions", isOn: $preferences.focusEnabled)
                Stepper("Focus: \(preferences.focusMinutes) min", value: $preferences.focusMinutes, in: 1...180)
                Stepper("Short break: \(preferences.shortBreakMinutes) min", value: $preferences.shortBreakMinutes, in: 1...180)
                Stepper("Long break: \(preferences.longBreakMinutes) min", value: $preferences.longBreakMinutes, in: 1...180)
                Stepper("Long break after \(preferences.focusCycles) sessions", value: $preferences.focusCycles, in: 2...8)
            } header: {
                Text("Pomodoro")
            } footer: {
                Text("New durations apply from the next session.")
            }
            Section {
                Toggle("Start the break automatically", isOn: $preferences.focusAutoBreak)
                Toggle("Send a notification when a session ends", isOn: $preferences.focusNotifications)
            } footer: {
                Text("macOS asks for notification permission the first time this is used.")
            }
            Section {
                Text("Morph Focus quiets the island during focus sessions, or whenever you turn it on in the Focus tab. Battery, music and device activities stay out of the way, while alerts, timers and the things you do yourself still appear. It's separate from macOS Focus: Morph doesn't read or change that, and macOS notifications aren't affected.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Morph Focus")
            }
        }
    }
}

struct LiveActivitySettingsView: View {
    @Environment(MorphPreferences.self) private var preferences
    @Environment(LiveAPIService.self) private var api
    @Environment(LiveActivityStore.self) private var store
    @State private var isTokenVisible = false

    private var statusText: String {
        switch api.status {
        case .off: "Off. No port is open."
        case .starting: "Starting"
        case .listening(let port): "Listening on 127.0.0.1:\(port)"
        case .failed(let reason): reason
        }
    }

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section {
                Toggle("Allow local apps to send activities", isOn: $preferences.liveAPIEnabled)
                LabeledContent("Status", value: statusText)
                LabeledContent("Port") {
                    TextField("Port", value: $preferences.liveAPIPort, format: .number.grouping(.never))
                        .labelsHidden()
                        .frame(width: 80)
                }
            } header: {
                Text("Local API")
            } footer: {
                Text("The server only exists while this is on, and it's reachable only from this Mac, never from the network.")
            }
            Section {
                if let token = api.token {
                    Text(isTokenVisible ? token : String(repeating: "•", count: 24))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    HStack {
                        Button(isTokenVisible ? "Hide" : "Show") { isTokenVisible.toggle() }
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(token, forType: .string)
                        }
                        Button("Regenerate", action: api.regenerateToken)
                    }
                } else {
                    Text("A token is created when the API is turned on.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Authorization")
            } footer: {
                Text("Apps send this token with every request. It's kept in your Keychain. Regenerating it disconnects every app using the old one.")
            }
            Section("Diagnostics") {
                LabeledContent("Open activities", value: "\(store.activities.count)")
                LabeledContent("Requests", value: "\(api.handledCount)")
                LabeledContent("Rejected", value: "\(api.rejectedCount)")
            }
        }
    }
}
