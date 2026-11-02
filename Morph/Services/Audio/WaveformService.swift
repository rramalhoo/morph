import Foundation
import Observation

/// What the capture should follow right now.
struct WaveformDemand: Equatable, Sendable {
    var bundleIdentifier: String
    var outputUID: String
    /// Changes per track, so a failed attempt is retried when the music moves on.
    var trackID: String
}

/// Owns the capture's lifetime and publishes bar levels. Capture only runs while bars are on screen
/// and music is playing, and it's never left on to wait.
@MainActor
@Observable
final class WaveformService {
    enum Status: Equatable, Sendable {
        case off
        case connecting
        case live
        /// Capture ran, but only digital silence arrived. Permission denied looks exactly like this:
        /// macOS offers no public way to ask, so it's treated as "nothing analyzable".
        case noSignal
        case unavailable
    }

    private static let signalTimeout = Duration.seconds(3)
    /// Bridges short gaps such as an activity passing over, without restarting the tap.
    private static let stopGrace = Duration.seconds(5)
    private static let fadeInterval = Duration.milliseconds(33)

    private(set) var levels = [Float](repeating: WaveformBarMapper.restLevel, count: WaveformBarMapper.barCount)
    private(set) var status = Status.off

    /// Real measurements are on screen, or settling after them.
    var showsRealLevels: Bool { status == .live }

    var sensitivity: Float = 1 {
        didSet {
            guard sensitivity != oldValue else { return }
            capture.setSensitivity(sensitivity)
        }
    }

    @ObservationIgnored private let capture: any AudioCapturing
    @ObservationIgnored private let scheduler: any Scheduling
    @ObservationIgnored private var demand: WaveformDemand?
    @ObservationIgnored private var failedDemand: WaveformDemand?
    @ObservationIgnored private var signalWork: (any ScheduledWork)?
    @ObservationIgnored private var stopWork: (any ScheduledWork)?
    @ObservationIgnored private var fadeWork: (any ScheduledWork)?
    @ObservationIgnored private var fader = WaveformBarMapper()
    @ObservationIgnored private var session = 0

    init(capture: any AudioCapturing, scheduler: any Scheduling) {
        self.capture = capture
        self.scheduler = scheduler
    }

    var isCapturing: Bool { demand != nil }

    /// Call whenever what should be followed changes. `nil` means nothing needs the bars.
    func update(demand wanted: WaveformDemand?) {
        guard let wanted else {
            scheduleStop()
            return
        }
        stopWork?.cancel()
        stopWork = nil
        guard wanted != failedDemand else { return }

        let needsRestart = wanted.bundleIdentifier != demand?.bundleIdentifier || wanted.outputUID != demand?.outputUID
        demand = wanted
        if needsRestart { begin(wanted) }
    }

    /// Shuts down at once: sleep, pausing Morph, or the feature being turned off.
    func stopNow() {
        stopCapture()
        failedDemand = nil
        fadeOut()
    }

    private func begin(_ wanted: WaveformDemand) {
        session += 1
        let current = session
        fadeWork?.cancel()
        status = .connecting
        capture.start(bundleIdentifier: wanted.bundleIdentifier, outputUID: wanted.outputUID, sensitivity: sensitivity,
                      onLevels: { [weak self] levels, hasSignal in
                          Task { @MainActor in self?.receive(levels, hasSignal: hasSignal, session: current) }
                      },
                      completion: { [weak self] error in
                          Task { @MainActor in self?.finishStarting(error: error, session: current) }
                      })
    }

    func finishStarting(error: AudioCaptureError?, session current: Int) {
        guard current == session else { return }
        if error != nil {
            fail(.unavailable)
            return
        }
        signalWork?.cancel()
        signalWork = scheduler.schedule(after: Self.signalTimeout) { [weak self] in
            guard let self, self.session == current, self.status == .connecting else { return }
            self.fail(.noSignal)
        }
    }

    func receive(_ levels: [Float], hasSignal: Bool, session current: Int) {
        guard current == session else { return }
        if hasSignal, status != .live {
            status = .live
            signalWork?.cancel()
            signalWork = nil
        }
        if status == .live { self.levels = levels }
    }

    /// Stops trying until the track changes, instead of capturing silence indefinitely.
    private func fail(_ reason: Status) {
        failedDemand = demand
        stopCapture()
        status = reason
    }

    private func scheduleStop() {
        guard demand != nil, stopWork == nil else {
            if demand == nil { failedDemand = nil }
            return
        }
        // Bars fall back to rest at once; the tap lingers in case the music returns.
        fadeOut()
        stopWork = scheduler.schedule(after: Self.stopGrace) { [weak self] in
            self?.stopWork = nil
            self?.stopCapture()
            self?.failedDemand = nil
        }
    }

    private func stopCapture() {
        session += 1
        signalWork?.cancel()
        signalWork = nil
        stopWork?.cancel()
        stopWork = nil
        if demand != nil { capture.stop() }
        demand = nil
        if status == .connecting { status = .off }
    }

    /// Lets the bars come down smoothly, then stops ticking and stays still.
    private func fadeOut() {
        session += 1
        fader = WaveformBarMapper(starting: levels)
        fadeWork?.cancel()
        tickFade()
    }

    private func tickFade() {
        levels = fader.advance(nil)
        guard !fader.isAtRest else {
            fadeWork = nil
            if demand == nil, status == .live { status = .off }
            return
        }
        fadeWork = scheduler.schedule(after: Self.fadeInterval) { [weak self] in self?.tickFade() }
    }
}
