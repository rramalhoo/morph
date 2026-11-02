import SwiftUI

struct HomeTabView: View {
    let artworkSpace: Namespace.ID

    @Environment(MediaController.self) private var media
    @Environment(MorphPreferences.self) private var preferences

    var body: some View {
        HStack(spacing: MorphSpacing.s) {
            Group {
                if preferences.musicEnabled, let snapshot = media.snapshot, let track = snapshot.track {
                    NowPlayingCard(snapshot: snapshot, track: track, artworkSpace: artworkSpace)
                } else if preferences.musicEnabled, let kind = media.providerNeedingAuthorization {
                    ConnectPlayerCard(kind: kind)
                } else if preferences.activitiesEnabled {
                    RecentCard()
                } else {
                    ClockCard()
                }
            }
            .frame(maxWidth: .infinity)

            SideColumn()
                .frame(width: 176)
        }
    }
}

private struct NowPlayingCard: View {
    let snapshot: PlaybackSnapshot
    let track: Track
    let artworkSpace: Namespace.ID

    @Environment(MediaController.self) private var media
    @Environment(VolumeService.self) private var output
    @Environment(AmbientColorService.self) private var ambient
    @Environment(IslandController.self) private var island

    var body: some View {
        MorphCard(tint: ambient.color?.color) {
            VStack(alignment: .leading, spacing: MorphSpacing.s) {
                HStack(spacing: MorphSpacing.m) {
                    ArtworkView(data: media.artwork, size: MorphSize.artwork)
                        .matchedGeometryEffect(id: "artwork", in: artworkSpace)
                    VStack(alignment: .leading, spacing: MorphSpacing.xxs) {
                        Text(track.title)
                            .font(MorphFont.primary)
                            .foregroundStyle(MorphColor.textPrimary)
                        Text(track.artist)
                            .font(MorphFont.secondary)
                            .foregroundStyle(MorphColor.textSecondary)
                        Text(track.album)
                            .font(MorphFont.secondary)
                            .foregroundStyle(MorphColor.textSecondary.opacity(0.7))
                    }
                    .lineLimit(1)
                    .accessibilityElement(children: .combine)
                }
                progress
                Spacer(minLength: 0)
                controls
            }
        }
    }

