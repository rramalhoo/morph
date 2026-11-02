import CoreGraphics
import Testing
@testable import Morph

@Suite("Notch geometry")
struct GeometryTests {
    /// Values read from a 13" MacBook Air at its default scaled resolution.
    private let macBookAir = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
        visibleFrame: CGRect(x: 0, y: 85, width: 1470, height: 838),
        safeAreaTop: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 924, width: 645.5, height: 32),
        auxiliaryTopRight: CGRect(x: 824.5, y: 924, width: 645.5, height: 32),
        scale: 2
    )

    private let external = ScreenMetrics(
        frame: CGRect(x: -203, y: 956, width: 1920, height: 1080),
        visibleFrame: CGRect(x: -203, y: 956, width: 1920, height: 1056),
        safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil, scale: 1
    )

    @Test func readsThePhysicalNotch() {
        let geometry = NotchGeometry.resolve(macBookAir)
        #expect(geometry.hasPhysicalNotch)
        #expect(geometry.notchRect == CGRect(x: 645.5, y: 924, width: 179, height: 32))
    }

    @Test func adaptsToADifferentScaledResolution() {
        let scaled = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1710, height: 1112),
            visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1075),
            safeAreaTop: 37,
            auxiliaryTopLeft: CGRect(x: 0, y: 1075, width: 750, height: 37),
            auxiliaryTopRight: CGRect(x: 960, y: 1075, width: 750, height: 37),
            scale: 2
        )
        #expect(NotchGeometry.resolve(scaled).notchRect == CGRect(x: 750, y: 1075, width: 210, height: 37))
    }

    @Test func notchlessDisplayGetsAVirtualNotchInItsMenuBar() {
        let geometry = NotchGeometry.resolve(external)
        #expect(!geometry.hasPhysicalNotch)
        #expect(geometry.notchRect.width == NotchGeometry.virtualNotchWidth)
        #expect(geometry.notchRect.height == 24)
        #expect(geometry.notchRect.midX == external.frame.midX)
        #expect(geometry.notchRect.maxY == external.frame.maxY)
    }

    @Test func autoHiddenMenuBarFallsBackToADefaultHeight() {
        var metrics = external
        metrics.visibleFrame = metrics.frame
        #expect(NotchGeometry.resolve(metrics).notchRect.height == NotchGeometry.fallbackMenuBarHeight)
    }

    @Test func aSafeAreaWithoutAuxiliaryAreasIsNotANotch() {
        var metrics = macBookAir
        metrics.auxiliaryTopLeft = nil
        #expect(!NotchGeometry.resolve(metrics).hasPhysicalNotch)
    }

    @Test func calibrationShiftsAndResizesAroundTheCenter() {
        let calibration = NotchCalibration(offsetX: 2, widthDelta: 4, heightDelta: 1)
        let rect = NotchGeometry.resolve(macBookAir, calibration: calibration).notchRect
        #expect(rect.midX == 737)
        #expect(rect.width == 183)
        #expect(rect.height == 33)
        #expect(rect.maxY == 956, "The island stays attached to the top edge")
    }

    @Test func calibrationCannotCollapseTheIsland() {
        let rect = NotchGeometry.resolve(macBookAir, calibration: NotchCalibration(widthDelta: -500, heightDelta: -500)).notchRect
        #expect(rect.width >= 80)
        #expect(rect.height >= 16)
    }

    @Test func panelHangsFromTheTopEdgeCenteredOnTheNotch() {
        let frame = NotchGeometry.resolve(macBookAir).panelFrame(for: CGSize(width: 560, height: 228))
        #expect(frame == CGRect(x: 455, y: 728, width: 560, height: 228))
        #expect(frame.midX == 735)
    }

    @Test func panelUsesGlobalCoordinatesOnASecondDisplay() {
        let geometry = NotchGeometry.resolve(external)
        let frame = geometry.panelFrame(for: CGSize(width: 400, height: 100))
        #expect(frame.maxY == 2036)
        #expect(frame.midX == external.frame.midX)
    }

    @Test func panelStaysOnScreenWhenCalibrationPushesItOut() {
        let narrow = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 600, height: 400), visibleFrame: CGRect(x: 0, y: 0, width: 600, height: 376),
                                   safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil, scale: 2)
        let geometry = NotchGeometry.resolve(narrow, calibration: NotchCalibration(offsetX: 20))
        let frame = geometry.panelFrame(for: CGSize(width: 560, height: 200))
        #expect(frame.maxX <= 600)
        #expect(frame.minX >= 0)
    }

    @Test func panelOriginsAreWholePointsCenteredOnTheNotch() {
        let geometry = NotchGeometry.resolve(macBookAir)
        for width: CGFloat in [179, 180, 259, 560] {
            let frame = geometry.panelFrame(for: CGSize(width: width, height: 32))
            #expect(frame.minX == frame.minX.rounded(), "AppKit rounds fractional origins")
            #expect(frame.midX == geometry.notchRect.midX)
            #expect(frame.width >= width)
            #expect(frame.width <= width + 1)
        }
    }

    @Test func framesLandOnWholePixels() {
        var metrics = macBookAir
        metrics.scale = 1
        let rect = NotchGeometry.resolve(metrics).notchRect
        #expect(rect.minX == rect.minX.rounded())
    }
}

