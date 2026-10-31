import Foundation

/// Mirrors the backend default MAX_INPUT_CHARS (UTF-16 length); the server still has the final say (413).
public let maxInputChars = 5000

public struct CorrectionRequest: Hashable, Sendable {
    public let text: String
    /// Mode ids, e.g. ["grammar", "casual"].
    public let modes: [String]
    /// BCP-47 tag; empty keeps the input's language.
    public let targetLanguage: String

    public init(text: String, modes: [String], targetLanguage: String) {
        self.text = text
        self.modes = modes
        self.targetLanguage = targetLanguage
    }
}

public struct Correction: Decodable, Equatable, Sendable {
    public let detectedLanguage: String
    public let targetLanguage: String
    /// Keyed by mode id: exactly the requested modes.
    public let suggestions: [String: String]
    /// English, 1-2 sentences.
    public let explanation: String

    public init(detectedLanguage: String, targetLanguage: String, suggestions: [String: String], explanation: String) {
        self.detectedLanguage = detectedLanguage
        self.targetLanguage = targetLanguage
        self.suggestions = suggestions
        self.explanation = explanation
    }
}

public struct WriteFlowError: Error, Equatable, Sendable {
    public let code: String
    public let message: String
    public var retryAfterSeconds: Int?

    public init(code: String, message: String, retryAfterSeconds: Int? = nil) {
        self.code = code
        self.message = message
        self.retryAfterSeconds = retryAfterSeconds
    }
}

/// The W button's score: how well the text already fits each chosen mode, and their average.
public struct Score: Equatable, Sendable, Decodable {
    /// 0-100, the average of `scores`.
    public let score: Int
    /// Mode id -> 0-100.
    public let scores: [String: Int]

    public init(score: Int, scores: [String: Int]) {
        self.score = score
        self.scores = scores
    }

    /// "Fix grammar 70 · Casual 86", in display order.
    public var breakdown: String {
        Mode.all.compactMap { mode in scores[mode.id].map { "\(mode.label) \($0)" } }.joined(separator: " · ")
    }
}

/// Colour band of a writing score: green from 85, yellow from 65, red below.
public enum ScoreBand: Equatable, Sendable {
    case low, fair, good

    public init(score: Int) {
        self = score >= 85 ? .good : score >= 65 ? .fair : .low
    }
}

public enum ConnectionCheck: Equatable, Sendable {
    case connected
    case needsKey
    case wrongKey
    case failed(String)
}

