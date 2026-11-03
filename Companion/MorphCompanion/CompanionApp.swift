import AppIntents
import SwiftUI

@main
struct CompanionApp: App {
    @Environment(\.scenePhase) private var phase
    private let model = CompanionModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .onOpenURL { model.pair(with: $0) }
                .onChange(of: phase) { _, phase in model.setActive(phase == .active) }
                .preferredColorScheme(.dark)
        }
    }
}

struct ContentView: View {
    @Environment(CompanionModel.self) private var model
    @State private var pasted = ""
    @State private var service = ""
    @State private var title = ""
    @State private var subtitle = ""
    @State private var icon = "timer"
    @State private var minutes = 15
    @State private var sensitive = true

    private var statusText: String {
        switch model.status {
        case .notPaired: "Not paired"
        case .pairing: "Pairing…"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .waiting(let reason): reason
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Status", value: statusText)
                    if let mac = model.mac {
                        LabeledContent("Mac", value: mac.name)
                        Button("Disconnect This Mac", role: .destructive) { model.forget() }
                    }
                    if let error = model.lastError {
                        Text(error).foregroundStyle(.orange)
                    }
                } footer: {
                    Text("Sync runs while this app is open. iOS pauses it in the background, and the Mac marks activities as out of sync after two minutes.")
                }

                if model.mac == nil {
                    Section {
                        Text("On your Mac, open Morph Settings › Continuity › Pair iPhone, then scan the QR code with the Camera app.")
                        TextField("Or paste the pairing link", text: $pasted)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Pair") {
                            if let url = URL(string: pasted.trimmingCharacters(in: .whitespaces)) { model.pair(with: url) }
                        }
                        .disabled(pasted.isEmpty)
                    } header: {
                        Text("Pair with a Mac")
                    }
                }

                Section("Activities on the Mac") {
                    if model.activities.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    }
                    ForEach(model.activities, id: \.id) { activity in
                        HStack {
                            Image(systemName: ContinuityActivityPayload.icons[activity.icon] ?? "circle")
                            VStack(alignment: .leading) {
                                Text(activity.title)
                                Text(activity.service).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let endsAt = activity.endsAt, endsAt > .now {
                                Text(timerInterval: Date.now...endsAt, countsDown: true).monospacedDigit()
                            }
                        }
                        .swipeActions { Button("End", role: .destructive) { model.end(activity.id) } }
                    }
                }

                Section {
                    TextField("Service (e.g. Laundry)", text: $service)
                    TextField("Title", text: $title)
                    TextField("Subtitle (optional)", text: $subtitle)
                    Picker("Icon", selection: $icon) {
                        ForEach(ContinuityActivityPayload.icons.keys.sorted(), id: \.self) { name in
                            Label(name, systemImage: ContinuityActivityPayload.icons[name]!).tag(name)
                        }
                    }
                    Stepper("Countdown: \(minutes) min", value: $minutes, in: 0...240)
                    Toggle("Sensitive", isOn: $sensitive)
                    Button("Send to Mac", action: send)
                        .disabled(service.isEmpty || title.isEmpty || model.mac == nil)
                } header: {
                    Text("New Activity")
                } footer: {
                    Text("Morph can't read other apps' Live Activities. Activities here are ones you create, or that a Shortcut sends with “Send Activity to Mac”.")
                }
            }
            .navigationTitle("Morph")
        }
    }

    private func send() {
        let activity = ContinuityActivityPayload(
            id: "manual-\(UUID().uuidString.prefix(8))", service: service, title: title,
            subtitle: subtitle.isEmpty ? nil : subtitle, icon: icon,
            endsAt: minutes > 0 ? Date.now.addingTimeInterval(TimeInterval(minutes * 60)) : nil, sensitive: sensitive,
            lifetime: TimeInterval(max(minutes, 30) * 60))
        if model.upsert(activity) {
            title = ""
            subtitle = ""
        }
    }
}

/// The documented way for other apps and automations to feed Morph: the user builds the Shortcut,
/// so nothing arrives without their say-so.
struct SendActivityIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Activity to Mac"
    static let description = IntentDescription("Shows an activity in Morph on your paired Mac.")
    static let openAppWhenRun = true

    @Parameter(title: "Service") var service: String
    @Parameter(title: "Title") var title: String
    @Parameter(title: "Subtitle") var subtitle: String?
    @Parameter(title: "Minutes Remaining", default: 0) var minutes: Int

    @MainActor
    func perform() async throws -> some IntentResult {
        let activity = ContinuityActivityPayload(
            id: "shortcut-\(service.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(40))", service: service, title: title,
            subtitle: subtitle, icon: minutes > 0 ? "timer" : "activity",
            endsAt: minutes > 0 ? Date.now.addingTimeInterval(TimeInterval(minutes * 60)) : nil,
            lifetime: TimeInterval(max(minutes, 30) * 60))
        CompanionModel.shared.upsert(activity)
        return .result()
    }
}
