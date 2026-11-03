import CryptoKit
import Foundation

/// The Mac and iPhone side of Morph Continuity share this file. Everything that crosses the
/// network is defined and checked here, so the two can't disagree about it.
///
/// Security in brief:
/// - Pairing needs a 256-bit secret the Mac shows as a QR code. It never crosses the network, so
///   someone on the same Wi-Fi can't pair, and can't learn anything to guess offline.
/// - Pairing runs an X25519 exchange, each side proving it knows the secret. The device key comes
///   from the exchange and the secret together, and is stored in the Keychain on both sides.
/// - Every connection derives a fresh session key from the device key and two random nonces, so a
///   recorded session can't be replayed into a new one. Within a session, sequence numbers must
///   rise, so frames can't be replayed or reordered either.
/// - Revoking a device deletes its key. It has to pair again with a new QR code.
public enum ContinuityProtocol {
    public static let version = 1
    public static let serviceType = "_morphsync._tcp"
    public static let maximumFrame = 16 * 1024
    public static let pairingLifetime: TimeInterval = 5 * 60
    static let keyInfo = Data("morph-continuity-v1".utf8)
    static let sessionInfo = Data("morph-continuity-session-v1".utf8)

    // MARK: Framing

    /// Four bytes of big-endian length, then that much JSON.
    public static func frame(_ object: some Encodable) throws -> Data {
        let body = try JSONEncoder().encode(object)
        guard body.count <= maximumFrame else { throw ContinuityError.frameTooLarge }
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }

    /// Splits complete frames off the front of `buffer`. Throws on an oversized frame, which ends
    /// the connection before any of it is read.
    public static func takeFrames(from buffer: inout Data) throws -> [Data] {
        var frames: [Data] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = Int(buffer[start]) << 24 | Int(buffer[start + 1]) << 16 | Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
            guard length <= maximumFrame else { throw ContinuityError.frameTooLarge }
            guard buffer.count >= 4 + length else { break }
            frames.append(Data(buffer[(start + 4)..<(start + 4 + length)]))
            buffer = Data(buffer[(start + 4 + length)...])
        }
        return frames
    }

    // MARK: Keys

    public static func deviceKey(shared: SharedSecret, secret: Data, deviceID: String) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: secret, sharedInfo: keyInfo + Data(deviceID.utf8), outputByteCount: 32)
    }

    /// One key per direction, so a frame can't be reflected back at its sender.
    public static func sessionKeys(device: SymmetricKey, clientNonce: Data, serverNonce: Data)
        -> (clientToServer: SymmetricKey, serverToClient: SymmetricKey) {
        let salt = clientNonce + serverNonce
        return (HKDF<SHA256>.deriveKey(inputKeyMaterial: device, salt: salt, info: sessionInfo + Data("c2s".utf8), outputByteCount: 32),
                HKDF<SHA256>.deriveKey(inputKeyMaterial: device, salt: salt, info: sessionInfo + Data("s2c".utf8), outputByteCount: 32))
    }

    public static func proof(_ label: String, secret: Data, parts: [Data]) -> Data {
        var hmac = HMAC<SHA256>(key: SymmetricKey(data: secret))
        hmac.update(data: Data(label.utf8))
        parts.forEach { hmac.update(data: $0) }
        return Data(hmac.finalize())
    }

    public static func randomBytes(_ count: Int) -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }

    /// Takes the same time wherever the first difference is.
    public static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

public enum ContinuityError: Error, Equatable {
    case frameTooLarge
    case malformed
    case notPairing
    case pairingExpired
    case badProof
    case unknownDevice
    case badSeal
    case replayed
    case invalid(String)
}

/// What the QR code carries. The secret stays on the two devices.
public struct PairingInvitation: Codable, Equatable, Sendable {
    public var version: Int
    /// The Mac's Bonjour service name, so the iPhone connects to the right Mac.
    public var service: String
    public var secret: Data
    public var macName: String
    public var expires: Date

    public init(service: String, secret: Data, macName: String, expires: Date) {
        version = ContinuityProtocol.version
        self.service = service
        self.secret = secret
        self.macName = macName
        self.expires = expires
    }

    public var url: URL {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return URL(string: "morph-pair://\(data.base64URLEncoded)")!
    }

    public init?(url: URL) {
        guard url.scheme == "morph-pair", let host = url.host(percentEncoded: false) ?? url.absoluteString.split(separator: "/").last.map(String.init),
              let data = Data(base64URLEncoded: host),
              let invitation = try? JSONDecoder().decode(PairingInvitation.self, from: data),
              invitation.version == ContinuityProtocol.version, invitation.secret.count == 32 else { return nil }
        self = invitation
    }
}

