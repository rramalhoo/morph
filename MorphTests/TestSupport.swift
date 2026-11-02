import CoreGraphics
import Foundation
@testable import Morph

/// Deterministic time: nothing fires until a test advances the clock.
@MainActor
final class ManualScheduler: Scheduling {
    private final class Work: ScheduledWork {
        let due: ContinuousClock.Instant
        let action: @MainActor () -> Void
        var isCancelled = false

        init(due: ContinuousClock.Instant, action: @escaping @MainActor () -> Void) {
            self.due = due
            self.action = action
        }

        func cancel() { isCancelled = true }
    }

    private(set) var now = ContinuousClock.now
    private var queue: [Work] = []

    var pendingCount: Int { queue.filter { !$0.isCancelled }.count }

    @discardableResult
    func schedule(after delay: Duration, _ work: @escaping @MainActor () -> Void) -> any ScheduledWork {
        let item = Work(due: now.advanced(by: delay), action: work)
        queue.append(item)
        return item
    }

    func advance(by duration: Duration) {
        let target = now.advanced(by: duration)
        while let next = queue.filter({ !$0.isCancelled && $0.due <= target }).min(by: { $0.due < $1.due }) {
            queue.removeAll { $0 === next }
            now = next.due
            next.action()
        }
        queue.removeAll(where: \.isCancelled)
        now = target
    }
}

/// Spins the main actor until a detached effect lands.
@MainActor
func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

let sessionIsLocked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false

/// A throwaway defaults domain.
func makeDefaults() -> UserDefaults {
    let name = "com.athene.morph.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@MainActor
final class StubMediaEvents: MediaEventSource {
    var onChange: (@MainActor () -> Void)?
    private(set) var isRunning = false

    func start(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        isRunning = true
    }

    func stop() {
        onChange = nil
        isRunning = false
    }
}

final class StubMediaProvider: MediaProvider, @unchecked Sendable {
    let kind: MediaProviderKind
    var availabilityResult = MediaAvailability.available
    var playback: Result<PlaybackSnapshot?, MediaError> = .success(nil)
    var artworkResult: Result<Data?, MediaError> = .success(nil)
    var commandResult: Result<Void, MediaError> = .success(())
    var commands: [String] = []

    init(_ kind: MediaProviderKind) {
        self.kind = kind
    }

    func availability() async -> MediaAvailability { availabilityResult }

    func requestAuthorization() async -> MediaAvailability {
        availabilityResult = .available
        return availabilityResult
    }

    func currentPlayback() async throws -> PlaybackSnapshot? { try playback.get() }
    func artwork(for track: Track) async throws -> Data? { try artworkResult.get() }

    private func record(_ command: String) throws {
        commands.append(command)
        try commandResult.get()
    }

    func playPause() async throws { try record("playPause") }
    func nextTrack() async throws { try record("next") }
    func previousTrack() async throws { try record("previous") }
    func seek(to position: TimeInterval) async throws { try record("seek \(position)") }
    func setVolume(_ volume: Int) async throws { try record("volume \(volume)") }

    func snapshot(_ state: PlaybackState, id: String = "1", title: String = "Song") -> PlaybackSnapshot {
        PlaybackSnapshot(provider: kind, state: state,
                         track: Track(id: id, title: title, artist: "Artist", album: "Album", duration: 200),
                         position: 10, capturedAt: .now)
    }
}

final class StubOutputSystem: AudioOutputSystem, @unchecked Sendable {
    var state: OutputState?
    var devices: [AudioOutputDevice] = []
    var writes: [String] = []
    var isObserving = false

    func currentOutput() -> OutputState? { state }
    func outputDevices() -> [AudioOutputDevice] { devices }
    func setVolume(_ volume: Float, device: UInt32) -> Bool { writes.append("volume \(volume)"); return true }
    func setMuted(_ muted: Bool, device: UInt32) -> Bool { writes.append("muted \(muted)"); return true }
    func startObserving(onChange: @escaping @Sendable () -> Void) { isObserving = true }
    func stopObserving() { isObserving = false }
}

final class StubAudioCapture: AudioCapturing, @unchecked Sendable {
    var startCount = 0
    var stopCount = 0
    var startError: AudioCaptureError?
    var onLevels: (@Sendable ([Float], Bool) -> Void)?

    func start(bundleIdentifier: String, outputUID: String, sensitivity: Float,
               onLevels: @escaping @Sendable ([Float], Bool) -> Void,
               completion: @escaping @Sendable (AudioCaptureError?) -> Void) {
        startCount += 1
        self.onLevels = onLevels
        completion(startError)
    }

    func setSensitivity(_ sensitivity: Float) {}
    func stop() { stopCount += 1 }
}

final class StubScriptRunner: ScriptRunning, @unchecked Sendable {
    var result: Result<ScriptValue, MediaError>
    var scripts: [String] = []

    init(_ result: Result<ScriptValue, MediaError>) {
        self.result = result
    }

    func run(_ source: String) async throws -> ScriptValue {
        scripts.append(source)
        return try result.get()
    }
}

struct StubApplications: ApplicationProbing {
    var installed = true
    var running = true
    var access = MediaAvailability.available

    func isInstalled(_ bundleIdentifier: String) -> Bool { installed }
    func isRunning(_ bundleIdentifier: String) -> Bool { running }
    func automationAccess(to bundleIdentifier: String, ask: Bool) -> MediaAvailability { access }
}
