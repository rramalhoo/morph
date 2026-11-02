import AppKit
import SwiftUI

struct MorphIconButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 14
    var isSelected = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(isSelected ? MorphColor.textPrimary : MorphColor.textSecondary)
                .frame(width: MorphSize.hitTarget, height: MorphSize.hitTarget)
                .background(
                    RoundedRectangle(cornerRadius: MorphRadius.small, style: .continuous)
                        .fill(isSelected || isHovering ? MorphColor.surfaceSecondary : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(MorphPressStyle())
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Text button for secondary actions inside cards.
struct MorphTextButton: View {
    let title: String
    var isProminent = false
    let action: () -> Void

    @Environment(\.morphAccent) private var accent

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(MorphFont.label)
                .foregroundStyle(isProminent ? .black : MorphColor.textPrimary)
                .padding(.horizontal, MorphSpacing.m)
                .frame(minHeight: 24)
                .background(Capsule().fill(isProminent ? accent : MorphColor.surfaceSecondary))
                .contentShape(Capsule())
        }
        .buttonStyle(MorphPressStyle())
    }
}

/// Seekable progress track. `onSeek` is nil when the source can't seek.
struct MorphProgressBar: View {
    let fraction: Double
    var onScrub: ((Bool) -> Void)?
    /// Called continuously during a drag, for values that apply live.
    var onDrag: ((Double) -> Void)?
    var onSeek: ((Double) -> Void)?

    @Environment(\.morphAccent) private var accent
    @Environment(\.morphMotion) private var motion
    @State private var dragFraction: Double?

    var body: some View {
        GeometryReader { proxy in
            let shown = (dragFraction ?? fraction).clamped(to: 0...1)
            ZStack(alignment: .leading) {
                Capsule().fill(MorphColor.surfaceSecondary)
                Capsule().fill(accent).frame(width: max(3, proxy.size.width * shown))
            }
            .frame(height: 3)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(scrub(width: proxy.size.width))
            .animation(dragFraction == nil ? motion.progress : nil, value: shown)
        }
        .frame(height: 12)
    }

    private func scrub(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard onSeek != nil, width > 0 else { return }
                if dragFraction == nil { onScrub?(true) }
                let fraction = (value.location.x / width).clamped(to: 0...1)
                dragFraction = fraction
                onDrag?(fraction)
            }
            .onEnded { _ in
                guard let dragFraction else { return }
                onSeek?(dragFraction)
                onScrub?(false)
                self.dragFraction = nil
            }
    }
}

struct ArtworkView: View {
    let data: Data?
    let size: CGFloat
    var radius: CGFloat = MorphRadius.medium

    @Environment(\.morphMotion) private var motion

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(MorphColor.surfaceSecondary)
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.38, weight: .medium))
                    .foregroundStyle(MorphColor.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .animation(motion.artwork, value: data)
        .accessibilityHidden(true)
    }
}

/// Card surface used throughout the expanded panel.
struct MorphCard<Content: View>: View {
    /// An ambient light in the corner of the card. The surface itself never changes color.
    var tint: Color?
    @ViewBuilder let content: Content

    @Environment(\.morphMotion) private var motion

    init(tint: Color? = nil, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        content
            .padding(MorphSpacing.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: MorphRadius.card, style: .continuous).fill(MorphColor.surface)
                    RoundedRectangle(cornerRadius: MorphRadius.card, style: .continuous)
                        .fill(RadialGradient(colors: [(tint ?? .clear).opacity(tint == nil ? 0 : 0.2), .clear],
                                             center: .topLeading, startRadius: 0, endRadius: 280))
                        .animation(motion.artwork, value: tint)
                }
            }
    }
}
