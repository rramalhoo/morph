import Foundation

/// One music player. Calls may hop off the main actor and may fail at any time; the player can quit
/// mid-call or the user can revoke access.
protocol MediaProvider: AnyObject, Sendable {
    var kind: MediaProviderKind { get }

    func availability() async -> MediaAvailability
    /// Shows the system Automation prompt if the user hasn't answered it yet.
    func requestAuthorization() async -> MediaAvailability

    func currentTrack() async throws -> Track?
    func currentPlayback() async throws -> PlaybackSnapshot?
    func artwork(for track: Track) async throws -> Data?

    func playPause() async throws
    func nextTrack() async throws
    func previousTrack() async throws
    func seek(to position: TimeInterval) async throws
    func setVolume(_ volume: Int) async throws
}

extension MediaProvider {
    func currentTrack() async throws -> Track? {
        try await currentPlayback()?.track
    }
}

/// Fires when any player may have changed. Consumers re-read rather than trusting a payload.
@MainActor
protocol MediaEventSource: AnyObject {
    func start(onChange: @escaping @MainActor () -> Void)
    func stop()
}

/// What Morph needs to know about installed and running apps.
protocol ApplicationProbing: Sendable {
    func isInstalled(_ bundleIdentifier: String) -> Bool
    func isRunning(_ bundleIdentifier: String) -> Bool
    /// `ask` may block until the user answers, so never call this on the main thread.
    func automationAccess(to bundleIdentifier: String, ask: Bool) -> MediaAvailability
}
