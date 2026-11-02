import AppKit
import SwiftUI

/// The shared animation vocabulary. With reduced motion, everything becomes a short fade.
struct MorphMotion: Equatable, Sendable {
    var intensity: AnimationIntensity
    var reduced: Bool

    private var bounce: Double {
        switch intensity {
        case .subtle: 0.02
        case .standard: 0.14
        case .expressive: 0.26
        }
    }

    /// Growing: a spring with some life in it.
    var expansion: Animation {
        reduced ? .easeInOut(duration: 0.14) : .spring(duration: 0.44, bounce: bounce)
    }

    /// Shrinking: quicker and settled, so the island feels like it returns to rest.
    var contraction: Animation {
        reduced ? .easeInOut(duration: 0.14) : .spring(duration: 0.36, bounce: bounce * 0.3)
    }

    var contentCrossfade: Animation { .easeInOut(duration: reduced ? 0.1 : 0.18) }
    var activityEntrance: Animation { reduced ? contentCrossfade : .spring(duration: 0.38, bounce: bounce) }
    var progress: Animation { reduced ? .linear(duration: 0) : .linear(duration: 0.25) }
    /// A level bar answers immediately and never overshoots its real value.
    var levelFill: Animation { reduced ? .linear(duration: 0) : .spring(duration: 0.22, bounce: 0) }
    var levelReveal: Animation { reduced ? contentCrossfade : .spring(duration: 0.4, bounce: 0.1).delay(0.06) }
    var levelConclude: Animation { .easeOut(duration: 0.26) }
    var artwork: Animation { reduced ? contentCrossfade : .spring(duration: 0.4, bounce: 0.08) }
    var press: Animation { .spring(duration: 0.18, bounce: 0.2) }

    /// Content entering or leaving a morphing island.
    var contentTransition: AnyTransition {
        guard !reduced else { return .opacity }
        return .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.08))
                .combined(with: .scale(scale: 0.96, anchor: .top)),
            removal: .opacity.animation(.easeIn(duration: 0.1))
        )
    }

    @MainActor
    static func resolve(_ preferences: MorphPreferences, systemReduced: Bool) -> MorphMotion {
        let reduced = switch preferences.reducedMotion {
        case .system: systemReduced
        case .always: true
        case .never: false
        }
        return MorphMotion(intensity: preferences.animationIntensity, reduced: reduced)
    }

    /// How long the window must stay large for a contraction to finish.
    @MainActor
    static func settleDuration(preferences: MorphPreferences) -> Duration {
        let systemReduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        return resolve(preferences, systemReduced: systemReduced).reduced ? .milliseconds(180) : .milliseconds(460)
    }
}

/// Press feedback for every control in the island.
struct MorphPressStyle: ButtonStyle {
    @Environment(\.morphMotion) private var motion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !motion.reduced ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(motion.press, value: configuration.isPressed)
    }
}
