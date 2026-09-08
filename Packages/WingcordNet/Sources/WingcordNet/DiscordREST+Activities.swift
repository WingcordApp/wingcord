import Foundation
import WingcordCore

// MARK: - Activities
//
// The launcher's directory, the launch itself, and the OAuth2 grant an activity
// asks for once it is running.
//
// **None of these routes is documented.** Every shape below is decoded from
// `activities123.har` / `activities_search.har` (2026-09-02), whose thirty
// Discord requests carry complete response bodies; `ActivityDecodeTests`
// replays them against these decoders. Where `docs.discord.food` describes the
// same thing it agrees, but the capture is what these were written from.

extension DiscordREST {

    // MARK: The directory

    /// Every activity Discord will offer, with its embedded config and its
    /// artwork.
    ///
    /// **The shelf's `assets` map is why this route is worth calling at all.**
    /// The collections route below returns richer *rows* but no assets, and
    /// the artwork a featured tile draws — `embedded_cover` — exists only
    /// here. Merging the two is `ActivityDirectory`'s whole job.
    public func activityShelf() async throws -> [ApplicationID: ActivityApp] {
        let shelf = try await get("/activities/shelf", route: "activities/shelf", as: ShelfDTO.self)
        let assets = shelf.assets ?? [:]
        return Dictionary(
            (shelf.applications ?? []).compactMap { dto -> (ApplicationID, ActivityApp)? in
                guard var app = dto.domain else { return nil }
                app.tileAssetID = ShelfDTO.tileAsset(in: assets[app.id.description])
                return (app.id, app)
            },
            // A shelf that listed one app twice would be Discord's bug, not a
            // reason to crash: keep the first, which is the higher-ranked row.
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The launcher's titled rows.
    ///
    /// The query is the reference client's own, verbatim. `surface=2` is the
    /// in-chat launcher (a different surface answers with different rows),
    /// `platform=4` is desktop, and `active_state=1` drops the rows Discord has
    /// retired. Sorted here rather than at the call site because the route
    /// answers in an order that is not `position` and never was.
    public func activityCollections(locale: String) async throws -> [ActivityCollection] {
        try await get(
            "/application-directory-static/collections",
            route: "application-directory-static/collections",
            query: [
                URLQueryItem(name: "surface", value: "2"),
                URLQueryItem(name: "active_state", value: "1"),
                URLQueryItem(name: "platform", value: "4"),
                URLQueryItem(name: "locale", value: locale),
                URLQueryItem(name: "cache", value: "true"),
            ],
            as: [CollectionDTO].self
        )
        .compactMap(\.domain)
        .sorted { $0.position < $1.position }
    }

    /// One app's directory page — the description, the carousel and the
    /// server count the row it was reached from does not carry.
    public func activityApp(
        _ id: ApplicationID,
        locale: String
    ) async throws -> ActivityApp {
        let dto = try await get(
            "/application-directory-static/applications/\(id.rawValue)",
            route: "application-directory-static/applications/:id",
            query: [URLQueryItem(name: "locale", value: locale)],
            as: DirectoryApplicationDTO.self
        )
        guard let app = dto.domain else {
            throw Failure.decoding("application \(id) answered with no name")
        }
        return app
    }

    /// The launcher's search field.
    ///
    /// Seven results a page against a `result_count` in the hundreds, so the
    /// page number matters. The five filter flags are the reference client's:
    /// they are what keeps the list to apps that can actually be *used* from a
    /// message box — installed-command apps, no custom install URL, and
    /// embedded apps only when they have an entry point to launch.
    public func searchActivities(
        query: String,
        page: Int = 1,
        locale: String
    ) async throws -> ActivitySearchPage {
        let dto = try await get(
            "/application-directory-static/search",
            route: "application-directory-static/search",
            query: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "locale", value: locale),
                URLQueryItem(name: "integration_type", value: "1"),
                URLQueryItem(name: "min_user_install_command_count", value: "1"),
                URLQueryItem(name: "exclude_apps_with_custom_install_url", value: "true"),
                URLQueryItem(name: "exclude_non_embedded_apps", value: "false"),
                URLQueryItem(
                    name: "exclude_embedded_apps_without_primary_entry_point_app_command",
                    value: "true"
                ),
                URLQueryItem(name: "source", value: "1"),
            ],
            as: SearchDTO.self
        )
        return ActivitySearchPage(
            apps: (dto.results ?? []).compactMap { $0.data?.domain },
            page: page,
            pageCount: dto.num_pages ?? 1,
            totalCount: dto.result_count ?? 0
        )
    }

