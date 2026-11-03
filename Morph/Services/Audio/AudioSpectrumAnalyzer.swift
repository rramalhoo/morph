import Accelerate
import Foundation

/// One analysis window, every value from 0 to 1.
struct SpectrumFrame: Equatable, Sendable {
    var bass: Float
    var mid: Float
    var treble: Float
    var overall: Float
    /// How sharply the low end just rose: beats, mostly.
    var transient: Float

    static let silent = SpectrumFrame(bass: 0, mid: 0, treble: 0, overall: 0, transient: 0)
}

/// Hann-windowed FFT reduced to bass, mid, treble and a transient measure.
///
/// Loudness varies enormously between tracks, so bands are scaled against recent peaks, which keeps
/// the bars expressive on a quiet ballad without flattening them on a loud master. A band's own peak
/// can't be the only reference, or spectral leakage from a single bass note would read as full-scale
/// mids. So each band is also held against the loudest band, allowing for music's natural tilt.
final class AudioSpectrumAnalyzer {
    static let size = 2048
    private static let log2Size = vDSP_Length(11)
    private static let bassRange: ClosedRange<Float> = 30...250
    private static let midRange: ClosedRange<Float> = 250...4000
    private static let trebleRange: ClosedRange<Float> = 4000...16000
    private static let silenceRMS: Float = 1e-5
    private static let floorDecibels: Float = -70
    private static let peakDecay: Float = 0.9995
    /// How far below the bass mids and treble typically sit in music, as a power ratio.
    private static let midTilt: Float = 0.1
    private static let trebleTilt: Float = 0.01
    /// A rise of this many decibels above the recent low-end level counts as a full transient.
    private static let transientRange: Float = 18

    private let setup: FFTSetup
    private let window: [Float]
    private var windowed = [Float](repeating: 0, count: size)
    private var real = [Float](repeating: 0, count: size / 2)
    private var imaginary = [Float](repeating: 0, count: size / 2)
    private var power = [Float](repeating: 0, count: size / 2)
    private var peaks = (bass: Float(1e-6), mid: Float(1e-6), treble: Float(1e-6))
    /// Recent low-end level in decibels. Measured before any scaling, which would hide the beat.
    private var bassLevel: Float?

    init() {
        setup = vDSP_create_fftsetup(Self.log2Size, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningNormalized, count: Self.size, isHalfWindow: false)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// `samples` must hold exactly `size` mono values.
    func analyze(_ samples: [Float], sampleRate: Float) -> SpectrumFrame {
        precondition(samples.count == Self.size)
        let rms = vDSP.rootMeanSquare(samples)
        guard rms > Self.silenceRMS else {
            bassLevel = nil
            return .silent
        }

        vDSP.multiply(samples, window, result: &windowed)
        transform()

        let binWidth = sampleRate / Float(Self.size)
        let bass = bandPower(Self.bassRange, binWidth: binWidth)
        let mid = bandPower(Self.midRange, binWidth: binWidth)
        let treble = bandPower(Self.trebleRange, binWidth: binWidth)

        peaks.bass = max(bass, peaks.bass * Self.peakDecay)
        peaks.mid = max(mid, peaks.mid * Self.peakDecay)
        peaks.treble = max(treble, peaks.treble * Self.peakDecay)

        let loudest = max(peaks.bass, peaks.mid, peaks.treble)
        return SpectrumFrame(bass: Self.normalize(bass, peak: peaks.bass),
                             mid: Self.normalize(mid, peak: max(peaks.mid, loudest * Self.midTilt)),
                             treble: Self.normalize(treble, peak: max(peaks.treble, loudest * Self.trebleTilt)),
                             overall: Self.normalize(rms * rms, peak: 0.25),
                             transient: transient(bass: bass))
    }

    private func transient(bass: Float) -> Float {
        let decibels = 10 * log10(max(bass, 1e-12))
        let previous = bassLevel ?? decibels
        bassLevel = previous + (decibels - previous) * 0.15
        return min(max((decibels - previous) / Self.transientRange, 0), 1)
    }

    private func transform() {
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBytes { bytes in
                    vDSP_ctoz(bytes.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(Self.size / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2Size, FFTDirection(kFFTDirection_Forward))
                split.imagp[0] = 0 // Packed Nyquist term, not part of the DC bin.
                power.withUnsafeMutableBufferPointer { powerPointer in
                    vDSP_zvmags(&split, 1, powerPointer.baseAddress!, 1, vDSP_Length(Self.size / 2))
                }
            }
        }
    }

    private func bandPower(_ range: ClosedRange<Float>, binWidth: Float) -> Float {
        let low = max(1, Int(range.lowerBound / binWidth))
        let high = min(power.count - 1, Int(range.upperBound / binWidth))
        guard high >= low else { return 0 }
        return vDSP.mean(power[low...high])
    }

    /// Decibels relative to `peak`, mapped so the top 42 dB fill the range with a gentle curve.
    private static func normalize(_ value: Float, peak: Float) -> Float {
        guard value > 0, peak > 0 else { return 0 }
        let decibels = 10 * log10(value / peak)
        let position = min(max(1 + decibels / 42, 0), 1)
        return position * position
    }
}

/// Maps audio onto the bars: bass in the center, mids around it, treble at the edges. Mirrored bars
/// mix their bands differently, so the shape isn't symmetric. Nothing here is random.
struct WaveformBarMapper: Sendable {
    static let barCount = 5
    static let restLevel: Float = 0.12
    private static let attack: Float = 0.62
    private static let decay: Float = 0.16
    /// Changes smaller than this are held still, which is what removes visual shimmer.
    private static let deadband: Float = 0.012

