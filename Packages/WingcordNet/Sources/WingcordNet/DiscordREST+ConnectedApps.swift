import Foundation
import WingcordCore

// MARK: - Connections and Authorized Apps
//
// `GET /users/@me/connections` and `GET /oauth2/tokens`. Neither is on READY,
// neither is documented, and every shape below is a captured payload rather
// than a remembered one — see `ConnectedAppsDecodeTests`.

extension DiscordREST {

    // MARK: Connections

    public func connections() async throws -> [AccountConnection] {
        try await get(
            "/users/@me/connections",
            route: "users/@me/connections",
            as: [ConnectionDTO].self
        ).compactMap(\.domain)
    }

    /// "Display on profile". The route takes a `Bool` and answers with the
    /// same connection as an `Int` — captured on the same account, seconds
    /// apart, and `AccountConnection` is where the two are reconciled.
    public func setConnectionVisible(
        _ isVisible: Bool,
        type: String,
        id: String
    ) async throws -> AccountConnection {
        struct Body: Encodable { var visibility: Bool }
        return try await patchConnection(type: type, id: id, body: Body(visibility: isVisible))
    }

    /// "Display \(platform) as your status".
    public func setConnectionShowsActivity(
        _ shows: Bool,
        type: String,
        id: String
    ) async throws -> AccountConnection {
        struct Body: Encodable { var show_activity: Bool }
        return try await patchConnection(type: type, id: id, body: Body(show_activity: shows))
    }

    private func patchConnection<Body: Encodable>(
        type: String,
        id: String,
        body: Body
    ) async throws -> AccountConnection {
        let dto = try await request(
            method: "PATCH",
            path: "/users/@me/connections/\(type)/\(id)",
            route: "users/@me/connections/:type/:id",
            body: body,
            as: ConnectionDTO.self
        )
        guard let domain = dto.domain else {
            throw Failure.decoding("connection \(type)/\(id) answered with no name")
        }
        return domain
    }

    public func removeConnection(type: String, id: String) async throws {
        _ = try await requestData(
            method: "DELETE",
            path: "/users/@me/connections/\(type)/\(id)",
            route: "users/@me/connections/:type/:id",
            body: Optional<Never>.none
        )
    }

    /// Where to send somebody to link a new connection.
    ///
    /// Opened in the system browser — Discord's own redirect handles the
    /// OAuth2 dance server-side, and this client only ever sees the far side
    /// of it by re-fetching `connections()`. There is no callback this app
    /// can catch: `redirect_uri` is a `discord.com` page, not a URL scheme
    /// this app registers.
    public func connectionAuthorizeURL(type: String) async throws -> URL {
        struct Response: Decodable { var url: URL }
        return try await get(
            "/connections/\(type)/authorize",
            route: "connections/:type/authorize",
            as: Response.self
        ).url
    }

    /// Starts, or retries, verifying a personal domain.
    ///
    /// **Not the authorize-redirect flow at all.** `domain` proves ownership
    /// in-app, with a token this route hands back on every call whether or
    /// not the domain has been proven yet — captured live, against a domain
    /// the account did not own: `POST` answered `400` with
    /// `{"code":50187,"message":"Unable to validate domain.","proof":"dh=…"}`,
    /// a shape `requestData`'s own error path would have thrown away.
    ///
    /// The body is read for a `proof` regardless of status, because that is
    /// the one field this call exists to return. **The verified shape has
    /// never been captured** — the reference client's own retry button
    /// answered the same "not yet" error against a domain that still is not
    /// owned — so a 2xx with no `proof` is read as verified without decoding
    /// it further; the caller re-fetches `connections()` to see the row.
    public func startDomainConnection(_ domain: String) async throws -> DomainConnectionOutcome {
        struct Body: Encodable {}
        struct ProofEnvelope: Decodable { var proof: String? }

        let (data, status) = try await requestRaw(
            method: "POST",
            path: "/users/@me/connections/domain/\(domain)",
            route: "users/@me/connections/domain/:id",
            body: Body()
        )
        if let proof = (try? JSONDecoder().decode(ProofEnvelope.self, from: data))?.proof {
            return .pending(proof: proof)
        }
        guard (200..<300).contains(status) else {
            throw DiscordREST.apiFailure(status: status, data: data)
        }
        return .verified
    }

    // MARK: Authorized Apps

    public func authorizedApps() async throws -> [AuthorizedApp] {
        try await get(
            "/oauth2/tokens",
            route: "oauth2/tokens",
            as: [AuthorizedAppDTO].self
        ).compactMap(\.domain)
    }

    public func deauthorizeApp(_ grantID: OAuthGrantID) async throws {
        _ = try await requestData(
            method: "DELETE",
            path: "/oauth2/tokens/\(grantID.rawValue)",
            route: "oauth2/tokens/:id",
            body: Optional<Never>.none
        )
    }
}

// MARK: - Wire types

/// `GET /users/@me/connections`'s entries, and the shape a `PATCH` answers
/// with too.
struct ConnectionDTO: Decodable, Sendable {
    var id: String?
    var type: String?
    var name: String?
    var verified: Bool?
    var show_activity: Bool?
    /// `0` or `1` on every read. The request that sets it sends a `Bool` —
    /// see `setConnectionVisible` — which is the wire's own asymmetry, not a
    /// mismatch between this file and that one.
    var visibility: Int?
    var friend_sync: Bool?
    var revoked: Bool?

    /// **`type == "contacts"` is filtered out, not decoded as some connection
    /// with no platform.** Every captured `/users/@me/connections` response
    /// carries one such entry — `id: "@me"`, `name: ""` — beside the
    /// account's real connections, and Discord's own count excludes it: a
    /// capture with two linked Spotify accounts reported "2 connections"
    /// against a three-entry array. It is phone-contact sync, not a platform
    /// this pane manages.
    var domain: AccountConnection? {
        guard let id, let type, type != "contacts", let name else { return nil }
        return AccountConnection(
            id: id,
            type: type,
            name: name,
            isVerified: verified ?? false,
            showsActivity: show_activity ?? false,
            isVisibleOnProfile: (visibility ?? 0) != 0,
            isFriendSyncEnabled: friend_sync ?? false,
            isRevoked: revoked ?? false
        )
    }
}

/// `GET /oauth2/tokens`'s entries — one OAuth2 grant, and the application it
/// named.
struct AuthorizedAppDTO: Decodable, Sendable {
    var id: OAuthGrantID?
    var scopes: [String]?
    var application: ApplicationDTO?

    /// A narrow slice of Discord's application object — the full shape also
    /// carries a nested bot user, install params and integration config that
    /// nothing in this pane reads.
    struct ApplicationDTO: Decodable, Sendable {
        var id: ApplicationID?
        var name: String?
        var icon: String?
        var description: String?
        var is_verified: Bool?
        var terms_of_service_url: URL?
        var privacy_policy_url: URL?
    }

    var domain: AuthorizedApp? {
        guard let id, let application,
              let applicationID = application.id,
              let name = application.name, !name.isEmpty
        else { return nil }
        return AuthorizedApp(
            id: id,
            applicationID: applicationID,
            name: name,
            iconHash: application.icon,
            description: application.description ?? "",
            isVerified: application.is_verified ?? false,
            scopes: scopes ?? [],
            termsOfServiceURL: application.terms_of_service_url,
            privacyPolicyURL: application.privacy_policy_url
        )
    }
}
