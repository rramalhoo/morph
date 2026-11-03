import CryptoKit
import Foundation
import Network
import Testing
@testable import Morph

final class MemoryKeyStore: ContinuityKeyStoring, @unchecked Sendable {
    var items: [String: (PairedDevice, SymmetricKey)] = [:]
    func load() -> [(device: PairedDevice, key: SymmetricKey)] { items.values.map { ($0.0, $0.1) } }
    func save(_ device: PairedDevice, key: SymmetricKey) -> Bool { items[device.id] = (device, key); return true }
    func delete(id: String) { items[id] = nil }
}

@Suite("Transfers")
@MainActor
struct TransferManagerTests {
    let scheduler = ManualScheduler()

    @Test func downloadStartsProgressesAndCompletes() throws {
        let manager = TransferManager(scheduler: scheduler)
        var events: [String] = []
        manager.onEvent = { event in
            switch event {
            case .started: events.append("started")
            case .progressed: events.append("progressed")
            case .finished: events.append("finished")
            }
        }
        try manager.begin(Transfer(id: "d", kind: .download, name: "a.zip", source: .watchedFolder, totalBytes: 1000))
        scheduler.advance(by: .seconds(1))
        try manager.update(id: "d", bytes: 500)
        #expect(manager.transfer(id: "d")?.progress == 0.5)
        #expect(manager.transfer(id: "d")?.state == .transferring)
        scheduler.advance(by: .seconds(1))
        try manager.update(id: "d", bytes: 800)
        #expect(manager.transfer(id: "d")?.speed.map { $0 > 0 } == true)
        #expect(manager.transfer(id: "d")?.remaining != nil)
        try manager.finish(id: "d")
        #expect(manager.transfer(id: "d")?.state == .completed)
        #expect(events == ["started", "progressed", "progressed", "finished"])
    }

    @Test func unknownTotalMeansNoPercentage() throws {
        let manager = TransferManager(scheduler: scheduler)
        try manager.begin(Transfer(id: "d", kind: .download, name: "a", source: .watchedFolder))
        try manager.update(id: "d", bytes: 12_345)
        #expect(manager.transfer(id: "d")?.progress == nil)
        #expect(manager.transfer(id: "d")?.remaining == nil)
        #expect(manager.transfer(id: "d")?.detail.contains("%") == false)
    }

    @Test func updatesAreThrottledButStateChangesAlwaysGetThrough() throws {
        let manager = TransferManager(scheduler: scheduler)
        var progressed = 0
        manager.onEvent = { if case .progressed = $0 { progressed += 1 } }
        try manager.begin(Transfer(id: "u", kind: .upload, name: "a", source: .liveAPI, state: .transferring, totalBytes: 100))
        for bytes in 1...20 { try manager.update(id: "u", bytes: Int64(bytes)) }
        #expect(progressed == 0)
        try manager.update(id: "u", state: .paused)
        #expect(progressed == 1)
        scheduler.advance(by: .seconds(1))
        try manager.update(id: "u", bytes: 50, state: .transferring)
        #expect(progressed == 2)
    }

    @Test func simultaneousUploadsAndDuplicates() throws {
        let manager = TransferManager(scheduler: scheduler)
        try manager.begin(Transfer(id: "a", kind: .upload, name: "a", source: .liveAPI))
        try manager.begin(Transfer(id: "b", kind: .upload, name: "b", source: .liveAPI))
        try manager.begin(Transfer(id: "a", kind: .upload, name: "a", source: .liveAPI, bytes: 10))
        #expect(manager.active.count == 2)
        try manager.finish(id: "a")
        #expect(throws: TransferManager.Failure.alreadyFinished) { try manager.begin(Transfer(id: "a", kind: .upload, name: "a", source: .liveAPI)) }
        #expect(throws: TransferManager.Failure.alreadyFinished) { try manager.finish(id: "a") }
    }

    @Test func interruptedTransfersEndAsUnknownNotFailed() throws {
        let manager = TransferManager(scheduler: scheduler)
        try manager.begin(Transfer(id: "d", kind: .download, name: "a", source: .watchedFolder, bytes: 5))
        manager.abandon(source: .watchedFolder)
        #expect(manager.transfer(id: "d")?.state == .unknown)
        #expect(manager.active.isEmpty)
    }

