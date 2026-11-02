import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct QuickActionsSection: View {
    private static let timerMinutes = [1, 5, 10, 15, 25, 45]

    @Environment(MorphPreferences.self) private var preferences

    var body: some View {
        Section {
            ForEach(preferences.quickActions) { action in
                HStack {
                    Label(action.title, systemImage: action.symbol)
                    Spacer()
                    Button {
                        preferences.quickActions.removeAll { $0 == action }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(action.title)")
                }
            }
            Menu("Add Action") {
                Button("Open Application…", action: chooseApplication)
                Menu("Start Timer") {
                    ForEach(Self.timerMinutes, id: \.self) { minutes in
                        Button("\(minutes) min") { add(.startTimer(seconds: minutes * 60)) }
                    }
                }
                Button("Open Morph Settings") { add(.openSettings) }
                ForEach(TogglablePreference.allCases, id: \.self) { preference in
                    Button("Toggle \(preference.title)") { add(.togglePreference(preference)) }
                }
            }
            .disabled(preferences.quickActions.count >= QuickAction.limit)
        } header: {
            Text("Quick Actions")
        } footer: {
            Text("Up to \(QuickAction.limit) actions appear in the expanded island.")
        }
    }

    private func add(_ action: QuickAction) {
        guard !preferences.quickActions.contains(action), preferences.quickActions.count < QuickAction.limit else { return }
        preferences.quickActions.append(action)
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url),
              let identifier = bundle.bundleIdentifier else { return }
        add(.openApplication(bundleIdentifier: identifier, name: url.deletingPathExtension().lastPathComponent))
    }
}
