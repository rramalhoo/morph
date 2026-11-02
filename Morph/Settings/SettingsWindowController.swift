import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let content: () -> AnyView
    private var keepsDockIcon = false

    init(@ViewBuilder content: @escaping () -> some View) {
        self.content = { AnyView(content()) }
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        // An accessory app can't own a focused window, so it takes a regular presence while open.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func setDockIconVisible(_ visible: Bool) {
        keepsDockIcon = visible
        guard window?.isVisible != true else { return }
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
    }

    func windowWillClose(_ notification: Notification) {
        if !keepsDockIcon { NSApp.setActivationPolicy(.accessory) }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content()))
        window.title = "Morph Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(CGSize(width: 720, height: 520))
        window.contentMinSize = CGSize(width: 640, height: 440)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }
}