    @Test func onlyMorphOwnedTransfersCanBeCancelled() throws {
        let manager = TransferManager(scheduler: scheduler)
        try manager.begin(Transfer(id: "api", kind: .upload, name: "a", source: .liveAPI))
        #expect(throws: TransferManager.Failure.notCancellable) { try manager.cancel(id: "api") }
        try manager.begin(Transfer(id: "mine", kind: .airDropSend, name: "a", source: .morph))
        try manager.cancel(id: "mine")
        #expect(manager.transfer(id: "mine")?.state == .cancelled)
    }

    @Test func historyIsKeptOnlyAsLongAsAsked() throws {
        let manager = TransferManager(scheduler: scheduler)
        manager.historyDuration = .zero
        try manager.begin(Transfer(id: "d", kind: .download, name: "a", source: .watchedFolder))
        try manager.finish(id: "d")
        scheduler.advance(by: .seconds(5))
        #expect(manager.transfer(id: "d") != nil, "Stays long enough to be seen")
        scheduler.advance(by: .seconds(6))
        #expect(manager.transfer(id: "d") == nil)
    }

    @Test func transferPrioritiesFollowTheAgreedOrder() {
        let active = IslandActivity(.transfer(Transfer(id: "a", kind: .download, name: "a", source: .watchedFolder, state: .transferring), others: 0), at: .now)
        var finished = Transfer(id: "b", kind: .download, name: "b", source: .watchedFolder)
        finished.finishedAt = .now
        finished.state = .completed
        let done = IslandActivity(.transfer(finished, others: 0), at: .now)
        let airDrop = IslandActivity(.transfer(Transfer(id: "c", kind: .airDropReceive, name: "c", source: .watchedFolder), others: 0), at: .now)
        let phone = IslandActivity(.continuity(ContinuityActivity(deviceID: "p", deviceName: "iPhone",
                                                                  payload: ContinuityActivityPayload(id: "x", service: "S", title: "T"),
                                                                  expiresAt: .now), hidesDetails: true), at: .now)
        #expect(ActivityPriority.critical > ActivityPriority.interaction && ActivityPriority.interaction > ActivityPriority.level)
        #expect(ActivityPriority.level > airDrop.priority)
        #expect(airDrop.priority > done.priority)
        #expect(done.priority > active.priority)
        #expect(active.priority > phone.priority)
        #expect(phone.priority > .music)
        #expect(active.dedupeKey == done.dedupeKey, "Transfers group into one activity")
        #expect(active.content.isPrivate && phone.content.isPrivate)
    }

    @Test func transfersAreHiddenWhenTheSessionLocks() {
        let activities = ActivityManager(scheduler: scheduler)
        activities.present(.transfer(Transfer(id: "a", kind: .download, name: "secret.pdf", source: .watchedFolder, state: .transferring), others: 0))
        activities.setSuppressed(true)
        #expect(activities.current == nil)
        #expect(!activities.isActive(dedupeKey: "transfers"))
    }

    @Test func simulatedAirDropProducesTheRingAndConfirmation() throws {
        // Visual validation only: no real AirDrop is involved here.
        let manager = TransferManager(scheduler: scheduler)
        try manager.begin(Transfer(id: "s", kind: .airDropSend, name: "photo.jpg", source: .morph, state: .transferring))
        #expect(manager.transfer(id: "s")?.progress == nil)
        #expect(manager.transfer(id: "s")?.detail == "Sending")
        try manager.finish(id: "s")
        let sent = try #require(manager.transfer(id: "s"))
        #expect(sent.symbol == "checkmark")
        #expect(sent.detail == "Sent with AirDrop")
        #expect(IslandActivity(.transfer(sent, others: 0), at: .now).content.symbol == "airdrop")
    }
}

