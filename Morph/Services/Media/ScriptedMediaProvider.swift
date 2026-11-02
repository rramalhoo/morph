import Foundation

/// The parts of the scripting interface that differ between players.
struct PlayerScriptDialect: Sendable {
    var kind: MediaProviderKind
    /// Returns `{state}` when stopped, otherwise
    /// `{state, id, name, artist, album, duration, position, volume[, artwork url]}`.
    var statusScript: String
    var artworkScript: String?
}

extension PlayerScriptDialect {
    static let appleMusic = PlayerScriptDialect(
        kind: .appleMusic,
        statusScript: statusScript(for: .appleMusic, trackID: "persistent ID of t", duration: "duration of t", extras: ""),
        // `current track` has no artwork for some streams, which surfaces as an error handled upstream.
        artworkScript: """
        with timeout of 4 seconds
            tell application id "com.apple.Music"
                return data of artwork 1 of current track
            end tell
        end timeout
        """
    )

    static let spotify = PlayerScriptDialect(
        kind: .spotify,
        // Spotify reports duration in milliseconds and position in seconds.
        statusScript: statusScript(for: .spotify, trackID: "id of t", duration: "(duration of t) / 1000", extras: ", artwork url of t"),
        artworkScript: nil
    )

    private static func statusScript(for kind: MediaProviderKind, trackID: String, duration: String, extras: String) -> String {
        """
        with timeout of 4 seconds
            tell application id "\(kind.bundleIdentifier)"
                set s to (player state as text)
                if s is "stopped" then return {s}
                try
                    set t to current track
                    return {s, \(trackID), name of t, artist of t, album of t, \(duration), player position, sound volume\(extras)}
                on error number -1728
                    return {s}
                end try
            end tell
        end timeout
        """
    }

    func commandScript(_ command: String) -> String {
        """
        with timeout of 4 seconds
            tell application id "\(kind.bundleIdentifier)" to \(command)
        end timeout
        """
    }

    func parse(_ value: ScriptValue, capturedAt: ContinuousClock.Instant) throws -> PlaybackSnapshot {
        guard let items = value.list, let stateText = items.first?.text else { throw MediaError.malformedResponse }
        let state: PlaybackState = switch stateText {
        case "playing": .playing
        case "paused": .paused
        default: .stopped
        }

        guard items.count >= 7, let id = items[1].text, let title = items[2].text else {
            return PlaybackSnapshot(provider: kind, state: state, track: nil, position: nil, capturedAt: capturedAt)
        }

        let track = Track(id: id, title: title, artist: items[3].text ?? "", album: items[4].text ?? "",
                          duration: items[5].number.flatMap { $0 > 0 ? $0 : nil },
                          artworkURL: items.count > 8 ? items[8].text.flatMap(Self.secureURL) : nil)
        let volume = items.count > 7 ? items[7].number.map { Int($0.rounded()) } : nil
        return PlaybackSnapshot(provider: kind, state: state, track: track, position: items[6].number,
                                capturedAt: capturedAt, volume: volume)
    }

    private static func secureURL(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme == "https" else { return nil }
        return url
    }
}

/// Talks to a player through its own scripting dictionary. Never launches it: every call first
/// checks that the player is running, because `tell application` would otherwise start it.
final class ScriptedMediaProvider: MediaProvider {
    private let dialect: PlayerScriptDialect
    private let runner: any ScriptRunning
    private let applications: any ApplicationProbing
    private let session: URLSession

    init(dialect: PlayerScriptDialect, runner: any ScriptRunning, applications: any ApplicationProbing,
         session: URLSession = .shared) {
        self.dialect = dialect
        self.runner = runner
        self.applications = applications
        self.session = session
    }

    var kind: MediaProviderKind { dialect.kind }

    func availability() async -> MediaAvailability {
        await check(ask: false)
    }

    func requestAuthorization() async -> MediaAvailability {
        await check(ask: true)
    }

    private func check(ask: Bool) async -> MediaAvailability {
        let bundleID = kind.bundleIdentifier
        guard applications.isInstalled(bundleID) else { return .notInstalled }
        guard applications.isRunning(bundleID) else { return .notRunning }
        let applications = applications
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: applications.automationAccess(to: bundleID, ask: ask))
            }
        }
    }

    private func requireAccess() async throws {
        switch await availability() {
        case .available: return
        case .notInstalled, .notRunning: throw MediaError.notRunning
        case .needsAuthorization, .denied: throw MediaError.notAuthorized
        }
    }

    func currentPlayback() async throws -> PlaybackSnapshot? {
        try await requireAccess()
        let value = try await runner.run(dialect.statusScript)
        return try dialect.parse(value, capturedAt: .now)
    }

    func artwork(for track: Track) async throws -> Data? {
        try await requireAccess()
        if let script = dialect.artworkScript {
            return try await runner.run(script).data
        }
        guard let url = track.artworkURL else { return nil }
        return try await session.data(from: url).0
    }

    func playPause() async throws { try await send("playpause") }
    func nextTrack() async throws { try await send("next track") }
    func previousTrack() async throws { try await send("previous track") }

    func seek(to position: TimeInterval) async throws {
        try await send(String(format: "set player position to %.2f", max(0, position)))
    }

    func setVolume(_ volume: Int) async throws {
        try await send("set sound volume to \(volume.clamped(to: 0...100))")
    }

    private func send(_ command: String) async throws {
        try await requireAccess()
        _ = try await runner.run(dialect.commandScript(command))
    }
}
