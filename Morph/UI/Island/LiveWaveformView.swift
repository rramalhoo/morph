import SwiftUI

/// The bars beside the notch. With real measurements they follow the music; otherwise this shows
/// something that can't be mistaken for them.
struct LiveWaveformView: View {
    private static let width: CGFloat = 18
    private static let height: CGFloat = 14

    @Environment(WaveformService.self) private var waveform
    @Environment(MorphPreferences.self) private var preferences
    @Environment(\.morphAccent) private var accent
    @Environment(\.morphMotion) private var motion

    var body: some View {
        if waveform.showsRealLevels, !motion.reduced {
            WaveformBars(levels: waveform.levels, color: accent)
                .frame(width: Self.width, height: Self.height)
        } else if preferences.waveformFallback == .decorative, !motion.reduced {
            // One slow wave across all bars, dimmed: plainly not tied to the audio.
            TimelineView(.animation(minimumInterval: 1.0 / 15)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                WaveformBars(levels: (0..<WaveformBarMapper.barCount).map { index in
                    Float(0.3 + 0.16 * sin(time * 1.6 + Double(index) * 0.7))
                }, color: accent.opacity(0.45))
            }
            .frame(width: Self.width, height: Self.height)
        } else {
            Image(systemName: "waveform").foregroundStyle(accent).font(MorphFont.compact)
        }
    }
}

struct WaveformBars: View {
    let levels: [Float]
    let color: Color

    var body: some View {
        Canvas { context, size in
            let gap: CGFloat = 1.5
            let count = CGFloat(levels.count)
            let width = (size.width - gap * (count - 1)) / count
            for (index, level) in levels.enumerated() {
                let height = max(width, size.height * CGFloat(min(max(level, 0), 1)))
                let rect = CGRect(x: CGFloat(index) * (width + gap), y: (size.height - height) / 2, width: width, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(color))
            }
        }
        .accessibilityHidden(true)
    }
}
