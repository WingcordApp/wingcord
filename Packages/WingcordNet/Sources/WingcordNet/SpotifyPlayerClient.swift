import Foundation
import WingcordCore

// MARK: - Spotify's player, for one linked account
//
// What Discord's `SpotifyStore` runs per connection (module `655116`, its calls
// in `107750`): Spotify's Web API with the account's own token, and Spotify's
// "dealer" socket, which pushes the player's state as it changes. The token is
// Discord's to hand out — `DiscordREST.spotifyAccessToken` — and is asked for
// again when Spotify answers 401, which is the one retry Discord's client makes.
//
// **Not on `DiscordREST`**, for `SpotifyEmbedClient`'s reason: these requests go
// to Spotify, and carry Spotify's token and nothing of Discord's.
//
// **The socket is the browser's, not an app's.** Discord's web client opens it
// from a page; nothing captured says Spotify accepts it from anywhere else, so
// a socket that will not stay up degrades to asking the player directly on the
// same backoff, which is slower and still correct.

/// Spotify's player for one account.
public actor SpotifyPlayerClient {
    /// What the socket says.
    public enum Event: Sendable {
        /// The player changed, or stopped (nil).
        case player(SpotifyPlayback?)
        /// The devices may have changed — Discord asks for them again.
        case devicesChanged
    }

    public typealias TokenRefresh = @Sendable () async throws -> String

    public let accountID: String
    private var accessToken: String
    private let refreshToken: TokenRefresh

    private static let api = "https://api.spotify.com/v1"
    /// "hm://pusher/v1/connections/<id>": the socket naming itself, which is
    /// what the player's notifications are subscribed with.
    private static let connectionPrefix = "hm://pusher/v1/connections/"
    /// Discord's ping and its longest wait between tries.
    private static let pingInterval: Duration = .seconds(30)
    private static let longestBackoff: Double = 60

    /// Its own session, as `SpotifyEmbedClient`'s: nothing of Discord's rides
    /// along to Spotify.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    public init(accountID: String, accessToken: String, refresh: @escaping TokenRefresh) {
        self.accountID = accountID
        self.accessToken = accessToken
        self.refreshToken = refresh
    }

    // MARK: The Web API

    /// What is playing — `GET /me/player`, tracks and episodes both. Nil when
    /// nothing is (Spotify answers 204).
    public func player() async throws -> SpotifyPlayback? {
        let data = try await call("GET", "/me/player", query: [URLQueryItem(name: "additional_types", value: "track,episode")])
        guard !data.isEmpty else { return nil }
        return try JSONDecoder().decode(SpotifyPlayerDTO.self, from: data).domain
    }

    /// Whether the account is on Premium, which following along needs.
    public func isPremium() async throws -> Bool {
        struct Profile: Decodable { var product: String? }
        let data = try await call("GET", "/me")
        return try JSONDecoder().decode(Profile.self, from: data).product == "premium"
    }

    public func devices() async throws -> [SpotifyDevice] {
        struct Answer: Decodable { var devices: [SpotifyPlayerDTO.DeviceDTO]? }
        let data = try await call("GET", "/me/player/devices")
        return (try JSONDecoder().decode(Answer.self, from: data).devices ?? []).compactMap(\.domain)
    }

    /// Plays an item from a position — Discord's `ZH`, what Join and Play on
    /// Spotify both call: `PUT /me/player/play?device_id=` with the item's
    /// `spotify:` address and the position in milliseconds.
    public func play(itemID: String, type: String, positionMs: Int, deviceID: String?) async throws {
        struct Body: Encodable {
            var uris: [String]
            var position_ms: Int
        }
        let body = try JSONEncoder().encode(Body(uris: ["spotify:\(type):\(itemID)"], position_ms: max(0, positionMs)))
        _ = try await call(
            "PUT", "/me/player/play",
            query: deviceID.map { [URLQueryItem(name: "device_id", value: $0)] } ?? [],
            body: body
        )
    }

    public func pause() async throws {
        _ = try await call("PUT", "/me/player/pause")
    }

    /// Asks Spotify to push this account's player state down a socket.
    private func subscribe(connectionID: String) async throws {
        _ = try await call(
            "PUT", "/me/notifications/player",
            query: [URLQueryItem(name: "connection_id", value: connectionID)]
        )
    }

    /// One call with the account's token, asking Discord for a fresh one and
    /// trying once more on a 401.
    private func call(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        isRetry: Bool = false
    ) async throws -> Data {
        guard var components = URLComponents(string: Self.api + path) else {
            throw DiscordREST.Failure.transport("Bad Spotify address")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw DiscordREST.Failure.transport("Bad Spotify address") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw DiscordREST.Failure.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw DiscordREST.Failure.transport("No answer") }
        switch http.statusCode {
        case 200 ..< 300:
            return data
        case 401 where !isRetry:
            accessToken = try await refreshToken()
            return try await call(method, path, query: query, body: body, isRetry: true)
        case 403:
            throw DiscordREST.Failure.forbidden(code: nil)
        case 404:
            throw DiscordREST.Failure.notFound
        default:
            throw DiscordREST.Failure.api(status: http.statusCode, code: nil, message: nil)
        }
    }

    // MARK: The dealer

    /// The player as it changes, for as long as somebody is listening.
    ///
    /// The state as it stands first, then whatever the socket pushes. A socket
    /// that drops comes back on a doubling wait up to a minute, and every wait
    /// asks the player directly, so the state still arrives while it is down.
    public nonisolated func events() -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task { await self.run(continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ continuation: AsyncStream<Event>.Continuation) async {
        var backoff: Double = 1
        while !Task.isCancelled {
            continuation.yield(.player(try? await player()))
            let opened = await listen(continuation)
            guard !Task.isCancelled else { break }
            backoff = opened ? 1 : min(backoff * 2, Self.longestBackoff)
            try? await Task.sleep(for: .seconds(backoff))
        }
        continuation.finish()
    }

    /// One socket, until it closes. Answers whether it ever opened.
    private func listen(_ continuation: AsyncStream<Event>.Continuation) async -> Bool {
        guard let url = URL(string: "wss://dealer.spotify.com/?access_token=\(accessToken)") else { return false }
        var request = URLRequest(url: url)
        request.setValue("https://discord.com", forHTTPHeaderField: "Origin")
        let socket = Self.session.webSocketTask(with: request)
        socket.resume()
        let pings = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pingInterval)
                try? await socket.send(.string(#"{"type":"ping"}"#))
            }
        }
        defer {
            pings.cancel()
            socket.cancel(with: .goingAway, reason: nil)
        }
        var opened = false
        while !Task.isCancelled {
            guard let message = try? await socket.receive() else { break }
            opened = true
            let text: String? = switch message {
            case .string(let string): string
            case .data(let data): String(data: data, encoding: .utf8)
            @unknown default: nil
            }
            guard let text, let data = text.data(using: .utf8),
                  let frame = try? JSONDecoder().decode(DealerFrame.self, from: data),
                  frame.type == "message"
            else { continue }
            if let uri = frame.uri, uri.hasPrefix(Self.connectionPrefix) {
                let connectionID = String(uri.dropFirst(Self.connectionPrefix.count)).removingPercentEncoding
                if let connectionID { try? await subscribe(connectionID: connectionID) }
                continue
            }
            for event in frame.payloads?.flatMap({ $0.events ?? [] }) ?? [] {
                switch event.type {
                case "PLAYER_STATE_CHANGED":
                    continuation.yield(.player(event.event?.state?.domain))
                case "DEVICE_STATE_CHANGED":
                    continuation.yield(.devicesChanged)
                default:
                    break
                }
            }
        }
        return opened
    }
}

