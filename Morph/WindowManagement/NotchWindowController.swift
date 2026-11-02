import AppKit
import SwiftUI

/// Owns the overlay panel: its placement, its lifecycle, and how its frame follows the island.
///
/// The panel is only ever as large as the island, or briefly larger while a contraction finishes.
/// That is what keeps idle cost at zero: no global pointer tracking and no invisible window over
/// the desktop. The tracking area on the panel itself is enough to notice the pointer arriving.
@MainActor
final class NotchWindowController {
    private let island: IslandController
    private let preferences: MorphPreferences
    private let shelf: FileShelfStore
    private let content: () -> AnyView

    private var panel: IslandPanel?
    private var container: IslandContainerView?
    private var loops: [ObservationLoop] = []
    private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    private var dragMonitor: Any?
    private var lastDragChangeCount = NSPasteboard(name: .drag).changeCount
    private var shrinkTask: Task<Void, Never>?
    private(set) var currentMetrics: ScreenMetrics?
    private(set) var currentDisplay: DisplayCandidate?
    private var currentDisplayIdentifier: String?

    /// Where the island lives, in the coordinates window listings use (origin at the top-left).
    var currentDisplayArea: DisplayArea? {
        guard let primary = NSScreen.screens.first?.frame,
              let screen = NSScreen.screens.first(where: { $0.stableIdentifier == currentDisplayIdentifier }),
              let id = screen.displayID else { return nil }
        let visible = screen.visibleFrame
        return DisplayArea(bounds: CGDisplayBounds(id),
                           usable: CGRect(x: visible.minX, y: primary.maxY - visible.maxY, width: visible.width, height: visible.height))
    }

    init(island: IslandController, preferences: MorphPreferences, shelf: FileShelfStore,
         @ViewBuilder content: @escaping () -> some View) {
        self.island = island
        self.preferences = preferences
        self.shelf = shelf
        self.content = { AnyView(content()) }
    }

    var isVisible: Bool { panel?.isVisible == true }

    func show() {
        guard panel == nil else { return }
        let panel = makePanel()
        self.panel = panel
        observeSystem()
        updateDisplay()
        panel.orderFrontRegardless()

        loops = [
            ObservationLoop { [weak self] in self?.followIsland() },
            ObservationLoop { [weak self] in self?.followKeyboardMode() },
            ObservationLoop { [weak self] in self?.followPreferences() },
            ObservationLoop { [weak self] in self?.followCinema() },
        ]
        setDragMonitor(enabled: preferences.shelfEnabled)
    }

    func hide() {
        loops.forEach { $0.invalidate() }
        loops = []
        shrinkTask?.cancel()
        shrinkTask = nil
        observers.forEach { $0.center.removeObserver($0.token) }
        observers = []
        setDragMonitor(enabled: false)
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        container = nil
        island.send(.reset)
    }

    // MARK: - Construction

    private func makePanel() -> IslandPanel {
        let panel = IslandPanel()
        let container = IslandContainerView(frame: CGRect(origin: .zero, size: IslandLayout.canvas))
        let hosting = IslandHostingView(rootView: content())
        hosting.sizingOptions = []
        container.install(hostingView: hosting, canvas: IslandLayout.canvas)
        panel.contentView = container
        self.container = container

        container.onPointerEntered = { [weak island] in island?.send(.pointerEntered) }
        container.onPointerExited = { [weak island] in island?.send(.pointerExited) }
        container.onDragEntered = { [weak island] in
            island?.showTab(.shelf)
            island?.send(.fileDragEntered)
        }
        container.onDragExited = { [weak island] in island?.send(.fileDragExited) }
        container.onDrop = { [weak self] urls in
            self?.shelf.add(urls)
            self?.island.isFileDragActive = false
            self?.island.send(.fileDragExited)
            return true
        }
        container.onScroll = { [weak island] in island?.handleScroll($0) }
        panel.onEscape = { [weak island] in island?.send(.escapePressed) }
        panel.onKeyCommand = { [weak island] in island?.handle($0) }
        panel.onResignKey = { [weak island] in island?.send(.focusLost) }
        return panel
    }

