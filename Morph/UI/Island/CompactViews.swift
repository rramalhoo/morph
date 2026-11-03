import SwiftUI

/// Left and right of the physical notch. Nothing may render in the middle: the camera housing
/// swallows those pixels.
struct NotchEars<Leading: View, Trailing: View>: View {
    let notch: CGSize
    let inset: CGFloat
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 0) {
            leading.frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: notch.width)
            trailing.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, inset + MorphSpacing.m)
        .frame(height: notch.height)
    }
}

struct LiveCompactView: View {
    let content: LiveContent
    let notch: CGSize
    let inset: CGFloat
    let artworkSpace: Namespace.ID

    @Environment(MediaController.self) private var media
    @Environment(TimerService.self) private var timers
    @Environment(FocusService.self) private var focus
    @Environment(LiveActivityStore.self) private var external
    @Environment(\.morphAccent) private var accent

    var body: some View {
        NotchEars(notch: notch, inset: inset) {
            leading
        } trailing: {
            trailing
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var leading: some View {
        switch content {
        case .media:
            ArtworkView(data: media.artwork, size: MorphSize.compactArtwork, radius: 5)
                .matchedGeometryEffect(id: "artwork", in: artworkSpace)
        case .timer:
            Image(systemName: "timer").foregroundStyle(accent).font(MorphFont.compact)
        case .stopwatch:
            Image(systemName: "stopwatch").foregroundStyle(accent).font(MorphFont.compact)
        case .focus:
            Image(systemName: focus.session.phase.symbol)
                .foregroundStyle(focus.session.timer.isPaused ? MorphColor.textSecondary : accent)
                .font(MorphFont.compact)
        case .external:
            Image(systemName: external.featured?.symbol ?? "dot.radiowaves.left.and.right")
                .foregroundStyle(accent)
                .font(MorphFont.compact)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch content {
        case .media:
            LiveWaveformView()
        case .timer:
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(TimeFormat.countdown(timers.countdown.remaining(at: timers.now).timeInterval))
                    .font(MorphFont.compact)
                    .foregroundStyle(MorphColor.textPrimary)
                    .fixedSize()
            }
        case .stopwatch:
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(TimeFormat.clock(timers.stopwatch.elapsed(at: timers.now).timeInterval))
                    .font(MorphFont.compact)
                    .foregroundStyle(MorphColor.textPrimary)
                    .fixedSize()
            }
        case .focus:
            TimelineView(.periodic(from: .now, by: focus.session.timer.isRunning ? 1 : 3600)) { _ in
                HStack(spacing: MorphSpacing.xs) {
                    ProgressRing(fraction: focus.session.fraction(at: focus.now), color: accent)
                    Text(TimeFormat.countdown(focus.session.timer.remaining(at: focus.now).timeInterval))
                        .font(MorphFont.compact)
                        .foregroundStyle(focus.session.timer.isPaused ? MorphColor.textSecondary : MorphColor.textPrimary)
                        .fixedSize()
                }
            }
        case .external:
            if let progress = external.featured?.progress {
                HStack(spacing: MorphSpacing.xs) {
                    ProgressRing(fraction: progress, color: accent)
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(MorphFont.compact)
                        .foregroundStyle(MorphColor.textPrimary)
                        .fixedSize()
                }
            } else {
                Text(external.featured?.title ?? "")
                    .font(MorphFont.compact)
                    .foregroundStyle(MorphColor.textPrimary)
                    .lineLimit(1)
            }
        }
    }

    private var accessibilityText: String {
        switch content {
        case .media: media.snapshot?.track.map { "Now playing \($0.title) by \($0.artist)" } ?? "Now playing"
        case .timer: "Timer running"
        case .stopwatch: "Stopwatch running"
        case .focus: "\(focus.session.phase.title) running"
        case .external: external.featured?.title ?? "Activity running"
        }
    }
}

/// How far along something is, small enough to sit beside the notch.
struct ProgressRing: View {
    let fraction: Double
    let color: Color

    @Environment(\.morphMotion) private var motion

