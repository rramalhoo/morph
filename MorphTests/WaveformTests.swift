import Foundation
import Testing
@testable import Morph

private func tone(_ frequency: Float, amplitude: Float = 0.4, sampleRate: Float = 48_000, offset: Int = 0) -> [Float] {
    (0..<AudioSpectrumAnalyzer.size).map { amplitude * sin(2 * .pi * frequency * Float($0 + offset) / sampleRate) }
}

@Suite("Spectrum analysis")
struct SpectrumTests {
    @Test func silenceIsSilent() {
        let analyzer = AudioSpectrumAnalyzer()
        #expect(analyzer.analyze(.init(repeating: 0, count: AudioSpectrumAnalyzer.size), sampleRate: 48_000) == .silent)
    }

    @Test func lowToneLandsInBass() {
        let analyzer = AudioSpectrumAnalyzer()
        let frame = analyzer.analyze(tone(90), sampleRate: 48_000)
        #expect(frame.bass > 0.9)
        #expect(frame.bass > frame.mid)
    }

    @Test func midToneLandsInMids() {
        let analyzer = AudioSpectrumAnalyzer()
        var frame = SpectrumFrame.silent
        // Bass is established first, so the band peaks are meaningful.
        _ = analyzer.analyze(tone(90), sampleRate: 48_000)
        _ = analyzer.analyze(tone(8000), sampleRate: 48_000)
        frame = analyzer.analyze(tone(1000), sampleRate: 48_000)
        #expect(frame.mid > frame.bass)
        #expect(frame.mid > frame.treble)
    }

    @Test func highToneLandsInTreble() {
        let analyzer = AudioSpectrumAnalyzer()
        _ = analyzer.analyze(tone(90), sampleRate: 48_000)
        _ = analyzer.analyze(tone(1000), sampleRate: 48_000)
        let frame = analyzer.analyze(tone(8000), sampleRate: 48_000)
        #expect(frame.treble > frame.bass)
        #expect(frame.treble > frame.mid)
    }

    @Test func aKickReadsAsATransientAndSustainDoesNot() {
        let analyzer = AudioSpectrumAnalyzer()
        for _ in 0..<40 { _ = analyzer.analyze(tone(90, amplitude: 0.002), sampleRate: 48_000) }
        let kick = analyzer.analyze(tone(90, amplitude: 0.8), sampleRate: 48_000)
        #expect(kick.transient > 0.3)
        var sustained = kick
        for _ in 0..<60 { sustained = analyzer.analyze(tone(90, amplitude: 0.8), sampleRate: 48_000) }
        #expect(sustained.transient < 0.05)
    }

    @Test func worksAtOtherSampleRates() {
        let analyzer = AudioSpectrumAnalyzer()
        let frame = analyzer.analyze(tone(90, sampleRate: 44_100), sampleRate: 44_100)
        #expect(frame.bass > frame.mid)
    }
}

@Suite("Bar mapping")
struct BarMappingTests {
    private let loud = SpectrumFrame(bass: 1, mid: 0.5, treble: 0.1, overall: 0.8, transient: 0)

    @Test func bassDrivesTheCenterAndTrebleTheEdges() {
        var mapper = WaveformBarMapper()
        for _ in 0..<30 { mapper.advance(loud) }
        let levels = mapper.levels
        #expect(levels[2] > levels[1])
        #expect(levels[1] > levels[0])
        #expect(levels[3] > levels[4])
    }

    @Test func barsAreNeverAllTheSame() {
        var mapper = WaveformBarMapper()
        for _ in 0..<30 { mapper.advance(SpectrumFrame(bass: 0.6, mid: 0.6, treble: 0.2, overall: 0.5, transient: 0)) }
        #expect(Set(mapper.levels).count > 1)
    }

    @Test func attackIsFasterThanDecay() {
        var rising = WaveformBarMapper()
        let up = rising.advance(loud)[2]
        for _ in 0..<30 { rising.advance(loud) }
        let peak = rising.levels[2]
        let down = rising.advance(nil)[2]
        #expect(up - WaveformBarMapper.restLevel > (peak - down) * 2)
    }

