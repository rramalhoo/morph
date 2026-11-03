import Foundation

enum WaveCaptureState: String, Equatable, Sendable {
    case idle
    /// The first capture this run. macOS decides on permission during it and never reports the
    /// answer, so it counts as waiting until real sound proves access.
    case requestingPermission
    case starting
    case capturing
    /// Waiting out a backoff before trying again.
    case recovering
    /// Won't try again until the music moves on.
    case unavailable
    case stopped
}

enum WaveCaptureEvent: Equatable, Sendable {
    /// Something wants the bars, or what they follow changed.
    case demanded
    case started
    case startFailed(retryable: Bool)
    case heardSignal
    /// No buffers are arriving: the capture has stopped, as opposed to the music being quiet.
    case stalled
    /// The player's processes changed under the tap. This isn't a failure of the capture.
    case targetChanged
    /// Buffers keep arriving, but none has ever held sound.
    case neverHeardSound
    case retryElapsed
    case released
}

enum WaveCaptureEffect: Equatable, Sendable {
    case startCapture
    case stopCapture
    case scheduleRetry(Duration)
    case cancelRetry
}

/// The rules of the capture's life, free of timers and Core Audio. `WaveformService` turns effects
/// into work and feeds what happened back in.
///
/// Starting is idempotent: `demanded` does nothing while a capture is running or on its way.
/// Silence is not an event here at all, so a quiet passage can never cause a restart.
struct WaveCaptureMachine: Sendable {
    /// Consecutive failures before giving up. Real sound resets the count.
    static let maximumAttempts = 6
    private static let firstDelay = Duration.milliseconds(500)
    private static let longestDelay = Duration.seconds(30)

    private(set) var state = WaveCaptureState.idle
    /// Lifetime total, for diagnostics.
    private(set) var recoveries = 0
    private(set) var attempts = 0
    private(set) var hasHeardSound = false

    var isCapturing: Bool { state == .capturing || state == .requestingPermission }

    static func delay(forAttempt attempt: Int) -> Duration {
        min(firstDelay * (1 << min(max(attempt - 1, 0), 10)), longestDelay)
    }

    mutating func handle(_ event: WaveCaptureEvent) -> [WaveCaptureEffect] {
        switch event {
        case .demanded:
            switch state {
            case .idle, .stopped, .unavailable:
                attempts = 0
                return begin()
            case .starting, .capturing, .requestingPermission, .recovering:
                return []
            }

        case .started:
            guard state == .starting else { return [] }
            state = hasHeardSound ? .capturing : .requestingPermission
            return []

        case .startFailed(let retryable):
            guard state == .starting else { return [] }
            return retryable ? recover() : giveUp()

        case .heardSignal:
            guard isCapturing else { return [] }
            state = .capturing
            hasHeardSound = true
            attempts = 0
            return []

        case .stalled:
            guard isCapturing else { return [] }
            return [.stopCapture] + recover()

        case .targetChanged:
            guard isCapturing else { return [] }
            return [.stopCapture] + begin()

        case .neverHeardSound:
            guard state == .requestingPermission else { return [] }
            return [.stopCapture] + giveUp()

        case .retryElapsed:
            guard state == .recovering else { return [] }
            return begin()

        case .released:
            let wasRunning = state == .starting || isCapturing
            let wasWaiting = state == .recovering
            attempts = 0
            state = .stopped
            return (wasRunning ? [.stopCapture] : []) + (wasWaiting ? [.cancelRetry] : [])
        }
    }

    private mutating func begin() -> [WaveCaptureEffect] {
        state = .starting
        return [.startCapture]
    }

    private mutating func recover() -> [WaveCaptureEffect] {
        attempts += 1
        guard attempts < Self.maximumAttempts else { return giveUp() }
        recoveries += 1
        state = .recovering
        return [.scheduleRetry(Self.delay(forAttempt: attempts))]
    }

    private mutating func giveUp() -> [WaveCaptureEffect] {
        state = .unavailable
        return []
    }
}