/// Unencrypted handshake frames. Only these may travel in the clear, and none carries content.
public struct HandshakeFrame: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case pair, paired, hello, challenge, sealed, refused
    }

    public var type: Kind
    public var device: String?
    public var name: String?
    public var key: Data?
    public var proof: Data?
    public var nonce: Data?
    /// A `ChaChaPoly` combined box, for `sealed`.
    public var box: Data?
    public var reason: String?

    public init(type: Kind, device: String? = nil, name: String? = nil, key: Data? = nil, proof: Data? = nil,
                nonce: Data? = nil, box: Data? = nil, reason: String? = nil) {
        self.type = type
        self.device = device
        self.name = name
        self.key = key
        self.proof = proof
        self.nonce = nonce
        self.box = box
        self.reason = reason
    }
}

/// An activity the iPhone sends: something the Companion or an app integrated with it owns.
public struct ContinuityActivityPayload: Codable, Equatable, Sendable {
    public enum State: String, Codable, CaseIterable, Sendable {
        case running, paused, success, failed
    }

    public static let icons: [String: String] = [
        "activity": "dot.radiowaves.left.and.right",
        "bag": "bag.fill",
        "bell": "bell.fill",
        "box": "shippingbox.fill",
        "car": "car.fill",
        "check": "checkmark.circle.fill",
        "food": "fork.knife",
        "sport": "sportscourt.fill",
        "timer": "timer",
        "train": "tram.fill",
        "walk": "figure.walk",
    ]
    public static let maximumLifetime: TimeInterval = 4 * 60 * 60
    public static let defaultLifetime: TimeInterval = 30 * 60

    public var id: String
    /// Which app or service it's about, as the sender names it.
    public var service: String
    public var title: String
    public var subtitle: String?
    public var icon: String
    public var progress: Double?
    /// A countdown target, such as an arrival time.
    public var endsAt: Date?
    public var state: State
    /// Hidden while locked, and from previews, unless the user allows it.
    public var sensitive: Bool
    /// Seconds it stays without another update.
    public var lifetime: TimeInterval?

    public init(id: String, service: String, title: String, subtitle: String? = nil, icon: String = "activity",
                progress: Double? = nil, endsAt: Date? = nil, state: State = .running, sensitive: Bool = true,
                lifetime: TimeInterval? = nil) {
        self.id = id
        self.service = service
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.progress = progress
        self.endsAt = endsAt
        self.state = state
        self.sensitive = sensitive
        self.lifetime = lifetime
    }

    public func validated(now: Date = .now) throws -> ContinuityActivityPayload {
        func text(_ value: String, _ name: String, _ limit: Int, required: Bool = true) throws {
            if required, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ContinuityError.invalid("\(name) can't be empty") }
            guard value.count <= limit else { throw ContinuityError.invalid("\(name) is too long") }
            guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw ContinuityError.invalid("\(name) can't hold control characters")
            }
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !id.isEmpty, id.count <= 64, id.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }) else {
            throw ContinuityError.invalid("id")
        }
        try text(service, "service", 40)
        try text(title, "title", 80)
        if let subtitle { try text(subtitle, "subtitle", 120, required: false) }
        guard Self.icons[icon] != nil else { throw ContinuityError.invalid("icon") }
        if let progress, !(progress.isFinite && (0...1).contains(progress)) { throw ContinuityError.invalid("progress") }
        if let endsAt, abs(endsAt.timeIntervalSince(now)) > 24 * 60 * 60 { throw ContinuityError.invalid("endsAt") }
        if let lifetime, !(lifetime.isFinite && lifetime >= 1 && lifetime <= Self.maximumLifetime) { throw ContinuityError.invalid("lifetime") }
        return self
    }
}

/// What travels inside a sealed frame.
public struct ContinuityMessage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case upsert, end, ping, ack, revoked
    }

    public var kind: Kind
    public var activity: ContinuityActivityPayload?
    public var id: String?

    public init(kind: Kind, activity: ContinuityActivityPayload? = nil, id: String? = nil) {
        self.kind = kind
        self.activity = activity
        self.id = id
    }
}

/// One direction of a session: seals outgoing messages and opens incoming ones, refusing anything
/// tampered with, replayed or out of order.
public struct SealedChannel: Sendable {
    private struct Envelope: Codable {
        var seq: UInt64
        var body: ContinuityMessage
    }

    private let sending: SymmetricKey
    private let receiving: SymmetricKey
    private var sent: UInt64 = 0
    private var received: UInt64 = 0

