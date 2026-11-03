import Foundation

enum MediaProviderKind: String, CaseIterable, Identifiable, Sendable {
    case appleMusic, spotify

    var id: String { rawValue }

    var bundleIdentifier: String {
        switch self {
        case .appleMusic: "com.apple.Music"
        case .spotify: "com.spotify.client"
        }
    }

    var displayName: String {
        switch self {
        case .appleMusic: "Apple Music"
        case .spotify: "Spotify"
        }
    }

    /// Distributed notification the player posts on every playback change.
    var changeNotification: String {
        switch self {
        case .appleMusic: "com.apple.Music.playerInfo"
        case .spotify: "com.spotify.client.PlaybackStateChanged"
        }
    }
}

enum MediaAvailability: Equatable, Sendable {
    case notInstalled
    case notRunning
    /// The user has not answered the Automation prompt yet.
    case needsAuthorization
    case denied
    case available

    var summary: String {
        switch self {
        case .notInstalled: "Not installed"
        case .notRunning: "Not running"
        case .needsAuthorization: "Waiting for permission"
        case .denied: "Permission denied"
        case .available: "Connected"
        }
    }
}

enum MediaError: Error, Equatable, Sendable {
    case notRunning
    case notAuthorized
    case timedOut
    case scriptFailed(code: Int, message: String)
    case malformedResponse
}

enum PlaybackState: Equatable, Sendable {
    case playing, paused, stopped
}

struct Track: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval?
    var artworkURL: URL?
}

struct PlaybackSnapshot: Equatable, Sendable {
    var provider: MediaProviderKind
    var state: PlaybackState
    var track: Track?
    var position: TimeInterval?
    var capturedAt: ContinuousClock.Instant
    /// The player's own volume, 0 to 100. System output volume has no supported API.
    var volume: Int?

    var isPlaying: Bool { state == .playing }

    /// A live stream has no timeline to move along, and neither does a track with no position.
    var canSeek: Bool {
        guard let duration = track?.duration else { return false }
        return duration > 0 && position != nil
    }

    /// Position extrapolated from the last report, so the UI needs no polling.
    func position(at instant: ContinuousClock.Instant) -> TimeInterval? {
        guard let position else { return nil }
        guard isPlaying else { return position }
        let advanced = position + capturedAt.duration(to: instant).timeInterval
        if let duration = track?.duration { return min(advanced, duration) }
        return advanced
    }
}