    /// Apps Discord thinks play like this one.
    ///
    /// **The same shape one app's own page answers with** — full application
    /// objects with `directory_entry` beside them — so it decodes through
    /// `DirectoryApplicationDTO` rather than through a second reader. Captured in
    /// `wordle.har`: each hit carries its own `guild_count`, which is what the
    /// row under it says.
    public func similarApps(to id: ApplicationID, locale: String) async throws -> [ActivityApp] {
        struct Reply: Decodable, Sendable { var applications: [DirectoryApplicationDTO]? }
        return try await get(
            "/application-directory-static/applications/\(id.rawValue)/similar",
            route: "application-directory-static/applications/{id}/similar",
            query: [URLQueryItem(name: "locale", value: locale)],
            as: Reply.self
        )
        .applications?.compactMap(\.domain) ?? []
    }

    /// Resolve applications this client knows only by id — what the Recents
    /// row is built from, since frecency stores ids and nothing else.
    ///
    /// **Batched, because the reference client batches.** One captured call
    /// asks for seventy-two ids at once as repeated `application_ids` items;
    /// seventy-two calls would be seventy-two rate-limit slots for one row.
    public func publicApplications(ids: [ApplicationID]) async throws -> [ActivityApp] {
        guard !ids.isEmpty else { return [] }
        return try await get(
            "/applications/public",
            route: "applications/public",
            query: ids.map { URLQueryItem(name: "application_ids", value: $0.description) },
            as: [ApplicationDTO].self
        )
        .compactMap(\.domain)
    }

    /// The Recents row, most-used first.
    ///
    /// **Not a route that answers "recent apps".** There is none. Discord keeps
    /// a frecency table in a second settings protobuf and the client resolves
    /// its keys itself — which is why this returns ids and `publicApplications`
    /// exists to turn them into rows.
    ///
    /// **The ordering is the one thing here that is not confirmed.** Sorted by
    /// Discord's stored `score`, then by most recent use. Neither field on its
    /// own reproduces the order the reference client drew in the capture's own
    /// screenshot, which suggests it recomputes a decayed score at read time
    /// rather than trusting the stored one. The row is right; the order within
    /// it may not be. See `HANDOFF.md`.
    public func applicationFrecency() async throws -> [ApplicationID] {
        FrecencyProto.applications(base64: try await frecencySettings())
            .filter { $0.totalUses > 0 }
            .sorted(by: FrecencyProto.mostUsedFirst)
            .map(\.key)
    }

    /// The account's own command usage, most-used first — the "Frequently Used"
    /// section of the `/` list.
    ///
    /// **Read, never written.** Discord's client writes this table back after
    /// every invocation, and a client that wanted to do the same would have to
    /// re-encode a 27 KB protobuf it can only read eight fields of — where a
    /// field it dropped is somebody's favourite GIFs or their emoji frecency,
    /// silently deleted. So the server's table is the floor and this session's
    /// own uses are layered over it in memory. See `CommandCatalog`.
    ///
    /// The blob is the same one `applicationFrecency` reads. Both are on the
    /// `settings-proto/:type` route budget, and asking for it twice within a
    /// session fetches it twice — which is why the launcher and the command
    /// list each call this once, at the moment their surface first opens.
    public func commandFrecency() async throws -> [String] {
        FrecencyProto.commands(base64: try await frecencySettings())
            .filter { $0.totalUses > 0 }
            .sorted(by: FrecencyProto.mostUsedFirst)
            .map(\.key)
    }

    /// Every server and channel the account goes to, and how much.
    ///
    /// **This is what orders the quick switcher, and there is no route that
    /// answers it directly.** Discord keeps it in the same settings protobuf as
    /// the two tables above — field 12, keyed by a guild *or* a channel
    /// snowflake — and its own client resolves the keys against tables it
    /// already holds. So does this one: the answer is a bare id-to-score map and
    /// nothing here knows or cares which ids are servers.
    ///
    /// Keyed by the raw snowflake rather than by a typed id, because the table
    /// mixes two id spaces and typing it either way would be a lie at half the
    /// call sites. The caller looks each key up in the channel index and in the
    /// guild table; one that answers to neither is a place the account has left.
    public func navigationFrecency() async throws -> [UInt64: PlaceFrecency] {
        let entries = FrecencyProto.guildsAndChannels(base64: try await frecencySettings())
        var table: [UInt64: PlaceFrecency] = [:]
        table.reserveCapacity(entries.count)
        for entry in entries {
            table[entry.key] = PlaceFrecency(score: entry.score, lastUsedAt: entry.lastUsedAt)
        }
        return table
    }

