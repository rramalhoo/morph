import Foundation
import Network
import Testing
@testable import Morph

private func payload(_ json: String) throws -> LiveActivityPayload {
    try LiveActivityPayload(json: Data(json.utf8))
}

private func rejection(_ json: String) -> LiveActivityValidationError? {
    do {
        _ = try payload(json)
        return nil
    } catch {
        return error as? LiveActivityValidationError
    }
}

@Suite("Live activity payloads")
struct LiveActivityPayloadTests {
    @Test func theDocumentedExampleIsAccepted() throws {
        let subject = try payload(#"{"id":"upload-001","title":"Enviando arquivo","subtitle":"Morph API","progress":0.65,"state":"running"}"#)
        #expect(subject.id == "upload-001")
        #expect(subject.progress == 0.65)
        #expect(subject.state == .running)
    }

    @Test func hostileValuesAreRejected() {
        #expect(rejection("[]") == .malformed)
        #expect(rejection("not json") == .malformed)
        #expect(rejection(#"{"path":"/etc/passwd"}"#) == .unknownField("path"))
        #expect(rejection(#"{"command":"rm -rf /"}"#) == .unknownField("command"))
        #expect(rejection(#"{"id":"../../etc"}"#) != nil)
        #expect(rejection(#"{"id":""}"#) != nil)
        #expect(rejection(#"{"id":"ação"}"#) != nil)
        #expect(rejection(#"{"title":"   "}"#) != nil)
        #expect(rejection(#"{"title":"a\nb"}"#) != nil)
        #expect(rejection(#"{"title":5}"#) != nil)
        #expect(rejection(#"{"icon":"/System/Library/x.png"}"#) != nil)
        #expect(rejection(#"{"progress":1.5}"#) != nil)
        #expect(rejection(#"{"progress":-0.1}"#) != nil)
        #expect(rejection(#"{"progress":true}"#) != nil)
        #expect(rejection(#"{"duration":0}"#) != nil)
        #expect(rejection(#"{"duration":3601}"#) != nil)
        #expect(rejection(#"{"duration":1.5}"#) != nil)
        #expect(rejection(#"{"priority":"critical"}"#) != nil, "There's no way to even ask for this")
        #expect(rejection(#"{"state":"exploded"}"#) != nil)
    }

    @Test func lengthsAreLimited() {
        let long = String(repeating: "a", count: LiveActivityLimits.maximumTitleLength + 1)
        #expect(rejection(#"{"title":"\#(long)"}"#) != nil)
        let longID = String(repeating: "a", count: LiveActivityLimits.maximumIDLength + 1)
        #expect(rejection(#"{"id":"\#(longID)"}"#) != nil)
    }
}

@Suite("HTTP parsing")
struct HTTPParsingTests {
    private func parse(_ text: String) -> HTTPRequest.ParseResult {
        HTTPRequest.parse(Data(text.utf8))
    }

    @Test func aCompleteRequestParses() {
        guard case .complete(let request) = parse("POST /v1/activities HTTP/1.1\r\nHost: a\r\nContent-Length: 2\r\n\r\n{}") else {
            Issue.record("Should parse")
            return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/v1/activities")
        #expect(request.headers["host"] == "a")
        #expect(request.body == Data("{}".utf8))
    }

    @Test func partialRequestsWaitForMore() {
        #expect(parse("GET / HT") == .incomplete)
        #expect(parse("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\n{") == .incomplete)
    }

    @Test func oversizedRequestsAreRefusedBeforeTheBodyArrives() {
        #expect(parse("POST / HTTP/1.1\r\nContent-Length: 4097\r\n\r\n") == .failed(status: 413))
        #expect(parse(String(repeating: "a", count: LiveActivityLimits.maximumHeaders + 1)) == .failed(status: 431))
    }

    @Test func requestSmugglingShapesAreRefused() {
        #expect(parse("POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n") == .failed(status: 400))
        #expect(parse("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n") == .failed(status: 501))
        #expect(parse("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n") == .failed(status: 400))
        #expect(parse("POST / HTTP/1.1\r\nContent-Length: abc\r\n\r\n") == .failed(status: 400))
        #expect(parse("BAD\r\n\r\n") == .failed(status: 400))
    }
}

@Suite("Live API authorization and limits")
@MainActor
struct LiveAPIRouterTests {
    private let scheduler = ManualScheduler()
    private let store: LiveActivityStore
    private let router: LiveAPIRouter

