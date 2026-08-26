import Foundation
import OSLog
import WingcordCore

/// Discord's REST API.
///
/// `nonisolated` throughout: a history page is up to a hundred messages of JSON
/// and decoding it must never touch the main thread. Nothing here reaches into
/// the store — every method returns values, and the caller applies them.
/// A page of history, plus the people who wrote it.
public struct MessagePage: Sendable {
    public var messages: [Message]
    public var authors: [UserID: User]
}

public actor DiscordREST {
    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "REST")

    public enum Failure: Error, Sendable {
        case unauthorized
        case forbidden
        case notFound
        /// Discord's own error envelope: an HTTP status plus its JSON code.
        case api(status: Int, code: Int?, message: String?)
        case transport(String)
        case decoding(String)
    }

    private let session: URLSession
    private let metadata: ClientMetadata
    private let limiter = RateLimiter()
    private var token: String?

    /// One decoder for the process.
    ///
    /// `JSONDecoder` is not cheap to construct — it builds a date strategy and a
    /// key strategy each time — and a history page decode that allocates one per
    /// call pays for it on every page.
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            // Discord sends ISO-8601 with fractional seconds on some fields and
            // without on others, in the same payload. A strategy that handles
            // only one silently fails to decode half of them.
            if let date = ISO8601DateFormatter.withFraction.date(from: text) { return date }
            if let date = ISO8601DateFormatter.plain.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unrecognised timestamp: \(text)"
            )
        }
        return decoder
    }()

    public init(metadata: ClientMetadata = ClientMetadata()) {
        self.metadata = metadata
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 20
        // REST responses are not cacheable in any useful way — history changes,
        // read state changes — and a cache here only costs disk and staleness.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func setToken(_ token: String?) {
        self.token = token
        if token == nil { Task { await limiter.reset() } }
    }

    // MARK: Routes

    /// The signed-in account. Also the token validation step.
    ///
    /// **A token is validated before it is stored.** One that never worked
    /// otherwise gets retried on every launch forever, and the app cannot tell
    /// "offline" from "this credential is dead".
    public func currentUser() async throws -> User {
        try await get("/users/@me", route: "users/@me", as: UserDTO.self).domain
    }

    public func settings() async throws -> ClientSettings {
        try await get(
            "/users/@me/settings",
            route: "users/@me/settings",
            as: ClientSettingsDTO.self
        ).domain
    }

    /// A page of history.
    ///
    /// `limit` is Discord's ceiling for the route, and that is a **scroll-feel**
    /// decision rather than a network one: paging back is a chain — reach the
    /// top, fetch, land, reach the top again — and every link is a round trip
    /// the reader waits through. Halving the number of links halves how often
    /// they meet one, and one request of twice the size is strictly cheaper
    /// against the rate limiter than two.
    public static let historyPageSize = 100

    public func messages(
        in channelID: ChannelID,
        before: MessageID? = nil,
        after: MessageID? = nil,
        around: MessageID? = nil,
        limit: Int = DiscordREST.historyPageSize
    ) async throws -> MessagePage {
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { items.append(URLQueryItem(name: "before", value: before.description)) }
        if let after { items.append(URLQueryItem(name: "after", value: after.description)) }
        if let around { items.append(URLQueryItem(name: "around", value: around.description)) }

        let page = try await get(
            "/channels/\(channelID.rawValue)/messages",
            route: "channels/\(channelID.rawValue)/messages",
            query: items,
            as: [MessageDTO].self
        )
        // **The authors come back with the page, and they have to.** A history
        // response is the only place this client ever learns who wrote an old
        // message: READY carries the reader's own member record and their
        // friends, and nothing else. Dropping them leaves every name in the
        // transcript reading "Unknown" over a "?" avatar.
        var authors: [UserID: User] = [:]
        for dto in page {
            guard let author = dto.author else { continue }
            authors[author.id] = author.domain
        }

        // Discord returns newest first; the store keeps oldest first, and
        // reversing here means no surface ever has to remember which way round
        // a page arrived.
        return MessagePage(messages: page.reversed().map(\.domain), authors: authors)
    }

    public func sendMessage(
        in channelID: ChannelID,
        content: String,
        nonce: String,
        replyingTo: MessageID? = nil
    ) async throws -> Message {
        struct Body: Encodable {
            var content: String
            var nonce: String
            var tts = false
            var message_reference: Reference?
            var flags: Int?

            struct Reference: Encodable {
                var message_id: String
                var fail_if_not_exists = false
            }
        }
        let body = Body(
            content: content,
            nonce: nonce,
            message_reference: replyingTo.map {
                Body.Reference(message_id: $0.description)
            },
            flags: nil
        )
        return try await post(
            "/channels/\(channelID.rawValue)/messages",
            route: "channels/\(channelID.rawValue)/messages",
            body: body,
            as: MessageDTO.self
        ).domain
    }

    public func editMessage(
        _ messageID: MessageID,
        in channelID: ChannelID,
        content: String
    ) async throws -> Message {
        struct Body: Encodable { var content: String }
        return try await request(
            method: "PATCH",
            path: "/channels/\(channelID.rawValue)/messages/\(messageID.rawValue)",
            route: "channels/\(channelID.rawValue)/messages/:id",
            body: Body(content: content),
            as: MessageDTO.self
        ).domain
    }

    public func deleteMessage(_ messageID: MessageID, in channelID: ChannelID) async throws {
        _ = try await requestData(
            method: "DELETE",
            path: "/channels/\(channelID.rawValue)/messages/\(messageID.rawValue)",
            route: "channels/\(channelID.rawValue)/messages/:id",
            body: Optional<Never>.none
        )
    }

    public func addReaction(
        _ emoji: EmojiRef,
        to messageID: MessageID,
        in channelID: ChannelID
    ) async throws {
        let encoded = emoji.apiIdentifier
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? emoji.apiIdentifier
        _ = try await requestData(
            method: "PUT",
            path: "/channels/\(channelID.rawValue)/messages/\(messageID.rawValue)/reactions/\(encoded)/@me",
            route: "channels/\(channelID.rawValue)/messages/:id/reactions",
            body: Optional<Never>.none
        )
    }

    public func removeReaction(
        _ emoji: EmojiRef,
        from messageID: MessageID,
        in channelID: ChannelID
    ) async throws {
        let encoded = emoji.apiIdentifier
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? emoji.apiIdentifier
        _ = try await requestData(
            method: "DELETE",
            path: "/channels/\(channelID.rawValue)/messages/\(messageID.rawValue)/reactions/\(encoded)/@me",
            route: "channels/\(channelID.rawValue)/messages/:id/reactions",
            body: Optional<Never>.none
        )
    }

    /// Marks a channel read.
    public func acknowledge(_ messageID: MessageID, in channelID: ChannelID) async throws {
        struct Body: Encodable { var token: String? = nil }
        _ = try await requestData(
            method: "POST",
            path: "/channels/\(channelID.rawValue)/messages/\(messageID.rawValue)/ack",
            route: "channels/\(channelID.rawValue)/ack",
            body: Body()
        )
    }

    public func typing(in channelID: ChannelID) async throws {
        _ = try await requestData(
            method: "POST",
            path: "/channels/\(channelID.rawValue)/typing",
            route: "channels/\(channelID.rawValue)/typing",
            body: Optional<Never>.none
        )
    }

    // MARK: Plumbing

    private func get<T: Decodable>(
        _ path: String,
        route: String,
        query: [URLQueryItem] = [],
        as type: T.Type
    ) async throws -> T {
        try await request(
            method: "GET",
            path: path,
            route: route,
            query: query,
            body: Optional<Never>.none,
            as: type
        )
    }

    private func post<Body: Encodable, T: Decodable>(
        _ path: String,
        route: String,
        body: Body,
        as type: T.Type
    ) async throws -> T {
        try await request(method: "POST", path: path, route: route, body: body, as: type)
    }

    private func request<Body: Encodable, T: Decodable>(
        method: String,
        path: String,
        route: String,
        query: [URLQueryItem] = [],
        body: Body?,
        as type: T.Type
    ) async throws -> T {
        let data = try await requestData(
            method: method,
            path: path,
            route: route,
            query: query,
            body: body
        )
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            Self.log.error("decode failed for \(route, privacy: .public): \(error)")
            throw Failure.decoding(String(describing: error))
        }
    }

    private func requestData<Body: Encodable>(
        method: String,
        path: String,
        route: String,
        query: [URLQueryItem] = [],
        body: Body?
    ) async throws -> Data {
        await limiter.acquire(route: route)

        var components = URLComponents(
            url: metadata.apiBase.appending(path: path),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw Failure.transport("bad url: \(path)") }

        var request = URLRequest(url: url)
        request.httpMethod = method
        metadata.apply(to: &request, token: token)
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw Failure.transport("no HTTP response")
        }
        await limiter.update(
            route: route,
            headers: http.allHeaderFields,
            statusCode: http.statusCode
        )

        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw Failure.unauthorized
        case 403:
            throw Failure.forbidden
        case 404:
            throw Failure.notFound
        case 429:
            // The limiter has recorded the reset; retry once. A second 429 after
            // waiting is a real problem rather than ordinary back-pressure, and
            // retrying forever would turn it into a loop.
            await limiter.acquire(route: route)
            let (retryData, retryResponse) = try await session.data(for: request)
            guard let retryHTTP = retryResponse as? HTTPURLResponse else {
                throw Failure.transport("no HTTP response on retry")
            }
            await limiter.update(
                route: route,
                headers: retryHTTP.allHeaderFields,
                statusCode: retryHTTP.statusCode
            )
            guard (200..<300).contains(retryHTTP.statusCode) else {
                throw Self.apiFailure(status: retryHTTP.statusCode, data: retryData)
            }
            return retryData
        default:
            throw Self.apiFailure(status: http.statusCode, data: data)
        }
    }

    private static func apiFailure(status: Int, data: Data) -> Failure {
        struct ErrorEnvelope: Decodable {
            var code: Int?
            var message: String?
        }
        let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
        return .api(status: status, code: envelope?.code, message: envelope?.message)
    }
}

extension ISO8601DateFormatter {
    /// Two formatters, built once.
    ///
    /// `ISO8601DateFormatter` is expensive to construct and is documented as
    /// thread-safe for formatting, so one shared instance per shape is both
    /// correct and far cheaper than one per decode — and a history page decodes
    /// hundreds of timestamps.
    nonisolated(unsafe) static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
