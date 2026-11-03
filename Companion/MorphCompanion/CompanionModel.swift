import CryptoKit
import Foundation
import Network
import Observation
import Security
import UIKit

/// The Mac this iPhone paired with. The key lives in the Keychain, never in plain storage.
struct PairedMac: Codable, Equatable, Identifiable {
    var id: String { service }
    var service: String
    var name: String
    var pairedAt: Date
}

enum CompanionKeychain {
    private static let service = "com.athene.morph.companion"

    private struct Record: Codable {
        var mac: PairedMac
        var key: Data
    }

    static func load() -> (PairedMac, SymmetricKey)? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let record = try? JSONDecoder().decode(Record.self, from: data), record.key.count == 32 else { return nil }
        return (record.mac, SymmetricKey(data: record.key))
    }

    static func save(_ mac: PairedMac, key: SymmetricKey) {
        delete()
        guard let data = try? JSONEncoder().encode(Record(mac: mac, key: key.withUnsafeBytes { Data($0) })) else { return }
        SecItemAdd([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                    kSecAttrAccount as String: "mac", kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}

/// Pairs with one Mac, keeps a connection to it while the app is open, and sends the activities
/// the user creates here or that Shortcuts hands over. iOS suspends apps in the background, so
/// sync pauses there; the Mac shows that rather than pretending otherwise.
@MainActor
@Observable
final class CompanionModel {
    enum Status: Equatable {
        case notPaired
        case pairing
        case connecting
        case connected
        case waiting(String)
    }

    static let shared = CompanionModel()
    private static let heartbeat = Duration.seconds(25)

    private(set) var status = Status.notPaired
    private(set) var mac: PairedMac?
    private(set) var activities: [ContinuityActivityPayload] = []
    private(set) var lastError: String?

    private var key: SymmetricKey?
    private var session: ContinuityClientSession
    private var connection: NWConnection?
    private var buffer = Data()
    private var retry = 0
    private var retryTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var isActive = true
    private let queue = DispatchQueue(label: "com.athene.morph.companion")

    private init() {
        let defaults = UserDefaults.standard
        let id = defaults.string(forKey: "deviceID") ?? UUID().uuidString
        defaults.set(id, forKey: "deviceID")
        session = ContinuityClientSession(deviceID: id, deviceName: UIDevice.current.name)
        if let (mac, key) = CompanionKeychain.load() {
            self.mac = mac
            self.key = key
            status = .connecting
        }
    }

    // MARK: Pairing

    /// From the QR code, opened by the Camera app, or a pasted link.
    func pair(with url: URL) {
        guard let invitation = PairingInvitation(url: url) else {
            lastError = "That isn't a Morph pairing code."
            return
        }
        guard invitation.expires > .now else {
            lastError = "That code expired. Show a new one on the Mac."
            return
        }
        disconnect()
        status = .pairing
        let frame: HandshakeFrame
        do {
            frame = try session.pair(with: invitation)
        } catch {
            lastError = "That code expired."
            status = .notPaired
            return
        }
        open(service: invitation.service) { [weak self] connection in
            self?.send(frame, on: connection)
        } onFrame: { [weak self] reply in
            guard let self else { return }
            if reply.type == .refused {
                self.lastError = reply.reason ?? "The Mac refused to pair."
                self.status = .notPaired
                self.disconnect()
                return
            }
            guard let key = try? self.session.finishPairing(reply) else {
                self.lastError = "The Mac couldn't prove it showed that code."
                self.status = .notPaired
                self.disconnect()
                return
            }
            let mac = PairedMac(service: invitation.service, name: invitation.macName, pairedAt: .now)
            CompanionKeychain.save(mac, key: key)
            self.mac = mac
            self.key = key
            self.lastError = nil
            self.disconnect()
            self.connect()
        }
    }

    /// Forgets the Mac here. The Mac keeps listing this iPhone until it's removed there too.
    func forget() {
        disconnect()
        CompanionKeychain.delete()
        mac = nil
        key = nil
        status = .notPaired
    }

    // MARK: Connection

    func setActive(_ active: Bool) {
        isActive = active
        if active {
            retry = 0
            connect()
        } else {
            disconnect()
            if mac != nil { status = .waiting("Paused while Morph is in the background") }
        }
    }

    func connect() {
        guard isActive, let mac, let key, connection == nil else { return }
        status = .connecting
        let hello = session.hello(deviceKey: key)
        open(service: mac.service) { [weak self] connection in
            self?.send(hello, on: connection)
        } onFrame: { [weak self] frame in
            self?.handle(frame)
        }
    }

    private func handle(_ frame: HandshakeFrame) {
        switch frame.type {
        case .challenge:
            guard let first = try? session.accept(frame), let connection else { return disconnect(retrying: true) }
            send(first, on: connection)
            status = .connected
            retry = 0
            lastError = nil
            activities.forEach { upsertOnWire($0) }
            startHeartbeat()
        case .sealed:
            guard let message = try? session.open(frame) else { return disconnect(retrying: true) }
            if message.kind == .revoked { forget() }
        case .refused:
            lastError = frame.reason
            if frame.reason == "Unknown device" {
                forget()
                lastError = "The Mac removed this iPhone. Pair again."
            } else {
                disconnect(retrying: true)
            }
        default:
            disconnect(retrying: true)
        }
    }

    private func open(service: String, onReady: @escaping @MainActor (NWConnection) -> Void,
                      onFrame: @escaping @MainActor (HandshakeFrame) -> Void) {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let connection = NWConnection(to: .service(name: service, type: ContinuityProtocol.serviceType, domain: "local.", interface: nil),
                                      using: parameters)
        self.connection = connection
        buffer = Data()
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                switch state {
                case .ready: onReady(connection)
                case .failed(let error):
                    self.lastError = error.localizedDescription
                    self.disconnect(retrying: true)
                case .waiting(let error):
                    self.status = .waiting(error.localizedDescription)
                default: break
                }
            }
        }
        connection.start(queue: queue)
        receive(on: connection, onFrame: onFrame)
    }

    private nonisolated func receive(on connection: NWConnection, onFrame: @escaping @MainActor (HandshakeFrame) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                self.buffer += data ?? Data()
                guard let frames = try? ContinuityProtocol.takeFrames(from: &self.buffer) else { return self.disconnect(retrying: true) }
                for data in frames {
                    guard let frame = try? JSONDecoder().decode(HandshakeFrame.self, from: data) else { return self.disconnect(retrying: true) }
                    onFrame(frame)
                }
                if isComplete || error != nil {
                    if self.connection === connection { self.disconnect(retrying: self.mac != nil) }
                } else {
                    self.receive(on: connection, onFrame: onFrame)
                }
            }
        }
    }

    private func send(_ frame: HandshakeFrame, on connection: NWConnection) {
        guard let data = try? ContinuityProtocol.frame(frame) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func disconnect(retrying: Bool = false) {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        retryTask?.cancel()
        retryTask = nil
        connection?.cancel()
        connection = nil
        guard retrying, isActive, mac != nil else { return }
        // Backs off to a minute, so a Mac that's asleep isn't hammered.
        retry += 1
        let delay = Duration.seconds(min(60, 1 << min(retry, 6)))
        status = .waiting("Mac not reachable. Retrying…")
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeat)
                guard !Task.isCancelled else { return }
                self?.sendMessage(ContinuityMessage(kind: .ping))
            }
        }
    }

    private func sendMessage(_ message: ContinuityMessage) {
        guard status == .connected, let connection, let frame = try? session.seal(message) else { return }
        send(frame, on: connection)
    }

    // MARK: Activities

    /// Validated here first, so a mistake shows on the phone rather than vanishing on the Mac.
    @discardableResult
    func upsert(_ activity: ContinuityActivityPayload) -> Bool {
        guard let valid = try? activity.validated() else {
            lastError = "That activity has a field that's too long or out of range."
            return false
        }
        if let index = activities.firstIndex(where: { $0.id == valid.id }) {
            activities[index] = valid
        } else {
            guard activities.count < 8 else {
                lastError = "Eight activities at a time."
                return false
            }
            activities.append(valid)
        }
        upsertOnWire(valid)
        return true
    }

    func end(_ id: String) {
        activities.removeAll { $0.id == id }
        sendMessage(ContinuityMessage(kind: .end, id: id))
    }

    private func upsertOnWire(_ activity: ContinuityActivityPayload) {
        sendMessage(ContinuityMessage(kind: .upsert, activity: activity))
    }
}
