import Foundation
import Testing
@testable import Morph

@Suite("Player scripts")
struct PlayerScriptTests {
    private let now = ContinuousClock.now

    @Test func parsesAppleMusicStatus() throws {
        let value = ScriptValue.list([.text("playing"), .text("ABC"), .text("Song"), .text("Artist"), .text("Album"), .number(200), .number(12.5), .number(60)])
        let snapshot = try PlayerScriptDialect.appleMusic.parse(value, capturedAt: now)
        #expect(snapshot.state == .playing)
        #expect(snapshot.track?.title == "Song")
        #expect(snapshot.track?.duration == 200)
        #expect(snapshot.position == 12.5)
        #expect(snapshot.volume == 60)
        #expect(snapshot.track?.artworkURL == nil)
    }

    @Test func parsesSpotifyArtworkOnlyOverHTTPS() throws {
        func parse(_ url: String) throws -> PlaybackSnapshot {
            let value = ScriptValue.list([.text("paused"), .text("spotify:track:1"), .text("Song"), .text("Artist"), .text("Album"),
                                          .number(180), .number(1), .number(50), .text(url)])
            return try PlayerScriptDialect.spotify.parse(value, capturedAt: now)
        }
        #expect(try parse("https://i.scdn.co/image/a").track?.artworkURL != nil)
        #expect(try parse("http://i.scdn.co/image/a").track?.artworkURL == nil)
    }

    @Test func stoppedPlayerHasNoTrack() throws {
        let snapshot = try PlayerScriptDialect.spotify.parse(.list([.text("stopped")]), capturedAt: now)
        #expect(snapshot.state == .stopped)
        #expect(snapshot.track == nil)
    }

    @Test func garbageIsAnErrorNotACrash() {
        #expect(throws: MediaError.malformedResponse) {
            try PlayerScriptDialect.appleMusic.parse(.text("huh"), capturedAt: now)
        }
    }

    @Test func positionExtrapolatesOnlyWhilePlayingAndStopsAtTheEnd() {
        let track = Track(id: "1", title: "", artist: "", album: "", duration: 100)
        var snapshot = PlaybackSnapshot(provider: .appleMusic, state: .playing, track: track, position: 10, capturedAt: now)
        #expect(snapshot.position(at: now.advanced(by: .seconds(5))) == 15)
        #expect(snapshot.position(at: now.advanced(by: .seconds(500))) == 100)
        snapshot.state = .paused
        #expect(snapshot.position(at: now.advanced(by: .seconds(5))) == 10)
    }

    @Test func applescriptErrorsMapToMeaningfulFailures() {
        #expect(OSAScriptRunner.mediaError(code: -1743, message: "") == .notAuthorized)
        #expect(OSAScriptRunner.mediaError(code: -600, message: "") == .notRunning)
        #expect(OSAScriptRunner.mediaError(code: -1712, message: "") == .timedOut)
        #expect(OSAScriptRunner.mediaError(code: -1, message: "x") == .scriptFailed(code: -1, message: "x"))
    }
}

@Suite("Scripted provider")
struct ScriptedProviderTests {
    private func provider(_ apps: StubApplications, runner: StubScriptRunner) -> ScriptedMediaProvider {
        ScriptedMediaProvider(dialect: .spotify, runner: runner, applications: apps)
    }

    @Test func missingPlayerIsReportedAndNeverScripted() async {
        let runner = StubScriptRunner(.success(.none))
        let subject = provider(StubApplications(installed: false, running: false), runner: runner)
        #expect(await subject.availability() == .notInstalled)
        await #expect(throws: MediaError.notRunning) { try await subject.playPause() }
        #expect(runner.scripts.isEmpty)
    }

    @Test func aPlayerThatIsNotRunningIsNeverLaunchedByAScript() async {
        let runner = StubScriptRunner(.success(.none))
        let subject = provider(StubApplications(running: false), runner: runner)
        #expect(await subject.availability() == .notRunning)
        await #expect(throws: MediaError.notRunning) { _ = try await subject.currentPlayback() }
        #expect(runner.scripts.isEmpty)
    }