    var sensitivity: Float = 1
    private(set) var levels: [Float]

    init(starting levels: [Float] = [Float](repeating: restLevel, count: barCount)) {
        self.levels = levels
    }

    /// `frame` is nil when there's nothing to follow; the bars then settle at rest.
    @discardableResult
    mutating func advance(_ frame: SpectrumFrame?) -> [Float] {
        let targets = frame.map(self.targets) ?? [Float](repeating: Self.restLevel, count: Self.barCount)
        for index in levels.indices {
            let difference = targets[index] - levels[index]
            guard abs(difference) > Self.deadband else { continue }
            levels[index] += difference * (difference > 0 ? Self.attack : Self.decay)
        }
        return levels
    }

    var isAtRest: Bool {
        levels.allSatisfy { abs($0 - Self.restLevel) <= Self.deadband * 1.5 }
    }

    private func targets(_ frame: SpectrumFrame) -> [Float] {
        let punch = frame.transient * 0.35
        let raw = [
            frame.treble,
            frame.mid * 0.8 + frame.bass * 0.2 + punch * 0.4,
            frame.bass + punch,
            frame.mid * 0.7 + frame.treble * 0.3 + punch * 0.4,
            frame.treble * 0.75 + frame.mid * 0.25,
        ]
        return raw.map { min(Self.restLevel + $0 * sensitivity * (1 - Self.restLevel), 1) }
    }
}

/// Runs on the analysis queue: mono FIFO in, bar levels out, at no more than `publishRate`. Its
/// buffers are sized up front, so a steady stream of audio allocates nothing here.
final class WaveformPipeline {
    private static let hop = AudioSpectrumAnalyzer.size / 2
    private static let publishRate = 30.0
    /// Longer than any IO buffer Core Audio hands out. Anything beyond it is older than the window.
    private static let chunk = 4096

    private let analyzer = AudioSpectrumAnalyzer()
    private let sampleRate: Float
    private let onLevels: @Sendable ([Float], Bool) -> Void
    private var mapper = WaveformBarMapper()
    private var mono = [Float](repeating: 0, count: chunk)
    /// A ring, so appending never shifts memory.
    private var ring = [Float](repeating: 0, count: AudioSpectrumAnalyzer.size)
    private var ordered = [Float](repeating: 0, count: AudioSpectrumAnalyzer.size)
    private var writeIndex = 0
    private var pendingCount = 0
    private var lastPublish: TimeInterval = 0

    init(sampleRate: Double, sensitivity: Float, onLevels: @escaping @Sendable ([Float], Bool) -> Void) {
        self.sampleRate = Float(sampleRate)
        self.onLevels = onLevels
        mapper.sensitivity = sensitivity
    }

    func setSensitivity(_ value: Float) {
        mapper.sensitivity = value
    }

    /// `samples` are interleaved floats, mixed down here.
    func consume(_ samples: UnsafeBufferPointer<Float>, channels: Int) {
        let channels = max(channels, 1)
        let frames = min(samples.count / channels, Self.chunk)
        guard frames > 0 else { return }
        let skipped = samples.count / channels - frames

        for frame in 0..<frames {
            var sum: Float = 0
            let start = (skipped + frame) * channels
            for channel in 0..<channels { sum += samples[start + channel] }
            mono[frame] = sum / Float(channels)
        }
        mono.withUnsafeBufferPointer { ingest(UnsafeBufferPointer(rebasing: $0[0..<frames])) }
    }

    func append(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { ingest($0) }
    }

    private func ingest(_ samples: UnsafeBufferPointer<Float>) {
        for sample in samples.suffix(ring.count) {
            ring[writeIndex] = sample
            writeIndex = (writeIndex + 1) % ring.count
        }
        pendingCount += samples.count
        guard pendingCount >= Self.hop else { return }
        pendingCount = 0

        let tail = ring.count - writeIndex
        for index in 0..<ring.count {
            ordered[index] = ring[index < tail ? writeIndex + index : index - tail]
        }
        let frame = analyzer.analyze(ordered, sampleRate: sampleRate)
        let levels = mapper.advance(frame == .silent ? nil : frame)

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPublish >= 1 / Self.publishRate else { return }
        lastPublish = now
        onLevels(levels, frame != .silent)
    }
}