    private func observeSystem() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        observe(center, NSApplication.didChangeScreenParametersNotification) { $0.updateDisplay() }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { $0.followCinema() }
        observe(workspace, NSWorkspace.didWakeNotification) {
            $0.updateDisplay()
            $0.followCinema()
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping @MainActor (NotchWindowController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { handler(self) }
            }
        }
        observers.append((center, token))
    }

    // MARK: - Placement

    /// Display list or scaling changed, or the preferred display did.
    private func updateDisplay() {
        guard let panel else { return }
        let screens = NSScreen.screens
        let candidates = screens.map(\.candidate)
        guard let chosen = DisplaySelector.select(candidates, preference: preferences.selectedDisplay),
              let screen = screens.first(where: { $0.stableIdentifier == chosen.identifier }) else {
            panel.orderOut(nil)
            island.update(geometry: nil)
            return
        }

        let metrics = screen.metrics
        let geometry = NotchGeometry.resolve(metrics, calibration: preferences.calibration)
        let displayMoved = currentDisplay?.identifier != chosen.identifier || currentMetrics?.frame != metrics.frame
        currentDisplay = chosen
        currentMetrics = metrics
        currentDisplayIdentifier = chosen.identifier
        if displayMoved { island.send(.reset) }
        island.update(geometry: geometry)
        setFrame(for: island.presentation, geometry: geometry)
        followCinema()
    }

    private func followCinema() {
        guard let panel else { return }
        if island.shouldShowPanel {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private func setFrame(for presentation: IslandPresentation, geometry: NotchGeometry) {
        guard let panel else { return }
        apply(frame: geometry.panelFrame(for: island.layout.panelSize(for: presentation)), to: panel, geometry: geometry)
    }

    private func apply(frame: CGRect, to panel: IslandPanel, geometry: NotchGeometry) {
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        container?.positionCanvas(centerX: geometry.notchRect.midX - panel.frame.minX)
    }

    // MARK: - Following model state

    /// Growing happens now, ahead of the spring. Shrinking waits for it to land, so the contraction
    /// is never clipped by its own window.
    private func followIsland() {
        let presentation = island.presentation
        guard let panel, let geometry = island.geometry else { return }
        let target = geometry.panelFrame(for: island.layout.panelSize(for: presentation))

        shrinkTask?.cancel()
        shrinkTask = nil

        if target.width >= panel.frame.width, target.height >= panel.frame.height {
            setFrame(for: presentation, geometry: geometry)
            return
        }

        // Morphing between two shapes: hold the union until the spring has settled.
        let union = geometry.panelFrame(for: CGSize(width: max(target.width, panel.frame.width),
                                                    height: max(target.height, panel.frame.height)))
        apply(frame: union, to: panel, geometry: geometry)

        let settle = MorphMotion.settleDuration(preferences: preferences)
        shrinkTask = Task { [weak self] in
            try? await Task.sleep(for: settle)
            guard !Task.isCancelled, let self else { return }
            self.setFrame(for: self.island.presentation, geometry: geometry)
            self.reconcilePointer()
        }
    }

    /// A shrinking window can leave the pointer outside without delivering `mouseExited`.
    private func reconcilePointer() {
        guard let panel else { return }
        if !panel.frame.contains(NSEvent.mouseLocation), island.mode != .idle {
            island.send(.pointerExited)
        }
    }

    private func followKeyboardMode() {
        guard let panel else { return }
        let wantsKey = island.mode == .expanded(.keyboard)
        panel.allowsKey = wantsKey
        if wantsKey {
            panel.makeKey()
        } else if panel.isKeyWindow {
            panel.resignKey()
        }
    }

    private func followPreferences() {
        guard let panel else { return }
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        // A non-activating panel can still appear in full screen without this, so actually getting
        // out of the way is the cinema detector's job. This only keeps the window server in line.
        let staysInFullScreen = switch preferences.cinemaMode {
        case .normal, .compact: true
        case .hidden: false
        case .automatic: preferences.cinemaAction == .compact
        }
        if staysInFullScreen { behavior.insert(.fullScreenAuxiliary) }
        panel.collectionBehavior = behavior

        container?.acceptsDrops = preferences.shelfEnabled
        setDragMonitor(enabled: preferences.shelfEnabled)

        // Read so this loop re-runs when they change.
        _ = preferences.calibration
        _ = preferences.selectedDisplay
        Task { @MainActor [weak self] in self?.updateDisplay() }
    }

    // MARK: - File drags

    /// Mouse-drag monitors need no permission and only fire while a button is held, so this costs
    /// nothing at rest. It lets the island grow toward an incoming file rather than asking the
    /// user to hit the notch exactly.
    private func setDragMonitor(enabled: Bool) {
        if enabled, dragMonitor == nil {
            dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
                let isDragging = event.type == .leftMouseDragged
                MainActor.assumeIsolated { self?.handleGlobalMouse(isDragging: isDragging) }
            }
        } else if !enabled, let monitor = dragMonitor {
            NSEvent.removeMonitor(monitor)
            dragMonitor = nil
        }
    }

    private func handleGlobalMouse(isDragging: Bool) {
        guard isDragging else {
            if island.isFileDragActive { island.isFileDragActive = false }
            return
        }
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != lastDragChangeCount else { return }
        lastDragChangeCount = pasteboard.changeCount
        if pasteboard.types?.contains(.fileURL) == true {
            island.isFileDragActive = true
        }
    }
}