    init() {
        store = LiveActivityStore(scheduler: scheduler)
        router = LiveAPIRouter(store: store, scheduler: scheduler, token: { "secret" }, port: { 47800 })
    }

    private func request(_ method: String, _ path: String, body: String = "", token: String? = "secret",
                         host: String = "127.0.0.1:47800", origin: String? = nil) -> HTTPRequest {
        var headers = ["host": host]
        if let token { headers["authorization"] = "Bearer \(token)" }
        if let origin { headers["origin"] = origin }
        return HTTPRequest(method: method, path: path, headers: headers, body: Data(body.utf8))
    }

    private func create(_ id: String) -> HTTPResponse {
        router.handle(request("POST", "/v1/activities", body: #"{"id":"\#(id)","title":"Work"}"#))
    }

    @Test func createUpdateEnd() {
        #expect(create("a").status == 201)
        #expect(store.activities.first?.title == "Work")
        #expect(router.handle(request("PATCH", "/v1/activities/a", body: #"{"progress":0.5}"#)).status == 200)
        #expect(store.activities.first?.progress == 0.5)
        #expect(router.handle(request("DELETE", "/v1/activities/a")).status == 204)
        #expect(store.activities.isEmpty)
        #expect(router.handle(request("DELETE", "/v1/activities/a")).status == 404)
    }

    @Test func capabilitiesDescribeTheAPI() throws {
        let response = router.handle(request("GET", "/v1/capabilities"))
        #expect(response.status == 200)
        let object = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        #expect(object["version"] as? Int == 1)
        #expect((object["icons"] as? [String])?.contains("timer") == true)
    }

    @Test func noTokenWrongTokenAndNoPrefixAreRefused() {
        #expect(router.handle(request("GET", "/v1/capabilities", token: nil)).status == 401)
        #expect(router.handle(request("GET", "/v1/capabilities", token: "wrong")).status == 401)
        #expect(router.handle(request("GET", "/v1/capabilities", token: "secre")).status == 401)
        var plain = request("GET", "/v1/capabilities", token: nil)
        plain.headers["authorization"] = "secret"
        #expect(router.handle(plain).status == 401)
    }

    @Test func noTokenConfiguredRefusesEverything() {
        let router = LiveAPIRouter(store: store, scheduler: scheduler, token: { nil }, port: { 47800 })
        #expect(router.handle(request("GET", "/v1/capabilities", token: "")).status == 401)
    }

    @Test func browsersAndReboundDomainsAreRefusedEvenWithTheToken() {
        #expect(router.handle(request("GET", "/v1/capabilities", origin: "https://evil.example")).status == 403)
        #expect(router.handle(request("GET", "/v1/capabilities", host: "evil.example:47800")).status == 403)
        #expect(router.handle(request("GET", "/v1/capabilities", host: "127.0.0.1:1")).status == 403)
        var noHost = request("GET", "/v1/capabilities")
        noHost.headers["host"] = nil
        #expect(router.handle(noHost).status == 403)
    }

    @Test func guessingTheTokenGetsThrottled() {
        var statuses: [Int] = []
        for _ in 0..<12 { statuses.append(router.handle(request("GET", "/v1/capabilities", token: "guess")).status) }
        #expect(statuses.prefix(10).allSatisfy { $0 == 401 })
        #expect(statuses.last == 429)
    }

    @Test func floodingIsLimitedAndRecovers() {
        var limited = 0
        for _ in 0..<100 where router.handle(request("GET", "/v1/capabilities")).status == 429 { limited += 1 }
        #expect(limited >= 69)
        scheduler.advance(by: .seconds(1))
        #expect(router.handle(request("GET", "/v1/capabilities")).status == 200)
    }

    @Test func tooManyActivitiesAreRefused() {
        for index in 0..<LiveActivityLimits.maximumActive { #expect(create("a\(index)").status == 201) }
        #expect(create("extra").status == 429)
        #expect(store.activities.count == LiveActivityLimits.maximumActive)
    }

    @Test func duplicateIDsAndMissingFieldsAreRefused() {
        #expect(create("a").status == 201)
        #expect(create("a").status == 409)
        #expect(router.handle(request("POST", "/v1/activities", body: #"{"id":"b"}"#)).status == 400)
        #expect(router.handle(request("PATCH", "/v1/activities/a", body: #"{"id":"b"}"#)).status == 400)
    }

    @Test func unknownRoutesAndMethods() {
        #expect(router.handle(request("GET", "/")).status == 404)
        #expect(router.handle(request("GET", "/v2/capabilities")).status == 404)
        #expect(router.handle(request("DELETE", "/v1/capabilities")).status == 405)
        #expect(router.handle(request("GET", "/v1/activities/a")).status == 405)
    }

    @Test func requestedPriorityNeverRaisesTheEffectiveOne() throws {
        let activity = try store.create(payload(#"{"id":"a","title":"Loud","priority":"high"}"#))
        #expect(activity.requestedPriority == .high)
        let effective = IslandActivity(.external(activity), at: scheduler.now).priority
        #expect(effective == .liveActivity)
        #expect(effective < .timer)
    }

    @Test func comparisonDoesNotStopAtTheFirstDifference() {
        #expect(LiveAPIRouter.constantTimeEqual(Data("abc".utf8), Data("abc".utf8)))
        #expect(!LiveAPIRouter.constantTimeEqual(Data("abc".utf8), Data("abd".utf8)))
        #expect(!LiveAPIRouter.constantTimeEqual(Data("abc".utf8), Data("ab".utf8)))
    }
}

@Suite("Live activity store")
@MainActor
struct LiveActivityStoreTests {
    private let scheduler = ManualScheduler()

    @Test func activitiesExpireOnTheirOwn() throws {
        let store = LiveActivityStore(scheduler: scheduler)
        _ = try store.create(payload(#"{"id":"a","title":"A","duration":5}"#))
        _ = try store.create(payload(#"{"id":"b","title":"B","duration":60}"#))
        scheduler.advance(by: .seconds(5))
        #expect(store.activities.map(\.id) == ["b"])
        scheduler.advance(by: .seconds(55))
        #expect(store.activities.isEmpty)
        #expect(scheduler.pendingCount == 0)
    }

    @Test func updatesKeepAnActivityAlive() throws {
        let store = LiveActivityStore(scheduler: scheduler)
        _ = try store.create(payload(#"{"id":"a","title":"A","duration":5}"#))
        scheduler.advance(by: .seconds(4))
        _ = try store.update(id: "a", with: payload(#"{"duration":5}"#))
        scheduler.advance(by: .seconds(4))
        #expect(store.activities.count == 1)
    }

    @Test func theSenderOrdersOnlyAmongItsOwn() throws {
        let store = LiveActivityStore(scheduler: scheduler)
        _ = try store.create(payload(#"{"id":"a","title":"A","priority":"low"}"#))
        _ = try store.create(payload(#"{"id":"b","title":"B"}"#))
        _ = try store.create(payload(#"{"id":"c","title":"C","priority":"high"}"#))
        #expect(store.activities.map(\.id) == ["c", "b", "a"])
    }

    @Test func updatesDoNotAnnounceThemselves() throws {
        let store = LiveActivityStore(scheduler: scheduler)
        var changes = 0
        store.onChange = { _ in changes += 1 }
        _ = try store.create(payload(#"{"id":"a","title":"A"}"#))
        for step in 1...50 { _ = try store.update(id: "a", with: payload(#"{"progress":\#(Double(step) / 50)}"#)) }
        try store.end(id: "a")
        #expect(changes == 2, "Fifty progress updates can't turn into fifty banners")
    }
}

@Suite("Keychain token")
struct KeychainTokenTests {
    /// A throwaway item in the real Keychain, never the one the app uses.
    @Test func aTokenRoundTripsAndIsDeleted() {
        let store = KeychainTokenStore(service: "com.athene.morph.tests.\(UUID().uuidString)")
        defer { store.delete() }
        #expect(store.load() == nil)
        #expect(store.save("first"))
        #expect(store.save("second"), "Saving replaces")
        #expect(store.load() == "second")
        store.delete()
        #expect(store.load() == nil)
    }
}

/// The real listener on a real socket, through the real sandbox.
@Suite("Live API server", .serialized)
@MainActor
struct LiveAPIServerTests {
    private let scheduler = SystemScheduler()
    private let tokens = InMemoryTokens()
    private let port = Int.random(in: 49_200...60_000)

    private func started() async throws -> (LiveAPIService, LiveActivityStore) {
        let store = LiveActivityStore(scheduler: scheduler)
        let service = LiveAPIService(store: store, tokens: tokens, scheduler: scheduler)
        service.apply(enabled: true, port: port)
        await waitUntil { service.status == .listening(port: port) }
        try #require(service.status == .listening(port: port))
        return (service, store)
    }

    private func send(_ method: String, _ path: String, body: String? = nil, token: String?) async throws -> Int {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!, timeoutInterval: 3)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = body?.data(using: .utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    @Test func createUpdateAndEndOverARealSocket() async throws {
        let (service, store) = try await started()
        defer { service.stop() }
        let token = try #require(service.token)
        #expect(token.count >= 43, "256 bits")
        #expect(tokens.token == token)

        #expect(try await send("GET", "/v1/capabilities", token: nil) == 401)
        #expect(try await send("GET", "/v1/capabilities", token: token) == 200)
        #expect(try await send("POST", "/v1/activities", body: #"{"id":"upload-001","title":"Enviando arquivo","subtitle":"Morph API","progress":0.65,"state":"running"}"#, token: token) == 201)
        #expect(store.activities.first?.progress == 0.65)
        #expect(try await send("PATCH", "/v1/activities/upload-001", body: #"{"progress":0.9}"#, token: token) == 200)
        #expect(store.activities.first?.progress == 0.9)
        #expect(try await send("DELETE", "/v1/activities/upload-001", token: token) == 204)
        #expect(store.activities.isEmpty)
    }

    @Test func anOversizedBodyIsRefused() async throws {
        let (service, _) = try await started()
        defer { service.stop() }
        let body = String(repeating: "a", count: LiveActivityLimits.maximumBody + 1)
        #expect(try await send("POST", "/v1/activities", body: body, token: service.token) == 413)
    }

    @Test func offMeansNoSocketAtAll() async throws {
        let (service, _) = try await started()
        service.stop()
        #expect(service.status == .off)
        try await Task.sleep(for: .milliseconds(100))
        await #expect(throws: (any Error).self) { try await send("GET", "/v1/capabilities", token: "x") }
    }

    @Test func turningOffTakesOpenActivitiesWithIt() async throws {
        let (service, store) = try await started()
        _ = try store.create(LiveActivityPayload(json: Data(#"{"id":"a","title":"A"}"#.utf8)))
        service.stop()
        #expect(store.activities.isEmpty)
    }

    @Test func theSameSettingsTwiceKeepTheSameServer() async throws {
        let (service, _) = try await started()
        defer { service.stop() }
        service.apply(enabled: true, port: port)
        #expect(service.status == .listening(port: port))
    }

    @Test func regeneratingInvalidatesTheOldToken() async throws {
        let (service, _) = try await started()
        defer { service.stop() }
        let old = try #require(service.token)
        service.regenerateToken()
        #expect(service.token != old)
        #expect(try await send("GET", "/v1/capabilities", token: old) == 401)
        #expect(try await send("GET", "/v1/capabilities", token: service.token) == 200)
    }

    @Test func aKeychainFailureMeansNoServer() async throws {
        tokens.failsToSave = true
        let store = LiveActivityStore(scheduler: scheduler)
        let service = LiveAPIService(store: store, tokens: tokens, scheduler: scheduler)
        service.apply(enabled: true, port: port)
        if case .failed = service.status {} else { Issue.record("Must not listen without a token") }
    }

    @Test func aPortInUseIsReported() async throws {
        let (first, _) = try await started()
        defer { first.stop() }
        let second = LiveAPIService(store: LiveActivityStore(scheduler: scheduler), tokens: tokens, scheduler: scheduler)
        second.apply(enabled: true, port: port)
        await waitUntil { if case .failed = second.status { true } else { false } }
        if case .failed(let reason) = second.status {
            #expect(reason.contains("\(port)"))
        } else {
            Issue.record("Expected a failure, got \(second.status)")
        }
    }

    /// Keeps a real server up for outside clients, using a throwaway token held only in memory, so
    /// the examples in `docs/examples` can be run against it. Off by default. Set
    /// `TEST_RUNNER_MORPH_EXAMPLE_TOKEN`, `TEST_RUNNER_MORPH_EXAMPLE_PORT` and
    /// `TEST_RUNNER_MORPH_EXAMPLE_COUNT` (clients expected), then run them.
    @Test func theDocumentedExamplesWorkFromOutside() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let token = environment["MORPH_EXAMPLE_TOKEN"], let port = environment["MORPH_EXAMPLE_PORT"].flatMap(Int.init),
              let expected = environment["MORPH_EXAMPLE_COUNT"].flatMap(Int.init) else { return }
        tokens.token = token
        let store = LiveActivityStore(scheduler: scheduler)
        let service = LiveAPIService(store: store, tokens: tokens, scheduler: scheduler)
        defer { service.stop() }
        var started: [String] = []
        var finished: [ExternalActivity] = []
        store.onChange = { change in
            switch change {
            case .started(let activity): started.append(activity.id)
            case .finished(let activity): finished.append(activity)
            }
        }
        service.apply(enabled: true, port: port)
        for _ in 0..<600 where finished.count < expected {
            try await Task.sleep(for: .milliseconds(100))
        }
        print("EXAMPLES started \(started), finished \(finished.map { "\($0.id) \($0.state.rawValue) \($0.progress ?? -1)" })")
        #expect(finished.count == expected)
        #expect(finished.allSatisfy { $0.state == .success && $0.progress != nil })
        #expect(store.activities.isEmpty)
    }

    /// The address that matters: this Mac's own LAN IP, which is what another machine would use.
    @Test func theServerIsNotReachableFromTheNetworkAddress() async throws {
        let (service, _) = try await started()
        defer { service.stop() }
        var addresses: UnsafeMutablePointer<ifaddrs>?
        try #require(getifaddrs(&addresses) == 0)
        defer { freeifaddrs(addresses) }
        var found: String?
        var cursor = addresses
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0, entry.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            found = String(decoding: host.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
            break
        }
        guard let found else { return }
        var request = URLRequest(url: URL(string: "http://\(found):\(port)/v1/capabilities")!, timeoutInterval: 2)
        request.setValue("Bearer \(service.token ?? "")", forHTTPHeaderField: "Authorization")
        await #expect(throws: (any Error).self, "Reachable on \(found)") { _ = try await URLSession.shared.data(for: request) }
    }
}
