import CryptoKit
import Foundation
import Observation

/// An activity a paired device sent. It lives only as long as its sender keeps it alive.
struct ContinuityActivity: Identifiable, Equatable, Sendable {
    var id: String { "\(deviceID)/\(payload.id)" }
    var deviceID: String
    var deviceName: String
    var payload: ContinuityActivityPayload
    var expiresAt: ContinuousClock.Instant
    /// The device dropped off. Kept briefly in case it comes back, and shown as out of date.
    var isStale = false

    var symbol: String { ContinuityActivityPayload.icons[payload.icon] ?? "dot.radiowaves.left.and.right" }
}

/// Receives activities from authorized sources: paired iPhones running Morph Companion. Owns
/// pairing, the handshake, revocation, rate limits and expiry. Networking is someone else's job:
/// this takes frames in and hands frames back, which is also how the tests drive it.
@MainActor
@Observable
final class MorphContinuityManager {
    enum Event: Equatable, Sendable {
        case started(ContinuityActivity)
        case updated(ContinuityActivity)
        case ended(ContinuityActivity)
    }

    struct Reply: Equatable, Sendable {
        var frames: [HandshakeFrame] = []
        var close = false
    }

    static let maximumConnections = 8
    static let maximumPerDevice = 8
    static let staleGrace = Duration.seconds(120)

    private(set) var devices: [PairedDevice] = []
    private(set) var connected: Set<String> = []
    private(set) var activities: [ContinuityActivity] = []
    private(set) var invitation: PairingInvitation?
    private(set) var refusedCount = 0
    private(set) var lastProblem: String?

    @ObservationIgnored var onEvent: ((Event) -> Void)?
    /// Asks the network layer to drop a connection, after a revocation.
    @ObservationIgnored var onDisconnect: ((UUID) -> Void)?

    private enum Phase {
        case fresh
        case challenged(device: String, key: SymmetricKey, clientNonce: Data, serverNonce: Data)
        case ready(device: String, channel: SealedChannel)
    }

    private struct Connection {
        var phase = Phase.fresh
        var bucket: TokenBucket
    }

    @ObservationIgnored private let store: any ContinuityKeyStoring
    @ObservationIgnored private let scheduler: any Scheduling
    @ObservationIgnored private var keys: [String: SymmetricKey] = [:]
    @ObservationIgnored private var connections: [UUID: Connection] = [:]
    @ObservationIgnored private var failures: TokenBucket
    @ObservationIgnored private var expiryWork: (any ScheduledWork)?

    init(store: any ContinuityKeyStoring, scheduler: any Scheduling) {
        self.store = store
        self.scheduler = scheduler
        failures = TokenBucket(capacity: LiveActivityLimits.failureBurst, rate: LiveActivityLimits.failureRate, now: scheduler.now)
        for (device, key) in store.load() {
            devices.append(device)
            keys[device.id] = key
        }
        devices.sort { $0.pairedAt < $1.pairedAt }
    }

    // MARK: - Pairing and devices

    /// A new single-use invitation. Showing it again replaces the old one.
    func beginPairing(service: String, macName: String, now: Date = .now) -> PairingInvitation {
        let invitation = PairingInvitation(service: service, secret: ContinuityProtocol.randomBytes(32), macName: macName,
                                           expires: now.addingTimeInterval(ContinuityProtocol.pairingLifetime))
        self.invitation = invitation
        return invitation
    }

    func cancelPairing() {
        invitation = nil
    }

    /// The key goes, its connections go, and so does everything it sent.
    func revoke(id: String) {
        store.delete(id: id)
        keys[id] = nil
        devices.removeAll { $0.id == id }
        for (connectionID, connection) in connections {
            switch connection.phase {
            case .ready(let device, _) where device == id, .challenged(let device, _, _, _) where device == id:
                drop(connectionID)
            default:
                continue
            }
        }
        connected.remove(id)
        for activity in activities where activity.deviceID == id { end(activity) }
    }