@Suite("Download detection")
struct DownloadDetectorTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func fresh(_ agent: String = "Safari") -> QuarantineMarker { QuarantineMarker(agent: agent, date: now) }

    @Test func existingFilesAreTheBaseline() {
        var detector = DownloadDetector()
        let changes = detector.process([DownloadFolderEntry(name: "old.pdf", size: 10, quarantine: fresh())], now: now)
        #expect(changes.isEmpty)
    }

    @Test func safariDownloadStartsAndFinishes() {
        var detector = DownloadDetector()
        _ = detector.process([], now: now)
        let started = detector.process([DownloadFolderEntry(name: "a.zip.download", size: 100, expectedSize: 1000)], now: now)
        guard case .started(let id, "a.zip", 100, 1000)? = started.first else { Issue.record("\(started)"); return }
        let progressed = detector.process([DownloadFolderEntry(name: "a.zip.download", size: 600, expectedSize: 1000)], now: now)
        #expect(progressed == [.progressed(id: id, name: "a.zip", bytes: 600, total: 1000)])
        let finished = detector.process([DownloadFolderEntry(name: "a.zip", size: 1000, quarantine: fresh())], now: now)
        #expect(finished == [.finished(id: id, name: "a.zip")])
    }

    @Test func firefoxPlaceholderIsNotASecondDownload() {
        var detector = DownloadDetector()
        _ = detector.process([], now: now)
        let changes = detector.process([DownloadFolderEntry(name: "b.iso", size: 0, quarantine: fresh()),
                                        DownloadFolderEntry(name: "b.iso.part", size: 5)], now: now)
        #expect(changes.count == 1)
        if case .started = changes.first {} else { Issue.record("\(changes)") }
    }

    @Test func chromiumRenameKeepsTheSameTransfer() {
        var detector = DownloadDetector()
        _ = detector.process([], now: now)
        guard case .started(let id, "Download", _, _)? = detector.process([DownloadFolderEntry(name: "Unconfirmed 123.crdownload", size: 1)], now: now).first else {
            Issue.record("no start"); return
        }
        let renamed = detector.process([DownloadFolderEntry(name: "movie.mp4.crdownload", size: 50)], now: now)
        #expect(renamed == [.progressed(id: id, name: "movie.mp4", bytes: 50, total: nil)])
    }

    @Test func copiedOrSavedFilesAreNotDownloads() {
        var detector = DownloadDetector()
        _ = detector.process([], now: now)
        let unmarked = detector.process([DownloadFolderEntry(name: "note.txt", size: 3)], now: now)
        #expect(unmarked.isEmpty)
        let stale = detector.process([DownloadFolderEntry(name: "note.txt", size: 3),
                                      DownloadFolderEntry(name: "old.dmg", size: 3, quarantine: QuarantineMarker(agent: "Safari", date: now.addingTimeInterval(-86_400)))], now: now)
        #expect(stale.isEmpty)
    }

    @Test func airDropIsOnlyCalledAirDropByItsMarker() {
        var detector = DownloadDetector()
        _ = detector.process([], now: now)
        let changes = detector.process([DownloadFolderEntry(name: "IMG_1.HEIC", size: 9, quarantine: fresh("sharingd")),
                                        DownloadFolderEntry(name: "file.pdf", size: 9, quarantine: fresh("Safari"))], now: now)
        #expect(changes.contains(.arrived(name: "IMG_1.HEIC", size: 9, isAirDrop: true)))
        #expect(changes.contains(.arrived(name: "file.pdf", size: 9, isAirDrop: false)))
    }

    @Test func aVanishedPartialIsUnknownNotFailed() {
        var detector = DownloadDetector()
        _ = detector.process([], now: now)
        guard case .started(let id, _, _, _)? = detector.process([DownloadFolderEntry(name: "x.part", size: 1)], now: now).first else { return }
        #expect(detector.process([], now: now) == [.vanished(id: id)])
    }

    @Test func quarantineMarkerParses() {
        let marker = QuarantineMarker("0083;6a0b1c2d;sharingd;ABC")
        #expect(marker?.isAirDrop == true)
        #expect(marker?.date == Date(timeIntervalSince1970: TimeInterval(0x6a0b1c2d)))
        #expect(QuarantineMarker("garbage") == nil)
    }

    @MainActor
    @Test func fileReceivedInTheAuthorizedFolderBecomesAFinishedTransfer() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let scheduler = ManualScheduler()
        let transfers = TransferManager(scheduler: scheduler)
        let monitor = DownloadFolderMonitor(transfers: transfers, scheduler: scheduler)
        monitor.receive([], in: folder)
        monitor.receive([DownloadFolderEntry(name: "c.pdf.download", size: 10, expectedSize: 20)], in: folder)
        #expect(transfers.active.first?.progress == 0.5)
        monitor.receive([DownloadFolderEntry(name: "c.pdf", size: 20, quarantine: QuarantineMarker(agent: "Safari", date: .now))], in: folder)
        #expect(transfers.recent.first?.state == .completed)
        #expect(transfers.recent.first?.fileURL == folder.appendingPathComponent("c.pdf"))
    }
}

