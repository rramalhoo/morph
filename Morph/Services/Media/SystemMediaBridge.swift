import AppKit
import CoreServices

struct WorkspaceApplicationProbe: ApplicationProbing {
    func isInstalled(_ bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    func isRunning(_ bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    func automationAccess(to bundleIdentifier: String, ask: Bool) -> MediaAvailability {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        guard let address = target.aeDesc else { return .denied }
        let status = AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, ask)
        switch status {
        case noErr: return .available
        case OSStatus(errAEEventWouldRequireUserConsent): return .needsAuthorization
        case OSStatus(procNotFound): return .notRunning
        default: return .denied
        }
    }
}

/// Event-driven player updates: the distributed notifications each player posts on a playback
/// change, plus workspace launch and quit. Nothing here runs while the player is quiet.
@MainActor
final class SystemMediaEvents: NSObject, MediaEventSource {
    private var onChange: (@MainActor () -> Void)?
    private var workspaceTokens: [any NSObjectProtocol] = []

    func start(onChange: @escaping @MainActor () -> Void) {
        guard self.onChange == nil else { return }
        self.onChange = onChange

        let distributed = DistributedNotificationCenter.default()
        for kind in MediaProviderKind.allCases {
            distributed.addObserver(self, selector: #selector(playerChanged),
                                    name: Notification.Name(kind.changeNotification), object: nil,
                                    suspensionBehavior: .deliverImmediately)
        }

        let bundleIDs = Set(MediaProviderKind.allCases.map(\.bundleIdentifier))
        let names = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification]
        workspaceTokens = names.map { name in
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let id = app?.bundleIdentifier, bundleIDs.contains(id) else { return }
                MainActor.assumeIsolated { self?.onChange?() }
            }
        }
    }

    func stop() {
        DistributedNotificationCenter.default().removeObserver(self)
        workspaceTokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceTokens = []
        onChange = nil
    }

    @objc private func playerChanged() {
        onChange?()
    }
}
