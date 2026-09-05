import Foundation
import WingcordCore

extension DiscordREST {

    // MARK: - Reading a board

    /// Somebody's linked game accounts, with the data each game publishes.
    ///
    /// **The data half of every application widget.** The profile route names
    /// which applications a board holds and nothing more; this is where the
    /// in-game name, the level and the character art come from. It answers for
    /// a person who has linked nothing with an empty array, which is the common
    /// case and not an error.
    public func applicationIdentities(of userID: UserID) async throws -> [ApplicationIdentity] {
        try await get(
            "/users/\(userID.rawValue)/application-identities",
            // Bucketed by route rather than by user: a board opened on twenty
            // people is twenty calls, and per-URL buckets would stop limiting.
            route: "users/{id}/application-identities",
            query: [URLQueryItem(name: "with_profiles", value: "true")],
            as: ApplicationIdentitiesDTO.self
        ).domain
    }

    /// One application's widget templates.
    ///
    /// The route for an application Discord has **not** featured — which is
    /// every widget somebody authored for themselves. A published config is the
    /// only one a board should draw, and a developer looking at their own
    /// application also gets their drafts here, so the caller filters.
    public func widgetConfigs(for applicationID: ApplicationID) async throws -> [WidgetConfig] {
        try await get(
            "/applications/\(applicationID.rawValue)/widget-configs",
            route: "applications/{id}/widget-configs",
            as: [WidgetConfigDTO].self
        ).compactMap(\.domain)
    }

    /// Every widget template Discord has promoted, in one call.
    ///
    /// **Fetched once a session, and it is what makes a linked game's labels
    /// appear instantly.** Discord's own client resolves Arknights' "Authority
    /// Level" without ever asking for that application's configs, because this
    /// set is already resident when the profile opens. Asking per application on
    /// demand would work and would put a visible round trip between the widget
    /// appearing and its labels appearing.
    public func featuredWidgetConfigs() async throws -> [WidgetConfig] {
        try await get(
            "/widget-configs/featured",
            route: "widget-configs/featured",
            as: FeaturedWidgetConfigsDTO.self
        ).domain
    }

    /// The applications behind a board's widgets.
    ///
    /// `/applications/public` again — the same route the activity shelf uses —
    /// but read for the two fields that route's activity view drops:
    /// `linked_games`, which is the only place a widget's game id exists, and
    /// `connection_entrypoint_url`, which is where a game sends somebody to
    /// link an account.
    public func widgetApplications(ids: [ApplicationID]) async throws -> [WidgetApplication] {
        guard !ids.isEmpty else { return [] }
        return try await get(
            "/applications/public",
            route: "applications/public",
            query: ids.map { URLQueryItem(name: "application_ids", value: $0.description) },
            as: [WidgetApplicationDTO].self
        ).compactMap(\.domain)
    }

    // MARK: - Writing a board

    /// Replaces the reader's own widgets, and answers with what stuck.
    ///
    /// **A replace, not a patch** — the array sent is the board afterwards, so
    /// an editor that omits a widget deletes it. Discord accepts at most one of
    /// each kind; `ProfileWidgetWrite` caps each list at that kind's own limit,
    /// because the route rejects an over-long one outright rather than
    /// truncating it.
    @discardableResult
    public func setProfileWidgets(_ widgets: [ProfileWidgetWrite]) async throws -> [ProfileWidget] {
        struct Body: Encodable, Sendable { var widgets: [ProfileWidgetWrite] }
        return try await request(
            method: "PUT",
            path: "/users/@me/widgets",
            route: "users/@me/widgets",
            body: Body(widgets: widgets),
            as: [ProfileWidgetDTO].self
        ).compactMap(\.domain)
    }

    /// Games Discord suggests for the reader's own board.
    public func suggestedWidgetGames() async throws -> (played: [ApplicationID], wishlist: [ApplicationID]) {
        struct Reply: Decodable, Sendable {
            var suggested_games: [ApplicationID]?
            var suggested_wishlist_games: [ApplicationID]?
        }
        let reply = try await get(
            "/users/@me/widgets/suggested-games",
            route: "users/@me/widgets/suggested-games",
            as: Reply.self
        )
        return (reply.suggested_games ?? [], reply.suggested_wishlist_games ?? [])
    }

    /// Shows or hides one linked game account on the reader's own profile.
    public func setApplicationIdentityVisible(
        _ isVisible: Bool,
        applicationID: ApplicationID,
        externalUserID: String
    ) async throws {
        struct Body: Encodable, Sendable { var connection_visible: Bool }
        _ = try await requestData(
            method: "PATCH",
            path: "/users/@me/application-identities/\(applicationID.rawValue)/\(externalUserID)/config",
            route: "users/@me/application-identities/{id}/{external}/config",
            body: Body(connection_visible: isVisible)
        )
    }
}

/// `/applications/public`, read for what a widget needs from it.
///
/// A second reader over the same route rather than more fields on
/// `ApplicationDTO`: that one describes an *embedded activity* and is decoded
/// for every tile on the shelf, and `linked_games` nests a whole second
/// application object inside itself that the shelf would then be decoding for
/// nothing.
struct WidgetApplicationDTO: Decodable, Sendable {
    var id: ApplicationID?
    var name: String?
    var icon: String?
    var is_verified: Bool?
    var connection_entrypoint_url: URL?
    var linked_games: [LinkedGameDTO]?

    struct LinkedGameDTO: Decodable, Sendable {
        /// The **game's** application id. The nested `application` object
        /// repeats it along with the game's own icon and cover, none of which is
        /// read here — `/games` answers for all of that, and taking it from two
        /// places is two answers that can disagree.
        var id: ApplicationID?
    }

    var domain: WidgetApplication? {
        guard let id, let name else { return nil }
        return WidgetApplication(
            id: id,
            name: name,
            iconHash: icon,
            isVerified: is_verified ?? false,
            connectionEntrypointURL: connection_entrypoint_url,
            linkedGameIDs: (linked_games ?? []).compactMap(\.id)
        )
    }
}