    @Test func staysInRangeAtMaximumSensitivity() {
        var mapper = WaveformBarMapper()
        mapper.sensitivity = 2
        for _ in 0..<60 {
            for level in mapper.advance(SpectrumFrame(bass: 1, mid: 1, treble: 1, overall: 1, transient: 1)) {
                #expect((0...1).contains(level))
            }
        }
    }

    @Test func silenceReturnsToAStillRest() {
        var mapper = WaveformBarMapper()
        for _ in 0..<30 { mapper.advance(loud) }
        for _ in 0..<80 { mapper.advance(nil) }
        #expect(mapper.isAtRest)
        let settled = mapper.levels
        #expect(mapper.advance(nil) == settled, "At rest nothing moves, so nothing redraws")
    }

    @Test func smallFluctuationsDoNotShimmer() {
        var mapper = WaveformBarMapper()
        for _ in 0..<60 { mapper.advance(loud) }
        let settled = mapper.levels
        var jitter = loud
        jitter.bass = 0.995
        #expect(mapper.advance(jitter) == settled)
    }

    @Test func sameInputAlwaysGivesTheSameBars() {
        var first = WaveformBarMapper(), second = WaveformBarMapper()
        for _ in 0..<20 {
            #expect(first.advance(loud) == second.advance(loud))
        }
    }
}

@Suite("Waveform pipeline")
struct PipelineTests {
    @Test func samplesBecomeLevelsAndMixDownToMono() {
        nonisolated(unsafe) var published: [[Float]] = []
        let pipeline = WaveformPipeline(sampleRate: 48_000, sensitivity: 1) { levels, hasSignal in
            if hasSignal { published.append(levels) }
        }
        var interleaved = [Float]()
        for sample in tone(90) { interleaved += [sample, sample] }
        interleaved.withUnsafeBufferPointer { pipeline.consume($0, channels: 2) }
        #expect(published.count == 1)
        #expect(published[0][2] > WaveformBarMapper.restLevel)
    }

    @Test func publishingIsRateLimited() {
        nonisolated(unsafe) var count = 0
        let pipeline = WaveformPipeline(sampleRate: 48_000, sensitivity: 1) { _, _ in count += 1 }
        for index in 0..<100 { pipeline.append(tone(90, offset: index * 1024)) }
        #expect(count < 10, "100 analyses in a few milliseconds must not reach the UI 100 times")
    }
}

@Suite("Waveform service")
@MainActor
struct WaveformServiceTests {
    private let scheduler = ManualScheduler()
    private let capture = StubAudioCapture()
    private let demand = WaveformDemand(bundleIdentifier: "com.apple.Music", outputUID: "out", trackID: "1")

