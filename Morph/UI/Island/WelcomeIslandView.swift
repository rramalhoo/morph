import SwiftUI

/// The greeting after an unlock: a hello first, then the few things worth knowing on return.
/// Both phases share one frame, so the island grows once and only its words change.
struct WelcomeIslandView: View {
    private enum Phase { case greeting, details }

    /// The details take over a little before the middle, so both phases get a fair look.
    private static let greetingShare = 0.42
    private static let minimumGreeting = Duration.milliseconds(1100)

    let welcome: WelcomeContent
    let duration: Duration
    let notch: CGSize

    @Environment(MediaController.self) private var media
    @Environment(MorphPreferences.self) private var preferences
    @Environment(\.morphMotion) private var motion
    @Environment(\.morphAccent) private var accent

    @State private var phase = Phase.greeting

    private var reduced: Bool { motion.reduced || preferences.welcomeReducedMotion }

    private var phaseAnimation: Animation {
        reduced ? .easeInOut(duration: 0.12) : .spring(duration: 0.42, bounce: 0.06)
    }

    private var phaseTransition: AnyTransition {
        guard !reduced else { return .opacity }
        return .asymmetric(insertion: .opacity.combined(with: .offset(y: 5)),
                           removal: .opacity.combined(with: .offset(y: -5)))
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notch.height)
            ZStack {
                switch phase {
                case .greeting: greeting.transition(phaseTransition)
                case .details: details.transition(phaseTransition)
                }
            }
            .padding(.horizontal, MorphSpacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            guard welcome.hasDetails else { return }
            let share = duration * Self.greetingShare
            try? await Task.sleep(for: max(share, Self.minimumGreeting))
            guard !Task.isCancelled else { return }
            withAnimation(phaseAnimation) { phase = .details }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var greeting: some View {
        HStack(spacing: MorphSpacing.m) {
            Image(systemName: greetingSymbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(accent)
                .symbolRenderingMode(.hierarchical)
            Text(welcome.greeting.text())
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(MorphColor.textPrimary)
                .lineLimit(1)
            Spacer(minLength: MorphSpacing.s)
            clock(font: .system(size: 15, weight: .medium).monospacedDigit(), color: MorphColor.textSecondary)
        }
    }

    private var details: some View {
        HStack(spacing: MorphSpacing.l) {
            clock(font: .system(size: 22, weight: .semibold, design: .rounded).monospacedDigit(), color: MorphColor.textPrimary)
            if let music = welcome.music {
                HStack(spacing: MorphSpacing.s) {
                    ArtworkView(data: media.artwork, size: 28, radius: 6)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(music.title)
                            .font(MorphFont.compact)
                            .foregroundStyle(MorphColor.textPrimary)
                        if !music.artist.isEmpty {
                            Text(music.artist)
                                .font(MorphFont.secondary)
                                .foregroundStyle(MorphColor.textSecondary)
                        }
                    }
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
            if let battery = welcome.battery {
                HStack(spacing: MorphSpacing.xs) {
                    Image(systemName: battery.symbol)
                        .foregroundStyle(battery.isCharging ? MorphColor.positive : MorphColor.textSecondary)
                    Text("\(battery.percentage)%")
                        .foregroundStyle(MorphColor.textPrimary)
                }
                .font(MorphFont.compact)
                .fixedSize()
            }
        }
    }

    private func clock(font: Font, color: Color) -> some View {
        TimelineView(.everyMinute) { context in
            Text(context.date, format: .dateTime.hour().minute())
                .font(font)
                .foregroundStyle(color)
                .fixedSize()
        }
    }

    private var greetingSymbol: String {
        switch welcome.greeting {
        case .morning: "sunrise.fill"
        case .afternoon: "sun.max.fill"
        case .evening: "moon.stars.fill"
        case .welcomeBack: "hand.wave.fill"
        }
    }

    private var accessibilityText: String {
        var parts = [welcome.greeting.text()]
        if let battery = welcome.battery {
            parts.append("Battery \(battery.percentage) percent\(battery.isCharging ? ", charging" : "")")
        }
        if let music = welcome.music {
            parts.append("\(music.isPlaying ? "Playing" : "Paused") \(music.title)")
        }
        return parts.joined(separator: ", ")
    }
}
