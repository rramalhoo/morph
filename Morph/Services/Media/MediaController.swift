import Foundation
import Observation

/// Merges the enabled providers into the single player the island shows. Provider failures end up
/// as state here, never as a crash or a button that silently does nothing.
@MainActor
@Observable
final class MediaController {
    private static let refreshDebounce = Duration.milliseconds(120)
    private static let commandSettle = Duration.milliseconds(250)
    private static let volumeDebounce = Duration.milliseconds(60)
    private static let pausedLinger = Duration.seconds(6)

    private(set) var snapshot: PlaybackSnapshot?
    private(set) var artwork: Data?
    private(set) var availability: [MediaProviderKind: MediaAvailability] = [:]
    private(set) var lastError: MediaError?
    /// Playing, or paused a moment ago: the island keeps its bars still briefly rather than vanishing.
    private(set) var isLive = false

    /// A new track started, or playback resumed from stopped.
    @ObservationIgnored var onPlaybackStarted: ((PlaybackSnapshot) -> Void)?
    @ObservationIgnored var onCommandFailed: ((String) -> Void)?
    /// Volume changed through a Morph control.
    @ObservationIgnored var onVolumeChanged: ((Int) -> Void)?

    @ObservationIgnored private let providers: [any MediaProvider]
    @ObservationIgnored private let events: any MediaEventSource
    @ObservationIgnored private let scheduler: any Scheduling
    @ObservationIgnored private var refreshWork: (any ScheduledWork)?
    @ObservationIgnored private var volumeWork: (any ScheduledWork)?
    @ObservationIgnored private var lingerWork: (any ScheduledWork)?
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var artworkTrackID: String?
    @ObservationIgnored private var isStarted = false

    /// Limits which providers are consulted.
    var source = MediaSourcePreference.automatic {
        didSet {
            guard source != oldValue else { return }
            requestRefresh()
        }
    }

    init(providers: [any MediaProvider], events: any MediaEventSource, scheduler: any Scheduling) {
        self.providers = providers
        self.events = events
        self.scheduler = scheduler
    }

    /// The provider that needs the user's permission before it can be shown, if any.
    var providerNeedingAuthorization: MediaProviderKind? {
        activeProviders.map(\.kind).first { availability[$0] == .needsAuthorization }
    }

    private var activeProviders: [any MediaProvider] {
        providers.filter { provider in
            switch source {
            case .automatic: true
            case .appleMusic: provider.kind == .appleMusic
            case .spotify: provider.kind == .spotify
            }
        }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        events.start { [weak self] in self?.requestRefresh() }
        requestRefresh()
    }

    func stop() {
        isStarted = false
        events.stop()
        refreshWork?.cancel()
        refreshWork = nil
        volumeWork?.cancel()
        volumeWork = nil
        lingerWork?.cancel()
        lingerWork = nil
        isLive = false
        refreshGeneration += 1
        snapshot = nil
        artwork = nil
        artworkTrackID = nil
        availability = [:]
    }

    /// Coalesces bursts: players often post several notifications for one change.
    func requestRefresh() {
        guard isStarted else { return }
        refreshWork?.cancel()
        refreshWork = scheduler.schedule(after: Self.refreshDebounce) { [weak self] in
            guard let self else { return }
            Task { await self.refresh() }
        }
    }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration

        var results: [(snapshot: PlaybackSnapshot?, kind: MediaProviderKind)] = []
        var availabilities: [MediaProviderKind: MediaAvailability] = [:]
        var failure: MediaError?

        for provider in activeProviders {
            let state = await provider.availability()
            availabilities[provider.kind] = state
            guard state == .available else { continue }
            do {
                results.append((try await provider.currentPlayback(), provider.kind))
            } catch {
                failure = error as? MediaError ?? .malformedResponse
            }
        }