@Suite("Live API transfers")
@MainActor
struct LiveAPITransferTests {
    let scheduler = ManualScheduler()

    private func make(enabled: Bool = true) -> (LiveAPIRouter, TransferManager) {
        let router = LiveAPIRouter(store: LiveActivityStore(scheduler: scheduler), scheduler: scheduler, token: { "secret" }, port: { 47800 })
        let transfers = TransferManager(scheduler: scheduler)
        router.transfers = transfers
        router.acceptsTransfers = enabled
        return (router, transfers)
    }

    private func request(_ method: String, _ path: String, _ body: String = "", token: String? = "secret") -> HTTPRequest {
        var headers = ["host": "127.0.0.1:47800"]
        if let token { headers["authorization"] = "Bearer \(token)" }
        return HTTPRequest(method: method, path: path, headers: headers, body: Data(body.utf8))
    }

    @Test func uploadLifecycle() {
        let (router, transfers) = make()
        #expect(router.handle(request("POST", "/v1/transfers", #"{"id":"up1","name":"video.mov","kind":"upload","bytes":0,"total":1000}"#)).status == 201)
        #expect(router.handle(request("PATCH", "/v1/transfers/up1", #"{"bytes":250}"#)).status == 200)
        #expect(transfers.transfer(id: "api-up1")?.progress == 0.25)
        #expect(transfers.transfer(id: "api-up1")?.canCancel == false)
        #expect(router.handle(request("PATCH", "/v1/transfers/up1", #"{"state":"completed","bytes":1000}"#)).status == 200)
        #expect(router.handle(request("PATCH", "/v1/transfers/up1", #"{"bytes":5}"#)).status == 409)
    }

    @Test func securityRulesStillApply() {
        let (router, _) = make()
        #expect(router.handle(request("POST", "/v1/transfers", #"{"id":"a","name":"a","kind":"upload"}"#, token: nil)).status == 401)
        #expect(router.handle(request("POST", "/v1/transfers", #"{"id":"a","name":"a","kind":"airDropSend"}"#)).status == 400)
        #expect(router.handle(request("POST", "/v1/transfers", #"{"id":"a","name":"a","kind":"upload","path":"/etc"}"#)).status == 400)
        #expect(router.handle(request("POST", "/v1/transfers", #"{"id":"a","name":"a","kind":"upload","bytes":5,"total":2}"#)).status == 400)
        #expect(router.handle(request("POST", "/v1/transfers", #"{"id":"../x","name":"a","kind":"upload"}"#)).status == 400)
        let (off, _) = make(enabled: false)
        #expect(off.handle(request("POST", "/v1/transfers", #"{"id":"a","name":"a","kind":"upload"}"#)).status == 404)
    }
}

@Suite("Continuity")
@MainActor
struct ContinuityTests {
    let scheduler = ManualScheduler()
    let store = MemoryKeyStore()

    private func frame(_ value: HandshakeFrame) -> Data { try! JSONEncoder().encode(value) }