    /// The account's starred GIFs, in the order it arranged them.
    ///
    /// The same blob the two frecency tables come from, so an account that has
    /// already opened the apps flyout pays nothing for this.
    public func favoriteGIFs() async throws -> [GIF] {
        FrecencyProto.favoriteGIFs(base64: try await frecencySettings())
    }

    /// Stars or un-stars a GIF, and answers with the account's new list.
    ///
    /// **The whole `favorite_gifs` field goes, every time, and nothing else
    /// does.** Captured in `gif favorite unfavorite.har`: Discord's own client
    /// sends a partial message on this route — the unfavourite carried a
    /// *smaller* map than the favourite that followed it, which a merge cannot
    /// express, and neither request carried the frecency tables that live beside
    /// it. So the field is replaced and the rest of the message survives
    /// untouched.
    ///
    /// The entries that are staying are re-emitted as **the bytes they arrived
    /// as**, so a field this client cannot read is not a field it can delete —
    /// see `FrecencyProto.favoriteGIFEntries`.
    ///
    /// - Returns: The favourites as they now stand, newest first, so the caller
    ///   never has to guess what the server ended up with.
    @discardableResult
    public func setFavorite(_ gif: GIF, favorite: Bool) async throws -> [GIF] {
        let blob = try await frecencySettings()
        var entries = FrecencyProto.favoriteGIFEntries(base64: blob)
        let key = gif.url.absoluteString
        entries.removeAll { $0.key == key }
        if favorite {
            // One past the highest, which is what puts it at the front of the
            // grid — the counter is an insertion order and the reader sorts on
            // it descending.
            let next = (entries.map(\.order).max() ?? 0) + 1
            entries.append(FrecencyProto.favoriteEntry(for: gif, order: next))
        }

        struct Body: Encodable { var settings: String }
        _ = try await requestData(
            method: "PATCH",
            path: "/users/@me/settings-proto/2",
            route: "users/@me/settings-proto/:type",
            body: Body(settings: FrecencyProto.encodeFavoriteGIFs(entries))
        )
        return FrecencyProto.favoriteGIFs(
            base64: FrecencyProto.encodeFavoriteGIFs(entries)
        )
    }

    private func frecencySettings() async throws -> String {
        struct Response: Decodable { var settings: String? }
        return try await get(
            "/users/@me/settings-proto/2",
            route: "users/@me/settings-proto/:type",
            as: Response.self
        ).settings ?? ""
    }

    // MARK: Launching

    /// The command that launches an app, if it has one.
    ///
    /// An activity is launched by *invoking a command*, not by a launch route.
    /// The command is `type: 4` — a primary entry point — with `handler: 2`,
    /// meaning Discord itself opens the activity rather than the app answering
    /// the interaction. An app with no such command cannot be launched from a
    /// message box, which is the check the launcher's button gates on.
    public func activityEntryPoint(
        for id: ApplicationID
    ) async throws -> ActivityEntryPoint? {
        if let entry = try await commandIndex(.application(id)).entryPoint {
            return entry
        }
        // **A user-installed app's entry point may only be in the reader's own
        // index.** Wordle's `play` is in `/users/@me/application-command-index`
        // and its `integration_types` include `1` — installed to the account
        // rather than to a server. Tried second because it is 119 KB against
        // the app-scoped route's 622 bytes, and the common case is answered by
        // the small one.
        return try await commandIndex(.account).entryPoint(for: id)
    }

    /// Launch. Creates the instance and posts the invitation into the channel.
    ///
    /// **`session_id` is the gateway's, and it is not optional.** The launch is
    /// an interaction, and an interaction names the session that will receive
    /// its response; a client that sends a stale one gets no activity and no
    /// error worth the name.
    ///
    /// The response is `204` with an empty body. What the launch produced
    /// arrives over the socket as the invitation message, and the instance it
    /// created is named by the interaction's own id — which is why
    /// `ActivityInstanceID` can be built without waiting for a dispatch.
    public func launchActivity(
        _ entryPoint: ActivityEntryPoint,
        channelID: ChannelID,
        sessionID: String,
        nonce: String,
        analyticsSection: String?
    ) async throws {
        _ = try await requestData(
            method: "POST",
            path: "/interactions",
            route: "interactions",
            body: LaunchInteraction(entryPoint, channelID: channelID, sessionID: sessionID,
                                    nonce: nonce, section: analyticsSection)
        )
    }

