import SwiftUI

struct ExpandedPanelView: View {
    let tab: ExpandedTab
    let notch: CGSize
    let inset: CGFloat
    let artworkSpace: Namespace.ID

    @Environment(IslandController.self) private var island
    @Environment(BatteryService.self) private var battery
    @Environment(ActivityManager.self) private var activities
    @Environment(MorphPreferences.self) private var preferences
    @Environment(\.morphMotion) private var motion

    var body: some View {
        VStack(spacing: MorphSpacing.s) {
            header
            if let alert = activities.current, alert.priority == .critical || alert.dismissal == .acknowledge {
                criticalBanner(alert)
            }
            ZStack {
                switch tab {
                case .home: HomeTabView(artworkSpace: artworkSpace)
                case .timers: TimersTabView()
                case .focus: FocusTabView()
                case .battery: BatteryTabView()
                case .activities: ActivitiesTabView()
                case .transfers: TransfersTabView()
                case .shelf: ShelfTabView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            .id(tab)
        }
        .padding(.horizontal, inset + MorphSpacing.s)
        .padding(.bottom, MorphSpacing.m)
        .animation(motion.contentCrossfade, value: tab)
        .animation(motion.contentCrossfade, value: activities.current?.presentation == .level)
    }

    /// Tabs share the space left of the notch, which they must never reach.
    private var tabWidth: CGFloat {
        let panel = island.layout.islandSize(for: .expanded(tab)).width
        let ear = (panel - 2 * (inset + MorphSpacing.s) - notch.width) / 2
        let count = CGFloat(island.availableTabs.count)
        return min(MorphSize.hitTarget, (ear - MorphSpacing.xxs * (count - 1)) / count)
    }

    private var header: some View {
        NotchEars(notch: notch, inset: 0) {
            HStack(spacing: MorphSpacing.xxs) {
                ForEach(island.availableTabs) { candidate in
                    MorphIconButton(symbol: candidate.symbol, label: candidate.title, size: 12, width: tabWidth,
                                    isSelected: candidate == tab) {
                        island.showTab(candidate)
                    }
                }
            }
        } trailing: {
            // Keys still deserve an answer with the panel open, and the panel stays as it is.
            if let level = activities.current, level.presentation == .level {
                LevelHUDInline(content: level.content)
                    .transition(.opacity)
            } else if tab != .home, preferences.batteryEnabled, let snapshot = battery.snapshot {
                BatteryBadge(snapshot: snapshot)
            } else {
                Text("morph.").font(MorphFont.wordmark).foregroundStyle(MorphColor.textSecondary)
            }
        }
    }

    private func criticalBanner(_ alert: IslandActivity) -> some View {
        HStack(spacing: MorphSpacing.s) {
            Image(systemName: alert.content.symbol).foregroundStyle(MorphColor.critical)
            Text([alert.content.title, alert.content.subtitle].compactMap { $0 }.joined(separator: " · "))
                .font(MorphFont.secondary)
                .foregroundStyle(MorphColor.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            MorphIconButton(symbol: "xmark", label: "Dismiss alert", size: 10) {
                activities.dismissCurrent()
            }
        }
        .padding(.horizontal, MorphSpacing.m)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: MorphRadius.medium, style: .continuous).fill(MorphColor.surfaceSecondary))
    }
}
