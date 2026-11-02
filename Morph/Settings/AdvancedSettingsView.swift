import AppKit
import SwiftUI

struct AdvancedSettingsView: View {
    let diagnostics: () -> String

    @Environment(MorphPreferences.self) private var preferences
    @Environment(IslandController.self) private var island
    @State private var isConfirmingReset = false
    @State private var report = ""

    var body: some View {
        @Bindable var preferences = preferences
        @Bindable var island = island

        Form {
            Section("Display") {
                Picker("Show island on", selection: $preferences.selectedDisplay) {
                    Text("Automatic").tag(MorphPreferences.automaticDisplay)
                    ForEach(NSScreen.screens.map(\.candidate), id: \.identifier) { display in
                        Text(display.name).tag(display.identifier)
                    }
                }
            }
            Section {
                Toggle("Show alignment guide", isOn: $island.showsCalibrationGuide)
                calibrationSlider("Horizontal offset", value: $preferences.calibration.offsetX, range: -20...20)
                calibrationSlider("Width", value: $preferences.calibration.widthDelta, range: -40...40)
                calibrationSlider("Height", value: $preferences.calibration.heightDelta, range: -12...12)
                Button("Reset Calibration") { preferences.calibration = .zero }
                    .disabled(preferences.calibration == .zero)
            } header: {
                Text("Notch Calibration")
            } footer: {
                Text("The guide draws a red outline just outside the island. Adjust until it follows the edge of the camera housing evenly.")
            }
            Section("Diagnostics") {
                Text(report)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button("Refresh") { report = diagnostics() }
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType: .string)
                    }
                }
            }
            Section {
                Button("Reset All Preferences…", role: .destructive) { isConfirmingReset = true }
            }
        }
        .onAppear { report = diagnostics() }
        .onDisappear { island.showsCalibrationGuide = false }
        .confirmationDialog("Reset all Morph preferences?", isPresented: $isConfirmingReset) {
            Button("Reset", role: .destructive) { preferences.reset() }
        } message: {
            Text("Settings return to their defaults. Your file shelf is kept.")
        }
    }

    private func calibrationSlider(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: 0.5).frame(width: 200)
                Text(value.wrappedValue, format: .number.precision(.fractionLength(1)))
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}