    /// The ticket the activity's frame is handed in its query string.
    ///
    /// Fetched *before* the launch in the capture. The app reads it to prove to
    /// its own backend that the frame was opened by a real client in a real
    /// channel; this client never inspects it, it only forwards it.
    public func activityProxyTicket(
        application: ApplicationID,
        channelID: ChannelID
    ) async throws -> String {
        struct Body: Encodable { var channel_id: String }
        struct Response: Decodable { var ticket: String }
        return try await post(
            "/applications/\(application.rawValue)/proxy-tickets",
            route: "applications/:id/proxy-tickets",
            body: Body(channel_id: channelID.description),
            as: Response.self
        ).ticket
    }

    /// Leave a running instance.
    ///
    /// The path splits `ActivityInstanceID` back into the two halves it is
    /// spelled from — `pc-{channel}` as one segment, the instance number as
    /// another — which is the capture's own shape and the reason
    /// `ActivityInstanceID` keeps them apart rather than storing one string.
    public func leaveActivity(
        _ instance: ActivityInstanceID,
        application: ApplicationID,
        sessionID: String
    ) async throws {
        struct Body: Encodable { var session_id: String }
        _ = try await requestData(
            method: "POST",
            path: "/applications/\(application.rawValue)/activities/"
                + "\(instance.location.rawValue)/instances/\(instance.instance)/leave",
            route: "applications/:id/activities/:location/instances/:instance/leave",
            body: Body(session_id: sessionID)
        )
    }

    // MARK: The grant an activity asks for

    /// What to show somebody before they let an activity into their account.
    ///
    /// Called when the running frame asks to authorize, not when Launch is
    /// pressed — the capture's order is launch, frame, *then* this. `authorized`
    /// says whether the grant already exists, and a client that ignores it puts
    /// a consent sheet in front of somebody who consented last week.
    public func activityAuthorization(
        application: ApplicationID,
        scopes: [String],
        state: String
    ) async throws -> ActivityAuthorization {
        let dto = try await get(
            "/oauth2/authorize",
            route: "oauth2/authorize",
            query: authorizeQuery(application: application, scopes: scopes, state: state)
                + [URLQueryItem(name: "integration_type", value: "1")],
            as: AuthorizationDTO.self
        )
        guard let application = dto.application, let id = application.id,
              let name = application.name
        else { throw Failure.decoding("oauth2/authorize answered with no application") }
        return ActivityAuthorization(
            applicationID: id,
            name: name,
            iconHash: application.icon,
            isVerified: application.is_verified ?? false,
            scopes: scopes,
            isAlreadyAuthorized: dto.authorized ?? false,
            termsOfServiceURL: application.terms_of_service_url,
            privacyPolicyURL: application.privacy_policy_url
        )
    }

    /// Grant it. Answers the redirect the frame is waiting for.
    ///
    /// **The interesting field is `location_context`, and its `guild_id` is a
    /// lie the wire tells on purpose.** A DM launch sends `"10000"` — not a
    /// guild that exists, and not the channel's own id — beside the real
    /// channel id and `channel_type: 1`. Captured verbatim; a client that
    /// sends the true absence of a guild here is sending something the
    /// reference client never sends.
    ///
    /// The response is `{"location": "…?code=…&state=…"}` and only the `code`
    /// matters — the redirect host is the app's own and this client never
    /// visits it. It hands the code back to the frame instead.
    public func authorizeActivity(
        application: ApplicationID,
        scopes: [String],
        state: String,
        channelID: ChannelID,
        guildID: GuildID?,
        channelKind: Int
    ) async throws -> String {
        struct LocationContext: Encodable {
            var guild_id: String
            var channel_id: String
            var channel_type: Int
        }
        struct Body: Encodable {
            var permissions: String
            var authorize: Bool
            var integration_type: Int
            var location_context: LocationContext
        }
        struct Response: Decodable { var location: String }

        let response = try await request(
            method: "POST",
            path: "/oauth2/authorize",
            route: "oauth2/authorize",
            query: authorizeQuery(application: application, scopes: scopes, state: state),
            body: Body(
                permissions: "0",
                authorize: true,
                integration_type: 1,
                location_context: LocationContext(
                    guild_id: guildID?.description ?? Self.dmLocationGuildID,
                    channel_id: channelID.description,
                    channel_type: channelKind
                )
            ),
            as: Response.self
        )
        guard let code = URLComponents(string: response.location)?
            .queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty
        else { throw Failure.decoding("authorize answered with no code") }
        return code
    }

