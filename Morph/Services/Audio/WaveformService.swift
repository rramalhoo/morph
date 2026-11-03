import Foundation
import Observation
import os

/// What the capture should follow right now.
struct WaveformDemand: Equatable, Sendable {
    var bundleIdentifier: String
    var outputUID: String
    /// Changes per track, so a capture that gave up is retried when the music moves on.
    var trackID: String
}

/// Hands the newest levels to the main thread. Anything the main thread hasn't reached yet is
/// replaced rather than queued, so a busy moment can't build up a backlog of work.
private final class LevelMailbox: Sendable {
    private struct Slot {
        var levels: [Float]?
        var hasSignal = false
    }

    private let slot = OSAllocatedUnfairLock(initialState: Slot())

    func post(_ levels: [Float], hasSignal: Bool, deliver: @escaping @MainActor @Sendable ([Float], Bool) -> Void) {
        let wasEmpty = slot.withLock { state -> Bool in
            let empty = state.levels == nil
            state = Slot(levels: levels, hasSignal: hasSignal)
            return empty
        }
        guard wasEmpty else { return }
        DispatchQueue.main.async { [self] in
            let latest = slot.withLock { state -> Slot in
                defer { state.levels = nil }
                return state
            }
            if let levels = latest.levels {
                MainActor.assumeIsolated { deliver(levels, latest.hasSignal) }
            }
        }
    }
}

/// Owns the capture's lifetime and publishes bar levels. Capture only runs while bars are on screen
/// and music is playing, and it's never left on to wait.
@MainActor
@Observable
final class WaveformService {
    private static let startTimeout = Duration.seconds(5)
    /// Bridges short gaps such as an activity passing over, without restarting the tap.
    private static let stopGrace = Duration.seconds(5)
    private static let fadeInterval = Duration.milliseconds(33)
    private static let healthInterval = Duration.seconds(2)
    /// No buffers for this long means the capture stopped, whatever the music is doing.
    private static let stallLimit = Duration.seconds(4)
    /// Quiet for this long, on the off chance the player moved to new processes.
    private static let quietCheck = Duration.seconds(6)
    /// Buffers of pure silence for this long, from a capture that has never heard anything. This
    /// is what a denied permission looks like, and also a very long silent intro.
    private static let soundTimeout = Duration.seconds(20)

    private(set) var levels = [Float](repeating: WaveformBarMapper.restLevel, count: WaveformBarMapper.barCount)
    private(set) var state = WaveCaptureState.idle
    /// The last audio had sound in it. Quiet music stays `capturing` with this off.
    private(set) var hasSignal = false
    private(set) var lastError: String?
    private(set) var recoveries = 0

    /// Bars are following real measurements, including settling during a quiet passage.
    var showsRealLevels: Bool { state == .capturing && heardSoundThisCapture }

    var sensitivity: Float = 1 {
        didSet {
            guard sensitivity != oldValue else { return }
            capture.setSensitivity(sensitivity)
        }
    }

    @ObservationIgnored private let capture: any AudioCapturing
    @ObservationIgnored private let scheduler: any Scheduling
    @ObservationIgnored private let mailbox = LevelMailbox()
    @ObservationIgnored private var machine = WaveCaptureMachine()
    @ObservationIgnored private var demand: WaveformDemand?
    /// The track that was playing when the capture gave up.
    @ObservationIgnored private var abandonedTrack: String?
    /// Nothing needs the bars right now, but the tap stays up for a moment in case that changes.
    @ObservationIgnored private var isLingering = false
    private var heardSoundThisCapture = false
    /// Identifies one running capture. Callbacks from any earlier one are stale.
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var startWork: (any ScheduledWork)?
    @ObservationIgnored private var retryWork: (any ScheduledWork)?
    @ObservationIgnored private var stopWork: (any ScheduledWork)?
    @ObservationIgnored private var fadeWork: (any ScheduledWork)?
    @ObservationIgnored private var healthWork: (any ScheduledWork)?
    @ObservationIgnored private var fader = WaveformBarMapper()
    @ObservationIgnored private var lastBufferCount: UInt64 = 0
    @ObservationIgnored private var lastBufferAt: ContinuousClock.Instant?
    @ObservationIgnored private var lastSignalAt: ContinuousClock.Instant?
    @ObservationIgnored private var captureStartedAt: ContinuousClock.Instant?

    init(capture: any AudioCapturing, scheduler: any Scheduling) {
        self.capture = capture
        self.scheduler = scheduler
    }

    var isCapturing: Bool { demand != nil }

    /// A line for Settings and the diagnostics report.
    var diagnostics: String {
        let age = lastBufferAt.map { String(format: "%.1fs ago", $0.duration(to: scheduler.now).timeInterval) } ?? "never"
        return "state \(state.rawValue), signal \(hasSignal), last buffer \(age), recoveries \(recoveries), last error \(lastError ?? "none")"
    }

    /// Call whenever what should be followed changes. `nil` means nothing needs the bars.
    func update(demand wanted: WaveformDemand?) {
        guard let wanted else {
            scheduleStop()
            return
        }
        stopWork?.cancel()
        stopWork = nil
        isLingering = false

        let isSameTarget = wanted.bundleIdentifier == demand?.bundleIdentifier && wanted.outputUID == demand?.outputUID
        let isNewTrack = wanted.trackID != abandonedTrack
        demand = wanted

        if !isSameTarget, machine.isCapturing || machine.state == .starting || machine.state == .recovering {
            send(.released)
        }
        if machine.state == .unavailable, isSameTarget, !isNewTrack { return }
        send(.demanded)
    }