    var body: some View {
        ZStack {
            Circle().stroke(MorphColor.surfaceSecondary, lineWidth: 2)
            Circle()
                .trim(from: 0, to: fraction.clamped(to: 0...1))
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(motion.progress, value: fraction)
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}

/// What hovering reveals: the one thing most worth knowing right now.
struct HoverSummaryView: View {
    let notch: CGSize
    let artworkSpace: Namespace.ID

    @Environment(MediaController.self) private var media
    @Environment(BatteryService.self) private var battery
    @Environment(TimerService.self) private var timers
    @Environment(MorphPreferences.self) private var preferences
    @Environment(ActivityManager.self) private var activities

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notch.height)
            HStack(spacing: MorphSpacing.s) {
                summary
            }
            .padding(.horizontal, MorphSpacing.l)
            .frame(maxHeight: .infinity)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var summary: some View {
        if let content = activities.current?.content, let level = content.level {
            LevelGlyph(content: content)
            LevelBar(fraction: level)
            LevelReadout(content: content)
        } else if preferences.timerEnabled, timers.countdown.isRunning {
            Image(systemName: "timer").foregroundStyle(MorphColor.textSecondary)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(TimeFormat.countdown(timers.countdown.remaining(at: timers.now).timeInterval))
                    .font(MorphFont.compact)
                    .foregroundStyle(MorphColor.textPrimary)
            }
        } else if preferences.musicEnabled, let track = media.snapshot?.track {
            ArtworkView(data: media.artwork, size: MorphSize.compactArtwork, radius: 5)
                .matchedGeometryEffect(id: "artwork", in: artworkSpace)
            Text(track.title)
                .font(MorphFont.compact)
                .foregroundStyle(MorphColor.textPrimary)
                .lineLimit(1)
            if !track.artist.isEmpty {
                Text(track.artist)
                    .font(MorphFont.secondary)
                    .foregroundStyle(MorphColor.textSecondary)
                    .lineLimit(1)
            }
        } else {
            Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(MorphFont.compact)
                .foregroundStyle(MorphColor.textPrimary)
                .lineLimit(1)
            Spacer(minLength: MorphSpacing.s)
            if preferences.batteryEnabled, let snapshot = battery.snapshot {
                BatteryBadge(snapshot: snapshot)
            }
        }
    }
}

struct BatteryBadge: View {
    let snapshot: BatterySnapshot

    var body: some View {
        HStack(spacing: MorphSpacing.xs) {
            Image(systemName: snapshot.symbol)
                .foregroundStyle(snapshot.isCharging ? MorphColor.positive : MorphColor.textSecondary)
            Text("\(snapshot.percentage)%")
                .foregroundStyle(MorphColor.textPrimary)
        }
        .font(MorphFont.compact)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(snapshot.percentage) percent, \(snapshot.statusText)")
    }
}

struct DropTargetView: View {
    let notch: CGSize

    @Environment(\.morphAccent) private var accent

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notch.height)
            HStack(spacing: MorphSpacing.s) {
                Image(systemName: "tray.and.arrow.down.fill").foregroundStyle(accent)
                Text("Drop to add to shelf")
                    .font(MorphFont.primary)
                    .foregroundStyle(MorphColor.textPrimary)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

struct ActivityView: View {
    let activity: IslandActivity
    let notch: CGSize
    let inset: CGFloat

    @Environment(\.morphAccent) private var accent

    private var content: IslandActivity.Content { activity.content }

    private var tint: Color {
        switch content {
        case .batteryCritical: MorphColor.critical
        case .batteryLow, .actionFailed, .peripheralLow: MorphColor.warning
        case .powerConnected, .fullyCharged, .deviceConnected: MorphColor.positive
        case .external(let external) where external.state == .failed: MorphColor.warning
        case .external(let external) where external.state == .success: MorphColor.positive
        default: accent
        }
    }

    var body: some View {
        Group {
            switch activity.presentation {
            case .minimal, .level, .screenshot:
                NotchEars(notch: notch, inset: inset) {
                    HStack(spacing: MorphSpacing.xs + 2) {
                        Image(systemName: content.symbol)
                            .foregroundStyle(tint)
                            .font(MorphFont.compact)
                        Text(minimalLeadingText)
                            .font(MorphFont.compact)
                            .foregroundStyle(MorphColor.textPrimary)
                            .lineLimit(1)
                    }
                } trailing: {
                    if let subtitle = content.subtitle {
                        Text(subtitle)
                            .font(MorphFont.compact)
                            .foregroundStyle(MorphColor.textSecondary)
                            .lineLimit(1)
                    }
                }
            case .banner:
                VStack(spacing: 0) {
                    Color.clear.frame(height: notch.height)
                    HStack(spacing: MorphSpacing.m) {
                        Image(systemName: content.symbol)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(content.title).font(MorphFont.primary).foregroundStyle(MorphColor.textPrimary)
                            if let subtitle = content.subtitle {
                                Text(subtitle).font(MorphFont.secondary).foregroundStyle(MorphColor.textSecondary)
                            }
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                        if activity.dismissal == .acknowledge {
                            Text("Click to dismiss").font(MorphFont.label).foregroundStyle(MorphColor.textSecondary)
                        }
                    }
                    .padding(.horizontal, MorphSpacing.xl)
                    .frame(maxHeight: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([content.title, content.subtitle].compactMap { $0 }.joined(separator: ", "))
    }

    private var minimalLeadingText: String {
        if case .nowPlaying(let title, _) = content { return title }
        return content.title
    }
}
