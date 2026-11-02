import AppKit
import SwiftUI

/// The volume and brightness HUD. It always lays out at the size it will finish at, and the island
/// reveals it as it opens, so nothing inside moves or reflows during the spring.
struct LevelHUDView: View {
    let content: IslandActivity.Content
    let notch: CGSize
    let inset: CGFloat
    let size: CGSize

    @Environment(ActivityManager.self) private var activities
    @Environment(\.morphMotion) private var motion
    @State private var hasAppeared = false

    var body: some View {
        VStack(spacing: 0) {
            NotchEars(notch: notch, inset: inset) {
                LevelGlyph(content: content)
            } trailing: {
                LevelReadout(content: content)
            }
            if let level = content.level {
                LevelBar(fraction: level)
                    .padding(.horizontal, inset + MorphSpacing.m)
                    .padding(.top, MorphSpacing.xxs)
                    .scaleEffect(x: hasAppeared || motion.reduced ? 1 : 0.4, anchor: .center)
                    .opacity(hasAppeared ? 1 : 0)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .opacity(activities.isConcluding ? 0.45 : 1)
        .animation(motion.levelConclude, value: activities.isConcluding)
        .onAppear {
            withAnimation(motion.levelReveal) { hasAppeared = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([content.title, content.subtitle].compactMap { $0 }.joined(separator: ", "))
    }
}

/// For where the island can't change shape: the open panel's header.
struct LevelHUDInline: View {
    let content: IslandActivity.Content

    @Environment(ActivityManager.self) private var activities
    @Environment(\.morphMotion) private var motion

    var body: some View {
        HStack(spacing: MorphSpacing.s) {
            LevelGlyph(content: content)
            if let level = content.level {
                LevelBar(fraction: level).frame(width: 84)
            }
            LevelReadout(content: content)
        }
        .opacity(activities.isConcluding ? 0.45 : 1)
        .animation(motion.levelConclude, value: activities.isConcluding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([content.title, content.subtitle].compactMap { $0 }.joined(separator: ", "))
    }
}

struct LevelGlyph: View {
    let content: IslandActivity.Content

    @Environment(\.morphMotion) private var motion

    private var variableValue: Double? {
        content.levelKind == .volume && !content.isMuted ? content.level : nil
    }

    var body: some View {
        Image(systemName: content.levelSymbol, variableValue: variableValue)
            .font(MorphFont.compact)
            .foregroundStyle(content.isMuted ? MorphColor.textSecondary : MorphColor.textPrimary)
            .contentTransition(motion.reduced ? .identity : .symbolEffect(.replace))
            .animation(motion.levelFill, value: content.levelSymbol)
            .frame(width: 20)
    }
}

struct LevelBar: View {
    let fraction: Double

    @Environment(\.morphAccent) private var accent
    @Environment(\.morphMotion) private var motion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(MorphColor.surfaceSecondary)
                Capsule()
                    .fill(accent)
                    .frame(width: proxy.size.width * fraction.clamped(to: 0...1))
            }
        }
        .frame(height: 3)
        .animation(motion.levelFill, value: fraction)
    }
}

/// A fixed width, so a change from 9% to 10% can't shift anything beside it.
struct LevelReadout: View {
    let content: IslandActivity.Content

    @Environment(MorphPreferences.self) private var preferences
    @Environment(\.morphMotion) private var motion

    private var showsValue: Bool {
        content.levelKind == .brightness ? preferences.brightnessShowsPercentage : preferences.volumeShowsPercentage
    }

    /// Direction is all there is without a real reading, and it's the only feedback then.
    private var text: String? {
        guard content.level != nil else { return content.title }
        return showsValue ? content.subtitle : nil
    }

    var body: some View {
        Text(text ?? "")
            .font(MorphFont.compact)
            .foregroundStyle(MorphColor.textPrimary)
            .lineLimit(1)
            .fixedSize()
            .contentTransition(motion.reduced ? .identity : .numericText(value: content.level ?? 0))
            .animation(motion.levelFill, value: text)
            .frame(minWidth: 40, alignment: .trailing)
    }
}

/// The click macOS plays after a volume key, which it can't play for a key it never received.
/// Shift inverts the preference, as it does for the system's own keys.
enum VolumeFeedback {
    private static let path = "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"

    @MainActor
    static func play(modifiers: LevelKeyModifiers) {
        guard !modifiers.isFine else { return }
        let enabled = UserDefaults.standard.integer(forKey: "com.apple.sound.beep.feedback") == 1
        if enabled != modifiers.shift { NSSound(contentsOfFile: path, byReference: true)?.play() }
    }
}
