import Foundation
import Network
import Observation
import Security

/// Where the API token lives.
protocol LiveAPITokenStoring: Sendable {
    func load() -> String?
    func save(_ token: String) -> Bool
    func delete()
}

struct KeychainTokenStore: LiveAPITokenStoring {
    private static let account = "local-token"

    var service = "com.athene.morph.live-api"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: Self.account]
    }

    func load() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ token: String) -> Bool {
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

/// A plain HTTP listener on the loopback interface only. Binding `127.0.0.1` rather than checking
/// addresses afterwards means the socket can't be reached from another machine at all. One request
/// per connection, and a connection that doesn't finish in time is dropped.
final class LiveAPIListener: @unchecked Sendable {
    enum Failure: Error { case badPort }

    private static let maximumConnections = 8
    private static let timeout = DispatchTimeInterval.seconds(5)

    private let queue = DispatchQueue(label: "com.athene.morph.live-api")
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    private let onState: @Sendable (NWListener.State) -> Void
    /// Only touched on `queue`.
    private var listener: NWListener?
    private var connections = 0

    init(handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse, onState: @escaping @Sendable (NWListener.State) -> Void) {
        self.handler = handler
        self.onState = onState
    }

    func start(port: Int) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else { throw Failure.badPort }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [onState] in onState($0) }
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        queue.async { [self] in
            self.listener = listener
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
        }
    }

    private func accept(_ connection: NWConnection) {
        guard connections < Self.maximumConnections else {
            connection.cancel()
            return
        }
        connections += 1
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                guard let self else { return }
                self.queue.async { self.connections -= 1 }
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.timeout) { connection.cancel() }
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer) {
            case .complete(let request):
                let handler = self.handler
                Task {
                    let response = await handler(request)
                    LiveAPIListener.respond(response, on: connection)
                }
            case .failed(let status):
                LiveAPIListener.respond(.error(status, "Bad request"), on: connection)
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.read(connection, buffer: buffer)
                }
            }
        }
    }

    private static func respond(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// The optional local API: off by default, and when it's off, no socket exists.
@MainActor
@Observable
final class LiveAPIService {
    enum Status: Equatable, Sendable {
        case off
        case starting
        case listening(port: Int)
        case failed(String)
    }

    private(set) var status = Status.off
    private(set) var token: String?
    private(set) var handledCount = 0
    private(set) var rejectedCount = 0

    @ObservationIgnored private let store: LiveActivityStore
    @ObservationIgnored private let tokens: any LiveAPITokenStoring
    @ObservationIgnored private var router: LiveAPIRouter!
    @ObservationIgnored private var listener: LiveAPIListener?
    @ObservationIgnored private var port = 0
    @ObservationIgnored private var generation = 0

    init(store: LiveActivityStore, tokens: any LiveAPITokenStoring, scheduler: any Scheduling) {
        self.store = store
        self.tokens = tokens
        router = LiveAPIRouter(store: store, scheduler: scheduler, token: { [weak self] in self?.token },
                               port: { [weak self] in self?.port ?? 0 })
    }

    /// Makes the server match the settings. Calling it again with the same values does nothing.
    func apply(enabled: Bool, port newPort: Int) {
        guard enabled else {
            stop()
            return
        }
        if listener != nil, newPort == port { return }
        stop()
        port = newPort
        guard ensureToken() else {
            status = .failed("Couldn't store the token in the Keychain")
            return
        }

        generation += 1
        let current = generation
        status = .starting
        let listener = LiveAPIListener(handler: { [weak self] request in
            await self?.handle(request) ?? .error(403, "API is off")
        }, onState: { [weak self] state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.follow(state, generation: current) }
            }
        })
        do {
            try listener.start(port: newPort)
            self.listener = listener
        } catch {
            status = .failed("Couldn't open port \(newPort)")
        }
    }

    func stop() {
        generation += 1
        listener?.stop()
        listener = nil
        store.removeAll()
        status = .off
    }

    /// The old token stops working at once.
    func regenerateToken() {
        token = Self.makeToken()
        if let token, !tokens.save(token) { status = .failed("Couldn't store the token in the Keychain") }
    }

    private func ensureToken() -> Bool {
        if token == nil { token = tokens.load() }
        if token != nil { return true }
        guard let fresh = Self.makeToken(), tokens.save(fresh) else { return false }
        token = fresh
        return true
    }

    /// 256 random bits, safe to paste into a header.
    private static func makeToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private func handle(_ request: HTTPRequest) -> HTTPResponse {
        guard listener != nil else { return .error(403, "API is off") }
        let response = router.handle(request)
        handledCount = router.handledCount
        rejectedCount = router.rejectedCount
        return response
    }

    private func follow(_ state: NWListener.State, generation current: Int) {
        guard current == generation else { return }
        switch state {
        case .ready:
            status = .listening(port: port)
        case .failed(let error):
            listener?.stop()
            listener = nil
            status = .failed(Self.describe(error, port: port))
        default:
            break
        }
    }

    private static func describe(_ error: NWError, port: Int) -> String {
        if case .posix(.EADDRINUSE) = error { return "Port \(port) is already in use" }
        return "Couldn't listen on port \(port)"
    }
}
