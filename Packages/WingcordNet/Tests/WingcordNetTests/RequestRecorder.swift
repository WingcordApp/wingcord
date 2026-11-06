import Foundation
@testable import WingcordNet

/// A `URLProtocol` that answers every request from a table and keeps what was
/// sent, filed by the `Authorization` header — so suites running in parallel
/// never read each other's requests. Each test makes a client with its own
/// token through `RequestRecorder.client()`.
final class RequestRecorder: URLProtocol, @unchecked Sendable {
    struct Captured: Sendable {
        var method: String
        var path: String
        var query: [String: String]
        /// Every query item in order — what `query` cannot hold for a key
        /// written more than once.
        var queryItems: [URLQueryItem]
        var headers: [String: String]
        var body: Data?

        /// The body as a JSON object, or nil.
        var json: [String: Any]? {
            body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: [String: [Captured]] = [:]
    nonisolated(unsafe) private static var answers: [String: (status: Int, body: Data)] = [:]

    /// A client whose every request is recorded under a token of its own, and
    /// answered with `status` and `body`.
    static func client(status: Int = 200, body: String = "{}") async -> (DiscordREST, String) {
        let token = "test-\(UUID().uuidString)"
        lock.withLock { answers[token] = (status, Data(body.utf8)) }
        let rest = DiscordREST(protocolClasses: [RequestRecorder.self])
        await rest.setToken(token)
        return (rest, token)
    }

    /// A client that is nobody, as the sign-in routes are: no token, and its
    /// requests filed under a fingerprint of its own instead.
    static func anonymousClient(status: Int = 200, body: String = "{}") async -> (DiscordREST, String) {
        let fingerprint = "fp-\(UUID().uuidString)"
        lock.withLock { answers[fingerprint] = (status, Data(body.utf8)) }
        let rest = DiscordREST(protocolClasses: [RequestRecorder.self])
        await rest.setFingerprint(fingerprint)
        return (rest, fingerprint)
    }

    static func requests(for token: String) -> [Captured] {
        lock.withLock { captured[token] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let token = request.value(forHTTPHeaderField: "Authorization")
            ?? request.value(forHTTPHeaderField: "X-Fingerprint")
            ?? ""
        let url = request.url
        let components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let entry = Captured(
            method: request.httpMethod ?? "GET",
            path: url?.path ?? "",
            query: query,
            queryItems: components?.queryItems ?? [],
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody ?? Self.read(request.httpBodyStream)
        )
        let answer = Self.lock.withLock { () -> (status: Int, body: Data) in
            Self.captured[token, default: []].append(entry)
            return Self.answers[token] ?? (200, Data("{}".utf8))
        }
        let response = HTTPURLResponse(
            url: url ?? URL(string: "https://discord.com")!,
            statusCode: answer.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
