import Foundation
import Network
import Observation

/// The network side of Continuity: a Bonjour-advertised TCP listener for the local network only.
/// It moves frames between sockets and `MorphContinuityManager`, and decides nothing itself.
/// No port is forwarded, no router is asked to open anything, and the local HTTP API is separate.
@MainActor
@Observable
final class ContinuityListener {
    enum Status: Equatable, Sendable {
        case off
        case starting
        case advertising(String)
        case failed(String)
    }

    private(set) var status = Status.off
    let serviceName: String

    @ObservationIgnored private let manager: MorphContinuityManager
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connections: [UUID: NWConnection] = [:]
    @ObservationIgnored private let queue = DispatchQueue(label: "com.athene.morph.continuity")

    init(manager: MorphContinuityManager, serviceName: String = "Morph on \(Host.current().localizedName ?? "Mac")") {
        self.manager = manager
        self.serviceName = String(serviceName.prefix(60))
        manager.onDisconnect = { [weak self] id in self?.drop(id) }
    }

    func apply(enabled: Bool) {
        if enabled, listener == nil { start() } else if !enabled, listener != nil || status != .off { stop() }
    }

    private func start() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        guard let listener = try? NWListener(using: parameters) else {
            status = .failed("Couldn't create the listener")
            return
        }
        listener.service = NWListener.Service(name: serviceName, type: ContinuityProtocol.serviceType)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.update(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        self.listener = listener
        status = .starting
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for id in Array(connections.keys) { drop(id) }
        status = .off
    }

    private func update(_ state: NWListener.State) {
        switch state {
        case .ready: status = .advertising(serviceName)
        case .failed(let error): status = .failed(error.localizedDescription)
        case .cancelled: if status != .off { status = .off }
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        // Only addresses on this network. Anything routed from elsewhere is refused unread.
        guard Self.isLocal(connection.endpoint) else {
            connection.cancel()
            return
        }
        let id = UUID()
        guard manager.open(id) else {
            connection.cancel()
            return
        }
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: Task { @MainActor in self?.closed(id) }
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, id: id, buffer: Data())
    }

    private nonisolated func receive(on connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            var buffer = buffer + (data ?? Data())
            let frames: [Data]
            do {
                frames = try ContinuityProtocol.takeFrames(from: &buffer)
            } catch {
                connection.cancel()
                return
            }
            let rest = buffer
            Task { @MainActor in
                guard let self else { return }
                for frame in frames {
                    let reply = self.manager.receive(frame, from: id)
                    for out in reply.frames {
                        if let data = try? ContinuityProtocol.frame(out) { connection.send(content: data, completion: .contentProcessed { _ in }) }
                    }
                    if reply.close {
                        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                        return
                    }
                }
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, id: id, buffer: rest)
                }
            }
        }
    }

    private func closed(_ id: UUID) {
        connections[id] = nil
        manager.close(id)
    }

    private func drop(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
        manager.close(id)
    }

    /// Private, link-local and unique-local ranges: what a phone on the same Wi-Fi can have.
    nonisolated static func isLocal(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            let bytes = [UInt8](address.rawValue)
            guard bytes.count == 4 else { return false }
            return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 169 && bytes[1] == 254) || bytes[0] == 127
        case .ipv6(let address):
            let bytes = [UInt8](address.rawValue)
            guard bytes.count == 16 else { return false }
            if address.isLoopback || address.isLinkLocal { return true }
            if bytes[0] & 0xFE == 0xFC { return true }
            // An IPv4 address carried in IPv6.
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
                return isLocal(.hostPort(host: .ipv4(IPv4Address(Data(bytes[12..<16]))!), port: 0))
            }
            return false
        default:
            return false
        }
    }
}
