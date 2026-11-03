import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        SingleInstance.takeOver()
        NSApp.mainMenu = MainMenuBuilder.make()
        let coordinator = AppCoordinator()
        self.coordinator = coordinator
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }

    /// With the menu bar icon hidden, opening the app again is the way back in, even when paused.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.resumeAndOpenSettings()
        return false
    }
}

/// Two copies draw two islands on top of each other and answer every key twice. LaunchServices only
/// prevents that for the same path, so a copy elsewhere, such as a fresh build, takes over from the
/// one already running. A notification works from inside the sandbox, where `terminate()` doesn't.
private enum SingleInstance {
    private static let name = Notification.Name("com.athene.morph.instance-started")
    private nonisolated(unsafe) static var token: (any NSObjectProtocol)?

    @MainActor
    static func takeOver() {
        let center = DistributedNotificationCenter.default()
        center.postNotificationName(name, object: "\(ProcessInfo.processInfo.processIdentifier)",
                                    userInfo: nil, deliverImmediately: true)
        let ownID = "\(ProcessInfo.processInfo.processIdentifier)"
        token = center.addObserver(forName: name, object: nil, queue: .main) { note in
            guard note.object as? String != ownID else { return }
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }
}

/// Accessory apps still need a main menu for Cmd-W, Cmd-Q and text editing in Settings.
private enum MainMenuBuilder {
    @MainActor
    static func make() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About Morph", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Morph", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: app, title: "Morph")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit, title: "Edit")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenu: window, title: "Window")

        return main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