@Suite("Display selection")
struct DisplaySelectionTests {
    private let builtIn = DisplayCandidate(identifier: "A", name: "Built-in", hasNotch: true, isBuiltIn: true, isMain: false)
    private let main = DisplayCandidate(identifier: "B", name: "External", hasNotch: false, isBuiltIn: false, isMain: true)
    private let other = DisplayCandidate(identifier: "C", name: "Other", hasNotch: false, isBuiltIn: false, isMain: false)

    @Test func automaticPrefersTheNotchEvenWhenAnotherDisplayIsMain() {
        #expect(DisplaySelector.select([main, builtIn], preference: MorphPreferences.automaticDisplay) == builtIn)
    }

    @Test func explicitChoiceWins() {
        #expect(DisplaySelector.select([main, builtIn, other], preference: "C") == other)
    }

    @Test func disconnectedChoiceFallsBack() {
        #expect(DisplaySelector.select([main, builtIn], preference: "gone") == builtIn)
    }

    @Test func clamshellFallsBackToMain() {
        #expect(DisplaySelector.select([other, main], preference: "automatic") == main)
    }

    @Test func noDisplaysIsSafe() {
        #expect(DisplaySelector.select([], preference: "automatic") == nil)
    }
}

@Suite("Island layout")
struct LayoutTests {
    private let layout = IslandLayout(notch: CGSize(width: 179, height: 32), size: .regular)
    private let activity = IslandActivity(.batteryLow(percentage: 19), at: .now)

    private var everyPresentation: [IslandPresentation] {
        [.idle, .hover, .dropTarget, .live(.media), .live(.timer), .activity(activity), .expanded(.home), .expanded(.shelf)]
    }

    @Test func idleMatchesTheNotchExactly() {
        #expect(layout.islandSize(for: .idle) == CGSize(width: 179, height: 32))
        #expect(layout.corners(for: .idle).top == 0)
    }

    @Test func compactStatesKeepRoomForTheHousing() {
        let compact = IslandActivity(.filesAdded(count: 1), at: .now)
        #expect(layout.islandSize(for: .activity(compact)).width > 179)
        #expect(layout.islandSize(for: .activity(compact)).height == 32)
        #expect(layout.islandSize(for: .live(.media)).height == 32)
    }

    @Test func everySizeFitsTheCanvas() {
        for size in IslandSizePreference.allCases {
            let layout = IslandLayout(notch: CGSize(width: 240, height: 44), size: size, showsCalibrationGuide: true)
            for presentation in everyPresentation {
                let panel = layout.panelSize(for: presentation)
                #expect(panel.width <= IslandLayout.canvas.width)
                #expect(panel.height <= IslandLayout.canvas.height)
            }
        }
    }

    @Test func guideOnlyGrowsTheIdlePanel() {
        var guided = layout
        guided.showsCalibrationGuide = true
        #expect(guided.panelSize(for: .idle).width == 179 + 2 * IslandLayout.calibrationMargin)
        #expect(guided.panelSize(for: .hover) == layout.panelSize(for: .hover))
    }

    @Test func windowDecisionsFollowThePresentation() {
        let screen = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1470, height: 956), visibleFrame: CGRect(x: 0, y: 0, width: 1470, height: 924),
                                   safeAreaTop: 32, auxiliaryTopLeft: CGRect(x: 0, y: 924, width: 645.5, height: 32),
                                   auxiliaryTopRight: CGRect(x: 824.5, y: 924, width: 645.5, height: 32), scale: 2)
        let geometry = NotchGeometry.resolve(screen)
        let idle = geometry.panelFrame(for: layout.panelSize(for: .idle))
        let expanded = geometry.panelFrame(for: layout.panelSize(for: .expanded(.home)))
        #expect(idle.contains(geometry.notchRect))
        #expect(idle.width <= geometry.notchRect.width + 1, "At rest the window covers the housing and nothing else")
        #expect(expanded.contains(idle))
        #expect(expanded.midX == idle.midX)
        #expect(expanded.maxY == idle.maxY)
    }
}