    func removeAllActivities() {
        activities = []
        expiryWork?.cancel()
        expiryWork = nil
    }

    // MARK: - Connections

    /// Returns false when there are already as many as Morph takes.
    func open(_ id: UUID) -> Bool {
        guard connections.count < Self.maximumConnections else { return false }
        connections[id] = Connection(bucket: TokenBucket(capacity: LiveActivityLimits.requestBurst,
                                                         rate: LiveActivityLimits.requestRate, now: scheduler.now))
        return true
    }

    func close(_ id: UUID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        guard case .ready(let device, _) = connection.phase else { return }
        let stillConnected = connections.values.contains {
            if case .ready(let other, _) = $0.phase { other == device } else { false }
        }
        guard !stillConnected else { return }
        connected.remove(device)
        // Gone quiet: keep its activities a moment in case it's only switching networks.
        let deadline = scheduler.now.advanced(by: Self.staleGrace)
        for index in activities.indices where activities[index].deviceID == device {
            activities[index].isStale = true
            activities[index].expiresAt = min(activities[index].expiresAt, deadline)
        }
        rearm()
    }

    func receive(_ data: Data, from id: UUID) -> Reply {
        guard var connection = connections[id] else { return Reply(close: true) }
        guard connection.bucket.take(at: scheduler.now) else { return refuse(id, "Too many messages") }
        guard let frame = try? JSONDecoder().decode(HandshakeFrame.self, from: data) else { return refuse(id, "Malformed frame") }

        switch (connection.phase, frame.type) {
        case (.fresh, .pair):
            return pair(frame, connection: id)
        case (.fresh, .hello):
            // Known devices reconnect freely; only strangers spend the failure budget.
            guard keys[frame.device ?? ""] != nil || failures.take(at: scheduler.now) else { return refuse(id, "Too many attempts") }
            guard let device = frame.device, let key = keys[device], let nonce = frame.nonce, nonce.count == 16 else {
                return refuse(id, "Unknown device")
            }
            let serverNonce = ContinuityProtocol.randomBytes(16)
            connection.phase = .challenged(device: device, key: key, clientNonce: nonce, serverNonce: serverNonce)
            connections[id] = connection
            return Reply(frames: [HandshakeFrame(type: .challenge, nonce: serverNonce)])
        case (.challenged(let device, let key, let clientNonce, let serverNonce), .sealed):
            let keys = ContinuityProtocol.sessionKeys(device: key, clientNonce: clientNonce, serverNonce: serverNonce)
            var channel = SealedChannel(sending: keys.serverToClient, receiving: keys.clientToServer)
            guard (try? channel.open(frame)) != nil else { return refuse(id, "Authentication failed") }
            connection.phase = .ready(device: device, channel: channel)
            connections[id] = connection
            connected.insert(device)
            for index in activities.indices where activities[index].deviceID == device { activities[index].isStale = false }
            return Reply()
        case (.ready(let device, var channel), .sealed):
            let message: ContinuityMessage
            do {
                message = try channel.open(frame)
            } catch {
                return refuse(id, error as? ContinuityError == .replayed ? "Replayed message" : "Authentication failed")
            }
            var reply = Reply()
            do {
                try handle(message, from: device)
                if message.kind != .ping, let ack = try? channel.seal(ContinuityMessage(kind: .ack, id: message.activity?.id ?? message.id)) {
                    reply.frames.append(ack)
                }
            } catch {
                lastProblem = "Rejected an activity: \(error)"
                refusedCount += 1
            }
            connection.phase = .ready(device: device, channel: channel)
            connections[id] = connection
            return reply
        default:
            return refuse(id, "Unexpected message")
        }
    }

