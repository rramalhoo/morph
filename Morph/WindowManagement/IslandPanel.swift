import AppKit

/// Borderless, non-activating overlay. It takes clicks without pulling focus from the active app,
/// and only becomes key when the island was opened for keyboard use.
final class IslandPanel: NSPanel {
    var allowsKey = false
    var onEscape: (() -> Void)?
    var onResignKey: (() -> Void)?
    var onKeyCommand: ((IslandKeyCommand) -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // One level above the menu bar, so the island can grow across it.
        level = .statusBar
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    // The default implementation pushes windows below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func keyDown(with event: NSEvent) {
        if let command = IslandKeyCommand(keyCode: event.keyCode) {
            onKeyCommand?(command)
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}
