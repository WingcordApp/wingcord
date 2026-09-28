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
    ///     `game profile` from an announcement, `Guild Discovery` from the
    ///     discovery grid — both captured, and the two are spelled differently
    ///     because Discord spells them differently.
    ///   - source: the `x-context-properties` source, one level finer than
    ///     `location`. Sent because it was captured; nothing depends on it, and
    ///     **discovery sends an empty object** rather than a source at all,
    ///     which is why this is optional rather than defaulted to something
    ///     plausible.
    ///   - recommendationLoadID: the id of the discovery load a card was clicked
    ///     from, so Discord can tie the lurk back to the grid that offered it.
    ///     Captured on every discovery lurk and on no other; nil elsewhere.
    public func lurkGuild(
        _ guildID: GuildID,
        sessionID: String,
        location: String?,
        source: String?,
        recommendationLoadID: String? = nil
    ) async throws -> Guild? {
        struct Empty: Encodable {}
        var query = [
            URLQueryItem(name: "lurker", value: "true"),
            URLQueryItem(name: "session_id", value: sessionID),
        ]
        if let recommendationLoadID {
            // Before `location`, which is the capture's own order.
            query.append(URLQueryItem(name: "recommendation_load_id", value: recommendationLoadID))
        }
        // None at all from a server tag's card, which is the capture.
        if let location { query.append(URLQueryItem(name: "location", value: location)) }

        let dto = try await request(
            method: "PUT",
            path: "/guilds/\(guildID.rawValue)/members/@me",
            route: "guilds/{id}/members/@me",
            query: query,
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
    ///
    /// **The captured join sends NO `location` at all** — only the context
    /// source, `Notice - Lurker Mode`, which is the banner the button is on.
    /// `join discoverable server.har`, twice. So `location` is optional here
    /// rather than required, and passing one where the capture sends none would
    /// be inventing a field.
    ///
    /// **It is also the request that raises the captcha.** Discord answered this
    /// exact call with an hCaptcha challenge for a client it does not recognise,
    /// in the same shape `POST /invites/{code}` does — so the solver already in
    /// the tree is what carries it, and no route here has to know that.
    public func joinGuild(
        _ guildID: GuildID,
        location: String? = nil,
        source: String? = nil
    ) async throws -> Guild? {
        struct Empty: Encodable {}
        let data = try await requestData(
            method: "PUT",
            path: "/guilds/\(guildID.rawValue)/members/@me",
            route: "guilds/{id}/members/@me",
            query: location.map { [URLQueryItem(name: "location", value: $0)] } ?? [],
            body: Empty(),
            headers: Self.contextProperties(source: source ?? location)
        )
        guard !data.isEmpty else { return nil }
        return try? Self.decoder.decode(GuildDTO.self, from: data).domain
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
    /// that knows it — discovery sends a different one from the same route.
    ///
    /// **Nil is a real value and it is not the same as omitting the header.**
    /// The captured discovery lurk sends `{}` — an empty object, base64'd — and
    /// the header is present. Dropping it entirely is a third thing nothing was
    /// observed doing.
    static func contextProperties(source: String?) -> [String: String] {
        struct Properties: Encodable { var source: String? }
        guard let json = try? JSONEncoder().encode(Properties(source: source)) else { return [:] }
        return ["x-context-properties": json.base64EncodedString()]
    }
}

// MARK: - Applications the reader has out

extension DiscordREST {

    /// Every server the reader has applied to and not yet heard back from.
    ///
    /// `GET /users/@me/join-request-guilds` — captured, and the answer is a
    /// **bare array of partial guilds**: id, name, icon, description, the two
    /// splashes and the feature list, with no request object beside them. So
    /// it says *which* servers are outstanding and nothing about when or why;
    /// the request itself is `GET /guilds/{id}/member-verification`.
    ///
    /// This is what puts a server back in front of the reader after a relaunch.
    /// Without it a submitted application is invisible until they happen to
    /// open the invite again.
    public func joinRequestGuilds() async throws -> [JoinRequestGuild] {
        struct DTO: Decodable {
            var id: GuildID
            var name: String?
            var icon: String?
            var description: String?
        }
        return try await get(
            "/users/@me/join-request-guilds",
            route: "users/@me/join-request-guilds",
            as: [DTO].self
        ).map {
            JoinRequestGuild(
                id: $0.id,
                name: $0.name ?? "Unknown",
                iconHash: $0.icon,
                description: $0.description.flatMap { $0.isEmpty ? nil : $0 }
            )
        }
    }

    /// Takes an application back.
    ///
    /// `DELETE /guilds/{id}/requests/@me` — captured, answers **204 with no
    /// body**, so there is nothing to read and success is the absence of a
    /// throw. It is the same path the submit `PUT`s to.
    public func withdrawJoinRequest(inGuild guildID: GuildID) async throws {
        _ = try await requestData(
            method: "DELETE",
            path: "/guilds/\(guildID.rawValue)/requests/@me",
            route: "guilds/{id}/requests/@me",
            body: Optional<String>.none
        )
    }
}