    @ViewBuilder
    private var progress: some View {
        if let duration = track.duration {
            // Ticks only while playing and only while this view exists, which is while expanded.
            TimelineView(.periodic(from: .now, by: snapshot.isPlaying ? 1 : 3600)) { _ in
                let position = snapshot.position(at: .now) ?? 0
                HStack(spacing: MorphSpacing.s) {
                    Text(TimeFormat.clock(position)).frame(width: 34, alignment: .leading)
                    MorphProgressBar(
                        fraction: duration > 0 ? position / duration : 0,
                        onScrub: { island.send($0 ? .interactionBegan : .interactionEnded) },
                        onSeek: { media.seek(to: $0 * duration) }
                    )
                    .accessibilityLabel("Playback position")
                    .accessibilityValue("\(TimeFormat.clock(position)) of \(TimeFormat.clock(duration))")
                    Text(TimeFormat.clock(duration)).frame(width: 34, alignment: .trailing)
                }
                .font(MorphFont.label.monospacedDigit())
                .foregroundStyle(MorphColor.textSecondary)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: MorphSpacing.s) {
            MorphIconButton(symbol: "backward.fill", label: "Previous Track", action: media.previousTrack)
            MorphIconButton(symbol: snapshot.isPlaying ? "pause.fill" : "play.fill",
                            label: snapshot.isPlaying ? "Pause" : "Play", size: 18, action: media.playPause)
            MorphIconButton(symbol: "forward.fill", label: "Next Track", action: media.nextTrack)
            Spacer(minLength: MorphSpacing.m)
            // The output slider in the side column takes over wherever the system volume is settable.
            if let volume = snapshot.volume, !output.isControllable {
                Image(systemName: IslandActivity.Content.volumeChanged(percentage: volume).symbol)
                    .font(MorphFont.label)
                    .foregroundStyle(MorphColor.textSecondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                MorphProgressBar(
                    fraction: Double(volume) / 100,
                    onScrub: { island.send($0 ? .interactionBegan : .interactionEnded) },
                    onSeek: { media.setVolume(Int(($0 * 100).rounded())) }
                )
                .frame(width: 72)
                .accessibilityElement()
                .accessibilityLabel("Volume")
                .accessibilityValue("\(volume) percent")
                .accessibilityAdjustableAction { direction in
                    media.adjustVolume(by: direction == .increment ? 5 : -5)
                }
            }
        }
    }
}

private struct ConnectPlayerCard: View {
    let kind: MediaProviderKind

    @Environment(MediaController.self) private var media

    var body: some View {
        MorphCard {
            VStack(alignment: .leading, spacing: MorphSpacing.s) {
                Image(systemName: "music.note")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(MorphColor.textSecondary)
                Text("Connect \(kind.displayName)")
                    .font(MorphFont.primary)
                    .foregroundStyle(MorphColor.textPrimary)
                Text("Morph needs your permission to show the current track and control playback.")
                    .font(MorphFont.secondary)
                    .foregroundStyle(MorphColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                MorphTextButton(title: "Allow Access", isProminent: true) { media.authorize(kind) }
            }
        }
    }
}

/// With no music, the main card becomes a record of what the island has been doing.
private struct RecentCard: View {
    @Environment(ActivityManager.self) private var activities

    var body: some View {
        if activities.recent.isEmpty {
            ClockCard()
        } else {
            MorphCard {
                VStack(alignment: .leading, spacing: MorphSpacing.s) {
                    Text("RECENT")
                        .font(MorphFont.label)
                        .foregroundStyle(MorphColor.textSecondary)
                    ForEach(activities.recent.prefix(4)) { record in
                        HStack(spacing: MorphSpacing.s) {
                            Image(systemName: record.content.symbol)
                                .frame(width: 16)
                                .foregroundStyle(MorphColor.textSecondary)
                            Text(record.content.title)
                                .foregroundStyle(MorphColor.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: MorphSpacing.s)
                            Text(record.date, format: .dateTime.hour().minute())
                                .foregroundStyle(MorphColor.textSecondary)
                        }
                        .font(MorphFont.secondary)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

private struct ClockCard: View {
    var body: some View {
        MorphCard {
            TimelineView(.everyMinute) { context in
                VStack(alignment: .leading, spacing: MorphSpacing.xs) {
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(MorphFont.timer)
                        .foregroundStyle(MorphColor.textPrimary)
                    Text(context.date, format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(MorphFont.secondary)
                        .foregroundStyle(MorphColor.textSecondary)
                    Spacer(minLength: 0)
                    Text("morph.")
                        .font(MorphFont.wordmark)
                        .foregroundStyle(MorphColor.textSecondary)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

private struct SideColumn: View {
    @Environment(BatteryService.self) private var battery
    @Environment(VolumeService.self) private var output
    @Environment(MorphPreferences.self) private var preferences
    @Environment(TimerService.self) private var timers
    @Environment(\.quickActionRunner) private var quickActionRunner

    private var actions: [QuickAction] {
        preferences.quickActions.prefix(QuickAction.limit).filter { action in
            if case .startTimer = action { return preferences.timerEnabled }
            return true
        }
    }

    var body: some View {
        VStack(spacing: MorphSpacing.s) {
            if preferences.batteryEnabled, let snapshot = battery.snapshot {
                MorphCard {
                    VStack(alignment: .leading, spacing: MorphSpacing.xxs) {
                        BatteryBadge(snapshot: snapshot)
                        Text(snapshot.statusText)
                            .font(MorphFont.secondary)
                            .foregroundStyle(MorphColor.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        BatteryLevelBar(snapshot: snapshot)
                    }
                }
            }
            if !actions.isEmpty {
                MorphCard {
                    VStack(alignment: .leading, spacing: MorphSpacing.xs) {
                        Text("QUICK ACTIONS")
                            .font(MorphFont.label)
                            .foregroundStyle(MorphColor.textSecondary)
                        HStack(spacing: MorphSpacing.xs) {
                            ForEach(actions) { action in
                                MorphIconButton(symbol: action.symbol, label: action.title) {
                                    quickActionRunner?.run(action)
                                }
                            }
                        }
                        OutputVolumeRow()
                    }
                }
            } else if output.isControllable {
                MorphCard { OutputVolumeRow() }
            }
        }
    }
}

/// The real system output volume. Hidden on outputs with no software volume.
private struct OutputVolumeRow: View {
    @Environment(VolumeService.self) private var output
    @Environment(IslandController.self) private var island

    var body: some View {
        if output.isControllable, let state = output.output, let percentage = state.percentage {
            HStack(spacing: MorphSpacing.xs) {
                Button(action: output.toggleMute) {
                    Image(systemName: IslandActivity.Content.outputVolume(percentage: percentage, muted: state.effectivelyMuted).symbol)
                        .font(MorphFont.label)
                        .foregroundStyle(MorphColor.textSecondary)
                        .frame(width: 18, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(MorphPressStyle())
                .disabled(!state.canMute)
                .help(state.device.name)
                .accessibilityLabel(state.effectivelyMuted ? "Unmute" : "Mute")

                MorphProgressBar(
                    fraction: state.effectivelyMuted ? 0 : Double(percentage) / 100,
                    onScrub: { island.send($0 ? .interactionBegan : .interactionEnded) },
                    onDrag: { output.setVolume(Float($0)) },
                    onSeek: { output.setVolume(Float($0)) }
                )
                .accessibilityElement()
                .accessibilityLabel("Output volume, \(state.device.name)")
                .accessibilityValue(state.effectivelyMuted ? "Muted" : "\(percentage) percent")
                .accessibilityAdjustableAction { direction in
                    output.adjustVolume(byPercent: direction == .increment ? 5 : -5)
                }
            }
        }
    }
}

private struct BatteryLevelBar: View {
    let snapshot: BatterySnapshot

    private var tint: Color {
        if snapshot.isCharging || snapshot.isOnExternalPower { return MorphColor.positive }
        return snapshot.percentage <= 20 ? MorphColor.warning : MorphColor.textPrimary
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(MorphColor.surfaceSecondary)
                Capsule().fill(tint).frame(width: proxy.size.width * CGFloat(snapshot.percentage) / 100)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

extension EnvironmentValues {
    @Entry var quickActionRunner: QuickActionRunner?
}
