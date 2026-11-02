import SwiftUI

struct TimersTabView: View {
    var body: some View {
        HStack(spacing: MorphSpacing.s) {
            CountdownCard()
            StopwatchCard()
        }
    }
}

private struct CountdownCard: View {
    private static let presets = [1, 5, 10, 25]

    @Environment(TimerService.self) private var timers

    var body: some View {
        MorphCard {
            VStack(alignment: .leading, spacing: MorphSpacing.s) {
                Text("TIMER").font(MorphFont.label).foregroundStyle(MorphColor.textSecondary)
                switch timers.countdown.phase {
                case .idle, .finished:
                    Spacer(minLength: 0)
                    Text(isFinished ? "Done" : "Choose a duration")
                        .font(MorphFont.primary)
                        .foregroundStyle(MorphColor.textPrimary)
                    HStack(spacing: MorphSpacing.xs) {
                        ForEach(Self.presets, id: \.self) { minutes in
                            MorphTextButton(title: "\(minutes)m") { timers.startCountdown(.seconds(minutes * 60)) }
                                .accessibilityLabel("Start \(minutes) minute timer")
                        }
                    }
                case .running, .paused:
                    Spacer(minLength: 0)
                    TimelineView(.periodic(from: .now, by: timers.countdown.isRunning ? 1 : 3600)) { _ in
                        Text(TimeFormat.countdown(timers.countdown.remaining(at: timers.now).timeInterval))
                            .font(MorphFont.timer)
                            .foregroundStyle(MorphColor.textPrimary)
                            .contentTransition(.numericText(countsDown: true))
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: MorphSpacing.xs) {
                        if timers.countdown.isRunning {
                            MorphIconButton(symbol: "pause.fill", label: "Pause Timer", action: timers.pauseCountdown)
                        } else {
                            MorphIconButton(symbol: "play.fill", label: "Resume Timer", action: timers.resumeCountdown)
                        }
                        MorphIconButton(symbol: "arrow.counterclockwise", label: "Reset Timer", action: timers.resetCountdown)
                    }
                }
            }
        }
    }

    private var isFinished: Bool { timers.countdown.phase == .finished }
}

private struct StopwatchCard: View {
    @Environment(TimerService.self) private var timers

    var body: some View {
        MorphCard {
            VStack(alignment: .leading, spacing: MorphSpacing.s) {
                Text("STOPWATCH").font(MorphFont.label).foregroundStyle(MorphColor.textSecondary)
                Spacer(minLength: 0)
                TimelineView(.periodic(from: .now, by: timers.stopwatch.isRunning ? 0.1 : 3600)) { _ in
                    Text(TimeFormat.stopwatch(timers.stopwatch.elapsed(at: timers.now).timeInterval))
                        .font(MorphFont.timer)
                        .foregroundStyle(MorphColor.textPrimary)
                }
                Spacer(minLength: 0)
                HStack(spacing: MorphSpacing.xs) {
                    if timers.stopwatch.isRunning {
                        MorphIconButton(symbol: "pause.fill", label: "Pause Stopwatch", action: timers.pauseStopwatch)
                    } else {
                        MorphIconButton(symbol: "play.fill", label: "Start Stopwatch", action: timers.startStopwatch)
                    }
                    MorphIconButton(symbol: "arrow.counterclockwise", label: "Reset Stopwatch", action: timers.resetStopwatch)
                }
            }
        }
    }
}
