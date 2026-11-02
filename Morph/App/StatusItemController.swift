import AppKit

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private let pauseItem = NSMenuItem(title: "Pause Morph", action: #selector(pauseChosen), keyEquivalent: "")

    private let onToggle: () -> Void
    private let onSettings: () -> Void
    private let onPause: () -> Void
    private let onAbout: () -> Void
    private let isPaused: () -> Bool

    init(onToggle: @escaping () -> Void, onSettings: @escaping () -> Void, onPause: @escaping () -> Void,
         onAbout: @escaping () -> Void, isPaused: @escaping () -> Bool) {
        self.onToggle = onToggle
        self.onSettings = onSettings
        self.onPause = onPause
        self.onAbout = onAbout
        self.isPaused = isPaused
        super.init()

        let open = NSMenuItem(title: "Open Morph", action: #selector(toggleChosen), keyEquivalent: "")
        let settings = NSMenuItem(title: "Settings…", action: #selector(settingsChosen), keyEquivalent: ",")
        let about = NSMenuItem(title: "About Morph", action: #selector(aboutChosen), keyEquivalent: "")
        let quit = NSMenuItem(title: "Quit Morph", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        [open, settings, pauseItem, about].forEach { $0.target = self }

        menu.addItem(open)
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(about)
        menu.addItem(quit)
        menu.delegate = self
    }

    func setVisible(_ visible: Bool) {
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Morph")
            item.button?.image?.isTemplate = true
            item.menu = menu
            statusItem = item
        } else if !visible, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    func refresh() {
        pauseItem.title = isPaused() ? "Resume Morph" : "Pause Morph"
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    @objc private func toggleChosen() { onToggle() }
    @objc private func settingsChosen() { onSettings() }
    @objc private func pauseChosen() { onPause() }
    @objc private func aboutChosen() { onAbout() }
}