    /// What this app must be told about before it runs — age gates and the
    /// like.
    ///
    /// Both captured calls are empty (`all_acked: true`), so the *contents* of
    /// a disclosure have never been seen. The ids are carried through as
    /// opaque strings and acked unchanged rather than decoded into a shape
    /// nothing has confirmed; a disclosure that needs a sentence in front of
    /// somebody will need a second capture before it gets one.
    public func applicationDisclosures(_ id: ApplicationID) async throws -> [String] {
        struct Response: Decodable {
            var disclosures: [String]?
            var all_acked: Bool?
        }
        let response = try await get(
            "/applications/\(id.rawValue)/disclosures",
            route: "applications/:id/disclosures",
            as: Response.self
        )
        return (response.all_acked ?? false) ? [] : (response.disclosures ?? [])
    }

    public func acknowledgeDisclosures(_ disclosures: [String], for id: ApplicationID) async throws {
        struct Body: Encodable { var disclosures: [String] }
        _ = try await requestData(
            method: "POST",
            path: "/applications/\(id.rawValue)/disclosures",
            route: "applications/:id/disclosures",
            body: Body(disclosures: disclosures)
        )
    }

    // MARK: Shared

    /// The `guild_id` a DM launch claims. See `authorizeActivity`.
    static let dmLocationGuildID = "10000"
    /// The same sentinel in the field that holds a channel *type*, for an
    /// install made from a page with no channel behind it at all. Captured in
    /// `OwO bot.har`; nothing else in this app sends it.
    static let noChannelKind = 10_000

    private func authorizeQuery(
        application: ApplicationID,
        scopes: [String],
        state: String
    ) -> [URLQueryItem] {
        [
            URLQueryItem(name: "client_id", value: application.description),
            URLQueryItem(name: "response_type", value: "code"),
            // Space-separated, and `URLQueryItem` percent-encodes it. The
            // capture's `%20` separators are that, not a different delimiter.
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
        ]
    }
}

// MARK: - Wire types

/// `GET /activities/shelf`.
struct ShelfDTO: Decodable, Sendable {
    var applications: [ApplicationDTO]?
    /// Application id → its registered assets. Keyed by the id as a *string*,
    /// which is why the lookup above goes through `description`.
    var assets: [String: [AssetDTO]]?

    struct AssetDTO: Decodable, Sendable {
        var id: String?
        /// `1` on all 249 assets in the capture — an image. Anything else has
        /// never been seen, so anything else is skipped rather than guessed at.
        var type: Int?
        var name: String?
    }

    /// The featured tile's artwork: the `embedded_cover` asset, highest id
    /// first. See `ActivityApp.tileAssetID` for why both of those matter.
    static func tileAsset(in assets: [AssetDTO]?) -> String? {
        assets?
            .filter { $0.name == "embedded_cover" && $0.type == 1 }
            .compactMap(\.id)
            .max { lhs, rhs in
                // Snowflakes, so numeric order — and they are the same length
                // in practice, but a string compare would still be wrong the
                // day one of them is shorter.
                (UInt64(lhs) ?? 0) < (UInt64(rhs) ?? 0)
            }
    }
}

/// One row of `GET /application-directory-static/collections`.
struct CollectionDTO: Decodable, Sendable {
    var id: String?
    var title: String?
    var position: Int?
    var type: Int?
    var application_directory_collection_items: [ItemDTO]?

    struct ItemDTO: Decodable, Sendable {
        var position: Int?
        var application: DirectoryApplicationDTO?
    }

    var domain: ActivityCollection? {
        guard let id, let title, !title.isEmpty else { return nil }
        let apps = (application_directory_collection_items ?? [])
            .sorted { ($0.position ?? 0) < ($1.position ?? 0) }
            .compactMap { $0.application?.domain }
        guard !apps.isEmpty else { return nil }
        return ActivityCollection(
            id: id,
            title: title,
            position: position ?? .max,
            kind: type ?? 4,
            apps: apps
        )
    }
}

