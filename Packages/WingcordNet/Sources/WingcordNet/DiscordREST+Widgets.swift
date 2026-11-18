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
        // **The reply is wrapped the same way the request is**, and decoding it
        // as a bare array is a save that lands on Discord and then reports
        // failure — the widget is gone, the editor says it is not, and pressing
        // Save again sends the board a second time. Captured:
        // `{"widgets":[{"id":"1539974257327743066","updated_at":…,"data":{…}}]}`.
        struct Reply: Decodable, Sendable { var widgets: [ProfileWidgetDTO]? }
        return try await request(
            method: "PUT",
            path: "/users/@me/widgets",
            route: "users/@me/widgets",
            body: Body(widgets: widgets),
            as: Reply.self
        ).widgets?.compactMap(\.domain) ?? []
    }

    /// Puts one picture where a personal widget can point at it.
    ///
    /// **Two requests, and the second one is not Discord's.** `POST
    /// /users/@me/widgets/assets/upload` answers a *signed Google Cloud Storage
    /// URL* and the path to quote afterwards; the bytes then go straight to
    /// Google with a plain `PUT` and no Authorization header at all — the
    /// signature in the query string is the credential, and attaching the
    /// account token to a third party's endpoint would be sending it somewhere
    /// it does not belong. Captured, `Custom widget.har`.
    ///
    /// **The returned filename is not the one that was sent.** Discord sanitises
    /// it: `WingCord-iOS-Default-128@2x.png` came back as
    /// `WingCord-iOS-Default-1282x.png`. So the value the widget quotes is the
    /// one this answers with, and a client that rebuilt the path from the local
    /// file name would point every picture at nothing.
    ///
    /// - Returns: the `upload_filename` to put in `PersonalWidget.Asset.staged`.
    public func uploadWidgetAsset(filename: String, bytes: Data) async throws -> String {
        struct Body: Encodable, Sendable {
            var filename: String
            var file_size: Int
        }
        struct Reply: Decodable, Sendable {
            var upload_url: URL?
            var upload_filename: String?
        }
        let staged = try await post(
            "/users/@me/widgets/assets/upload",
            route: "users/@me/widgets/assets/upload",
            body: Body(filename: filename, file_size: bytes.count),
            as: Reply.self
        )
        guard let url = staged.upload_url, let name = staged.upload_filename else {
            throw Failure.decoding("upload reply carried no url")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.upload(for: request, from: bytes)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure.api(
                status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                code: nil,
                message: "The picture could not be uploaded."
            )
        }
        return name
    }

    /// Puts one clip where a clips gallery can name it.
    ///
    /// Discord's `uploadWidgetClip` (`958805`): `POST
    /// /users/@me/widgets/clips/upload {file_size}` answers a signed upload URL
    /// and the `upload_filename` to quote, and the video goes to that URL as
    /// `video/mp4` — with no Authorization header, the signature being the
    /// credential (`uploadWidgetAsset`'s rule).
    ///
    /// - Parameter progress: called with the fraction sent, on the session's
    ///   queue.
    /// - Returns: the `upload_filename` for `ProfileClip.Storage.staged`.
    public func uploadWidgetClip(
        from file: URL, progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        struct Body: Encodable, Sendable { var file_size: Int }
        struct Reply: Decodable, Sendable {
            var upload_url: URL?
            var upload_filename: String?
        }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let staged = try await post(
            "/users/@me/widgets/clips/upload",
            route: "users/@me/widgets/clips/upload",
            body: Body(file_size: size),
            as: Reply.self
        )
        guard let url = staged.upload_url, let name = staged.upload_filename else {
            throw Failure.decoding("clip upload reply carried no url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        let delegate = progress.map(UploadProgressDelegate.init(report:))
        let (_, response) = try await session.upload(for: request, fromFile: file, delegate: delegate)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure.api(
                status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                code: nil,
                message: "The clip could not be uploaded."
            )
        }
        return name
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
    /// Discord's application type — 5 is a game (`ApplicationTypes.GAME`).
    var type: Int?
    var linked_games: [LinkedGameDTO]?

    struct LinkedGameDTO: Decodable, Sendable {
        /// The **game's** application id. The nested `application` object
        /// repeats it along with the game's own icon and cover, none of which is
        /// read here — `/games` answers for all of that, and taking it from two
        /// places is two answers that can disagree.
        var id: ApplicationID?
        /// The nested application's type alone: whether this link IS a game.
        var application: Kind?
        struct Kind: Decodable, Sendable { var type: Int? }
    }

    var domain: WidgetApplication? {
        guard let id, let name else { return nil }
        return WidgetApplication(
            id: id,
            name: name,
            iconHash: icon,
            isVerified: is_verified ?? false,
            connectionEntrypointURL: connection_entrypoint_url,
            linkedGameIDs: (linked_games ?? []).compactMap(\.id),
            // **Discord's `getCanonicalGameId`**: the application itself when
            // it is a game, else the first linked application that is one —
            // not merely the first link, which for Fortnite named something
            // with no game record and no profile (Alex, 2026-11-18).
            gameID: type == 5 ? id : linked_games?.first { $0.application?.type == 5 }?.id
        )
    }
}

/// Reports an upload's progress as a fraction.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let report: @Sendable (Double) -> Void

    init(report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