        // A newer refresh has overtaken this one, or Morph stopped meanwhile.
        guard generation == refreshGeneration else { return }
        availability = availabilities
        lastError = failure
        apply(Self.preferred(results.compactMap(\.snapshot), current: snapshot?.provider))
    }

    /// Whatever is playing wins. Otherwise stick with the current player, so a paused track doesn't
    /// jump to the other app.
    private static func preferred(_ snapshots: [PlaybackSnapshot], current: MediaProviderKind?) -> PlaybackSnapshot? {
        let withTrack = snapshots.filter { $0.track != nil && $0.state != .stopped }
        return withTrack.first(where: \.isPlaying)
            ?? withTrack.first { $0.provider == current }
            ?? withTrack.first
    }

    private func apply(_ latest: PlaybackSnapshot?) {
        let previous = snapshot
        snapshot = latest
        updateLiveness(playing: latest?.isPlaying == true && latest?.track != nil,
                       wasPlaying: previous?.isPlaying == true, hasTrack: latest?.track != nil)
        guard let latest, let track = latest.track else {
            artwork = nil
            artworkTrackID = nil
            return
        }

        if track.id != artworkTrackID {
            artworkTrackID = track.id
            artwork = nil
            loadArtwork(for: track, provider: latest.provider)
        }

        let changedTrack = previous?.track?.id != track.id
        let resumedFromNothing = previous == nil
        if latest.isPlaying, changedTrack || resumedFromNothing {
            onPlaybackStarted?(latest)
        }
    }

    private func updateLiveness(playing: Bool, wasPlaying: Bool, hasTrack: Bool) {
        if playing {
            lingerWork?.cancel()
            lingerWork = nil
            isLive = true
        } else if !hasTrack {
            lingerWork?.cancel()
            lingerWork = nil
            isLive = false
        } else if wasPlaying {
            lingerWork = scheduler.schedule(after: Self.pausedLinger) { [weak self] in
                self?.lingerWork = nil
                self?.isLive = false
            }
        }
    }

    private func loadArtwork(for track: Track, provider kind: MediaProviderKind) {
        guard let provider = providers.first(where: { $0.kind == kind }) else { return }
        Task { [weak self] in
            // Missing art is routine for streams, and the UI has a fallback.
            let data = try? await provider.artwork(for: track)
            guard let self, self.artworkTrackID == track.id else { return }
            self.artwork = data
        }
    }

    // MARK: - Commands

    func playPause() { perform { try await $0.playPause() } }
    func nextTrack() { perform { try await $0.nextTrack() } }
    func previousTrack() { perform { try await $0.previousTrack() } }

    func seek(to position: TimeInterval) {
        perform { try await $0.seek(to: position) }
    }

    /// Updates the UI at once and sends only the latest value, so a scroll isn't a burst of scripts.
    func setVolume(_ value: Int) {
        guard var latest = snapshot, latest.volume != nil else { return }
        let volume = value.clamped(to: 0...100)
        guard volume != latest.volume else { return }
        latest.volume = volume
        snapshot = latest
        onVolumeChanged?(volume)
        volumeWork?.cancel()
        volumeWork = scheduler.schedule(after: Self.volumeDebounce) { [weak self] in
            self?.perform { try await $0.setVolume(volume) }
        }
    }

    func adjustVolume(by delta: Int) {
        guard let volume = snapshot?.volume else { return }
        setVolume(volume + delta)
    }

    /// Starts the Automation prompt flow for a player.
    func authorize(_ kind: MediaProviderKind) {
        guard let provider = providers.first(where: { $0.kind == kind }) else { return }
        Task {
            _ = await provider.requestAuthorization()
            await refresh()
        }
    }

    private func perform(_ command: @escaping @Sendable (any MediaProvider) async throws -> Void) {
        guard let kind = snapshot?.provider, let provider = providers.first(where: { $0.kind == kind }) else { return }
        Task { [weak self] in
            do {
                try await command(provider)
                self?.scheduler.schedule(after: Self.commandSettle) { self?.requestRefresh() }
            } catch {
                let mediaError = error as? MediaError ?? .malformedResponse
                self?.lastError = mediaError
                self?.onCommandFailed?(Self.describe(mediaError, player: kind.displayName))
                self?.requestRefresh()
            }
        }
    }

    private static func describe(_ error: MediaError, player: String) -> String {
        switch error {
        case .notRunning: "\(player) isn't running"
        case .notAuthorized: "Morph doesn't have access to \(player)"
        case .timedOut: "\(player) didn't respond"
        case .scriptFailed, .malformedResponse: "\(player) rejected the command"
        }
    }
}
