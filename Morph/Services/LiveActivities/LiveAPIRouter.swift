import Foundation

struct HTTPRequest: Equatable, Sendable {
    var method: String
    var path: String
    /// Names are lowercased.
    var headers: [String: String]
    var body: Data

    enum ParseResult: Equatable, Sendable {
        /// More bytes are needed.
        case incomplete
        case complete(HTTPRequest)
        case failed(status: Int)
    }

    /// Reads one request. The limits apply before anything is decoded, so size alone can't cost
    /// memory or time here.
    static func parse(_ data: Data) -> ParseResult {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else {
            return data.count > LiveActivityLimits.maximumHeaders ? .failed(status: 431) : .incomplete
        }
        guard end.lowerBound <= LiveActivityLimits.maximumHeaders else { return .failed(status: 431) }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .failed(status: 400) }

        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().components(separatedBy: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."), parts[1].hasPrefix("/") else { return .failed(status: 400) }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .failed(status: 400) }
            let name = line[..<colon].lowercased()
            // Two Host or Content-Length headers mean someone is playing tricks.
            guard headers[name] == nil else { return .failed(status: 400) }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .failed(status: 501) }

        let declared = headers["content-length"].map { Int($0) } ?? 0
        guard let length = declared, length >= 0 else { return .failed(status: 400) }
        guard length <= LiveActivityLimits.maximumBody else { return .failed(status: 413) }
        let available = data.endIndex - end.upperBound
        guard available >= length else { return .incomplete }
        let body = Data(data[end.upperBound..<(end.upperBound + length)])
        return .complete(HTTPRequest(method: parts[0], path: parts[1], headers: headers, body: body))
    }
}

struct HTTPResponse: Equatable, Sendable {
    var status: Int
    var body: Data

    static func json(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
        HTTPResponse(status: status, body: (try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)) ?? Data())
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(status, ["error": message])
    }

    var serialized: Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if !body.isEmpty { head += "Content-Type: application/json\r\n" }
        head += "X-Content-Type-Options: nosniff\r\nCache-Control: no-store\r\n\r\n"
        return Data(head.utf8) + body
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 413: "Content Too Large"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 501: "Not Implemented"
        default: "Error"
        }
    }
}

/// Refills over time. Measured against an injected clock so tests need no waiting.
struct TokenBucket: Sendable {
    let capacity: Double
    let rate: Double
    private var tokens: Double
    private var updatedAt: ContinuousClock.Instant

    init(capacity: Double, rate: Double, now: ContinuousClock.Instant) {
        self.capacity = capacity
        self.rate = rate
        tokens = capacity
        updatedAt = now
    }

    mutating func take(at now: ContinuousClock.Instant) -> Bool {
        tokens = min(capacity, tokens + updatedAt.duration(to: now).timeInterval * rate)
        updatedAt = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}

/// Every request's path through the rules: who may ask, how often, and whether it makes sense.
/// Nothing here runs a command or opens a file, and no field is ever treated as a path.
@MainActor
final class LiveAPIRouter {
    private let store: LiveActivityStore
    private let scheduler: any Scheduling
    private let token: () -> String?
    private let port: () -> Int
    private var requests: TokenBucket
    private var failures: TokenBucket

    /// Transfers reported through `/v1/transfers`. Absent, or switched off, the route doesn't exist.
    var transfers: TransferManager?
    var acceptsTransfers = false

    private(set) var handledCount = 0
    private(set) var rejectedCount = 0

    init(store: LiveActivityStore, scheduler: any Scheduling, token: @escaping () -> String?, port: @escaping () -> Int) {
        self.store = store
        self.scheduler = scheduler
        self.token = token
        self.port = port
        requests = TokenBucket(capacity: LiveActivityLimits.requestBurst, rate: LiveActivityLimits.requestRate, now: scheduler.now)
        failures = TokenBucket(capacity: LiveActivityLimits.failureBurst, rate: LiveActivityLimits.failureRate, now: scheduler.now)
    }

    func handle(_ request: HTTPRequest) -> HTTPResponse {
        let response = route(request)
        handledCount += 1
        if response.status >= 400 { rejectedCount += 1 }
        return response
    }

    private func route(_ request: HTTPRequest) -> HTTPResponse {
        let now = scheduler.now
        guard requests.take(at: now) else { return .error(429, "Too many requests") }
        // A web page can reach loopback, but it always names itself in Origin, and a rebound
        // domain gives itself away in Host. Neither is a local script.
        guard request.headers["origin"] == nil else { return .error(403, "Browser requests aren't allowed") }
        guard isLocalHost(request.headers["host"]) else { return .error(403, "Host not allowed") }
        guard isAuthorized(request) else {
            return failures.take(at: now) ? .error(401, "Missing or invalid token") : .error(429, "Too many failed attempts")
        }

        let parts = request.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        guard parts.first == "v1", parts.count >= 2, parts.count <= 3 else { return .error(404, "Not found") }
        let id = parts.count == 3 ? parts[2] : nil

        switch (parts[1], id) {
        case ("capabilities", nil):
            return request.method == "GET" ? capabilities() : .error(405, "Method not allowed")
        case ("activities", nil):
            guard request.method == "POST" else { return .error(405, "Method not allowed") }
            return perform { .json(201, Self.describe(try store.create(LiveActivityPayload(json: request.body)))) }
        case ("activities", let id?):
            switch request.method {
            case "PATCH":
                return perform { .json(200, Self.describe(try store.update(id: id, with: LiveActivityPayload(json: request.body)))) }
            case "DELETE":
                return perform {
                    try store.end(id: id)
                    return HTTPResponse(status: 204, body: Data())
                }
            default:
                return .error(405, "Method not allowed")
            }
        case ("transfers", let id):
            guard acceptsTransfers, let transfers else { return .error(404, "Not found") }
            return routeTransfer(request, id: id, in: transfers)
        default:
            return .error(404, "Not found")
        }
    }