    private func started() async -> WaveformService {
        let service = WaveformService(capture: capture, scheduler: scheduler)
        service.update(demand: demand)
        await settle()
        return service
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    private func publish(_ levels: [Float] = [0.5, 0.6, 0.9, 0.6, 0.4], signal: Bool = true) async {
        capture.onLevels?(levels, signal)
        await settle()
    }

    @Test func noRealBarsAreClaimedBeforeRealAudioArrives() async {
        let service = await started()
        #expect(service.status == .connecting)
        #expect(!service.showsRealLevels)
        await publish()
        #expect(service.showsRealLevels)
        #expect(service.levels[2] == 0.9)
    }

    @Test func onlyDigitalSilenceMeansNoSignalAndCaptureStops() async {
        let service = await started()
        await publish([0.12, 0.12, 0.12, 0.12, 0.12], signal: false)
        scheduler.advance(by: .seconds(3))
        await settle()
        #expect(service.status == .noSignal)
        #expect(!service.showsRealLevels)
        #expect(capture.stopCount == 1, "Denied permission must not leave a tap running")

        service.update(demand: demand)
        #expect(capture.startCount == 1, "Same track: don't hammer the tap")
        var next = demand
        next.trackID = "2"
        service.update(demand: nil)
        scheduler.advance(by: .seconds(6))
        service.update(demand: next)
        #expect(capture.startCount == 2, "A new track retries")
    }

    @Test func startFailureIsReported() async {
        capture.startError = .noPlayerProcess
        let service = await started()
        #expect(service.status == .unavailable)
    }

    @Test func aNewTrackDoesNotRestartARunningTap() async {
        let service = await started()
        var next = demand
        next.trackID = "2"
        service.update(demand: next)
        #expect(capture.startCount == 1)
    }

    @Test func changingOutputRestartsTheTap() async {
        let service = await started()
        var next = demand
        next.outputUID = "airpods"
        service.update(demand: next)
        #expect(capture.startCount == 2)
    }

    @Test func pausingFadesToRestThenStopsCapture() async {
        let service = await started()
        await publish()
        service.update(demand: nil)
        scheduler.advance(by: .seconds(2))
        #expect(abs(service.levels[2] - WaveformBarMapper.restLevel) < 0.03)
        #expect(capture.stopCount == 0, "A short gap keeps the tap")
        scheduler.advance(by: .seconds(4))
        #expect(capture.stopCount == 1)
        #expect(scheduler.pendingCount == 0, "Nothing keeps ticking once still")
    }

    @Test func returningWithinTheGraceKeepsTheSameTap() async {
        let service = await started()
        await publish()
        service.update(demand: nil)
        scheduler.advance(by: .seconds(2))
        service.update(demand: demand)
        scheduler.advance(by: .seconds(10))
        #expect(capture.startCount == 1)
        #expect(capture.stopCount == 0)
    }

    @Test func lateLevelsFromAStoppedSessionAreIgnored() async {
        let service = await started()
        await publish()
        service.stopNow()
        scheduler.advance(by: .seconds(2))
        let settled = service.levels
        await publish()
        #expect(service.levels == settled)
        #expect(!service.isCapturing)
    }
}

@Suite("Brightness")
@MainActor
struct BrightnessTests {
    private struct Fixed: BrightnessReading {
        let value: Float?
        func read() -> Float? { value }
    }

    private func data(key: Int, state: Int) -> Int { key << 16 | state << 8 }

    @Test func recognizesOnlyBrightnessKeyDown() {
        #expect(LevelKeyPress(subtype: 8, data1: data(key: 2, state: 0xA)) == LevelKeyPress(key: .brightnessUp))
        #expect(LevelKeyPress(subtype: 8, data1: data(key: 3, state: 0xA)) == LevelKeyPress(key: .brightnessDown))
        #expect(LevelKeyPress(subtype: 8, data1: data(key: 3, state: 0xB)) == LevelKeyPress(key: .brightnessDown, isDown: false))
        #expect(LevelKeyPress(subtype: 8, data1: data(key: 0, state: 0xA)) == LevelKeyPress(key: .volumeUp))
        #expect(LevelKeyPress(subtype: 8, data1: data(key: 16, state: 0xA)) == nil, "Play/pause stays with macOS")
        #expect(LevelKeyPress(subtype: 7, data1: data(key: 2, state: 0xA)) == nil)
    }

    @Test func noReadingMeansNoPercentageNeverAnInventedOne() {
        let scheduler = ManualScheduler()
        let service = BrightnessService(reader: Fixed(value: nil), scheduler: scheduler)
        var received: [Int?] = []
        service.onChange = { _, percentage in received.append(percentage) }
        service.handle(subtype: 8, data1: data(key: 2, state: 0xA))
        scheduler.advance(by: .seconds(1))
        #expect(received == [nil])
        #expect(IslandActivity.Content.brightness(increased: true, percentage: nil).level == nil)
    }

    @Test func aRealReadingIsShown() {
        let scheduler = ManualScheduler()
        let service = BrightnessService(reader: Fixed(value: 0.75), scheduler: scheduler)
        var received: [Int?] = []
        service.onChange = { _, percentage in received.append(percentage) }
        service.handle(subtype: 8, data1: data(key: 3, state: 0xA))
        scheduler.advance(by: .seconds(1))
        #expect(received == [75])
    }

    @Test func thisMacsPublicReadingIsReportedHonestly() {
        print("Public brightness reading: \(IOKitBrightnessReader().read().map(String.init(describing:)) ?? "not available")")
    }
}
