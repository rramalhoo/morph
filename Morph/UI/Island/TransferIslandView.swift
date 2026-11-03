import AppKit
import SwiftUI

/// A transfer under the notch: what it is, how far it's got, and, once done, a way to it.
struct TransferIslandView: View {
    let transfer: Transfer
    let others: Int
    let notch: CGSize

    @Environment(\.morphMotion) private var motion
    @Environment(\.morphAccent) private var accent

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notch.height)
            HStack(spacing: MorphSpacing.m) {
                TransferGlyph(transfer: transfer, size: 30)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: MorphSpacing.xs) {
                        Text(transfer.name)
                            .font(MorphFont.compact)
                            .foregroundStyle(MorphColor.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if others > 0 {
                            Text("+\(others)")
                                .font(MorphFont.label)
                                .foregroundStyle(MorphColor.textSecondary)
                        }
                        Spacer(minLength: MorphSpacing.xs)
                        trailing
                    }
                    if !transfer.kind.isAirDrop || transfer.progress != nil {
                        TransferBar(transfer: transfer)
                    }
                    Text(transfer.detail)
                        .font(MorphFont.label)
                        .foregroundStyle(MorphColor.textSecondary)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                        .animation(motion.contentCrossfade, value: transfer.detail)
                }
            }
            .padding(.horizontal, MorphSpacing.l)
            .frame(maxHeight: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(transfer.kind.title), \(transfer.name), \(transfer.detail)")
    }

    @ViewBuilder
    private var trailing: some View {
        if transfer.canOpen, let url = transfer.fileURL {
            HStack(spacing: MorphSpacing.xxs) {
                MorphIconButton(symbol: "arrow.up.forward.app", label: "Open", size: 11) {
                    NSWorkspace.shared.open(url)
                }
                MorphIconButton(symbol: "folder", label: "Show in Finder", size: 11) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            .transition(.opacity)
        } else if let progress = transfer.progress, !transfer.isOver {
            Text("\(Int((progress * 100).rounded(.down)))%")
                .font(MorphFont.compact)
                .foregroundStyle(MorphColor.textPrimary)
                .contentTransition(.numericText())
                .animation(motion.progress, value: progress)
        }
    }
}

/// The icon, which becomes the outcome when the transfer ends. AirDrop gets its ring.
struct TransferGlyph: View {
    let transfer: Transfer
    let size: CGFloat

    @Environment(\.morphMotion) private var motion
    @Environment(\.morphAccent) private var accent

    private var tint: Color {
        switch transfer.state {
        case .completed: MorphColor.positive
        case .failed: MorphColor.warning
        case .cancelled, .unknown: MorphColor.textSecondary
        default: accent
        }
    }

    var body: some View {
        ZStack {
            if transfer.kind.isAirDrop {
                AirDropRing(progress: transfer.progress, isOver: transfer.isOver, tint: tint)
            } else {
                Circle().fill(MorphColor.surfaceSecondary)
            }
            Image(systemName: transfer.isOver ? transfer.symbol : transfer.kind.symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: size, height: size)
        .animation(motion.activityEntrance, value: transfer.state)
        .accessibilityHidden(true)
    }
}

/// A ring that fills with real progress, or turns slowly when there's none to show, and closes
/// into a full circle when the transfer ends.
struct AirDropRing: View {
    let progress: Double?
    let isOver: Bool
    let tint: Color

    @Environment(\.morphMotion) private var motion
    @State private var spinning = false
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle().stroke(MorphColor.surfaceSecondary, lineWidth: 2.5)
            if !isOver, !motion.reduced {
                // A soft pulse, the only motion when nothing is measurable.
                Circle()
                    .stroke(tint.opacity(0.35), lineWidth: 1)
                    .scaleEffect(pulsing ? 1.28 : 1)
                    .opacity(pulsing ? 0 : 0.8)
            }
            Circle()
                .trim(from: 0, to: fill)
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90 + (progress == nil && !isOver && spinning ? 360 : 0)))
                .animation(motion.progress, value: fill)
        }
        .onAppear(perform: animate)
        .onChange(of: isOver) { animate() }
    }

    private var fill: Double {
        if isOver { return 1 }
        return progress ?? 0.28
    }

    private func animate() {
        guard !motion.reduced, !isOver else {
            spinning = false
            pulsing = false
            return
        }
        withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { spinning = progress == nil }
        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulsing = true }
    }
}