/// An application as the plain routes answer with one — `/applications/public`,
/// the shelf, and the nested object inside a search result.
struct ApplicationDTO: Decodable, Sendable {
    var id: ApplicationID?
    var name: String?
    var icon: String?
    var cover_image: String?
    var description: String?
    var summary: String?
    var is_verified: Bool?
    var tags: [String]?
    var max_participants: Int?
    var terms_of_service_url: URL?
    var privacy_policy_url: URL?
    var embedded_activity_config: EmbeddedConfigDTO?
    /// The application's bot account. **Only its banner is wanted**, which is
    /// the picture a directory card draws — see `ActivityApp.botBannerHash`.
    var bot: BotDTO?
    /// The directory's own headings for this app. See `categoryNames`.
    var categories: [CategoryDTO]?
    /// The application's own flags. **Where the privileged gateway intents
    /// live**, and therefore what the Data Access section is drawn from — see
    /// `AppDataAccess`.
    var flags: UInt64?
    var is_monetized: Bool?
    /// What the app asks for on a server install. Its `permissions` is the
    /// Required Permissions list; `.fmbot`'s `275415092288` is the eight its
    /// page names, checked bit by bit.
    var install_params: InstallParamsDTO?
    /// The app's support server, whole. No second fetch is needed for the card.
    var guild: SupportGuildDTO?

    struct CategoryDTO: Decodable, Sendable {
        var id: Int?
        var name: String?
    }

    struct InstallParamsDTO: Decodable, Sendable {
        /// A decimal **string**, as every permission bitfield on this wire is —
        /// it does not fit a JSON number.
        var permissions: String?
    }

    struct SupportGuildDTO: Decodable, Sendable {
        var id: GuildID?
        var name: String?
        var icon: String?
        var description: String?
        var home_header: String?
        var splash: String?
        var discovery_splash: String?
        var approximate_member_count: Int?
        var approximate_presence_count: Int?

        var domain: AppSupportGuild? {
            guard let id, let name, !name.isEmpty else { return nil }
            return AppSupportGuild(
                id: id,
                name: name,
                iconHash: icon,
                description: (description?.isEmpty ?? true) ? nil : description,
                headerHash: home_header,
                splashHash: splash,
                discoverySplashHash: discovery_splash,
                memberCount: approximate_member_count ?? 0,
                onlineCount: approximate_presence_count ?? 0
            )
        }
    }

    struct BotDTO: Decodable, Sendable {
        var banner: String?
        /// Discord sends both and they mean the same thing here: an integer
        /// RGB. `banner_color` is what a profile sets explicitly and
        /// `accent_color` is what it derives; both are null on most bots.
        var banner_color: Int?
        var accent_color: Int?
    }

    struct EmbeddedConfigDTO: Decodable, Sendable {
        var activity_preview_video_asset_id: String?
        var supported_platforms: [String]?
        var shelf_rank: Int?
        var requires_age_gate: Bool?
        var has_csp_exception: Bool?
        var displays_advertisements: Bool?

        var domain: EmbeddedActivityConfig {
            EmbeddedActivityConfig(
                previewVideoAssetID: activity_preview_video_asset_id,
                supportedPlatforms: supported_platforms ?? [],
                shelfRank: shelf_rank,
                requiresAgeGate: requires_age_gate ?? false,
                hasCSPException: has_csp_exception ?? false,
                displaysAdvertisements: displays_advertisements ?? false
            )
        }
    }

    var domain: ActivityApp? {
        guard let id, let name, !name.isEmpty else { return nil }
        return ActivityApp(
            id: id,
            name: name,
            iconHash: icon,
            coverHash: cover_image,
            botBannerHash: bot?.banner,
            botAccentColor: bot?.banner_color ?? bot?.accent_color,
            categoryNames: (categories ?? []).compactMap(\.name).filter { !$0.isEmpty },
            installPermissions: install_params?.permissions
                .flatMap(UInt64.init).map(Permissions.init(rawValue:)),
            flags: flags ?? 0,
            isMonetized: is_monetized ?? false,
            supportGuild: guild?.domain,
            summary: summary ?? "",
            isVerified: is_verified ?? false,
            about: description ?? "",
            tags: tags ?? [],
            maxParticipants: max_participants,
            termsOfServiceURL: terms_of_service_url,
            privacyPolicyURL: privacy_policy_url,
            config: embedded_activity_config?.domain
        )
    }
}

/// The same application with the directory's own additions hung off it.
struct DirectoryApplicationDTO: Decodable, Sendable {
    var application: ApplicationDTO
    var directory_entry: EntryDTO?

