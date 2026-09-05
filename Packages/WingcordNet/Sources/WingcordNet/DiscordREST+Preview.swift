import Foundation
import WingcordCore

// Previewing a server you are not in — "lurking", in Discord's own vocabulary.
//
// **Captured**, `me?lurker.har`, entry 20: opening a community announcement from
// a game profile fires exactly one request before the transcript is fetched:
//
// ```
// PUT /guilds/1151759657283629076/members/@me
//     ?lurker=true
//     &session_id=d205a890acf5cc157b9c8926b67d609e
//     &location=game%20profile
// x-context-properties: {"source":"Game Profile Announcements"}  (base64)
// body: {}
// → 200, the full guild object
// ```
//
// Two facts in that shape are the whole design and neither is guessable:
//
//  1. **The session id is the GATEWAY's, and it is required.** A lurk is not an
//     account state — it is a subscription attached to one socket, and it dies
//     with the socket. `docs.discord.food` says so outright: "Lurking a guild
//     allows the user to receive Gateway events for the guild without being a
//     full member *for the lifetime of the Gateway session*."
//  2. **The channels are not in the response.** The 200 carries the guild's own
//     fields — name, icon, features, roles, emoji — and no `channels` array at
//     all. They arrive a moment later as a `GUILD_CREATE` over the socket, which
//     is the same event a real join produces, so everything downstream of it is
//     already built.
//
// Lurking requires the `PREVIEW_ENABLED` guild feature, which discoverable
// guilds and guilds with member verification have by default.

extension DiscordREST {

    /// Starts previewing a guild on this gateway session.
    ///
    /// Returns the guild as the route describes it. The *contents* — channels,
    /// roles, members — arrive separately as `GUILD_CREATE`; a caller that waits
    /// on this value for a channel list will wait for ever.
    ///
    /// - Parameters:
    ///   - sessionID: the **gateway** session, not an HTTP one. Without it the
    ///     route joins the guild for real rather than lurking it.
    ///   - location: Discord's analytics field for where the click came from.
    ///   - source: the `x-context-properties` source, one level finer than
    ///     `location`. Sent because it was captured; nothing depends on it.
    public func lurkGuild(
        _ guildID: GuildID,
        sessionID: String,
        location: String,
        source: String
    ) async throws -> Guild? {
        struct Empty: Encodable {}
        let dto = try await request(
            method: "PUT",
            path: "/guilds/\(guildID.rawValue)/members/@me",
            route: "guilds/{id}/members/@me",
            query: [
                URLQueryItem(name: "lurker", value: "true"),
                URLQueryItem(name: "session_id", value: sessionID),
                URLQueryItem(name: "location", value: location),
            ],
            body: Empty(),
            headers: Self.contextProperties(source: source),
            as: GuildDTO.self
        )
        return dto.domain
    }

    /// Joins a guild for real.
    ///
    /// **The same route as the lurk, without `lurker`.** That is the whole
    /// difference, and it is why the two live together: a copy of this path that
    /// forgot to drop the flag would silently do nothing but re-lurk, and the
    /// reader would keep seeing a preview banner over a server they thought they
    /// had joined.
    ///
    /// Returns the guild for a first join, or nil where the account was already
    /// a member — the route answers 204 for that, which is not a failure.
    public func joinGuild(_ guildID: GuildID, location: String) async throws -> Guild? {
        struct Empty: Encodable {}
        let data = try await requestData(
            method: "PUT",
            path: "/guilds/\(guildID.rawValue)/members/@me",
            route: "guilds/{id}/members/@me",
            query: [URLQueryItem(name: "location", value: location)],
            body: Empty(),
            headers: Self.contextProperties(source: location)
        )
        guard !data.isEmpty else { return nil }
        return try? decoder.decode(GuildDTO.self, from: data).domain
    }

    /// Stops previewing, or leaves for real.
    ///
    /// **One route, and the body is the difference.** `DELETE
    /// /users/@me/guilds/{id}` with `{"lurking": true}` ends a preview; without
    /// it, the same call leaves a server the reader actually joined. Sending the
    /// wrong one is the difference between closing a page and losing a
    /// membership, which is why the flag is required rather than defaulted here.
    public func leaveGuild(_ guildID: GuildID, lurking: Bool) async throws {
        struct Body: Encodable { var lurking: Bool }
        _ = try await requestData(
            method: "DELETE",
            path: "/users/@me/guilds/\(guildID.rawValue)",
            route: "users/@me/guilds/{id}",
            body: Body(lurking: lurking)
        )
    }

    /// `x-context-properties`: base64 of a small JSON object.
    ///
    /// Built rather than hard-coded so the source travels with the call site
    /// that knows it — the discovery tab will send a different one from the same
    /// route.
    static func contextProperties(source: String) -> [String: String] {
        struct Properties: Encodable { var source: String }
        guard let json = try? JSONEncoder().encode(Properties(source: source)) else { return [:] }
        return ["x-context-properties": json.base64EncodedString()]
    }
}
