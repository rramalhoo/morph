import AppKit
import SwiftUI

/// Hosts SwiftUI at a fixed canvas size. The first click on a control in the non-key panel must
/// reach it rather than only activating the window.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
}

/// The panel's content view: pointer tracking and file drops for the whole island.
///
/// The hosting view inside never resizes. Changing the panel frame only crops the canvas, so the
/// window can follow the island without any SwiftUI layout pass.
final class IslandContainerView: NSView {
    var onPointerEntered: (() -> Void)?
    var onPointerExited: (() -> Void)?
    var onDragEntered: (() -> Void)?
    var onDragExited: (() -> Void)?
    var onDrop: (([URL]) -> Bool)?
    var onScroll: ((ScrollInput) -> Void)?
    var acceptsDrops = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        registerForDraggedTypes([.fileURL])
        // Added once rather than in `updateTrackingAreas`, which AppKit doesn't reliably call for a
        // borderless panel resized with `display: false`. `.inVisibleRect` follows every resize.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func install(hostingView: NSView, canvas: CGSize) {
        hostingView.frame = CGRect(origin: .zero, size: canvas)
        hostingView.autoresizingMask = []
        addSubview(hostingView)
    }

    /// Pins the canvas to the top edge with its center at `centerX`, in this view's coordinates.
    func positionCanvas(centerX: CGFloat) {
        guard let canvas = subviews.first else { return }
        canvas.setFrameOrigin(CGPoint(x: centerX - canvas.frame.width / 2, y: bounds.height - canvas.frame.height))
    }

    override func mouseEntered(with event: NSEvent) { onPointerEntered?() }
    override func mouseExited(with event: NSEvent) { onPointerExited?() }

    /// Reaches here because SwiftUI passes on anything it doesn't scroll itself.
    override func scrollWheel(with event: NSEvent) {
        // Natural scrolling flips the deltas relative to the fingers, which gestures care about.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
        onScroll?(ScrollInput(deltaX: event.scrollingDeltaX * sign, deltaY: event.scrollingDeltaY * sign,
                              phase: Self.phase(of: event), isPrecise: event.hasPreciseScrollingDeltas,
                              time: event.timestamp))
    }

    private static func phase(of event: NSEvent) -> ScrollInput.Phase {
        if !event.momentumPhase.isEmpty { return .momentum }
        switch event.phase {
        case .began, .mayBegin: return .began
        case .changed, .stationary: return .changed
        case .ended, .cancelled: return .ended
        default: return .discrete
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrops, !fileURLs(from: sender).isEmpty else { return [] }
        onDragEntered?()
        return .link
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        acceptsDrops ? .link : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDragExited?()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onDrop?(fileURLs(from: sender)) ?? false
    }

    private func fileURLs(from info: any NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }
}
