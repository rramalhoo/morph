import CoreGraphics

/// The screen values geometry depends on, separated from `NSScreen` so they can be tested.
struct ScreenMetrics: Equatable, Sendable {
    var frame: CGRect
    var visibleFrame: CGRect
    var safeAreaTop: CGFloat
    var auxiliaryTopLeft: CGRect?
    var auxiliaryTopRight: CGRect?
    var scale: CGFloat
}

/// Where the island lives, in global AppKit coordinates (origin bottom-left of the primary display).
struct NotchGeometry: Equatable, Sendable {
    static let virtualNotchWidth: CGFloat = 180
    static let fallbackMenuBarHeight: CGFloat = 24
    private static let minimumSize = CGSize(width: 80, height: 16)

    let screenFrame: CGRect
    let notchRect: CGRect
    let hasPhysicalNotch: Bool
    let scale: CGFloat

    var notchSize: CGSize { notchRect.size }

    /// Reads the camera housing from the gap between the auxiliary areas. Displays without a
    /// housing get a virtual notch of the same proportions, sitting in the menu bar.
    static func resolve(_ metrics: ScreenMetrics, calibration: NotchCalibration = .zero) -> NotchGeometry {
        var rect: CGRect
        let hasNotch: Bool

        if metrics.safeAreaTop > 0,
           let left = metrics.auxiliaryTopLeft, let right = metrics.auxiliaryTopRight,
           !left.isEmpty, !right.isEmpty, right.minX > left.maxX {
            hasNotch = true
            rect = CGRect(x: left.maxX, y: metrics.frame.maxY - metrics.safeAreaTop,
                          width: right.minX - left.maxX, height: metrics.safeAreaTop)
        } else {
            hasNotch = false
            let reported = metrics.frame.maxY - metrics.visibleFrame.maxY
            let height = reported > 0 ? reported : fallbackMenuBarHeight
            rect = CGRect(x: metrics.frame.midX - virtualNotchWidth / 2, y: metrics.frame.maxY - height,
                          width: virtualNotchWidth, height: height)
        }

        let width = max(minimumSize.width, rect.width + calibration.widthDelta)
        let height = max(minimumSize.height, rect.height + calibration.heightDelta)
        rect = CGRect(x: rect.midX - width / 2 + calibration.offsetX, y: metrics.frame.maxY - height,
                      width: width, height: height)

        return NotchGeometry(screenFrame: metrics.frame, notchRect: snapped(rect, scale: metrics.scale),
                             hasPhysicalNotch: hasNotch, scale: metrics.scale)
    }

    /// The window frame for an island of `size`: hanging from the top edge, centered on the
    /// notch, and kept on screen.
    ///
    /// AppKit rounds window origins to whole points, so a 179pt island over a notch at 645.5 would
    /// land half a point off. Instead the width is padded to the parity that puts a whole-point
    /// origin exactly on the notch's center. The island itself is centered inside by the canvas.
    func panelFrame(for size: CGSize) -> CGRect {
        let doubledCenter = (notchRect.midX * 2).rounded()
        var width = size.width.rounded(.up)
        if (width + doubledCenter).truncatingRemainder(dividingBy: 2) != 0 { width += 1 }
        let height = size.height.rounded(.up)
        let x = max(screenFrame.minX, min((doubledCenter - width) / 2, screenFrame.maxX - width))
        return CGRect(x: x, y: screenFrame.maxY - height, width: width, height: height)
    }

    private static func snapped(_ rect: CGRect, scale: CGFloat) -> CGRect {
        guard scale > 0 else { return rect }
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        return CGRect(x: snap(rect.minX), y: snap(rect.minY), width: snap(rect.width), height: snap(rect.height))
    }
}

struct DisplayCandidate: Equatable, Sendable {
    var identifier: String
    var name: String
    var hasNotch: Bool
    var isBuiltIn: Bool
    var isMain: Bool
}

enum DisplaySelector {
    /// An explicit choice wins while connected; otherwise notched, built-in, main, first.
    static func select(_ candidates: [DisplayCandidate], preference: String) -> DisplayCandidate? {
        candidates.first { $0.identifier == preference }
            ?? candidates.first(where: \.hasNotch)
            ?? candidates.first(where: \.isBuiltIn)
            ?? candidates.first(where: \.isMain)
            ?? candidates.first
    }
}