    public init(sending: SymmetricKey, receiving: SymmetricKey) {
        self.sending = sending
        self.receiving = receiving
    }

    public mutating func seal(_ message: ContinuityMessage) throws -> HandshakeFrame {
        sent += 1
        let plain = try JSONEncoder().encode(Envelope(seq: sent, body: message))
        let box = try ChaChaPoly.seal(plain, using: sending).combined
        return HandshakeFrame(type: .sealed, box: box)
    }

    public mutating func open(_ frame: HandshakeFrame) throws -> ContinuityMessage {
        guard frame.type == .sealed, let box = frame.box,
              let sealed = try? ChaChaPoly.SealedBox(combined: box),
              let plain = try? ChaChaPoly.open(sealed, using: receiving) else { throw ContinuityError.badSeal }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: plain) else { throw ContinuityError.malformed }
        guard envelope.seq > received else { throw ContinuityError.replayed }
        received = envelope.seq
        return envelope.body
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded text: String) {
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base += String(repeating: "=", count: (4 - base.count % 4) % 4)
        self.init(base64Encoded: base)
    }
}

/// The iPhone's half of the handshake, kept free of networking so both apps' tests can run it.
public struct ContinuityClientSession: Sendable {
    public let deviceID: String
    public let deviceName: String
    private var pairingKey: Curve25519.KeyAgreement.PrivateKey?
    private var invitation: PairingInvitation?
    private var deviceKey: SymmetricKey?
    private var clientNonce: Data?
    private var channel: SealedChannel?

    public init(deviceID: String, deviceName: String) {
        self.deviceID = deviceID
        self.deviceName = deviceName
    }

    public var isReady: Bool { channel != nil }

    public mutating func pair(with invitation: PairingInvitation, now: Date = .now) throws -> HandshakeFrame {
        guard invitation.expires > now else { throw ContinuityError.pairingExpired }
        let key = Curve25519.KeyAgreement.PrivateKey()
        pairingKey = key
        self.invitation = invitation
        let publicKey = key.publicKey.rawRepresentation
        return HandshakeFrame(type: .pair, device: deviceID, name: deviceName, key: publicKey,
                              proof: ContinuityProtocol.proof("pair", secret: invitation.secret, parts: [Data(deviceID.utf8), publicKey]))
    }

    /// Checks the Mac knew the secret too, then returns the device key to keep in the Keychain.
    public mutating func finishPairing(_ frame: HandshakeFrame) throws -> SymmetricKey {
        defer { pairingKey = nil; invitation = nil }
        guard frame.type == .paired, let pairingKey, let invitation, let macKey = frame.key, let proof = frame.proof else {
            throw ContinuityError.badProof
        }
        let expected = ContinuityProtocol.proof("paired", secret: invitation.secret, parts: [macKey, pairingKey.publicKey.rawRepresentation])
        guard ContinuityProtocol.constantTimeEqual(proof, expected),
              let macPublic = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: macKey) else { throw ContinuityError.badProof }
        let shared = try pairingKey.sharedSecretFromKeyAgreement(with: macPublic)
        return ContinuityProtocol.deviceKey(shared: shared, secret: invitation.secret, deviceID: deviceID)
    }

    public mutating func hello(deviceKey: SymmetricKey) -> HandshakeFrame {
        let nonce = ContinuityProtocol.randomBytes(16)
        self.deviceKey = deviceKey
        clientNonce = nonce
        channel = nil
        return HandshakeFrame(type: .hello, device: deviceID, nonce: nonce)
    }

    /// The first sealed frame proves the device holds its key.
    public mutating func accept(_ challenge: HandshakeFrame) throws -> HandshakeFrame {
        guard challenge.type == .challenge, let serverNonce = challenge.nonce, serverNonce.count == 16,
              let deviceKey, let clientNonce else { throw ContinuityError.malformed }
        let keys = ContinuityProtocol.sessionKeys(device: deviceKey, clientNonce: clientNonce, serverNonce: serverNonce)
        var channel = SealedChannel(sending: keys.clientToServer, receiving: keys.serverToClient)
        let first = try channel.seal(ContinuityMessage(kind: .ping))
        self.channel = channel
        return first
    }

    public mutating func seal(_ message: ContinuityMessage) throws -> HandshakeFrame {
        guard var channel else { throw ContinuityError.malformed }
        defer { self.channel = channel }
        return try channel.seal(message)
    }

    public mutating func open(_ frame: HandshakeFrame) throws -> ContinuityMessage {
        guard var channel else { throw ContinuityError.malformed }
        defer { self.channel = channel }
        return try channel.open(frame)
    }
}