    /// Scripts report; Morph shows. Morph never offers to cancel these, since it can't.
    private func routeTransfer(_ request: HTTPRequest, id: String?, in transfers: TransferManager) -> HTTPResponse {
        switch (request.method, id) {
        case ("POST", nil):
            return perform {
                let payload = try TransferPayload(json: request.body)
                guard let id = payload.id, let name = payload.name, let kind = payload.kind else {
                    throw LiveActivityValidationError.invalid("id, name and kind are required")
                }
                let transfer = try transfers.begin(Transfer(id: "api-\(id)", kind: kind, name: name, source: .liveAPI,
                                                            state: payload.state ?? .transferring, bytes: payload.bytes ?? 0,
                                                            totalBytes: payload.total))
                return .json(201, Self.describe(transfer))
            }
        case ("PATCH", let id?):
            return perform {
                let payload = try TransferPayload(json: request.body)
                guard payload.id == nil || payload.id == id else { throw LiveActivityValidationError.invalid("id can't change") }
                guard payload.kind == nil else { throw LiveActivityValidationError.invalid("kind can't change") }
                let key = "api-\(id)"
                guard transfers.transfer(id: key)?.source == .liveAPI else { throw TransferManager.Failure.notFound }
                let transfer = if let state = payload.state, state.isFinished {
                    try transfers.finish(id: key, state: state, bytes: payload.bytes, error: payload.error, name: payload.name)
                } else {
                    try transfers.update(id: key, bytes: payload.bytes, totalBytes: payload.total, state: payload.state, name: payload.name)
                }
                return .json(200, Self.describe(transfer))
            }
        case ("DELETE", let id?):
            return perform {
                let key = "api-\(id)"
                guard transfers.transfer(id: key)?.source == .liveAPI else { throw TransferManager.Failure.notFound }
                try transfers.finish(id: key, state: .cancelled)
                return HTTPResponse(status: 204, body: Data())
            }
        default:
            return .error(405, "Method not allowed")
        }
    }

    private static func describe(_ transfer: Transfer) -> [String: Any] {
        var object: [String: Any] = ["id": String(transfer.id.dropFirst(4)), "name": transfer.name, "kind": transfer.kind.rawValue,
                                     "state": transfer.state.rawValue, "bytes": transfer.bytes]
        if let total = transfer.totalBytes { object["total"] = total }
        if let progress = transfer.progress { object["progress"] = progress }
        return object
    }

    private func perform(_ work: () throws -> HTTPResponse) -> HTTPResponse {
        do {
            return try work()
        } catch let error as LiveActivityValidationError {
            return .error(400, error.message)
        } catch LiveActivityStore.Failure.alreadyExists {
            return .error(409, "An activity with this id exists")
        } catch LiveActivityStore.Failure.notFound {
            return .error(404, "No activity with this id")
        } catch LiveActivityStore.Failure.tooMany {
            return .error(429, "Too many activities at once")
        } catch TransferManager.Failure.notFound {
            return .error(404, "No transfer with this id")
        } catch TransferManager.Failure.alreadyFinished {
            return .error(409, "This transfer has already ended")
        } catch TransferManager.Failure.tooMany {
            return .error(429, "Too many transfers at once")
        } catch {
            return .error(400, "Invalid request")
        }
    }

    private func isLocalHost(_ host: String?) -> Bool {
        guard let host else { return false }
        return host == "127.0.0.1:\(port())" || host == "localhost:\(port())"
    }

    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        guard let token = token(), let header = request.headers["authorization"], header.hasPrefix("Bearer ") else { return false }
        return Self.constantTimeEqual(Data(header.dropFirst(7).utf8), Data(token.utf8))
    }

    /// Takes the same time wherever the first difference is, so timing can't reveal the token.
    nonisolated static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func capabilities() -> HTTPResponse {
        .json(200, [
            "version": LiveActivityLimits.version,
            "icons": LiveActivityLimits.icons.keys.sorted(),
            "states": ExternalActivity.State.allCases.map(\.rawValue),
            "priorities": ExternalActivity.RequestedPriority.allCases.map(\.rawValue),
            "transfers": acceptsTransfers && transfers != nil,
            "limits": [
                "maximumActive": LiveActivityLimits.maximumActive,
                "maximumBodyBytes": LiveActivityLimits.maximumBody,
                "maximumTitleLength": LiveActivityLimits.maximumTitleLength,
                "maximumSubtitleLength": LiveActivityLimits.maximumSubtitleLength,
                "maximumDurationSeconds": LiveActivityLimits.durationRange.upperBound,
                "defaultDurationSeconds": LiveActivityLimits.defaultDuration,
            ],
        ])
    }

    private static func describe(_ activity: ExternalActivity) -> [String: Any] {
        var object: [String: Any] = ["id": activity.id, "title": activity.title, "state": activity.state.rawValue,
                                     "priority": activity.requestedPriority.rawValue]
        if let subtitle = activity.subtitle { object["subtitle"] = subtitle }
        if let progress = activity.progress { object["progress"] = progress }
        return object
    }
}
