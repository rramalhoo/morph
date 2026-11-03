import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, behavior, music, devices, system, screenshots, focus, activities, modules, advanced

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .behavior: "cursorarrow.motionlines"
        case .music: "waveform"
        case .devices: "airpodspro"
        case .system: "macbook"
        case .screenshots: "camera.viewfinder"
        case .focus: "brain.head.profile"
        case .activities: "dot.radiowaves.left.and.right"
        case .modules: "square.grid.2x2"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}

struct SettingsRootView: View {
    let diagnostics: () -> String

    @State private var selection: SettingsSection? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            Group {
                switch selection ?? .general {
                case .general: GeneralSettingsView()
                case .appearance: AppearanceSettingsView()
                case .behavior: BehaviorSettingsView()
                case .music: MusicSettingsView()
                case .devices: DevicesSettingsView()
                case .system: SystemSettingsView()
                case .screenshots: ScreenshotSettingsView()
                case .focus: FocusSettingsView()
                case .activities: LiveActivitySettingsView()
                case .modules: ModulesSettingsView()
                case .advanced: AdvancedSettingsView(diagnostics: diagnostics)
                }
            }
            .formStyle(.grouped)
            .navigationTitle((selection ?? .general).title)
        }
    }
}
