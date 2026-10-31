import XCTest
@testable import WriteFlowCore

/// Answers every request from `handler` and records what was sent.
final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    static var requests: [(request: URLRequest, body: Data)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append((request, Self.readBody(request)))
        let (status, headers, data) = Self.handler?(request) ?? (500, [:], Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class APIClientTests: XCTestCase {
    private var client: APIClient!
    private let server = "https://stub.example"
    private let ok = Data(#"{"detectedLanguage":"en","targetLanguage":"en","suggestions":{"grammar":"Hello."},"explanation":"Fixed."}"#.utf8)

    override func setUp() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        client = APIClient(session: URLSession(configuration: configuration))
        StubProtocol.requests = []
        StubProtocol.handler = nil
    }

    func testSendsInstallIDAndOmitsEmptyKeyAndLanguage() async throws {
        StubProtocol.handler = { [ok] _ in (200, [:], ok) }
        let result = await client.correct(
            CorrectionRequest(text: "helo", modes: ["grammar"], targetLanguage: ""),
            server: server, accessKey: "", installID: "install-1234567890abcdef"
        )
        XCTAssertEqual(try result.get().suggestions["grammar"], "Hello.")

        let sent = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(sent.request.url?.absoluteString, "https://stub.example/api/v1/corrections")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "X-WriteFlow-Install"), "install-1234567890abcdef")
        XCTAssertNil(sent.request.value(forHTTPHeaderField: "X-WriteFlow-Key"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        XCTAssertEqual(body["text"] as? String, "helo")
        XCTAssertEqual(body["modes"] as? [String], ["grammar"])
        XCTAssertNil(body["targetLanguage"])
    }

    func testSendsKeyAndLanguageWhenSet() async throws {
        StubProtocol.handler = { [ok] _ in (200, [:], ok) }
        _ = await client.correct(
            CorrectionRequest(text: "hi", modes: ["grammar"], targetLanguage: "mr-Latn"),
            server: server, accessKey: "secret", installID: "install-1234567890abcdef"
        )
        let sent = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "X-WriteFlow-Key"), "secret")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        XCTAssertEqual(body["targetLanguage"] as? String, "mr-Latn")
    }

    func testCachesSameRequest() async {
        StubProtocol.handler = { [ok] _ in (200, [:], ok) }
        let request = CorrectionRequest(text: "hi", modes: ["grammar"], targetLanguage: "")
        _ = await client.correct(request, server: server, accessKey: "", installID: "i")
        _ = await client.correct(request, server: server, accessKey: "", installID: "i")
        XCTAssertEqual(StubProtocol.requests.count, 1)
    }

    func testRateLimitedKeepsServerMessageAndRetryAfter() async {
        let body = Data(#"{"error":{"code":"RATE_LIMITED","message":"Too many requests. Please wait a moment and try again.","requestId":"r"}}"#.utf8)
        StubProtocol.handler = { _ in (429, ["Retry-After": "42"], body) }
        let result = await client.correct(
            CorrectionRequest(text: "hi", modes: ["grammar"], targetLanguage: ""), server: server, accessKey: "", installID: "i"
        )
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error.code, "RATE_LIMITED")
        XCTAssertEqual(error.message, "Too many requests. Please wait a moment and try again.")
        XCTAssertEqual(error.retryAfterSeconds, 42)
    }

    func testUnauthorizedExplainsTheKey() async {
        StubProtocol.handler = { _ in (401, [:], Data()) }
        let request = CorrectionRequest(text: "hi", modes: ["grammar"], targetLanguage: "")
        let withoutKey = await client.correct(request, server: server, accessKey: "", installID: "i")
        let withKey = await client.correct(request, server: server, accessKey: "k", installID: "i")
        guard case .failure(let a) = withoutKey, case .failure(let b) = withKey else { return XCTFail("expected failures") }
        XCTAssertTrue(a.message.contains("needs an access key"))
        XCTAssertTrue(b.message.contains("rejected the access key"))
    }

    func testNonJSONErrorFallsBackToStatus() async {
        StubProtocol.handler = { _ in (502, [:], Data("Bad Gateway".utf8)) }
        let result = await client.correct(
            CorrectionRequest(text: "hi", modes: ["grammar"], targetLanguage: ""), server: server, accessKey: "", installID: "i"
        )
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error.code, "HTTP_502")
    }

    func testScoreSendsTextAndCaches() async throws {
        StubProtocol.handler = { _ in (200, [:], Data(#"{"score":78,"scores":{"grammar":70,"casual":86}}"#.utf8)) }
        let first = await client.score(" hello ", modes: ["grammar", "casual"], server: server, accessKey: "", installID: "install-1234567890abcdef")
        let second = await client.score("hello", modes: ["grammar", "casual"], server: server, accessKey: "", installID: "install-1234567890abcdef")
        XCTAssertEqual(first, Score(score: 78, scores: ["grammar": 70, "casual": 86]))
        XCTAssertEqual(second, first)
        XCTAssertEqual(first?.breakdown, "Fix grammar 70 · Casual 86")
        XCTAssertEqual(StubProtocol.requests.count, 1)
        // Other modes are a different question, so they are asked again.
        _ = await client.score("hello", modes: ["polite"], server: server, accessKey: "", installID: "i")
        XCTAssertEqual(StubProtocol.requests.count, 2)
        let sent = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(sent.request.url?.path, "/api/v1/scores")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "X-WriteFlow-Install"), "install-1234567890abcdef")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        XCTAssertEqual(body["text"] as? String, "hello")
        XCTAssertEqual(body["modes"] as? [String], ["grammar", "casual"])
    }

    func testScoreIsNilOnErrors() async {
        StubProtocol.handler = { _ in (429, ["Retry-After": "5"], Data(#"{"error":{"code":"RATE_LIMITED","message":"x","requestId":"r"}}"#.utf8)) }
        let limited = await client.score("a", modes: ["grammar"], server: server, accessKey: "", installID: "i")
        XCTAssertNil(limited)
        StubProtocol.handler = { _ in (200, [:], Data(#"{"score":140,"scores":{}}"#.utf8)) }
        let outOfRange = await client.score("b", modes: ["grammar"], server: server, accessKey: "", installID: "i")
        XCTAssertNil(outOfRange)
        let empty = await client.score("   ", modes: ["grammar"], server: server, accessKey: "", installID: "i")
        XCTAssertNil(empty)
    }

    func testScoreBands() {
        XCTAssertEqual(ScoreBand(score: 0), .low)
        XCTAssertEqual(ScoreBand(score: 64), .low)
        XCTAssertEqual(ScoreBand(score: 65), .fair)
        XCTAssertEqual(ScoreBand(score: 84), .fair)
        XCTAssertEqual(ScoreBand(score: 85), .good)
        XCTAssertEqual(ScoreBand(score: 100), .good)
    }

    func testConnectionCheck() async {
        StubProtocol.handler = { request in
            request.url?.path == "/health" ? (200, [:], Data(#"{"status":"ok"}"#.utf8)) : (400, [:], Data())
        }
        let connected = await client.checkConnection(server: server, accessKey: "")
        XCTAssertEqual(connected, .connected)
        StubProtocol.handler = { request in
            request.url?.path == "/health" ? (200, [:], Data(#"{"status":"ok"}"#.utf8)) : (401, [:], Data())
        }
        let needsKey = await client.checkConnection(server: server, accessKey: "")
        let wrongKey = await client.checkConnection(server: server, accessKey: "k")
        XCTAssertEqual(needsKey, .needsKey)
        XCTAssertEqual(wrongKey, .wrongKey)
    }

    /// Real round trip, only when asked: WRITEFLOW_LIVE_URL=https://… swift test
    func testLiveServer() async throws {
        guard let server = ProcessInfo.processInfo.environment["WRITEFLOW_LIVE_URL"] else {
            throw XCTSkip("set WRITEFLOW_LIVE_URL to run against a real server")
        }
        let live = APIClient()
        let result = await live.correct(
            CorrectionRequest(text: "How are you? I will come tomorrow.", modes: ["grammar", "casual"], targetLanguage: "mr-Latn"),
            server: server, accessKey: "", installID: "writeflow-mac-live-test"
        )
        let correction = try result.get()
        XCTAssertNotNil(correction.suggestions["grammar"])
        XCTAssertNotNil(correction.suggestions["casual"])
        print("live:", correction.suggestions)
    }
}
