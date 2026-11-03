import SwiftUI

/// The screenshot that was just taken, with what can be done with it. Dragging the image hands the
/// file to whatever it lands on.
struct ScreenshotPreviewView: View {
    let notch: CGSize
    let inset: CGFloat

    @Environment(ScreenshotService.self) private var screenshots
    @Environment(ActivityManager.self) private var activities
    @Environment(IslandController.self) private var island

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notch.height)
            HStack(spacing: MorphSpacing.m) {
                thumbnail
                VStack(alignment: .leading, spacing: MorphSpacing.xs) {
                    Text("Screenshot")
                        .font(MorphFont.primary)
                        .foregroundStyle(MorphColor.textPrimary)
                    Text(screenshots.current?.name ?? "")
                        .font(MorphFont.label)
                        .foregroundStyle(MorphColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: MorphSpacing.xs) {
                        MorphIconButton(symbol: "doc.on.doc", label: "Copy", size: 12, action: copy)
                        MorphIconButton(symbol: "arrow.up.forward.app", label: "Open", size: 12, action: open)
                        MorphIconButton(symbol: "folder", label: "Show in Finder", size: 12, action: reveal)
                        Spacer(minLength: 0)
                        MorphIconButton(symbol: "xmark", label: "Close", size: 11) { activities.dismissCurrent() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, inset + MorphSpacing.m)
            .padding(.bottom, MorphSpacing.s)
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = screenshots.thumbnail, let url = screenshots.current?.url {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: 124, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: MorphRadius.small, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: MorphRadius.small, style: .continuous)
                        .stroke(MorphColor.hairline, lineWidth: 0.5)
                }
                .contentShape(Rectangle())
                .onDrag {
                    screenshots.isDragging = true
                    island.isExportingDrag = true
                    return NSItemProvider(contentsOf: url) ?? NSItemProvider()
                }
                .help("Drag to another app")
                .accessibilityLabel("Screenshot preview")
                .accessibilityHint("Drag to another app")
        }
    }

    private func copy() {
        screenshots.copy()
        activities.dismissCurrent()
    }

    private func open() {
        screenshots.open()
        activities.dismissCurrent()
    }

    private func reveal() {
        screenshots.reveal()
        activities.dismissCurrent()
    }
}