    private func pair(_ frame: HandshakeFrame, connection id: UUID) -> Reply {
        guard failures.take(at: scheduler.now) else { return refuse(id, "Too many attempts") }
        guard let invitation else { return refuse(id, "Not pairing") }
        guard invitation.expires > .now else {
            self.invitation = nil
            return refuse(id, "Pairing code expired")
        }
        guard let device = frame.device, !device.isEmpty, device.count <= 64, let phoneKey = frame.key, let proof = frame.proof,
              let phonePublic = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: phoneKey),
              ContinuityProtocol.constantTimeEqual(proof, ContinuityProtocol.proof("pair", secret: invitation.secret,
                                                                                   parts: [Data(device.utf8), phoneKey])) else {
            return refuse(id, "Pairing proof didn't match")
        }
        let macKey = Curve25519.KeyAgreement.PrivateKey()
        guard let shared = try? macKey.sharedSecretFromKeyAgreement(with: phonePublic) else { return refuse(id, "Pairing failed") }
        let key = ContinuityProtocol.deviceKey(shared: shared, secret: invitation.secret, deviceID: device)
        let name = String((frame.name ?? "iPhone").prefix(40))
        let paired = PairedDevice(id: device, name: name, pairedAt: .now)
        guard store.save(paired, key: key) else { return refuse(id, "Couldn't store the device key") }
        // Single use: the code is spent whether or not anything else happens.
        self.invitation = nil
        keys[device] = key
        devices.removeAll { $0.id == device }
        devices.append(paired)
        let macPublic = macKey.publicKey.rawRepresentation
        let reply = HandshakeFrame(type: .paired, key: macPublic,
                                   proof: ContinuityProtocol.proof("paired", secret: invitation.secret, parts: [macPublic, phoneKey]))
        // The device reconnects with its new key; this connection has done its job.
        connections[id] = nil
        return Reply(frames: [reply], close: true)
    }

    private func refuse(_ id: UUID, _ reason: String) -> Reply {
        refusedCount += 1
        lastProblem = reason
        close(id)
        return Reply(frames: [HandshakeFrame(type: .refused, reason: reason)], close: true)
    }

    private func drop(_ id: UUID) {
        close(id)
        onDisconnect?(id)
    }

    // MARK: - Activities

    private func handle(_ message: ContinuityMessage, from device: String) throws {
        switch message.kind {
        case .ping, .ack, .revoked:
            return
        case .end:
            guard let id = message.id, let activity = activities.first(where: { $0.deviceID == device && $0.payload.id == id }) else { return }
            end(activity)
        case .upsert:
            guard let payload = try message.activity?.validated() else { throw ContinuityError.malformed }
            let lifetime = payload.lifetime ?? ContinuityActivityPayload.defaultLifetime
            let expiry = scheduler.now.advanced(by: .seconds(lifetime))
            let name = devices.first { $0.id == device }?.name ?? "iPhone"
            if let index = activities.firstIndex(where: { $0.deviceID == device && $0.payload.id == payload.id }) {
                let previous = activities[index]
                activities[index].payload = payload
                activities[index].expiresAt = expiry
                activities[index].isStale = false
                rearm()
                // The same content again is only a keep-alive.
                if previous.payload != payload { onEvent?(.updated(activities[index])) }
            } else {
                guard activities.filter({ $0.deviceID == device }).count < Self.maximumPerDevice else {
                    throw ContinuityError.invalid("too many activities")
                }
                let activity = ContinuityActivity(deviceID: device, deviceName: name, payload: payload, expiresAt: expiry)
                activities.append(activity)
                rearm()
                onEvent?(.started(activity))
            }
        }
    }

    private func end(_ activity: ContinuityActivity) {
        activities.removeAll { $0.id == activity.id }
        rearm()
        onEvent?(.ended(activity))
    }

    private func rearm() {
        expiryWork?.cancel()
        expiryWork = nil
        guard let next = activities.map(\.expiresAt).min() else { return }
        expiryWork = scheduler.schedule(after: max(.zero, scheduler.now.duration(to: next))) { [weak self] in self?.expire() }
    }

    private func expire() {
        let now = scheduler.now
        let expired = activities.filter { $0.expiresAt <= now }
        activities.removeAll { $0.expiresAt <= now }
        rearm()
        expired.forEach { onEvent?(.ended($0)) }
    }
}