    struct EntryDTO: Decodable, Sendable {
        var short_description: String?
        var guild_count: Int?
        var carousel_items: [CarouselItemDTO]?
        /// The developer's own links — `[{"name":"FAQ","url":"…"}]`. Captured in
        /// `blazing 8s.har`; absent on an app that declares none, which is most.
        var external_urls: [ExternalURLDTO]?
        /// BCP-47 tags. `["en-US"]` on all three captured apps.
        var supported_locales: [String]?
        /// The developer's long-form Markdown. See `ActivityApp.detailedDescription`.
        var detailed_description: String?
        /// **The five Discord lists under "Popular Slash Commands"**, whole
        /// command records in the route's own order. Decoded and thrown away
        /// for two releases: the ids beside them were read and the commands
        /// were not.
        var popular_application_commands: [CommandIndexDTO.CommandDTO]?

        struct ExternalURLDTO: Decodable, Sendable {
            var name: String?
            var url: URL?

            var domain: ExternalLink? {
                // A developer-supplied address, so the scheme is checked here
                // rather than trusted — §5.5, the same rule the transcript's own
                // links are held to.
                guard let name, !name.isEmpty, let url, url.scheme == "https" else { return nil }
                return ExternalLink(name: name, url: url)
            }
        }

        struct CarouselItemDTO: Decodable, Sendable {
            /// `1` is a picture, `2` a YouTube embed. Only pictures are usable
            /// here — a `2` is an `embed` URL that needs a browser, so the
            /// carousel is filtered rather than showing an item that cannot
            /// draw.
            var type: Int?
            var url: URL?
            /// Discord's own re-host of `url`. Preferred so the request goes
            /// to a host this client already talks to, rather than to
            /// `app-directory-assets.discordactivities.com`.
            var proxy_url: URL?
        }

        /// Every picture in the strip, in the developer's order.
        ///
        /// **Type 1 only.** A `2` is a YouTube embed URL that needs a browser,
        /// so it is filtered rather than drawn as a picture that cannot load.
        var gallery: [URL] {
            (carousel_items ?? [])
                .filter { $0.type == 1 }
                .compactMap { $0.proxy_url ?? $0.url }
        }

        var heroImageURL: URL? { gallery.first }
    }

    /// The application object is inline rather than nested — the directory
    /// routes spell an application's own fields at the top level and hang
    /// `directory_entry` beside them.
    init(from decoder: any Decoder) throws {
        application = try ApplicationDTO(from: decoder)
        directory_entry = try? EntryDTO(from: decoder.container(
            keyedBy: Key.self
        ).superDecoder(forKey: .directory_entry))
    }

    private enum Key: String, CodingKey { case directory_entry }

    var domain: ActivityApp? {
        guard var app = application.domain else { return nil }
        app.tagline = directory_entry?.short_description
        app.guildCount = directory_entry?.guild_count
        app.heroImageURL = directory_entry?.heroImageURL
        app.gallery = directory_entry?.gallery ?? []
        app.externalLinks = (directory_entry?.external_urls ?? []).compactMap(\.domain)
        app.supportedLocales = directory_entry?.supported_locales ?? []
        app.detailedDescription = directory_entry?.detailed_description
        app.popularCommands =
            (directory_entry?.popular_application_commands ?? []).compactMap(\.domain)
        return app
    }
}

/// `GET /application-directory-static/search`.
struct SearchDTO: Decodable, Sendable {
    var results: [ResultDTO]?
    var num_pages: Int?
    var result_count: Int?

    struct ResultDTO: Decodable, Sendable {
        var type: Int?
        var data: DirectoryApplicationDTO?
    }
}

/// `POST /interactions`, for a primary entry point.
///
/// **The command is echoed back inside the interaction, not merely named.**
/// `data.application_command` repeats the whole record the command index
/// answered with — id, version, contexts, handler — beside the `id`/`version`
/// pair one level up. Captured that way; sent that way, and *the index's own
/// values*: `launch activity.har` shows Wordle's `play` going out with
/// `handler: 1`, `dm_permission: true` and its real description, where this
/// client had been sending `2`, `false` and an empty string.
///
/// **The launcher and an app's own page send two different shapes**, and
/// `dank memer.har` has both of them for the same command:
///
/// ```
/// app_launcher  + section_name + source=TEXT   ← the launcher's grid
/// slash_ui      , neither key present          ← the app's own page
/// ```
///
/// The section is what tells them apart — a launch from a page comes from no
/// section — so there is no second parameter to keep in step with the first.
struct LaunchInteraction: Encodable {
    var type = 2
    var application_id: String
    var channel_id: String
    var session_id: String
    var data: Data
    var nonce: String
    /// Where in the client the launch came from. Discord's own analytics
    /// vocabulary, sent because the route is shaped around it — and because a
    /// launcher that omitted it would be the one client sending a shape nobody
    /// else sends.
    var analytics_location: String
    /// **Both absent for a launch from an app's own page.** `Encodable`
    /// synthesis omits a nil optional, which is exactly the captured shape.
    var section_name: String?
    var source: String?