    @Test func deniedAccessSurfacesWithoutRunningAScript() async {
        let runner = StubScriptRunner(.success(.none))
        let subject = provider(StubApplications(access: .denied), runner: runner)
        await #expect(throws: MediaError.notAuthorized) { try await subject.nextTrack() }
        #expect(runner.scripts.isEmpty)
    }

    @Test func commandsSendTheRealVerbs() async throws {
        let runner = StubScriptRunner(.success(.none))
        let subject = provider(StubApplications(), runner: runner)
        try await subject.playPause()
        try await subject.nextTrack()
        try await subject.previousTrack()
        try await subject.seek(to: 12.5)
        #expect(runner.scripts[0].contains("playpause"))
        #expect(runner.scripts[1].contains("next track"))
        #expect(runner.scripts[2].contains("previous track"))
        #expect(runner.scripts[3].contains("set player position to 12.50"))
        try await subject.setVolume(140)
        #expect(runner.scripts[4].contains("set sound volume to 100"))
    }

    @Test func runnerFailurePropagates() async {
        let subject = provider(StubApplications(), runner: StubScriptRunner(.failure(.timedOut)))
        await #expect(throws: MediaError.timedOut) { _ = try await subject.currentTrack() }
    }
}

@Suite("Media controller")
@MainActor
struct MediaControllerTests {
    private let scheduler = ManualScheduler()
    private let events = StubMediaEvents()

    private func controller(_ providers: [StubMediaProvider]) -> MediaController {
        MediaController(providers: providers, events: events, scheduler: scheduler)
    }

    @Test func providerFailureBecomesStateNotACrash() async {
        let provider = StubMediaProvider(.appleMusic)
        provider.playback = .failure(.timedOut)
        let subject = controller([provider])
        await subject.refresh()
        #expect(subject.snapshot == nil)
        #expect(subject.lastError == .timedOut)
    }

    @Test func oneFailingProviderDoesNotHideTheOther() async {
        let broken = StubMediaProvider(.appleMusic)
        broken.playback = .failure(.scriptFailed(code: -1, message: "x"))
        let working = StubMediaProvider(.spotify)
        working.playback = .success(working.snapshot(.playing))
        let subject = controller([broken, working])
        await subject.refresh()
        #expect(subject.snapshot?.provider == .spotify)
    }

    @Test func playingBeatsPausedRegardlessOfOrder() async {
        let music = StubMediaProvider(.appleMusic)
        music.playback = .success(music.snapshot(.paused))
        let spotify = StubMediaProvider(.spotify)
        spotify.playback = .success(spotify.snapshot(.playing))
        let subject = controller([music, spotify])
        await subject.refresh()
        #expect(subject.snapshot?.provider == .spotify)
    }

    @Test func pausedPlayerStaysSelected() async {
        let music = StubMediaProvider(.appleMusic)
        let spotify = StubMediaProvider(.spotify)
        spotify.playback = .success(spotify.snapshot(.playing))
        music.playback = .success(music.snapshot(.paused))
        let subject = controller([music, spotify])
        await subject.refresh()
        spotify.playback = .success(spotify.snapshot(.paused))
        await subject.refresh()
        #expect(subject.snapshot?.provider == .spotify)
    }

    @Test func sourcePreferenceExcludesTheOtherPlayer() async {
        let music = StubMediaProvider(.appleMusic)
        music.playback = .success(music.snapshot(.playing))
        let spotify = StubMediaProvider(.spotify)
        spotify.playback = .success(spotify.snapshot(.paused))
        let subject = controller([music, spotify])
        subject.source = .spotify
        await subject.refresh()
        #expect(subject.snapshot?.provider == .spotify)
    }

    @Test func noPermissionShowsTheConnectFlowAndAuthorizationClearsIt() async {
        let music = StubMediaProvider(.appleMusic)
        music.availabilityResult = .needsAuthorization
        let subject = controller([music])
        await subject.refresh()
        #expect(subject.providerNeedingAuthorization == .appleMusic)
        #expect(subject.snapshot == nil)
    }