/// Talks to the WriteFlow server. Same headers, timeouts and messages as the extension's background.js.
public actor APIClient {
    public static let accessKeyHeader = "X-WriteFlow-Key"
    public static let installIDHeader = "X-WriteFlow-Install"
    /// Long enough for a free Render server to wake from sleep (about a minute) and then answer.
    public static let timeout: TimeInterval = 90
    private static let cacheLimit = 50

    /// Nil: a fresh session per request. A reused session remembers that the server offers HTTP/3
    /// and tries QUIC (UDP) first, which hangs for most of a minute on networks that drop UDP.
    private let session: URLSession?
    /// Same text, modes and language give the same answer; spares a round trip when a card reopens.
    private var cache: [CorrectionRequest: Correction] = [:]
    private var cacheOrder: [CorrectionRequest] = []
    /// Modes + selected text -> score; the same selection is never scored twice for the same modes.
    private var scores: [String: Score] = [:]
    private var scoreOrder: [String] = []

    public init(session: URLSession? = nil) {
        self.session = session
    }

    private func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        if let session { return try await session.data(for: request) }
        let fresh = URLSession(configuration: .ephemeral)
        defer { fresh.finishTasksAndInvalidate() }
        return try await fresh.data(for: request)
    }

    private struct Body: Encodable {
        let text: String
        let modes: [String]
        let targetLanguage: String?
    }

    private struct ErrorEnvelope: Decodable {
        struct Inner: Decodable {
            let code: String
            let message: String
        }
        let error: Inner
    }

    public func correct(
        _ request: CorrectionRequest, server: String, accessKey: String, installID: String
    ) async -> Result<Correction, WriteFlowError> {
        if let cached = cache[request] { return .success(cached) }
        guard let url = URL(string: "\(server)/api/v1/corrections") else {
            return .failure(WriteFlowError(code: "BAD_SERVER", message: "The server address in Settings is not valid."))
        }

        var urlRequest = URLRequest(url: url, timeoutInterval: Self.timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(installID, forHTTPHeaderField: Self.installIDHeader)
        if !accessKey.isEmpty { urlRequest.setValue(accessKey, forHTTPHeaderField: Self.accessKeyHeader) }
        let body = Body(
            text: request.text,
            modes: request.modes,
            targetLanguage: request.targetLanguage.isEmpty ? nil : request.targetLanguage
        )
        urlRequest.httpBody = try? JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await load(urlRequest)
        } catch let error as URLError where error.code == .timedOut {
            return .failure(WriteFlowError(code: "TIMEOUT", message: "The WriteFlow server took too long to answer."))
        } catch {
            return .failure(WriteFlowError(code: "NETWORK", message: "Can't reach the WriteFlow server at \(server). Check your internet connection."))
        }
        guard let http = response as? HTTPURLResponse else {
            return .failure(WriteFlowError(code: "NETWORK", message: "The server sent an unexpected answer."))
        }

        if http.statusCode == 401 {
            return .failure(WriteFlowError(
                code: "UNAUTHORIZED",
                message: accessKey.isEmpty
                    ? "This server needs an access key. Add it in WriteFlow Settings."
                    : "The server rejected the access key. Check it in WriteFlow Settings."
            ))
        }
        if (200..<300).contains(http.statusCode),
           let correction = try? JSONDecoder().decode(Correction.self, from: data),
           !correction.suggestions.isEmpty {
            remember(correction, for: request)
            return .success(correction)
        }
        let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
        return .failure(WriteFlowError(
            code: envelope?.error.code ?? "HTTP_\(http.statusCode)",
            message: envelope?.error.message ?? "The server answered with status \(http.statusCode).",
            retryAfterSeconds: http.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) }
        ))
    }

    /// The W button's score for `modes` (mode ids), or nil on any failure (the button then shows
    /// just the W). Not worth waiting a minute for a sleeping server, hence the shorter timeout.
    public func score(
        _ text: String, modes: [String], server: String, accessKey: String, installID: String
    ) async -> Score? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf16.count <= maxInputChars, !modes.isEmpty else { return nil }
        let key = modes.joined(separator: ",") + "\n" + trimmed
        if let cached = scores[key] { return cached }
        guard let url = URL(string: "\(server)/api/v1/scores") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(installID, forHTTPHeaderField: Self.installIDHeader)
        if !accessKey.isEmpty { request.setValue(accessKey, forHTTPHeaderField: Self.accessKeyHeader) }
        struct Body: Encodable { let text: String; let modes: [String] }
        request.httpBody = try? JSONEncoder().encode(Body(text: trimmed, modes: modes))
        guard let (data, response) = try? await load(request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let score = try? JSONDecoder().decode(Score.self, from: data),
              (0...100).contains(score.score)
        else { return nil }
        scores[key] = score
        scoreOrder.append(key)
        if scoreOrder.count > 200 { scores[scoreOrder.removeFirst()] = nil }
        return score
    }

    /// For Settings: /health, then an empty request, which costs no model call (the key is checked
    /// first and answers 401, otherwise the body is rejected with 400).
    public func checkConnection(server: String, accessKey: String) async -> ConnectionCheck {
        guard let health = URL(string: "\(server)/health"), let corrections = URL(string: "\(server)/api/v1/corrections") else {
            return .failed("Enter an http:// or https:// address.")
        }
        do {
            let (data, response) = try await load(URLRequest(url: health, timeoutInterval: Self.timeout))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard status == 200, body?["status"] as? String == "ok" else { return .failed("Server answered \(status).") }

            var probe = URLRequest(url: corrections, timeoutInterval: 15)
            probe.httpMethod = "POST"
            probe.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !accessKey.isEmpty { probe.setValue(accessKey, forHTTPHeaderField: Self.accessKeyHeader) }
            probe.httpBody = Data("{}".utf8)
            let (_, probeResponse) = try await load(probe)
            if (probeResponse as? HTTPURLResponse)?.statusCode == 401 { return accessKey.isEmpty ? .needsKey : .wrongKey }
            return .connected
        } catch {
            return .failed("Can't reach it. Check the address and your internet connection.")
        }
    }

    private func remember(_ correction: Correction, for request: CorrectionRequest) {
        cache[request] = correction
        cacheOrder.append(request)
        if cacheOrder.count > Self.cacheLimit { cache[cacheOrder.removeFirst()] = nil }
    }
}