    struct Data: Encodable {
        var version: String
        var id: String
        var name: String
        var type = 4
        var options: [String] = []
        var application_command: Command
        var attachments: [String] = []

        struct Command: Encodable {
            var id: String
            var type = 4
            var application_id: String
            var version: String
            var name: String
            var dm_permission: Bool
            var contexts: [Int]
            var integration_types: [Int]
            var handler: Int
            var description: String
            var options: [String] = []
            /// **Present only where there is a description**, which is the one
            /// difference between the two captured bodies: Watch Together's
            /// index record carries no `description` and its launch omits this
            /// key entirely, while Wordle's carries one and its launch sends
            /// both. Optional, so the synthesised encoding drops it.
            var description_localized: String?
            var name_localized: String
        }
    }

    init(
        _ entryPoint: ActivityEntryPoint,
        channelID: ChannelID,
        sessionID: String,
        nonce: String,
        section: String?
    ) {
        application_id = entryPoint.applicationID.description
        channel_id = channelID.description
        session_id = sessionID
        self.nonce = nonce
        section_name = section
        analytics_location = section == nil ? Self.pageLocation : Self.launcherLocation
        source = section == nil ? nil : "TEXT"
        data = Data(
            version: entryPoint.version,
            id: entryPoint.id,
            name: entryPoint.name,
            application_command: Data.Command(
                id: entryPoint.id,
                application_id: entryPoint.applicationID.description,
                version: entryPoint.version,
                name: entryPoint.name,
                dm_permission: entryPoint.dmPermission,
                contexts: entryPoint.contexts,
                integration_types: entryPoint.integrationTypes,
                // `2` where the index said nothing: it is the ordinary handler,
                // and an entry point with none is one this client never saw.
                handler: entryPoint.handler ?? 2,
                description: entryPoint.summary,
                description_localized: entryPoint.summary.isEmpty ? nil : entryPoint.summary,
                name_localized: entryPoint.name
            )
        )
    }

    /// The launcher's grid, which is the only surface that has a section.
    static let launcherLocation = "app_launcher"
    /// An app's own page. Captured, and it is not `app_launcher` — see above.
    static let pageLocation = "slash_ui"
}

/// `GET /oauth2/authorize`.
struct AuthorizationDTO: Decodable, Sendable {
    var application: ApplicationDTO?
    /// Whether this account has already granted these scopes. The capture's
    /// value is `false` — the sheet was shown — and the route exists to answer
    /// exactly this.
    var authorized: Bool?
}

// MARK: - The token an activity hands back

extension DiscordREST {
    /// Who a bearer token belongs to.
    ///
    /// **The one route here called with somebody else's credentials.** An
    /// activity authorizes, sends its code to its own backend, and the backend
    /// exchanges it for an access token — which the app then hands *back* to
    /// the client through the RPC bridge's `AUTHENTICATE`. The client's job is
    /// to say who that token is for, and this is the route that answers.
    /// Captured immediately after the authorize round trip in
    /// `activities123.har`.
    ///
    /// The user's own session token is deliberately not sent: this request is
    /// made **as the activity**, and attaching the account's token as well
    /// would be handing an app's credentials and the reader's to the same call.
    public func oauthIdentity(bearer token: String) async throws -> OAuthIdentity {
        var request = URLRequest(url: metadata.apiBase.appending(path: "/oauth2/@me"))
        request.httpMethod = "GET"
        metadata.apply(to: &request, token: "Bearer \(token)")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Self.apiFailure(status: status, data: data)
        }
        let dto = try decoder.decode(IdentityDTO.self, from: data)
        guard let user = dto.user?.domain else {
            throw Failure.decoding("oauth2/@me answered with no user")
        }
        return OAuthIdentity(
            user: user,
            scopes: dto.scopes ?? [],
            expires: dto.expires,
            application: dto.application?.domain
        )
    }

    struct IdentityDTO: Decodable, Sendable {
        var user: UserDTO?
        var scopes: [String]?
        var expires: Date?
        var application: ApplicationDTO?
    }
}

/// What `GET /oauth2/@me` answers: whose token it is, and what it may do.
public struct OAuthIdentity: Sendable {
    public var user: User
    public var scopes: [String]
    public var expires: Date?
    public var application: ActivityApp?
}