    @Test func playerQuittingClearsTheSnapshot() async {
        let music = StubMediaProvider(.appleMusic)
        music.playback = .success(music.snapshot(.playing))
        let subject = controller([music])
        await subject.refresh()
        #expect(subject.snapshot != nil)
        music.availabilityResult = .notRunning
        await subject.refresh()
        #expect(subject.snapshot == nil)
    }

    @Test func announcesNewTracksButNotPauses() async {
        let music = StubMediaProvider(.appleMusic)
        let subject = controller([music])
        var announced: [String] = []
        subject.onPlaybackStarted = { announced.append($0.track!.id) }

        music.playback = .success(music.snapshot(.playing, id: "1"))
        await subject.refresh()
        music.playback = .success(music.snapshot(.paused, id: "1"))
        await subject.refresh()
        music.playback = .success(music.snapshot(.playing, id: "1"))
        await subject.refresh()
        music.playback = .success(music.snapshot(.playing, id: "2"))
        await subject.refresh()
        #expect(announced == ["1", "2"])
    }

    @Test func artworkFailureLeavesTheTrackIntact() async {
        let music = StubMediaProvider(.appleMusic)
        music.playback = .success(music.snapshot(.playing))
        music.artworkResult = .failure(.scriptFailed(code: -1728, message: "none"))
        let subject = controller([music])
        await subject.refresh()
        #expect(subject.snapshot?.track != nil)
        #expect(subject.artwork == nil)
    }

    @Test func failedCommandIsReportedToTheUser() async {
        let music = StubMediaProvider(.appleMusic)
        music.playback = .success(music.snapshot(.playing))
        music.commandResult = .failure(.notAuthorized)
        let subject = controller([music])
        await subject.refresh()

        let message: String? = await withCheckedContinuation { continuation in
            subject.onCommandFailed = { continuation.resume(returning: $0) }
            subject.playPause()
        }
        #expect(message == "Morph doesn't have access to Apple Music")
        #expect(music.commands == ["playPause"])
    }

    @Test func commandsWithoutAnActivePlayerAreIgnored() async {
        let music = StubMediaProvider(.appleMusic)
        let subject = controller([music])
        subject.playPause()
        await Task.yield()
        #expect(music.commands.isEmpty)
    }

    @Test func volumeUpdatesAtOnceAndSendsOnlyTheFinalValue() async {
        let music = StubMediaProvider(.appleMusic)
        var snapshot = music.snapshot(.playing)
        snapshot.volume = 50
        music.playback = .success(snapshot)
        let subject = controller([music])
        await subject.refresh()

        var reported: [Int] = []
        subject.onVolumeChanged = { reported.append($0) }
        for _ in 0..<5 { subject.adjustVolume(by: 2) }
        #expect(subject.snapshot?.volume == 60)
        #expect(reported == [52, 54, 56, 58, 60])

        scheduler.advance(by: .milliseconds(60))
        await waitUntil { !music.commands.isEmpty }
        #expect(music.commands == ["volume 60"])
    }

    @Test func volumeIsClampedAndIgnoredWithoutSupport() async {
        let music = StubMediaProvider(.appleMusic)
        music.playback = .success(music.snapshot(.playing))
        let subject = controller([music])
        await subject.refresh()
        subject.setVolume(50)
        #expect(subject.snapshot?.volume == nil, "A snapshot with no volume can't be changed")

        var loud = music.snapshot(.playing)
        loud.volume = 98
        music.playback = .success(loud)
        await subject.refresh()
        subject.adjustVolume(by: 50)
        #expect(subject.snapshot?.volume == 100)
    }

    @Test func burstsOfEventsCoalesce() {
        let subject = controller([])
        subject.start()
        for _ in 0..<50 { events.onChange?() }
        #expect(scheduler.pendingCount == 1)
        subject.stop()
        #expect(scheduler.pendingCount == 0)
        #expect(!events.isRunning)
    }
}
