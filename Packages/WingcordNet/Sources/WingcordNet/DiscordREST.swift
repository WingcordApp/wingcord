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
    /// The threads hanging off messages on this page.
    ///
    /// **The whole channel, not just the chip's three fields.** A message that
    /// started a thread carries the thread's channel object inline — captured,
    /// `threads.har` — and putting it into `ChannelIndex` is what makes clicking
    /// the chip open something. Without this the chip resolves to nothing and
    /// the click is silently dropped.
    public var threads: [Channel] = []
}

public actor DiscordREST {
    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "REST")

    public enum Failure: Error, Sendable {
        case unauthorized
        case forbidden
        case notFound
        /// Discord's own error envelope: an HTTP status plus its JSON code.
        case api(status: Int, code: Int?, message: String?)
        /// A message refused by the channel's slowmode (code 20016), and how
        /// long Discord says is left — nil when the body did not say.
        ///
        /// **Its own case because it is not a rate limit.** A 429 anywhere else
        /// is the route's budget running out, which the limiter waits out and
        /// retries; this one is about the reader in one channel, and waiting it
        /// out can take six hours. See `slowmodeRefusal(status:data:)`.
        case slowmode(retryAfter: TimeInterval?)
        case transport(String)
        case decoding(String)
    }

    let session: URLSession
    /// `internal` alongside `session` and `decoder`: one route builds its own
    /// request, because it is made with an activity's bearer token rather than
    /// the account's. See `oauthIdentity(bearer:)`.
    let metadata: ClientMetadata
    private let limiter = RateLimiter()
    private var token: String?
    /// Who can put a human check on screen. See `DiscordREST+Captcha`.
    ///
    /// **Nil is a working configuration**, not a missing dependency: with none
    /// installed a challenged write fails with Discord's own rejection, which is
    /// what the test suite and any headless use of this actor want.
    var captchaSolver: (any CaptchaSolving)?

    /// One decoder for the process.
    ///
    /// `JSONDecoder` is not cheap to construct — it builds a date strategy and a
    /// key strategy each time — and a history page decode that allocates one per
    /// call pays for it on every page.
    ///
    /// **`static`, so it really is one for the process** rather than one per
    /// client, and so the decode tests can use the same instance production
    /// does. That second reason is not convenience: the date strategy below is
    /// the only thing that reads Discord's two timestamp spellings, and a test
    /// that reached for a bare `JSONDecoder()` would be asserting against a
    /// decoder the app never uses — passing on fixtures the client cannot
    /// actually read.
    ///
    /// No `nonisolated(unsafe)`: `JSONDecoder` is `Sendable` under the current
    /// SDK, and the compiler rejects the annotation as unnecessary on a
    /// constant of a `Sendable` type. Nothing mutates its strategies after this
    /// closure returns, which is what makes sharing it safe either way.
    public static let decoder: JSONDecoder = {
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
    public func currentUser() async throws -> CurrentAccount {
        try await get("/users/@me", route: "users/@me", as: UserDTO.self).currentAccount
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
    ) async throws -> ProfileFetch {
        var query = [
            URLQueryItem(name: "with_mutual_guilds", value: "true"),
            // **Asked for, because the answer is people the store has never
            // heard of.** A mutual friend is very often in none of the reader's
            // servers, so there is no second route that could name them — the
            // list arrives with whole user objects or it does not exist.
            URLQueryItem(name: "with_mutual_friends", value: "true"),
        ]
        if let guildID {
            query.append(URLQueryItem(name: "guild_id", value: String(guildID.rawValue)))
        }
        let payload = try await get(
            "/users/\(userID.rawValue)/profile",
            // The rate limiter buckets by ROUTE, not by URL: every profile has
            // to share one bucket or a roster of five hundred opens five hundred
            // of them and the limiter stops limiting anything.
            route: "users/{id}/profile",
            query: query,
            as: UserProfileDTO.self
        )
        return ProfileFetch(
            user: payload.domain,
            guildUser: guildID == nil ? nil : payload.guildDomain,
            guildID: guildID,
            widgets: (payload.widgets ?? []).compactMap(\.domain)
        )
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

    /// Where a custom emoji came from.
    ///
    /// **The only route that answers for a server the reader is not in**, which
    /// is the only case the question is ever asked about — an emoji from one of
    /// your own servers is already nameable from the resident tables.
    ///
    /// It answers for private servers too, since it is scoped to the emoji
    /// rather than to the server; what to publish from that is the client's
    /// decision, and `EmojiSource.Guild.isPublic` is where it is made.
    public func emojiSource(_ emojiID: EmojiID) async throws -> ExpressionSource? {
        try await get(
            "/emojis/\(emojiID.rawValue)/source",
            // Bucketed by route: a busy channel can raise a dozen of these in a
            // minute and each must share one bucket.
            route: "emojis/{id}/source",
            as: ExpressionSourceDTO.self
        ).domain
    }

    /// The server a sticker came from.
    ///
    /// **A different shape from the emoji route**: this one answers with the
    /// guild directly where that one nests it under `guild`, so the two have
    /// separate readers rather than one that guesses.
    public func stickerSource(_ stickerID: UInt64) async throws -> ExpressionSource? {
        try await get(
            "/stickers/\(stickerID)/guild",
            route: "stickers/{id}/guild",
            as: StickerSourceDTO.self
        ).domain
    }

    /// The card behind a server tag.
    ///
    /// **Answered for servers the reader is not in**, which is the whole point:
    /// a tag is worn across every server its owner is in, and the reader has to
    /// be able to find out what it stands for without joining anything. Nothing
    /// resident can answer it — the online count, the description, the badge
    /// artwork and the traits are on this route and on no other.
    public func guildProfile(of guildID: GuildID) async throws -> GuildProfile {
        try await get(
            "/guilds/\(guildID.rawValue)/profile",
            // Bucketed by route, not by URL: a reader hovering a busy channel
            // can ask about a dozen tags in a minute and each must share one
            // bucket, or the limiter stops limiting anything.
            route: "guilds/{id}/profile",
            as: GuildProfileDTO.self
        ).domain
    }

    /// Resolves a collectible SKU to its artwork.
    ///
    /// Profile effects and profile frames are both named on a profile by SKU
    /// and both described here, in different shapes — see `Collectible`.
    /// Shared across every account that owns one, so the caller caches by SKU
    /// rather than by user: a server where twenty people wear the same frame
    /// fetches it once.
    public func collectible(sku: String) async throws -> Collectible? {
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
        // transcript reading "Unknown" over a "?" avatar. Whoever each reply
        // quotes comes too — see `page(from:reversed:)`.
        //
        // Discord returns newest first; the store keeps oldest first, and
        // reversing there means no surface ever has to remember which way round
        // a page arrived.
        return Self.page(from: page, reversed: true)
    }

    /// - Parameter stickerIDs: Stickers to send. Discord accepts a message with
    ///   stickers and no text, which is what picking one does — so the content
    ///   may legitimately be empty here and only here.
    /// - Parameter attachments: Files already uploaded through
    ///   `createUploadSlots` and `upload(_:to:)`. A message may be nothing but
    ///   these, which is the second place empty content is legitimate.
    public func sendMessage(
        in channelID: ChannelID,
        content: String,
        nonce: String,
        replyingTo: MessageID? = nil,
        stickerIDs: [UInt64] = [],
        attachments: [UploadedAttachment] = []
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
            /// Omitted when empty, for the same reason as `sticker_ids`.
            var attachments: [Attached]?

            struct Reference: Encodable {
                var message_id: String
                var fail_if_not_exists = false
            }

            /// **`uploaded_filename` is the object; `filename` is the label.**
            /// Sending the reader's own name in the first field is the
            /// documented way to get a 500 out of this route.
            struct Attached: Encodable {
                var id: String
                var filename: String
                var uploaded_filename: String
                var description: String?
            }
        }
        let body = Body(
            content: content,
            nonce: nonce,
            message_reference: replyingTo.map {
                Body.Reference(message_id: $0.description)
            },
            flags: nil,
            sticker_ids: stickerIDs.isEmpty ? nil : stickerIDs.map(String.init),
            attachments: attachments.isEmpty ? nil : attachments.map {
                Body.Attached(
                    id: $0.id,
                    filename: $0.filename,
                    uploaded_filename: $0.uploadedFilename,
                    description: $0.altText
                )
            }
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

    // MARK: Reactions
    //
    // **The emoji goes into the path RAW.** `requestData` builds the URL with
    // `appending(path:)`, which percent-encodes the segment itself — so a
    // segment encoded beforehand is encoded twice, and 🔥 went out as
    // `%25F0%259F%2594%25A5`, which Discord reads as an emoji literally named
    // `%F0%9F%94%A5`. Every reaction this client wrote was an Unknown Emoji.
    //
    // All three shapes are Discord's own client's, read out of module `649963`
    // and its route table. The listing route is captured
    // (`lottiesuperreaction.har`); the two writes are not, and are worth
    // confirming on an account that has Nitro — see `HANDOFF.md`.

    /// Adds the reader's reaction of `kind`.
    ///
    /// `PUT …/reactions/{emoji}/@me?location=…&type=…` — the same route for both
    /// kinds, told apart by `type` alone.
    public func addReaction(
        _ emoji: EmojiRef,
        kind: ReactionKind,
        location: ReactionLocation,
        to messageID: MessageID,
        in channelID: ChannelID
    ) async throws {
        _ = try await requestData(
            method: "PUT",
            path: "/channels/\(channelID.rawValue)/messages/\(messageID.rawValue)/reactions/\(emoji.apiIdentifier)/@me",
            route: "channels/\(channelID.rawValue)/messages/:id/reactions",
            query: [
                URLQueryItem(name: "location", value: location.rawValue),
                URLQueryItem(name: "type", value: String(kind.rawValue)),
            ],
            body: Optional<Never>.none
        )
    }

    /// Takes the reader's reaction of `kind` back.
    ///
    /// **The type is a path segment here, not a query** — `…/{emoji}/{type}/@me`
    /// — which is the route Discord's client uses for every removal, plain ones
    /// included. The bare `…/{emoji}/@me` removes only a plain reaction and has
    /// no way to name a super one.
    public func removeReaction(
        _ emoji: EmojiRef,
        kind: ReactionKind,
        location: ReactionLocation,
        from messageID: MessageID,
        in channelID: ChannelID
    ) async throws {
        _ = try await requestData(
            method: "DELETE",
            path: "/channels/\(channelID.rawValue)/messages/\(messageID.rawValue)/reactions/\(emoji.apiIdentifier)/\(kind.rawValue)/@me",
            route: "channels/\(channelID.rawValue)/messages/:id/reactions",
            query: [
                URLQueryItem(name: "location", value: location.rawValue),
                URLQueryItem(name: "burst", value: kind == .burst ? "true" : "false"),
            ],
            body: Optional<Never>.none
        )
    }

    /// The first people who reacted with `emoji` of `kind` — what a chip's
    /// tooltip names.
    ///
    /// **Captured**: `GET …/reactions/x_shaq%3A…?limit=3&type=1` answers a bare
    /// array of whole user objects, and Discord asks for exactly three, because
    /// three names are all its sentence has room for.
    public func reactors(
        of emoji: EmojiRef,
        kind: ReactionKind,
        on messageID: MessageID,
        in channelID: ChannelID,
        limit: Int = 3
    ) async throws -> [User] {
        try await get(
            "/channels/\(channelID.rawValue)/messages/\(messageID.rawValue)/reactions/\(emoji.apiIdentifier)",
            route: "channels/\(channelID.rawValue)/messages/:id/reactions",
            query: [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "type", value: String(kind.rawValue)),
            ],
            as: [UserDTO].self
        ).map(\.domain)
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

    /// Casts the reader's vote.
    ///
    /// **The whole ballot every time, not a delta.** The route replaces the
    /// reader's selection, so un-voting is an empty array and changing a vote on
    /// a single-choice poll is the new id on its own — a client that sent only
    /// the id just clicked would leave the previous one standing on a
    /// multiselect poll.
    public func vote(
        answerIDs: [Int],
        onPoll messageID: MessageID,
        in channelID: ChannelID
    ) async throws {
        struct Body: Encodable { var answer_ids: [String] }
        _ = try await requestData(
            method: "PUT",
            path: "/channels/\(channelID.rawValue)/polls/\(messageID.rawValue)/answers/@me",
            route: "channels/\(channelID.rawValue)/polls/:id/answers",
            body: Body(answer_ids: answerIDs.map(String.init))
        )
    }

    /// Tells the channel the reader is typing, and hears how much of its
    /// slowmode the reader still has to wait out.
    ///
    /// **The answer is the only place a send made elsewhere shows up.** A 204
    /// means no cooldown is running; a 200 carries it —
    /// `{"message_send_cooldown_ms":1096,"thread_create_cooldown_ms":0}`,
    /// captured in `conversations + slowmode + jump to recent.har`. Somebody who
    /// posted from their phone ten seconds ago is refused here until the rest of
    /// it passes, and this is how the composer knows before they press Return.
    /// Discord's own composer reads it for exactly that (module `741961`).
    ///
    /// - Returns: what is left of the message cooldown, in seconds, or nil
    ///   when nothing is.
    public func typing(in channelID: ChannelID) async throws -> TimeInterval? {
        let data = try await requestData(
            method: "POST",
            path: "/channels/\(channelID.rawValue)/typing",
            route: "channels/\(channelID.rawValue)/typing",
            body: Optional<Never>.none
        )
        return Self.slowmodeCooldown(typingResponse: data)
    }

    /// The message cooldown in a typing answer. Nil for the 204's empty body,
    /// and for a zero — the field is present and 0 when only a *thread*
    /// cooldown is running.
    static func slowmodeCooldown(typingResponse data: Data) -> TimeInterval? {
        struct Answer: Decodable { var message_send_cooldown_ms: Int? }
        guard !data.isEmpty,
              let milliseconds = (try? decoder.decode(Answer.self, from: data))?
                  .message_send_cooldown_ms,
              milliseconds > 0
        else { return nil }
        return TimeInterval(milliseconds) / 1000
    }

    // MARK: Plumbing
    //
    // `internal` rather than `private` so a route can live in an extension in
    // another file. The routes are grouped by what they are *for* — a message,
    // a relationship, a report — and one file holding every path this client
    // knows is a file nobody reads. Nothing outside the package can reach these.

    func get<T: Decodable>(
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

    func post<Body: Encodable, T: Decodable>(
        _ path: String,
        route: String,
        body: Body,
        as type: T.Type
    ) async throws -> T {
        try await request(method: "POST", path: path, route: route, body: body, as: type)
    }

    func request<Body: Encodable, T: Decodable>(
        method: String,
        path: String,
        route: String,
        query: [URLQueryItem] = [],
        body: Body?,
        headers: [String: String] = [:],
        as type: T.Type
    ) async throws -> T {
        let data = try await requestData(
            method: method,
            path: path,
            route: route,
            query: query,
            body: body,
            headers: headers
        )
        // One route's raw shape is worth naming, once, while it is still
        // unknown. See `traceProfileShape`.
        if route == "users/{id}/profile" { Self.traceProfileShape(data) }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            Self.log.error("decode failed for \(route, privacy: .public): \(error)")
            throw Failure.decoding(String(describing: error))
        }
    }

    /// - Parameter headers: request-scoped headers on top of the client's own.
    ///   **Only for the analytics headers Discord's own client sends on specific
    ///   routes** — `x-context-properties` and nothing else so far. Anything
    ///   every request needs belongs in `ClientMetadata.apply`, which is the one
    ///   place a header can be added without a call site having to remember it.
    func requestData<Body: Encodable>(
        method: String,
        path: String,
        route: String,
        query: [URLQueryItem] = [],
        body: Body?,
        headers: [String: String] = [:]
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
        // After the client's own, so a route may only add and never silently
        // replace an identity header.
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
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
        // **Before the limiter hears about it.** A slowmode refusal is a 429,
        // and the limiter would file its `Retry-After` against this route —
        // which a channel's history fetches share with its sends — and the 429
        // branch below would sleep it out and send again. Both are wrong for a
        // wait that belongs to the reader in one channel and can run to six
        // hours: the history stalls, and the message goes out long after the
        // reader stopped expecting it to.
        if http.statusCode == 429, let refusal = Self.slowmodeRefusal(status: 429, data: data) {
            Self.traceRefusal(status: 429, route: route, data: data)
            throw refusal
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
            Self.traceRefusal(status: 401, route: route, data: data)
            throw Failure.unauthorized
        case 403:
            Self.traceRefusal(status: 403, route: route, data: data)
            throw Failure.forbidden
        case 404:
            Self.traceRefusal(status: 404, route: route, data: data)
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
            // **A human check is a rejection with instructions, not a failure.**
            // It arrives as a 400 carrying no `code` and no `message`, so it
            // does not survive `apiFailure` — which is why it is recognised
            // here, before the status becomes an error, rather than at a call
            // site that would have to know which routes can raise one.
            if let solution = await solveCaptcha(in: data) {
                solution.apply(to: &request)
                return try await sendSolved(request, route: route)
            }
            throw Self.apiFailure(status: http.statusCode, data: data)
        }
    }

    /// Puts a challenge on screen and waits, if this really is one and there is
    /// anybody to show it to.
    ///
    /// Returns nil for every other outcome — no challenge in the body, a service
    /// this build cannot render, no solver installed, or somebody who closed it
    /// — and the caller then reports Discord's own rejection.
    private func solveCaptcha(in data: Data) async -> CaptchaSolution? {
        guard let solver = captchaSolver,
              let challenge = Self.captchaChallenge(in: data),
              challenge.isSolvable
        else { return nil }
        return await solver.solve(challenge)
    }

    /// Re-sends a request that a solved challenge has just been applied to.
    ///
    /// **Exactly once.** hCaptcha's token is single-use and Discord's rejection
    /// of a solved one is a real answer, so a second challenge on the retry is
    /// reported rather than presented — the alternative is a window somebody
    /// cannot get out of by answering it correctly.
    private func sendSolved(_ request: URLRequest, route: String) async throws -> Data {
        await limiter.acquire(route: route)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw Failure.transport("no HTTP response on captcha retry")
        }
        await limiter.update(
            route: route,
            headers: http.allHeaderFields,
            statusCode: http.statusCode
        )
        guard (200..<300).contains(http.statusCode) else {
            throw Self.apiFailure(status: http.statusCode, data: data)
        }
        return data
    }

    /// Like `requestData`, but returns the response verbatim — body and
    /// status both — instead of throwing outside 200..<300.
    ///
    /// For the one route whose error envelope carries data the caller still
    /// needs: `POST /users/@me/connections/domain/{id}` answers "not verified
    /// yet" with a 4xx that still carries the token the reader has to go
    /// publish, and `requestData` throwing that body away would throw away
    /// the only reason to have called it. No 429 retry here — a second
    /// identical write for one reader-initiated click is not worth the extra
    /// path, unlike the read-heavy routes above.
    func requestRaw<Body: Encodable>(
        method: String,
        path: String,
        route: String,
        query: [URLQueryItem] = [],
        body: Body?
    ) async throws -> (data: Data, statusCode: Int) {
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
        await limiter.update(route: route, headers: http.allHeaderFields, statusCode: http.statusCode)
        return (data, http.statusCode)
    }

    /// Writes a refusal's own words into the trace before it is thrown away.
    ///
    /// **401, 403 and 404 are the three statuses whose body this client
    /// discards**, because each maps to a case with no associated value — so
    /// "Not authorised." reaches the reader with no way to tell a signed-out
    /// session from a route that wants MFA from a path that does not exist.
    /// Discord says which in the body every time: `{"message": "401:
    /// Unauthorized", "code": 0}` and `{"code": 60003, "message": "Two factor
    /// is required for this operation"}` are the same status and two different
    /// things to do about it.
    ///
    /// This is `INVARIANTS.md`'s "never log a close code without its reason",
    /// one layer over — it cost three rounds of guessing on the voice gateway
    /// and it is costing them again on `users/@me/scheduled-messages`. Gated on
    /// the sink, so it is free in a build nobody is tracing, and capped so a
    /// large error page cannot flood the log.
    static func traceRefusal(status: Int, route: String, data: Data) {
        guard let sink = traceSink else { return }
        let body = String(data: data.prefix(400), encoding: .utf8) ?? "<\(data.count) bytes>"
        sink("HTTP \(status) \(route): \(body)")
    }

    /// Discord's code for a message refused by slowmode.
    static let slowmodeCode = 20016

    /// The refusal, when it is slowmode's; nil for every other response.
    ///
    /// Read the way Discord's own client reads it (module `148494`): a 4xx
    /// whose body carries code 20016, with `retry_after` in seconds beside it.
    /// **Not captured** — nothing in `conversations + slowmode + jump to
    /// recent.har` was sent into a running cooldown — so both fields are
    /// optional, and a different shape of body loses the wait rather than the
    /// refusal.
    static func slowmodeRefusal(status: Int, data: Data) -> Failure? {
        struct Refusal: Decodable {
            var code: Int?
            var retry_after: Double?
        }
        guard (400..<500).contains(status),
              let refusal = try? decoder.decode(Refusal.self, from: data),
              refusal.code == slowmodeCode
        else { return nil }
        return .slowmode(retryAfter: refusal.retry_after.flatMap { $0 > 0 ? $0 : nil })
    }

    static func apiFailure(status: Int, data: Data) -> Failure {
        // Every path that turns a body into a failure — the ordinary one, the
        // captcha retry — reports slowmode as itself.
        if let refusal = slowmodeRefusal(status: status, data: data) { return refusal }
        struct ErrorEnvelope: Decodable {
            var code: Int?
            var message: String?
        }
        let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
        // **`message` alone is useless on a 50035.** "Invalid Form Body" says a
        // field was rejected and not which one; the `errors` object beside it
        // says exactly which, and it was being thrown away. Diagnosing a
        // rejected save without it means guessing at four routes' worth of
        // fields — see `fieldErrors`.
        let detail = fieldErrors(in: data)
        let message = [envelope?.message, detail]
            .compactMap { $0 }
            .joined(separator: " — ")
        return .api(
            status: status,
            code: envelope?.code,
            message: message.isEmpty ? nil : message
        )
    }

    /// Discord's per-field complaints, flattened to `path: message`.
    ///
    /// The shape nests one level per path component and ends in an `_errors`
    /// array, so a bad widget id arrives as
    /// `{"widgets":{"0":{"id":{"_errors":[{"message":"Value … is not
    /// snowflake."}]}}}}`. Walked rather than typed, because the path is the
    /// request's own shape and every route has a different one.
    private static func fieldErrors(in data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = root["errors"] as? [String: Any]
        else { return nil }

        var found: [String] = []
        func walk(_ node: Any, path: [String]) {
            // Two at most: a save that broke five fields is still a save the
            // reader has to fix one field at a time, and a paragraph in a bar is
            // a paragraph nobody reads.
            guard found.count < 2 else { return }
            if let list = (node as? [String: Any])?["_errors"] as? [[String: Any]] {
                let messages = list.compactMap { $0["message"] as? String }
                if let first = messages.first {
                    found.append(path.isEmpty ? first : "\(path.joined(separator: ".")): \(first)")
                }
                return
            }
            guard let object = node as? [String: Any] else { return }
            for key in object.keys.sorted() {
                walk(object[key] as Any, path: path + [key])
            }
        }
        walk(errors, path: [])
        return found.isEmpty ? nil : found.joined(separator: "; ")
    }

    // MARK: Multipart
    //
    // **One route in this whole client needs this**, and there is no way to know
    // that except by capturing it: creating a sticker is `multipart/form-data`
    // while creating an emoji, one page over in the same window, is JSON with a
    // base64 data URI. Two uploads, two encodings, and Discord's own
    // documentation describes neither.
    //
    // So this is deliberately not a general uploader. It takes the parts a
    // sticker needs — a few short text fields and one file — and nothing else,
    // because a general one would be machinery built for a single caller.

    /// One part of a multipart body.
    struct MultipartPart: Sendable {
        var name: String
        var value: Value

        enum Value: Sendable {
            case text(String)
            /// A file, with the filename and content type the part declares.
            ///
            /// **The declared type need not match the filename**, and in the
            /// captured request it does not: the reference client sends
            /// `filename="474344.jpg"` with `Content-Type: image/png`, because
            /// it re-encoded the image when it cropped it. Both are therefore
            /// carried separately rather than derived from each other.
            case file(Data, filename: String, contentType: String)
        }

        static func text(_ name: String, _ value: String) -> MultipartPart {
            MultipartPart(name: name, value: .text(value))
        }

        static func file(
            _ name: String,
            _ data: Data,
            filename: String,
            contentType: String
        ) -> MultipartPart {
            MultipartPart(name: name, value: .file(data, filename: filename, contentType: contentType))
        }
    }

    /// Sends a `multipart/form-data` request.
    ///
    /// The boundary is generated per request from a UUID. A fixed one would
    /// work until the day a caller uploads a file whose bytes contain it, and
    /// the failure then is a 400 that names the wrong field.
    func requestMultipart<T: Decodable>(
        method: String,
        path: String,
        route: String,
        parts: [MultipartPart],
        as type: T.Type
    ) async throws -> T {
        await limiter.acquire(route: route)

        let boundary = "wingcord.\(UUID().uuidString)"
        var request = URLRequest(url: metadata.apiBase.appending(path: path))
        request.httpMethod = method
        metadata.apply(to: &request, token: token)
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = Self.multipartBody(parts: parts, boundary: boundary)

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
        await limiter.update(route: route, headers: http.allHeaderFields, statusCode: http.statusCode)

        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401, 403, 404:
                Self.traceRefusal(status: http.statusCode, route: route, data: data)
                switch http.statusCode {
                case 401: throw Failure.unauthorized
                case 403: throw Failure.forbidden
                default: throw Failure.notFound
                }
            default: throw Self.apiFailure(status: http.statusCode, data: data)
            }
        }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            Self.log.error("decode failed for \(route, privacy: .public): \(error)")
            throw Failure.decoding(String(describing: error))
        }
    }

    /// Builds the body.
    ///
    /// Static and pure so it is testable without a socket, and so the one thing
    /// that is easy to get wrong here — CRLF everywhere, including the pair that
    /// closes the final boundary — is checkable against a captured body.
    static func multipartBody(parts: [MultipartPart], boundary: String) -> Data {
        var body = Data()
        // Reserving up front matters: a sticker is half a megabyte and appending
        // it to an empty `Data` reallocates its way there.
        let fileBytes = parts.reduce(0) { total, part in
            if case .file(let data, _, _) = part.value { return total + data.count }
            return total + 128
        }
        body.reserveCapacity(fileBytes + parts.count * 128 + 64)

        func append(_ text: String) {
            // UTF-8 of an ASCII-plus-header string never fails to encode, and a
            // label may legitimately carry an emoji.
            body.append(Data(text.utf8))
        }

        for part in parts {
            append("--\(boundary)\r\n")
            switch part.value {
            case .text(let value):
                append("Content-Disposition: form-data; name=\"\(part.name)\"\r\n\r\n")
                append(value)
                append("\r\n")
            case .file(let data, let filename, let contentType):
                append(
                    "Content-Disposition: form-data; name=\"\(part.name)\";"
                        + " filename=\"\(filename)\"\r\n"
                )
                append("Content-Type: \(contentType)\r\n\r\n")
                body.append(data)
                append("\r\n")
            }
        }
        append("--\(boundary)--\r\n")
        return body
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
        GIF.drawable(candidates)
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

// MARK: - The three surfaces beside a server's channels
//
// Server Guide, Channels & Roles and Game Servers. All five routes below are
// **per guild and stable for a session** — a guide, a set of questions and a
// rented server change about as often as the server's name — so every caller
// caches by guild id and none of them is on a refresh timer.
//
// Each is bucketed by ROUTE with the id templated out. A reader stepping through
// ten servers must share one bucket per surface, or the limiter stops limiting
// anything.

extension DiscordREST {

    /// The page a server shows somebody who has just arrived.
    ///
    /// Answers 404 for a server that has never configured one, which is the
    /// ordinary case rather than an error — the caller reads that as "no guide"
    /// and draws no row for it.
    public func serverGuide(of guildID: GuildID) async throws -> ServerGuide {
        // **A server with no guide answers 204, not 404**, and a 204 has an
        // empty body — so decoding it throws `.decoding` rather than the
        // `.notFound` a caller would think to catch. That is the *ordinary*
        // answer for a fresh server, and it is what a capture of one caught:
        // the reader's side survived it only because it catches every error and
        // stores an empty guide, while the settings page reported "Discord
        // answered with something this client could not read."
        //
        // Handled here rather than at either caller, so the next one does not
        // have to know.
        let data = try await requestData(
            method: "GET",
            path: "/guilds/\(guildID.rawValue)/new-member-welcome",
            route: "guilds/{id}/new-member-welcome",
            body: Optional<Never>.none
        )
        guard !data.isEmpty else { return ServerGuide(guildID: guildID, isEnabled: false) }
        do {
            return try Self.decoder.decode(NewMemberWelcomeDTO.self, from: data).domain(guildID: guildID)
        } catch {
            throw Failure.decoding(String(describing: error))
        }
    }

    /// The questions a community server asks, and what answering them unlocks.
    public func onboarding(of guildID: GuildID) async throws -> GuildOnboarding {
        try await get(
            "/guilds/\(guildID.rawValue)/onboarding",
            route: "guilds/{id}/onboarding",
            as: OnboardingDTO.self
        ).domain(guildID: guildID)
    }

    /// How many people hold each of a server's roles.
    ///
    /// One object of `role id -> count`, for **every** role in the server —
    /// nearly two hundred entries on a large one. It is what lets an onboarding
    /// option say how many people chose it, and it is the only route that
    /// answers that at all.
    ///
    /// Keyed straight into `RoleID` at the boundary so no surface parses an id.
    public func roleMemberCounts(inGuild guildID: GuildID) async throws -> [RoleID: Int] {
        let raw = try await get(
            "/guilds/\(guildID.rawValue)/roles/member-counts",
            route: "guilds/{id}/roles/member-counts",
            as: [String: Int].self
        )
        var counts: [RoleID: Int] = [:]
        counts.reserveCapacity(raw.count)
        for (key, value) in raw {
            guard let id = UInt64(key) else { continue }
            counts[RoleID(rawValue: id)] = value
        }
        return counts
    }

    /// Records the reader's answers, and returns the ballot as the server now
    /// holds it.
    ///
    /// **`POST`, and the method is not a detail.** This was `PUT` — which reads
    /// as right for a whole-object replace, and is what the route's own name
    /// suggests — and Discord answers a `PUT` here with **403 "You do not have
    /// permission to do that."** That is a rejection nothing about the request
    /// explains: the account is a member, the body is correct, and the message
    /// names permissions rather than a method. `forza onboarding1.har` entry 16
    /// settles it — `POST /guilds/{id}/onboarding-responses`, 200.
    ///
    /// It cost a live join to find, because the 403 was invisible in every test:
    /// nothing here exercises the real route, and the surface that used it
    /// before — Channels & Roles — reports a failed save by quietly restoring
    /// the previous answer, which looks exactly like a chip that did not take
    /// the click.
    ///
    /// **The whole ballot, never a delta.** The route replaces a selection, so a
    /// client that sent only the id just clicked would drop every previous
    /// answer — the same shape as the poll route, and for the same reason.
    ///
    /// The answer is read back rather than assumed: the server can refuse an
    /// option, and a client that kept its optimistic set would then disagree
    /// with it about which roles it had just granted.
    public func setOnboardingResponses(
        _ optionIDs: Set<UInt64>,
        prompts: [GuildOnboarding.Prompt],
        inGuild guildID: GuildID
    ) async throws -> Set<UInt64> {
        let data = try await requestData(
            method: "POST",
            path: "/guilds/\(guildID.rawValue)/onboarding-responses",
            route: "guilds/{id}/onboarding-responses",
            body: OnboardingResponsesBody(responses: optionIDs, prompts: prompts)
        )
        return (try? Self.decoder.decode(OnboardingResponsesDTO.self, from: data))?.responses
            ?? optionIDs
    }

    /// The rules a server makes people agree to.
    ///
    /// `with_guild=false` because the guild half of the response is a copy of
    /// an object the store already holds, and asking for it doubles the payload
    /// to learn nothing.
    ///
    /// - Parameter inviteCode: the invite this gate was reached through, when it
    ///   was. Captured — `?with_guild=false&invite_code=forza` — and sent for the
    ///   same reason `location` is sent on the join: Discord's own client sends
    ///   it, and a gate reached by a route this client does not model is a gate
    ///   Discord may describe differently. Omitted where there was no invite,
    ///   which is every server opened from the rail.
    public func memberVerification(
        of guildID: GuildID,
        inviteCode: String? = nil
    ) async throws -> MemberVerification {
        var query = [URLQueryItem(name: "with_guild", value: "false")]
        if let inviteCode, !inviteCode.isEmpty {
            query.append(URLQueryItem(name: "invite_code", value: inviteCode))
        }
        return try await get(
            "/guilds/\(guildID.rawValue)/member-verification",
            route: "guilds/{id}/member-verification",
            query: query,
            as: MemberVerificationDTO.self
        ).domain(guildID: guildID)
    }

    /// Follows or unfollows one channel — or one whole category.
    ///
    /// `PATCH /users/@me/guilds/settings` — note the **plural**: the route takes
    /// every guild at once and is patched with a nested object naming just the
    /// one that changed. That shape is the capture's, not a simplification of
    /// it: `{"guilds": {"<guild>": {"channel_overrides": {"<channel>": {…}}}}}`.
    ///
    /// **A category is a channel here.** The Follow Category switch and a
    /// channel's checkbox write the same override on the same key, which is why
    /// there is one method rather than two — the only thing that differs is what
    /// the reader is told it means.
    ///
    /// The answer is the guild's whole settings object, and **an unfollowed
    /// channel comes back missing rather than zeroed**. So the reply is read as
    /// the complete set of follows for that guild, not as a delta.
    public func setChannelFollowed(
        _ isFollowed: Bool,
        channelID: ChannelID,
        inGuild guildID: GuildID
    ) async throws -> Set<ChannelID> {
        struct Override: Encodable { var flags: Int }
        struct GuildBody: Encodable { var channel_overrides: [String: Override] }
        struct Body: Encodable { var guilds: [String: GuildBody] }

        let data = try await requestData(
            method: "PATCH",
            path: "/users/@me/guilds/settings",
            route: "users/@me/guilds/settings",
            body: Body(guilds: [
                String(guildID.rawValue): GuildBody(channel_overrides: [
                    String(channelID.rawValue): Override(
                        flags: isFollowed ? ChannelSettingsFlags.followed : 0
                    )
                ])
            ])
        )

        let settings = (try? Self.decoder.decode([GuildSettingsDTO].self, from: data)) ?? []
        var followed: Set<ChannelID> = []
        for entry in settings where entry.guild_id == guildID {
            for override in entry.channel_overrides ?? [] {
                guard let id = override.channel_id,
                      (override.flags ?? 0) & ChannelSettingsFlags.followed != 0
                else { continue }
                followed.insert(id)
            }
        }
        return followed
    }

    /// Records that the reader has read and agreed to a server's rules.
    ///
    /// `PUT /guilds/{id}/requests/@me` — the route behind the join flow's
    /// **Finish**, and the only write on any of these pages besides the
    /// onboarding ballot.
    ///
    /// **The whole form goes back, version string included, byte for byte.** The
    /// agreement is recorded against that text; a client that re-serialised it
    /// from a `Date` would record against a string the server does not have.
    ///
    /// The answer is a *join request*, not an acknowledgement: a rules-only gate
    /// approves instantly, a server that also asks questions leaves it pending a
    /// moderator, and one that has turned somebody away answers rejected. All
    /// three are real, and the caller tells them apart.
    public func agreeToRules(
        _ verification: MemberVerification,
        inGuild guildID: GuildID
    ) async throws -> MemberVerificationOutcome {
        guard let body = MemberVerificationSubmitBody(verification) else {
            throw Failure.transport("no rules to agree to")
        }
        let data = try await requestData(
            method: "PUT",
            path: "/guilds/\(guildID.rawValue)/requests/@me",
            route: "guilds/{id}/requests/@me",
            body: body
        )
        return (try? Self.decoder.decode(JoinRequestDTO.self, from: data))?.outcome
            // A 2xx with a body this client cannot read is still a request the
            // server accepted, and the gateway's member update is what settles
            // it either way.
            ?? .pending
    }

    /// The game servers a community has rented through Discord.
    ///
    /// Answers `[]` for the overwhelming majority of servers and 403/404 for one
    /// the reader may not ask about. All three mean the same thing to the
    /// caller — there is nothing to show — which is why the row only appears
    /// once this has answered with something.
    public func gameServers(inGuild guildID: GuildID) async throws -> [GameServer] {
        try await get(
            "/guilds/\(guildID.rawValue)/game-servers",
            route: "guilds/{id}/game-servers",
            as: [GameServerDTO].self
        ).compactMap(\.domain)
    }

    /// The steps the game needs to connect to a rented server.
    ///
    /// **They belong to the product, not to the instance**, so this is cached by
    /// SKU: two servers on the same plan share one answer, and a reader who
    /// opens the connect sheet twice asks once.
    ///
    /// `country_code` and `payment_source_id` are on Discord's own request and
    /// are **deliberately not sent**. Both describe a purchase, this client
    /// makes none, and neither can change the four sentences that are the only
    /// part of the response read here. If the route ever refuses without them,
    /// the sheet degrades to the address and its copy button — which is the part
    /// somebody actually needs — rather than failing.
    public func gameServerProduct(sku skuID: String) async throws -> GameServerProduct {
        try await get(
            "/storefront/products/sku/\(skuID)",
            route: "storefront/products/sku/{id}",
            query: [URLQueryItem(name: "locale", value: "en-US")],
            as: StorefrontProductDTO.self
        ).domain(skuID: skuID)
    }
}

/// Where a reaction was made, in the words Discord's own client puts in the
/// reaction routes' `location` query — module `649963`'s table, verbatim.
///
/// Only the two surfaces this client reacts from. The value changes nothing
/// about what the route does; it is sent because Discord's client always sends
/// it, and a request that differs from the official one for no reason is a
/// request that stands out.
public enum ReactionLocation: String, Sendable {
    /// A chip under a message.
    case inlineButton = "Message Inline Button"
    /// The emoji picker a message's Add Reaction opens.
    case reactionPicker = "Message Reaction Picker"
}
