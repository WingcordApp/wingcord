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

    /// Somebody's full profile.
    ///
    /// The banner, the bio and the theme colours live **only** here — the user
    /// objects on READY and on the member-list op carry none of them — so a
    /// profile card that has not called this can only ever draw a name and an
    /// avatar.
    ///
    /// `guildID` asks for the per-guild layer as well, which is how a member
    /// who has themed themselves differently in one server shows that server's
    /// banner rather than their global one.
    public func profile(
        of userID: UserID,
        inGuild guildID: GuildID? = nil
    ) async throws -> User {
        var query = [
            URLQueryItem(name: "with_mutual_guilds", value: "true"),
            URLQueryItem(name: "with_mutual_friends", value: "false"),
        ]
        if let guildID {
            query.append(URLQueryItem(name: "guild_id", value: String(guildID.rawValue)))
        }
        let user = try await get(
            "/users/\(userID.rawValue)/profile",
            // The rate limiter buckets by ROUTE, not by URL: every profile has
            // to share one bucket or a roster of five hundred opens five hundred
            // of them and the limiter stops limiting anything.
            route: "users/{id}/profile",
            query: query,
            as: UserProfileDTO.self
        )
        return user.domain
    }

    /// Names what a profile response actually contains, once per session.
    ///
    /// **Profile effects are the one cosmetic whose asset shape this client has
    /// never seen.** Decorations turned out to be APNG and banners GIF, both
    /// confirmed by decoding real bytes — but an effect is a layered, timed
    /// composition and Discord describes it in a structure nothing here has
    /// captured. Reading the keys off a live response is the difference between
    /// implementing it and guessing at it, and a guess in a decoder does not
    /// fail loudly; it yields plausible nonsense.
    ///
    /// Diagnostic only, gated on the trace sink, and capped so a large response
    /// cannot flood the log.
    nonisolated static func traceProfileShape(_ data: Data) {
        guard let sink = traceSink else { return }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        sink("PROFILE keys: \(root.keys.sorted().joined(separator: ","))")
        if let profile = root["user_profile"] as? [String: Any] {
            sink("PROFILE user_profile keys: \(profile.keys.sorted().joined(separator: ","))")
            if let effect = profile["profile_effect"] {
                sink("PROFILE profile_effect: \(effect)")
            } else {
                sink("PROFILE profile_effect: ABSENT")
            }
        }
        for key in ["user", "guild_member_profile"] {
            guard let nested = root[key] as? [String: Any] else { continue }
            sink("PROFILE \(key) keys: \(nested.keys.sorted().joined(separator: ","))")
        }
    }

    /// Where diagnostic lines go. Installed by the app when tracing is on.
    nonisolated(unsafe) public static var traceSink: (@Sendable (String) -> Void)?

    /// Resolves a collectible SKU to its artwork.
    ///
    /// Profile effects are named on a profile by SKU and described here. Shared
    /// across every account that owns one, so the caller caches by SKU rather
    /// than by user — a server where twenty people wear the same effect fetches
    /// it once.
    public func collectible(sku: String) async throws -> ProfileEffect? {
        try await get(
            "/collectibles-products/\(sku)",
            route: "collectibles-products/{sku}",
            query: [URLQueryItem(name: "locale", value: "en-US")],
            as: CollectiblesProductDTO.self
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

    /// - Parameter stickerIDs: Stickers to send. Discord accepts a message with
    ///   stickers and no text, which is what picking one does — so the content
    ///   may legitimately be empty here and only here.
    public func sendMessage(
        in channelID: ChannelID,
        content: String,
        nonce: String,
        replyingTo: MessageID? = nil,
        stickerIDs: [UInt64] = []
    ) async throws -> Message {
        struct Body: Encodable {
            var content: String
            var nonce: String
            var tts = false
            var message_reference: Reference?
            var flags: Int?
            /// Omitted entirely when empty: the route rejects an empty array
            /// where it accepts a missing key.
            var sticker_ids: [String]?

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
            flags: nil,
            sticker_ids: stickerIDs.isEmpty ? nil : stickerIDs.map(String.init)
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
        // One route's raw shape is worth naming, once, while it is still
        // unknown. See `traceProfileShape`.
        if route == "users/{id}/profile" { Self.traceProfileShape(data) }
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

// MARK: - GIFs
//
// Discord's own `/gifs` routes rather than the provider's. Discord has moved
// this backend before; the proxy's shape survived it, and the provider's API key
// stays on Discord's side rather than shipping inside this binary.
//
// `media_format=mp4` is what these routes are known to answer with, and it is
// deliberately NOT what the picker draws — see `GIFDTO.preview`, which takes the
// animated image and never the video.

extension DiscordREST {
    /// The landing screen: Discord's categories, plus the trending page that
    /// comes attached to them.
    public func gifLanding() async throws -> GIFLanding {
        let payload = try await get(
            "/gifs/trending",
            route: "gifs/trending",
            query: Self.gifQuery(),
            as: GIFTrendingDTO.self
        )
        return GIFLanding(
            categories: payload.categories?.compactMap(\.domain) ?? [],
            trending: payload.gifs?.compactMap(\.domain) ?? []
        )
    }

    /// Trending on its own, for the Trending tile.
    public func trendingGIFs(limit: Int = 50) async throws -> [GIF] {
        try await get(
            "/gifs/trending-gifs",
            route: "gifs/trending-gifs",
            query: Self.gifQuery(limit: limit),
            as: [GIFDTO].self
        ).compactMap(\.domain)
    }

    public func searchGIFs(_ query: String, limit: Int = 50) async throws -> [GIF] {
        try await get(
            "/gifs/search",
            route: "gifs/search",
            query: Self.gifQuery(limit: limit) + [URLQueryItem(name: "q", value: query)],
            as: [GIFDTO].self
        ).compactMap(\.domain)
    }

    /// The shape Discord's own client sends — `media_format=webm`, with the
    /// locale, captured from its request rather than guessed.
    ///
    /// It is deliberately **not** what the picker draws: webm is a video, and
    /// every image in this app goes through `CGImageSource`, which decodes none
    /// of it. Asking for it anyway keeps the response the shape these routes are
    /// known to answer with, and `GIFDTO.drawable` takes the animated image out
    /// of the same payload.
    private static func gifQuery(limit: Int? = nil) -> [URLQueryItem] {
        var query = [
            URLQueryItem(name: "media_format", value: "webm"),
            URLQueryItem(name: "locale", value: "en-US"),
        ]
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        return query
    }
}

/// One result. Every field past the URL is optional because these routes drop
/// whichever rendition the backend did not produce, and a strict decode there
/// throws away the whole page for one malformed entry.
struct GIFDTO: Decodable, Sendable {
    var url: URL?
    var src: URL?
    var gif_src: URL?
    var width: Int?
    var height: Int?

    var domain: GIF? {
        guard let url else { return nil }
        return GIF(
            url: url,
            previewURL: Self.drawable(gif_src, src, url),
            width: width,
            height: height
        )
    }

    /// The first candidate this app can turn into pixels.
    ///
    /// A video rendition is dropped rather than preferred: there is no player
    /// anywhere in the image path, so an MP4 is a placeholder that never
    /// resolves — which is what made every tile in the picker a grey square the
    /// first time this preferred `src`.
    static func drawable(_ candidates: URL?...) -> URL? {
        let video: Set<String> = ["mp4", "m4v", "mov", "webm"]
        return candidates
            .compactMap(\.self)
            .first { !video.contains($0.pathExtension.lowercased()) }
    }
}

struct GIFCategoryDTO: Decodable, Sendable {
    var name: String?
    var src: URL?
    var gif_src: URL?

    var domain: GIFCategory? {
        guard let name, !name.isEmpty else { return nil }
        return GIFCategory(name: name, previewURL: GIFDTO.drawable(gif_src, src))
    }
}

struct GIFTrendingDTO: Decodable, Sendable {
    var categories: [GIFCategoryDTO]?
    var gifs: [GIFDTO]?
}

// MARK: - Discord's own sticker packs

extension DiscordREST {
    /// The standard packs — Wumpus and friends — grouped the way Discord groups
    /// them, one pack per character.
    ///
    /// **Fetched once per launch, not per picker.** The set is the same for
    /// every account and changes about twice a year; a request per open is a
    /// request per open for an answer that cannot have changed.
    public func stickerPacks() async throws -> [StickerPack] {
        try await get(
            "/sticker-packs",
            route: "sticker-packs",
            as: StickerPacksDTO.self
        ).sticker_packs?.compactMap(\.domain) ?? []
    }
}

struct StickerPacksDTO: Decodable, Sendable {
    var sticker_packs: [StickerPackDTO]?
}

struct StickerPackDTO: Decodable, Sendable {
    var id: String?
    var name: String?
    var stickers: [StickerDTO]?
    /// The sticker Discord uses as the pack's face on a rail.
    var cover_sticker_id: String?

    var domain: StickerPack? {
        guard let name, !name.isEmpty else { return nil }
        let items = stickers?.compactMap(\.catalogEntry) ?? []
        guard !items.isEmpty else { return nil }
        return StickerPack(
            id: id ?? name,
            name: name,
            coverStickerID: cover_sticker_id.flatMap(UInt64.init) ?? items[0].id,
            stickers: items
        )
    }
}
