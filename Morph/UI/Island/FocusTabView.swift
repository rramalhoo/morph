import SwiftUI

struct FocusTabView: View {
    var body: some View {
        HStack(spacing: MorphSpacing.s) {
            PomodoroCard()
            MorphFocusCard().frame(width: 176)
        }
    }
}

private struct PomodoroCard: View {
    @Environment(FocusService.self) private var focus

    private var session: PomodoroSession { focus.session }

    var body: some View {
        MorphCard {
            VStack(alignment: .leading, spacing: MorphSpacing.s) {
                Text(session.isActive ? session.phase.title.uppercased() : "POMODORO")
                    .font(MorphFont.label)
                    .foregroundStyle(MorphColor.textSecondary)
                Spacer(minLength: 0)
                TimelineView(.periodic(from: .now, by: session.timer.isRunning ? 1 : 3600)) { _ in
                    VStack(alignment: .leading, spacing: MorphSpacing.s) {
                        Text(TimeFormat.countdown(remaining.timeInterval))
                            .font(MorphFont.timer)
                            .foregroundStyle(MorphColor.textPrimary)
                            .contentTransition(.numericText(countsDown: true))
                        LevelBar(fraction: session.fraction(at: focus.now))
                            .opacity(session.isActive ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                }
                Spacer(minLength: 0)
                controls
            }
        }
    }

    private var remaining: Duration {
        session.isActive ? session.timer.remaining(at: focus.now) : focus.configuration.focus
    }

    private var controls: some View {
        HStack(spacing: MorphSpacing.xs) {
            if !session.isActive {
                MorphTextButton(title: "Start Focus", isProminent: true, action: focus.startFocus)
            } else {
                if session.timer.isRunning {
                    MorphIconButton(symbol: "pause.fill", label: "Pause", action: focus.pause)
                } else {
                    MorphIconButton(symbol: "play.fill", label: "Resume", action: focus.resume)
                }
                MorphIconButton(symbol: "forward.end.fill", label: "Skip", action: focus.skip)
                MorphIconButton(symbol: "stop.fill", label: "End Session", action: focus.stop)
            }
            Spacer(minLength: 0)
            Text("\(session.completedFocus)/\(focus.configuration.cycles)")
                .font(MorphFont.label.monospacedDigit())
                .foregroundStyle(MorphColor.textSecondary)
                .accessibilityLabel("\(session.completedFocus) of \(focus.configuration.cycles) focus sessions done")
        }
    }
}

private struct MorphFocusCard: View {
    @Environment(FocusService.self) private var focus

    var body: some View {
        MorphCard {
            VStack(alignment: .leading, spacing: MorphSpacing.xs) {
                Text("MORPH FOCUS")
                    .font(MorphFont.label)
                    .foregroundStyle(MorphColor.textSecondary)
                Text(focus.isQuiet ? "Quiet island" : "Off")
                    .font(MorphFont.primary)
                    .foregroundStyle(MorphColor.textPrimary)
                Text("Separate from macOS Focus, which Morph can't read.")
                    .font(MorphFont.label)
                    .foregroundStyle(MorphColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                MorphTextButton(title: focus.isMorphFocusOn ? "Turn Off" : "Turn On", isProminent: !focus.isMorphFocusOn) {
                    focus.setMorphFocus(!focus.isMorphFocusOn)
                }
            }
        }
    }
}