    /// Shuts down at once: sleep, pausing Morph, or the feature being turned off.
    func stopNow() {
        stopWork?.cancel()
        stopWork = nil
        isLingering = false
        demand = nil
        abandonedTrack = nil
        send(.released)
        fadeOut()
    }

    func receive(_ newLevels: [Float], hasSignal signal: Bool, session current: Int) {
        guard current == session else { return }
        if signal {
            lastSignalAt = scheduler.now
            if !heardSoundThisCapture { heardSoundThisCapture = true }
            send(.heardSignal)
        }
        if hasSignal != signal { hasSignal = signal }
        if !isLingering, machine.isCapturing { levels = newLevels }
    }

    func finishStarting(error: AudioCaptureError?, session current: Int) {
        guard current == session else { return }
        startWork?.cancel()
        startWork = nil
        if let error {
            lastError = error.summary
            send(.startFailed(retryable: error.isRetryable))
        } else {
            send(.started)
        }
    }

    // MARK: - State

    private func send(_ event: WaveCaptureEvent) {
        let effects = machine.handle(event)
        effects.forEach(perform)
        if state != machine.state { state = machine.state }
        if recoveries != machine.recoveries { recoveries = machine.recoveries }

        if machine.isCapturing {
            if healthWork == nil { scheduleHealthCheck() }
        } else {
            healthWork?.cancel()
            healthWork = nil
        }
        if machine.state == .unavailable {
            abandonedTrack = demand?.trackID
            fadeOut()
        } else if machine.state == .stopped {
            hasSignal = false
            heardSoundThisCapture = false
        }
    }

    private func perform(_ effect: WaveCaptureEffect) {
        switch effect {
        case .startCapture: begin()
        case .stopCapture: endCapture()
        case .scheduleRetry(let delay):
            retryWork?.cancel()
            retryWork = scheduler.schedule(after: delay) { [weak self] in
                self?.retryWork = nil
                self?.send(.retryElapsed)
            }
        case .cancelRetry:
            retryWork?.cancel()
            retryWork = nil
        }
    }

    private func begin() {
        guard let demand else {
            send(.released)
            return
        }
        session += 1
        let current = session
        fadeWork?.cancel()
        fadeWork = nil
        heardSoundThisCapture = false
        lastBufferCount = 0
        lastBufferAt = nil
        let now = scheduler.now
        captureStartedAt = now
        lastSignalAt = now
        let mailbox = mailbox

        // Setup can hang inside Core Audio. It counts as a failed start, not a capture in progress.
        startWork?.cancel()
        startWork = scheduler.schedule(after: Self.startTimeout) { [weak self] in
            guard let self, self.session == current else { return }
            self.finishStarting(error: .hardware(-1), session: current)
        }
        capture.start(bundleIdentifier: demand.bundleIdentifier, outputUID: demand.outputUID, sensitivity: sensitivity,
                      onLevels: { [weak self] levels, hasSignal in
                          mailbox.post(levels, hasSignal: hasSignal) { levels, signal in
                              self?.receive(levels, hasSignal: signal, session: current)
                          }
                      },
                      completion: { [weak self] error in
                          DispatchQueue.main.async {
                              MainActor.assumeIsolated { self?.finishStarting(error: error, session: current) }
                          }
                      })
    }

    private func endCapture() {
        session += 1
        startWork?.cancel()
        startWork = nil
        capture.stop()
    }

    // MARK: - Watching over the capture

    private func scheduleHealthCheck() {
        healthWork = scheduler.schedule(after: Self.healthInterval) { [weak self] in
            guard let self else { return }
            self.healthWork = nil
            let current = self.session
            self.capture.checkHealth { [weak self] health in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.review(health, session: current) }
                }
            }
        }
    }

    func review(_ health: AudioCaptureHealth, session current: Int) {
        guard current == session, machine.isCapturing else { return }
        let now = scheduler.now
        if health.bufferCount != lastBufferCount {
            lastBufferCount = health.bufferCount
            lastBufferAt = now
        }

        let lastSeen = lastBufferAt ?? captureStartedAt ?? now
        let quietFor = (lastSignalAt ?? now).duration(to: now)
        if lastSeen.duration(to: now) >= Self.stallLimit {
            lastError = "No audio buffers for \(Int(Self.stallLimit.timeInterval)) seconds"
            send(.stalled)
        } else if quietFor >= Self.quietCheck, !health.followsPlayer {
            send(.targetChanged)
        } else if !heardSoundThisCapture, !machine.hasHeardSound, quietFor >= Self.soundTimeout {
            lastError = "Only silence received. Check the audio capture permission."
            send(.neverHeardSound)
        }
        if machine.isCapturing, healthWork == nil { scheduleHealthCheck() }
    }

    // MARK: - Letting go

    private func scheduleStop() {
        guard demand != nil else { return }
        guard !isLingering else { return }
        // Bars fall back to rest at once; the tap lingers in case the music returns.
        isLingering = true
        fadeOut()
        stopWork = scheduler.schedule(after: Self.stopGrace) { [weak self] in
            guard let self else { return }
            self.stopWork = nil
            self.isLingering = false
            self.demand = nil
            self.abandonedTrack = nil
            self.send(.released)
        }
    }

    /// Lets the bars come down smoothly, then stops ticking and stays still.
    private func fadeOut() {
        fader = WaveformBarMapper(starting: levels)
        fadeWork?.cancel()
        tickFade()
    }

    private func tickFade() {
        levels = fader.advance(nil)
        guard !fader.isAtRest else {
            fadeWork = nil
            return
        }
        fadeWork = scheduler.schedule(after: Self.fadeInterval) { [weak self] in self?.tickFade() }
    }
}