// MARK: - Wire types

/// One frame from the dealer: a connection naming itself, or events.
private struct DealerFrame: Decodable {
    var type: String?
    var uri: String?
    var payloads: [Payload]?

    struct Payload: Decodable {
        var events: [Event]?
    }

    struct Event: Decodable {
        var type: String?
        var event: Body?
    }

    struct Body: Decodable {
        var state: SpotifyPlayerDTO?
    }
}

/// Spotify's player object — the Web API's and the dealer's are one shape.
struct SpotifyPlayerDTO: Decodable {
    var device: DeviceDTO?
    var progress_ms: Int?
    var is_playing: Bool?
    var repeat_state: String?
    var item: ItemDTO?
    var context: ContextDTO?

    struct DeviceDTO: Decodable {
        var id: String?
        var name: String?
        var type: String?
        var is_active: Bool?
        var is_restricted: Bool?

        var domain: SpotifyDevice? {
            guard let id, let name else { return nil }
            return SpotifyDevice(
                id: id,
                name: name,
                type: type ?? "",
                isActive: is_active ?? false,
                isRestricted: is_restricted ?? false
            )
        }
    }

    struct ItemDTO: Decodable {
        var id: String?
        var name: String?
        var duration_ms: Int?
        var type: String?
        var is_local: Bool?
        var linked_from: Linked?
        var album: CollectionDTO?
        /// An episode's in place of an album.
        var show: CollectionDTO?
        var artists: [ArtistDTO]?

        struct Linked: Decodable { var id: String? }
    }

    struct CollectionDTO: Decodable {
        var id: String?
        var name: String?
        var images: [ImageDTO]?
        var type: String?
    }

    struct ImageDTO: Decodable { var url: String? }

    struct ArtistDTO: Decodable {
        var id: String?
        var name: String?
    }

    struct ContextDTO: Decodable {
        var type: String?
        var uri: String?
    }

    /// Discord's reading (`655116`'s `ec`): a track by its own id or the one
    /// it was relinked from, an episode under its show, and nothing else.
    /// The context only when it is an album: a playlist's would need a second
    /// request to learn whether it is public, and Discord leaves a private one
    /// off.
    var domain: SpotifyPlayback {
        var playing: SpotifyPlayback.Item?
        if let item, let id = item.linked_from?.id ?? item.id, let name = item.name {
            switch item.type {
            case "track":
                playing = SpotifyPlayback.Item(
                    id: id,
                    name: name,
                    duration: item.duration_ms ?? 0,
                    type: "track",
                    albumID: item.album?.id ?? "",
                    albumName: item.album?.name ?? "",
                    imageURL: item.album?.images?.first?.url.flatMap(URL.init(string:)),
                    albumType: item.album?.type ?? "album",
                    artists: (item.artists ?? []).compactMap { artist in
                        guard let id = artist.id, !id.isEmpty, let name = artist.name, !name.isEmpty else { return nil }
                        return SpotifyPlayback.Artist(id: id, name: name)
                    },
                    isLocal: item.is_local ?? false
                )
            case "episode":
                playing = SpotifyPlayback.Item(
                    id: id,
                    name: name,
                    duration: item.duration_ms ?? 0,
                    type: "episode",
                    albumID: item.show?.id ?? "",
                    albumName: item.show?.name ?? "",
                    imageURL: item.show?.images?.first?.url.flatMap(URL.init(string:)),
                    albumType: "show"
                )
            default:
                break
            }
        }
        return SpotifyPlayback(
            item: playing,
            isPlaying: is_playing ?? false,
            progress: progress_ms ?? 0,
            repeats: (repeat_state ?? "off") != "off",
            contextURI: context?.type == "album" ? context?.uri : nil,
            device: device?.domain
        )
    }
}