/// Real progress fills; unknown progress shows a quiet moving segment, never a made-up length.
struct TransferBar: View {
    let transfer: Transfer

    @Environment(\.morphMotion) private var motion
    @Environment(\.morphAccent) private var accent
    @State private var sweep = false

    private var tint: Color {
        switch transfer.state {
        case .completed: MorphColor.positive
        case .failed: MorphColor.warning
        case .cancelled, .unknown, .paused: MorphColor.textSecondary
        default: accent
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(MorphColor.surfaceSecondary)
                if let progress = transfer.progress {
                    Capsule().fill(tint)
                        .frame(width: max(4, proxy.size.width * progress))
                        .animation(motion.reduced ? nil : .spring(duration: 0.4, bounce: 0), value: progress)
                } else if !transfer.isOver {
                    Capsule().fill(tint.opacity(0.75))
                        .frame(width: proxy.size.width * 0.22)
                        .offset(x: sweep ? proxy.size.width * 0.78 : 0)
                }
            }
        }
        .frame(height: 4)
        .onAppear {
            guard !motion.reduced else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { sweep = true }
        }
        .accessibilityHidden(true)
    }
}

/// Everything moving, then what finished lately. Memory only, gone after the history duration.
struct TransfersTabView: View {
    @Environment(TransferManager.self) private var manager: TransferManager?

    var body: some View {
        if let manager { TransfersList(transfers: manager) }
    }
}

private struct TransfersList: View {
    let transfers: TransferManager

    private var list: some View {
        VStack(spacing: MorphSpacing.s) {
            ForEach(transfers.transfers) { TransferRow(transfer: $0, manager: transfers) }
        }
    }

    var body: some View {
        MorphCard {
            VStack(alignment: .leading, spacing: MorphSpacing.xs) {
                HStack {
                    Text(transfers.active.isEmpty ? "RECENT" : "\(transfers.active.count) ACTIVE")
                        .font(MorphFont.label)
                        .foregroundStyle(MorphColor.textSecondary)
                    Spacer()
                    if !transfers.recent.isEmpty {
                        MorphIconButton(symbol: "clear", label: "Clear Finished", size: 11, action: transfers.clearHistory)
                    }
                }
                ViewThatFits(in: .vertical) {
                    list
                    ScrollView(.vertical, showsIndicators: false) { list }
                }
            }
        }
    }
}

private struct TransferRow: View {
    let transfer: Transfer
    let manager: TransferManager

    var body: some View {
        HStack(spacing: MorphSpacing.m) {
            TransferGlyph(transfer: transfer, size: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(transfer.name).font(MorphFont.secondary).foregroundStyle(MorphColor.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                if !transfer.isOver, !transfer.kind.isAirDrop || transfer.progress != nil {
                    TransferBar(transfer: transfer)
                }
                Text(transfer.detail).font(MorphFont.label).foregroundStyle(MorphColor.textSecondary).lineLimit(1)
            }
            Spacer(minLength: MorphSpacing.s)
            if transfer.canOpen, let url = transfer.fileURL {
                MorphIconButton(symbol: "arrow.up.forward.app", label: "Open", size: 11) { NSWorkspace.shared.open(url) }
                MorphIconButton(symbol: "folder", label: "Show in Finder", size: 11) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            if transfer.canCancel {
                MorphIconButton(symbol: "xmark", label: "Cancel", size: 11) { try? manager.cancel(id: transfer.id) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Hands files to macOS's AirDrop picker. One object for the app's life, so views compare it by
/// identity and read the preferences themselves to decide whether to offer it.
@MainActor
final class AirDropAction {
    let isAvailable: Bool
    private let perform: @MainActor ([URL]) -> Void

    init(isAvailable: Bool, perform: @escaping @MainActor ([URL]) -> Void) {
        self.isAvailable = isAvailable
        self.perform = perform
    }

    func callAsFunction(_ urls: [URL]) { perform(urls) }
}

extension EnvironmentValues {
    @Entry var airDropAction: AirDropAction? = nil
}
