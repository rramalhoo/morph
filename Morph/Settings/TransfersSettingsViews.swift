import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct TransfersSettingsView: View {
    @Environment(MorphPreferences.self) private var preferences
    @Environment(DownloadFolderMonitor.self) private var downloads
    @Environment(LiveAPIService.self) private var liveAPI

    private var folderStatus: String {
        switch downloads.status {
        case .off: "Off"
        case .needsFolder: "Choose your downloads folder"
        case .watching(let name): "Watching \(name)"
        case .folderUnavailable: "Can't read that folder. Choose it again."
        }
    }

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section {
                Toggle("Enable Transfer Activities", isOn: $preferences.transfersEnabled)
                Toggle("Show Downloads", isOn: $preferences.showDownloads)
                Toggle("Show Uploads", isOn: $preferences.showUploads)
                Toggle("Show AirDrop Activities", isOn: $preferences.showAirDrop)
                Toggle("Transfer Completion Animation", isOn: $preferences.transferCompletionAnimation)
                Picker("Transfer History Duration", selection: $preferences.transferHistoryMinutes) {
                    Text("Don't keep").tag(0)
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("1 hour").tag(60)
                }
            } footer: {
                Text("History lives in memory only, is never saved, and is hidden while the Mac is locked.")
            }
            Section {
                Toggle("Monitor Downloads Folder", isOn: $preferences.monitorDownloads)
                LabeledContent("Status", value: folderStatus)
                LabeledContent("Folder") {
                    Button("Choose Folder…", action: chooseFolder)
                }
            } header: {
                Text("Downloads")
            } footer: {
                Text("Morph sees a download only through the folder you choose: a browser's partial file (.download, .crdownload, .part) while it's written, then the finished file. A percentage appears only when the size is known, which Safari records and other browsers usually don't. New files count as downloads only if macOS marked them as just downloaded, so files you copy or save there are ignored. Morph never reads browser history or data.")
            }
            .disabled(!preferences.transfersEnabled)
            Section {
                LabeledContent("Uploads and other downloads") {
                    Text(liveAPIEnabled ? "Accepted through the local API" : "Turn on the local API under Activities")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Scripts and Apps")
            } footer: {
                Text("Morph can't see other apps' network traffic, and doesn't try. Uploads appear when a script or app reports them to /v1/transfers on the local API; Morph shows them but can't cancel them. See docs/TRANSFERS_AND_CONTINUITY.md.")
            }
            Section {
                LabeledContent("Sending") { Text("Shelf › AirDrop button").foregroundStyle(.secondary) }
            } header: {
                Text("AirDrop")
            } footer: {
                Text("Sending uses macOS's own AirDrop picker and confirmation. macOS reports only that the share finished, not bytes or whether it was accepted. Received files are recognized in the watched folder by the marker macOS gives AirDropped files; there's no public way to see an AirDrop while it's arriving, or who sent it.")
            }
        }
    }

    private var liveAPIEnabled: Bool { preferences.liveAPIEnabled }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch Folder"
        if let home = getpwuid(getuid())?.pointee.pw_dir {
            panel.directoryURL = URL(fileURLWithPath: String(cString: home)).appendingPathComponent("Downloads")
        }
        guard panel.runModal() == .OK, let url = panel.url,
              let bookmark = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                   includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        preferences.downloadsFolder = bookmark
        preferences.monitorDownloads = true
    }
}

struct ContinuitySettingsView: View {
    @Environment(MorphPreferences.self) private var preferences
    @Environment(MorphContinuityManager.self) private var continuity
    @Environment(ContinuityListener.self) private var listener
    @Environment(LiveAPIService.self) private var liveAPI

    private var listenerStatus: String {
        switch listener.status {
        case .off: "Off"
        case .starting: "Starting…"
        case .advertising(let name): "Ready as “\(name)”"
        case .failed(let reason): "Unavailable: \(reason)"
        }
    }

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section {
                Toggle("Enable iPhone Sync", isOn: $preferences.continuityEnabled)
                Toggle("Show iPhone Activities", isOn: $preferences.showContinuityActivities)
                    .disabled(!preferences.continuityEnabled)
                Toggle("Hide Sensitive Information", isOn: $preferences.continuityHidesSensitive)
                    .disabled(!preferences.continuityEnabled)
            } footer: {
                Text("Apple offers no way for another app to read the Live Activities that macOS mirrors from your iPhone, so Morph can't show Uber, iFood or any other app's activities, and doesn't try. What it shows comes from Morph Companion on your iPhone: activities you create there, or ones apps send to it directly. With sensitive information hidden, the island names only the service.")
            }
            Section("Paired Devices") {
                if continuity.devices.isEmpty {
                    Text("No iPhone paired").foregroundStyle(.secondary)
                }
                ForEach(continuity.devices) { device in
                    LabeledContent {
                        HStack {
                            Text(continuity.connected.contains(device.id) ? "Connected" : "Not connected").foregroundStyle(.secondary)
                            Button("Disconnect Device", role: .destructive) { continuity.revoke(id: device.id) }
                        }
                    } label: {
                        Text(device.name)
                        Text("Paired \(device.pairedAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                PairingView(serviceName: listener.serviceName)
                    .disabled(!preferences.continuityEnabled || listener.status != .advertising(listener.serviceName))
            }
            Section("Connected Sources") {
                LabeledContent("Morph Companion") {
                    Text("\(continuity.connected.count) connected, \(continuity.activities.count) activities").foregroundStyle(.secondary)
                }
                LabeledContent("Local API (scripts, your own webhook relays)") {
                    Text(preferences.liveAPIEnabled ? "On" : "Off").foregroundStyle(.secondary)
                }
                LabeledContent("Third-party iPhone Live Activities") {
                    Text("Not available to apps").foregroundStyle(.secondary)
                }
            }
            Section("Connection Diagnostics") {
                LabeledContent("Listener", value: listenerStatus)
                LabeledContent("Refused messages", value: "\(continuity.refusedCount)")
                if let problem = continuity.lastProblem {
                    LabeledContent("Last problem", value: problem)
                }
            }
        }
    }
}

/// A one-time QR code. It holds a fresh secret that's never sent over the network, expires in
/// five minutes, and works once.
private struct PairingView: View {
    let serviceName: String

    @Environment(MorphContinuityManager.self) private var continuity

    var body: some View {
        if let invitation = continuity.invitation, invitation.expires > .now {
            VStack(alignment: .leading, spacing: 8) {
                if let image = Self.qrCode(invitation.url.absoluteString) {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 180, height: 180)
                }
                Text("Scan with Morph Companion on your iPhone. Expires \(invitation.expires.formatted(date: .omitted, time: .shortened)).")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Cancel Pairing") { continuity.cancelPairing() }
            }
        } else {
            Button("Pair iPhone…") {
                continuity.beginPairing(service: serviceName, macName: Host.current().localizedName ?? "Mac")
            }
        }
    }

    private static func qrCode(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
