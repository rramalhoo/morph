import SwiftUI

/// What other apps have open right now. The tab exists only while something is.
struct ActivitiesTabView: View {
    @Environment(LiveActivityStore.self) private var external
    @Environment(MorphContinuityManager.self) private var continuity: MorphContinuityManager?
    @Environment(MorphPreferences.self) private var preferences

    private var list: some View {
        VStack(spacing: MorphSpacing.s) {
            if preferences.continuityEnabled, preferences.showContinuityActivities {
                ForEach(continuity?.activities ?? []) { ContinuityActivityRow(activity: $0) }
            }
            ForEach(external.activities) { ExternalActivityRow(activity: $0) }
        }
    }

    var body: some View {
        MorphCard {
            ViewThatFits(in: .vertical) {
                list
                ScrollView(.vertical, showsIndicators: false) { list }
            }
        }
    }
}

private struct ExternalActivityRow: View {
    let activity: ExternalActivity

    @Environment(\.morphAccent) private var accent

    var body: some View {
        HStack(spacing: MorphSpacing.m) {
            Image(systemName: activity.symbol)
                .foregroundStyle(MorphColor.textSecondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(activity.title).font(MorphFont.secondary).foregroundStyle(MorphColor.textPrimary)
                if let subtitle = activity.subtitle {
                    Text(subtitle).font(MorphFont.label).foregroundStyle(MorphColor.textSecondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: MorphSpacing.s)
            if let progress = activity.progress {
                ProgressRing(fraction: progress, color: accent)
                Text("\(Int((progress * 100).rounded()))%")
                    .font(MorphFont.compact)
                    .foregroundStyle(MorphColor.textPrimary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([activity.title, activity.subtitle, activity.progress.map { "\(Int($0 * 100)) percent" }]
            .compactMap { $0 }.joined(separator: ", "))
    }
}

/// The panel is something the user opened, so it shows the full activity, with its source and
/// whether it's still in sync.
private struct ContinuityActivityRow: View {
    let activity: ContinuityActivity

    @Environment(\.morphAccent) private var accent

    var body: some View {
        HStack(spacing: MorphSpacing.m) {
            Image(systemName: activity.symbol)
                .foregroundStyle(activity.isStale ? MorphColor.textSecondary : accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(activity.payload.title).font(MorphFont.secondary).foregroundStyle(MorphColor.textPrimary)
                Text([activity.payload.service, activity.payload.subtitle, activity.isStale ? "Out of sync" : activity.deviceName]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(MorphFont.label).foregroundStyle(MorphColor.textSecondary)
            }
            .lineLimit(1)
            Spacer(minLength: MorphSpacing.s)
            ContinuityIndicator(activity: activity, hidesDetails: false)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
        .accessibilityElement(children: .combine)
    }
}
