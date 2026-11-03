import SwiftUI

/// The canvas hosted in the panel. It always fills the fixed canvas; the island is drawn at the top
/// and everything else stays transparent.
struct IslandRootView: View {
    @Environment(IslandController.self) private var island
    @Environment(MorphPreferences.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    let onOpenSettings: () -> Void
    let onPause: () -> Void
    let onQuit: () -> Void

    @Namespace private var artworkSpace

    private var motion: MorphMotion {
        var motion = MorphMotion.resolve(preferences, systemReduced: systemReduceMotion)
        // The welcome has its own switch, for those who like the greeting but not the movement.
        if preferences.welcomeReducedMotion, case .activity(let activity) = island.presentation,
           activity.presentation == .welcome {
            motion.reduced = true
        }
        return motion
    }

    var body: some View {
        let presentation = island.presentation
        let layout = island.layout
        let size = layout.islandSize(for: presentation)
        let corners = layout.corners(for: presentation)
        let shape = NotchShape(topRadius: corners.top, bottomRadius: corners.bottom)
        let isGrowing = size.height > layout.notch.height

        ZStack(alignment: .top) {
            IslandContentView(presentation: presentation, notch: layout.notch, inset: corners.top, size: size,
                              artworkSpace: artworkSpace)
                .transition(motion.contentTransition)
                .id(presentation.contentIdentity)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipped()
        .background(MorphColor.background)
        .clipShape(shape)
        .overlay {
            if case .expanded = presentation {
                shape.stroke(MorphColor.hairline, lineWidth: 0.5).allowsHitTesting(false)
            }
        }
        .overlay { calibrationGuide(shape: shape) }
        .contentShape(shape)
        .onTapGesture { island.handleClick() }
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Morph")
        .accessibilityAction(named: "Open Morph") { island.toggleFromMenu() }
        .animation(isGrowing ? motion.expansion : motion.contraction, value: size)
        .animation(isGrowing ? motion.expansion : motion.contraction, value: corners)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .environment(\.morphMotion, motion)
        .environment(\.morphAccent, MorphColor.accent(preferences.accent))
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func calibrationGuide(shape: NotchShape) -> some View {
        if island.showsCalibrationGuide, island.presentation == .idle {
            shape.stroke(Color.red, lineWidth: 1.5)
                .padding(-IslandLayout.calibrationMargin / 2)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Morph Settings…", action: onOpenSettings)
        Button("Pause Morph", action: onPause)
        Divider()
        Button("Quit Morph", action: onQuit)
    }
}

extension IslandPresentation {
    /// Changes only when the content needs to crossfade, not on every value update.
    var contentIdentity: String {
        switch self {
        case .idle: "idle"
        case .live(let content): "live-\(content)"
        case .hover: "hover"
        case .dropTarget: "drop"
        // Volume and brightness share one view, so moving between them never rebuilds it.
        // Transfers update in place, so the bar moves instead of the content crossfading.
        case .activity(let activity) where activity.presentation == .transfer: "transfer"
        case .activity(let activity): activity.presentation == .level ? "level" : "activity-\(activity.id)"
        case .expanded: "expanded"
        }
    }
}

private struct IslandContentView: View {
    let presentation: IslandPresentation
    let notch: CGSize
    let inset: CGFloat
    let size: CGSize
    let artworkSpace: Namespace.ID

    var body: some View {
        switch presentation {
        case .idle:
            Color.clear
        case .live(let content):
            LiveCompactView(content: content, notch: notch, inset: inset, artworkSpace: artworkSpace)
        case .hover:
            HoverSummaryView(notch: notch, artworkSpace: artworkSpace)
        case .dropTarget:
            DropTargetView(notch: notch)
        case .activity(let activity) where activity.presentation == .level:
            LevelHUDView(content: activity.content, notch: notch, inset: inset, size: size)
        case .activity(let activity) where activity.presentation == .screenshot:
            ScreenshotPreviewView(notch: notch, inset: inset)
        case .activity(let activity):
            if case .welcome(let welcome) = activity.content {
                WelcomeIslandView(welcome: welcome, duration: activity.duration, notch: notch)
            } else if case .transfer(let transfer, let others) = activity.content {
                TransferIslandView(transfer: transfer, others: others, notch: notch)
            } else {
                ActivityView(activity: activity, notch: notch, inset: inset)
            }
        case .expanded(let tab):
            ExpandedPanelView(tab: tab, notch: notch, inset: inset, artworkSpace: artworkSpace)
        }
    }
}