    /// Runs a real pairing between the iPhone's session code and the Mac's manager.
    private func paired() throws -> (MorphContinuityManager, ContinuityClientSession, SymmetricKey) {
        let manager = MorphContinuityManager(store: store, scheduler: scheduler)
        let invitation = manager.beginPairing(service: "Morph", macName: "Mac")
        var phone = ContinuityClientSession(deviceID: "phone-1", deviceName: "iPhone")
        let id = UUID()
        #expect(manager.open(id))
        let reply = manager.receive(frame(try phone.pair(with: invitation)), from: id)
        #expect(reply.close)
        let key = try phone.finishPairing(try #require(reply.frames.first))
        return (manager, phone, key)
    }

    private func connect(_ manager: MorphContinuityManager, _ phone: inout ContinuityClientSession, key: SymmetricKey) throws -> UUID {
        let id = UUID()
        _ = manager.open(id)
        let challenge = manager.receive(frame(phone.hello(deviceKey: key)), from: id)
        let first = try phone.accept(try #require(challenge.frames.first))
        #expect(!manager.receive(frame(first), from: id).close)
        return id
    }

    @Test func pairingStoresTheKeyOnBothSidesAndIsSingleUse() throws {
        let (manager, _, key) = try paired()
        #expect(manager.devices.map(\.id) == ["phone-1"])
        #expect(manager.invitation == nil)
        #expect(store.items["phone-1"]?.1.withUnsafeBytes { Data($0) } == key.withUnsafeBytes { Data($0) })
    }

    @Test func aWrongSecretCantPair() throws {
        let manager = MorphContinuityManager(store: store, scheduler: scheduler)
        let real = manager.beginPairing(service: "Morph", macName: "Mac")
        var forged = real
        forged.secret = ContinuityProtocol.randomBytes(32)
        var phone = ContinuityClientSession(deviceID: "evil", deviceName: "x")
        let id = UUID()
        _ = manager.open(id)
        let reply = manager.receive(frame(try phone.pair(with: forged)), from: id)
        #expect(reply.frames.first?.type == .refused)
        #expect(manager.devices.isEmpty)
    }

    @Test func expiredInvitationsAreRefused() throws {
        var phone = ContinuityClientSession(deviceID: "p", deviceName: "x")
        let old = PairingInvitation(service: "s", secret: ContinuityProtocol.randomBytes(32), macName: "Mac", expires: .now.addingTimeInterval(-1))
        #expect(throws: ContinuityError.pairingExpired) { try phone.pair(with: old) }
    }

    @Test func invitationRoundTripsThroughItsURL() {
        let invitation = PairingInvitation(service: "Morph on Mac", secret: ContinuityProtocol.randomBytes(32), macName: "Mac",
                                           expires: Date(timeIntervalSince1970: 2_000_000_000))
        #expect(PairingInvitation(url: invitation.url) == invitation)
        #expect(PairingInvitation(url: URL(string: "https://example.com")!) == nil)
    }

    @Test func syncedActivitiesArriveUpdateAndEnd() throws {
        var (manager, phone, key) = try paired()
        var events: [MorphContinuityManager.Event] = []
        manager.onEvent = { events.append($0) }
        let id = try connect(manager, &phone, key: key)
        #expect(manager.connected.contains("phone-1"))

        let activity = ContinuityActivityPayload(id: "ride", service: "Ride", title: "Car arriving", icon: "car",
                                                 endsAt: .now.addingTimeInterval(300))
        let ack = manager.receive(frame(try phone.seal(ContinuityMessage(kind: .upsert, activity: activity))), from: id)
        #expect(try phone.open(try #require(ack.frames.first)).kind == .ack)
        #expect(manager.activities.first?.payload.title == "Car arriving")
        _ = manager.receive(frame(try phone.seal(ContinuityMessage(kind: .upsert, activity: activity))), from: id)
        _ = manager.receive(frame(try phone.seal(ContinuityMessage(kind: .end, id: "ride"))), from: id)
        #expect(manager.activities.isEmpty)
        #expect(events.count == 2, "A repeated identical update is only a keep-alive")
    }

    @Test func replayedAndTamperedFramesAreRefused() throws {
        var (manager, phone, key) = try paired()
        let id = try connect(manager, &phone, key: key)
        let message = frame(try phone.seal(ContinuityMessage(kind: .ping)))
        #expect(!manager.receive(message, from: id).close)
        #expect(manager.receive(message, from: id).close, "Same frame twice")

        let other = try connect(manager, &phone, key: key)
        var sealed = try phone.seal(ContinuityMessage(kind: .ping))
        sealed.box![sealed.box!.count - 1] ^= 1
        #expect(manager.receive(frame(sealed), from: other).close)
    }

    @Test func unknownDevicesAndWrongKeysCantConnect() throws {
        var (manager, phone, _) = try paired()
        let id = UUID()
        _ = manager.open(id)
        let challenge = manager.receive(frame(phone.hello(deviceKey: SymmetricKey(size: .bits256))), from: id)
        let forged = try phone.accept(try #require(challenge.frames.first))
        #expect(manager.receive(frame(forged), from: id).close)

        var stranger = ContinuityClientSession(deviceID: "stranger", deviceName: "x")
        let other = UUID()
        _ = manager.open(other)
        #expect(manager.receive(frame(stranger.hello(deviceKey: SymmetricKey(size: .bits256))), from: other).frames.first?.type == .refused)
    }

    @Test func revocationDropsTheDeviceItsActivitiesAndItsConnection() throws {
        var (manager, phone, key) = try paired()
        var dropped: [UUID] = []
        manager.onDisconnect = { dropped.append($0) }
        let id = try connect(manager, &phone, key: key)
        _ = manager.receive(frame(try phone.seal(ContinuityMessage(kind: .upsert, activity: ContinuityActivityPayload(id: "a", service: "S", title: "T")))), from: id)
        manager.revoke(id: "phone-1")
        #expect(manager.devices.isEmpty && manager.activities.isEmpty)
        #expect(dropped == [id])
        #expect(store.items.isEmpty)
        let again = UUID()
        _ = manager.open(again)
        #expect(manager.receive(frame(phone.hello(deviceKey: key)), from: again).frames.first?.type == .refused)
    }

    @Test func lostConnectionsGoStaleThenExpireAndReconnectRecovers() throws {
        var (manager, phone, key) = try paired()
        let id = try connect(manager, &phone, key: key)
        _ = manager.receive(frame(try phone.seal(ContinuityMessage(kind: .upsert, activity: ContinuityActivityPayload(id: "a", service: "S", title: "T")))), from: id)
        manager.close(id)
        #expect(manager.activities.first?.isStale == true)
        _ = try connect(manager, &phone, key: key)
        #expect(manager.activities.first?.isStale == false)
        scheduler.advance(by: .seconds(121))
        #expect(manager.activities.isEmpty, "Without a fresh update, the grace period still ends it")
    }

    @Test func activitiesExpireWithoutUpdates() throws {
        var (manager, phone, key) = try paired()
        let id = try connect(manager, &phone, key: key)
        _ = manager.receive(frame(try phone.seal(ContinuityMessage(kind: .upsert, activity: ContinuityActivityPayload(id: "a", service: "S", title: "T", lifetime: 60)))), from: id)
        scheduler.advance(by: .seconds(61))
        #expect(manager.activities.isEmpty)
    }

    @Test func invalidActivitiesAreRejectedAndCounted() throws {
        var (manager, phone, key) = try paired()
        let id = try connect(manager, &phone, key: key)
        let bad = ContinuityActivityPayload(id: "a/b", service: "S", title: "T")
        _ = manager.receive(frame(try phone.seal(ContinuityMessage(kind: .upsert, activity: bad))), from: id)
        let icon = ContinuityActivityPayload(id: "a", service: "S", title: "T", icon: "../../etc")
        _ = manager.receive(frame(try phone.seal(ContinuityMessage(kind: .upsert, activity: icon))), from: id)
        #expect(manager.activities.isEmpty)
        #expect(manager.refusedCount == 2)
    }

    @Test func messageFloodsAreLimited() throws {
        var (manager, phone, key) = try paired()
        let id = try connect(manager, &phone, key: key)
        var closed = false
        for _ in 0..<40 where !closed {
            closed = manager.receive(frame(try phone.seal(ContinuityMessage(kind: .ping))), from: id).close
        }
        #expect(closed)
    }

    @Test func oversizedFramesAreRefusedBeforeReading() {
        var buffer = Data([0x7F, 0xFF, 0xFF, 0xFF])
        #expect(throws: ContinuityError.frameTooLarge) { try ContinuityProtocol.takeFrames(from: &buffer) }
    }

    @Test func onlyLocalAddressesAreAccepted() {
        func host(_ text: String) -> NWEndpoint { .hostPort(host: NWEndpoint.Host(text), port: 1) }
        #expect(ContinuityListener.isLocal(host("192.168.1.20")))
        #expect(ContinuityListener.isLocal(host("10.0.0.5")))
        #expect(ContinuityListener.isLocal(host("fe80::1")))
        #expect(!ContinuityListener.isLocal(host("8.8.8.8")))
        #expect(!ContinuityListener.isLocal(host("2001:4860::8888")))
    }

    @Test func sensitiveActivitiesNameOnlyTheService() {
        let activity = ContinuityActivity(deviceID: "p", deviceName: "iPhone",
                                          payload: ContinuityActivityPayload(id: "a", service: "Delivery", title: "Order from home address", sensitive: true),
                                          expiresAt: .now)
        #expect(IslandActivity.Content.continuity(activity, hidesDetails: true).title == "Delivery")
        #expect(IslandActivity.Content.continuity(activity, hidesDetails: false).title == "Order from home address")
    }
}
