import Foundation
import WingcordCore
import WingcordNet

// MARK: - Activities
//
// The launcher's data, the launch itself, and leaving. Everything that touches
// the network for an activity crosses here — the store holds the result and
// never reaches for it.

extension SessionController {

    /// The directory, once per launch.
    ///
    /// **Two routes, merged, and both are needed.** The collections route
    /// carries the titled rows and their ordering but no artwork; the shelf
    /// carries the `embedded_cover` asset every featured tile draws and no
    /// grouping at all. Requested together rather than in sequence — neither
    /// depends on the other, and the launcher opens on whichever is slower.
    func loadActivityDirectory() async {
        // **Keyed on the collections, never on the app table.** That table is
        // also filled by `resolveApplications` and the Recents row, which put
        // apps in it long before a launcher opens — and a guard on "any app at
        // all" read the directory as loaded when it never was: the launcher
        // drew Recents alone and the call's shelf waited for ever.
        guard model.activityDirectory.collections.isEmpty, !isLoadingActivityDirectory else { return }
        isLoadingActivityDirectory = true
        defer { isLoadingActivityDirectory = false }
        let locale = metadata.locale

        async let shelf = try? rest.activityShelf()
        async let collections = try? rest.activityCollections(locale: locale)
        let (shelfApps, rows) = await (shelf, collections)

        guard let ranked = shelfApps, let rows, !rows.isEmpty else {
            // Nothing partial: a launcher showing four of nine collections with
            // no way to say so is worse than one that says it could not load.
            Self.trace("activities: directory unavailable")
            return
        }

        // The collections' own application objects carry the directory entry —
        // the tagline and the server count — where the shelf's carry the asset
        // map. Each row keeps its collection's copy and borrows the shelf's
        // artwork, which is the only field the collections route never sends.
        let apps = Dictionary(ranked.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // What was resolved elsewhere stays beside the shelf's own.
        var merged = model.activityDirectory.apps.merging(apps) { _, shelf in shelf }
        let enriched = rows.map { collection in
            var collection = collection
            collection.apps = collection.apps.map { app in
                var app = app
                app.tileAssetID = apps[app.id]?.tileAssetID
                if app.coverHash == nil { app.coverHash = apps[app.id]?.coverHash }
                merged[app.id] = app
                return app
            }
            return collection
        }

        model.activityDirectory = ActivityDirectory(
            collections: enriched, apps: merged, shelf: ranked.map(\.id)
        )
        model.activitySectionsCache = nil
        model.activityRevision &+= 1
    }

    /// The Recents row.
    ///
    /// Two hops, and the second is the reason this is separate from the
    /// directory load: frecency answers ids, and an id is not a row. Only the
    /// ones the shelf did not already describe are resolved — on the captured
    /// account that is a handful out of twenty-nine.
    func loadActivityRecents() async {
        guard model.activityRecents.isEmpty else { return }
        guard let ids = try? await rest.applicationFrecency(), !ids.isEmpty else { return }

        let shown = Array(ids.prefix(AppModel.recentsShown))
        let unknown = shown.filter { model.activityDirectory.apps[$0] == nil }
        if !unknown.isEmpty, let resolved = try? await rest.publicApplications(ids: unknown) {
            for app in resolved { model.activityDirectory.apps[app.id] = app }
        }

        // Anything still unresolved is dropped rather than drawn as a grey
        // square: the Recents strip is icons and nothing else, so a row with no
        // icon and no name is a gap the reader cannot act on.
        model.activityRecents = ids.filter { model.activityDirectory.apps[$0] != nil }
        model.activitySectionsCache = nil
        model.activityRevision &+= 1
    }

    /// One app's own page.
    func loadActivityApp(_ id: ApplicationID) async {
        guard model.activityDetails[id] == nil else { return }
        guard var app = try? await rest.activityApp(id, locale: metadata.locale) else { return }
        // The detail route has no asset map either, so the tile artwork stays
        // whatever the shelf already knew.
        app.tileAssetID = model.activityDirectory.apps[id]?.tileAssetID
        model.activityDetails[id] = app
        model.activityRevision &+= 1
    }

    /// The launcher's search.
    ///
    /// The caller owns the debounce — this issues the request it is given. A
    /// cancelled task drops its result rather than writing it, which is what
    /// keeps a slow page-one answer from landing on top of a newer page-two.
    func searchActivities(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            model.activitySearchResults = []
            model.activitySectionsCache = nil
            model.activityRevision &+= 1
            return
        }
        guard let page = try? await rest.searchActivities(query: trimmed, locale: metadata.locale)
        else { return }
        guard !Task.isCancelled else { return }
        model.activitySearchResults = page.apps
        model.activitySectionsCache = nil
        model.activityRevision &+= 1
    }

    /// Quantises an app's icon into the colour its invitation card is ruled
    /// with.
    ///
    /// Once per application, and only for apps that actually have a card in the
    /// transcript — so a channel with no invitations in it costs nothing. The
    /// decode goes through the ordinary image cache and the quantisation is
    /// handed off the main actor, exactly as `deriveTheme` does for a profile.
    func deriveActivityAccent(_ invite: ActivityInvite) {
        guard model.activityAccents[invite.applicationID] == nil,
              let hash = invite.iconHash,
              let url = CDN.applicationIcon(
                  id: invite.applicationID,
                  hash: hash,
                  side: CGFloat(ProfileThemePalette.applicationPixelSize),
                  scale: 1
              ),
              activityAccentFetches.insert(invite.applicationID).inserted
        else { return }

        Task { [weak self] in
            guard let self else { return }
            defer { activityAccentFetches.remove(invite.applicationID) }
            let key = ImageStore.Key(url: url, maximumPixelSize: ProfileThemePalette.applicationPixelSize)
            guard let image = await ImageStore.shared.image(for: key, bucket: .thumbnail)
            else { return }
            let palette = await Task.detached(priority: .utility) {
                ProfileThemePalette.derive(from: image)
            }.value
            guard !palette.isEmpty else { return }
            // Discord's pair: the palette's first two, each taken down until
            // white reads on it.
            let pair = InviteCardColours.pair(from: palette)
            model.activityAccents[invite.applicationID] = ActivityCardTint(
                primary: pair.primary, secondary: pair.secondary
            )
            // The row cache keys on the mention table's token, which moves with
            // this counter — without the bump a card already laid out keeps its
            // neutral ground for as long as the channel stays open.
            model.identityRevision &+= 1

            // The app's cover, where the shelf knows one — Discord's
            // `embedded_cover`, bled into the card's trailing side. After the
            // colours, so a card is never waiting on a picture to stop being
            // grey.
            guard let asset = model.activityDirectory.apps[invite.applicationID]?.tileAssetID,
                  let coverURL = CDN.applicationAsset(id: invite.applicationID, assetID: asset, side: 600),
                  let cover = await ImageStore.shared.image(
                      for: ImageStore.Key(url: coverURL, maximumPixelSize: 600), bucket: .artwork
                  )
            else { return }
            ActivityCardCovers.set(cover, for: invite.applicationID)
            model.activityAccents[invite.applicationID]?.hasCover = true
        }
    }

    /// The account's starred GIFs, once per launch.
    ///
    /// Its own latch rather than "is the array empty": an account with no
    /// favourites answers an empty list, and that is a real answer the picker
    /// would otherwise re-ask for on every open.
    func loadFavoriteGIFs() async {
        // `--demo` keeps none, and asks for none.
        guard !hasLoadedFavoriteGIFs, !LaunchOptions.current.usesDemoFixtures else { return }
        hasLoadedFavoriteGIFs = true
        do {
            model.favoriteGIFs = try await rest.favoriteGIFs()
        } catch {
            Self.trace("gifs: favorites unavailable — \(Self.describe(error))")
        }
    }

    // MARK: Launching

    /// Launch an app into a channel, and put its frame on screen.
    ///
    /// **The order here is the capture's order, and two steps of it are not
    /// obvious.** The proxy ticket is fetched *before* the interaction, and the
    /// instance is named from the interaction's own id rather than waited for
    /// — Discord dispatches the invitation message a beat later, and a client
    /// that waited for it would open the frame after the app already had.
    func launchActivity(_ app: ActivityApp, in channelID: ChannelID, section: String?) async {
        guard app.isLaunchable else {
            model.reportActionFailure("\(app.name) cannot be launched here.")
            return
        }
        guard let sessionID = await socketSessionID() else {
            model.reportActionFailure("Not connected.")
            return
        }

        do {
            guard let entryPoint = try await rest.activityEntryPoint(for: app.id) else {
                model.reportActionFailure("\(app.name) has nothing to launch.")
                return
            }
            let ticket = try await rest.activityProxyTicket(
                application: app.id,
                channelID: channelID
            )
            // **The nonce is not the instance.** Discord mints the interaction
            // id server-side and answers this route with `204` and no body, so
            // the instance has to be read off the invitation message the launch
            // produces. See `awaitActivityInstance`.
            let nonce = Self.nonce()
            // **Registered before the post, not after.** See
            // `beginActivityLaunch` — the acknowledgement outruns the request.
            let pending = beginActivityLaunch(
                application: app.id,
                channelID: channelID,
                nonce: nonce
            )
            do {
                try await rest.launchActivity(
                    entryPoint,
                    channelID: channelID,
                    sessionID: sessionID,
                    nonce: nonce,
                    analyticsSection: section
                )
            } catch {
                // The waiter outlives a failed post otherwise, and answers the
                // *next* launch's acknowledgement.
                if pendingActivityLaunch === pending { pendingActivityLaunch = nil }
                throw error
            }
            guard let instance = await awaitActivityInstance(pending) else {
                model.reportActionFailure("\(app.name) did not start.")
                return
            }
            openActivity(app, in: channelID, ticket: ticket, instance: instance)
        } catch {
            model.reportActionFailure(Self.reason(for: error, verb: "launch \(app.name)"))
        }
    }

    /// Launch into the reader's direct message with the application's own bot.
    ///
    /// **"Launch in DM" is the same launch into a different channel.** The
    /// capture proves it: two launches of Dank Memer's `GRIND XP`, byte-identical
    /// apart from the nonce and the `channel_id` — one into the conversation the
    /// page was opened over, one into `863486177982021682`, the DM with the bot.
    ///
    /// **A bot's user id is its application id**, which is what makes the DM
    /// resolvable without a directory lookup — the same identity the component
    /// press already leans on.
    ///
    /// **And the reader goes with it, as Discord's does.** The stage is drawn
    /// only in the channel an instance runs in (`ActivityStageContainer`), so a
    /// launch that left the reader on the directory, or in the channel the
    /// launcher was opened over, started the app where nobody could see it —
    /// which is what "Launch in DM does nothing" was.
    func launchActivityInDirectMessage(_ app: ActivityApp) async {
        do {
            let channel = try await rest.openDirectMessage(
                with: UserID(rawValue: app.id.rawValue)
            )
            model.channelIndex.upsert(channel)
            model.openDirectMessage(channel.id)
            await launchActivity(app, in: channel.id, section: nil)
        } catch {
            model.reportActionFailure(
                Self.reason(for: error, verb: "open a direct message with \(app.name)")
            )
        }
    }

    /// Puts an already-running instance on screen — the Play button on an
    /// invitation card, and the tail of a launch.
    func openActivity(
        _ app: ActivityApp,
        in channelID: ChannelID,
        ticket: String,
        instance: String
    ) {
        let location = ActivityLocation(
            guildID: model.channelIndex.guildID(of: channelID),
            channelID: channelID
        )
        let id = ActivityInstanceID(instance: instance, location: location)
        guard let url = ActivityFrame.url(
            application: app.id,
            instance: id,
            proxyTicket: ticket,
            channelID: channelID
        ) else {
            model.reportActionFailure("Could not open \(app.name).")
            return
        }
        // A previous session, if the reader launched something else without
        // leaving first. One activity at a time, and the old frame must be
        // stopped rather than left running behind the new one.
        model.activityRuntime?.stop()

        let running = RunningActivity(
            instance: id,
            applicationID: app.id,
            name: app.name,
            iconURL: app.iconHash.flatMap {
                CDN.applicationIcon(id: app.id, hash: $0, side: Metrics.activityHeaderIcon)
            },
            frameURL: url
        )
        // The runtime first: the stage reads it in the same pass the running
        // activity publishes, and a stage that finds none draws nothing.
        model.activityRuntime = ActivityRuntime(activity: running, model: model)
        model.runningActivity = running
    }

    /// Join an instance somebody else started, from an invitation card.
    ///
    /// The ticket is per-launch and per-channel, so it is fetched fresh rather
    /// than remembered from whenever the card was drawn.
    func joinActivity(_ invite: ActivityInvite, in channelID: ChannelID) async {
        guard let instance = invite.instance else {
            model.reportActionFailure("That activity has no instance to join.")
            return
        }
        let app = model.activityApp(invite.applicationID)
            ?? ActivityApp(
                id: invite.applicationID,
                name: invite.name,
                iconHash: invite.iconHash,
                config: EmbeddedActivityConfig(supportedPlatforms: ["web"])
            )
        do {
            let ticket = try await rest.activityProxyTicket(
                application: invite.applicationID,
                channelID: channelID
            )
            openActivity(app, in: channelID, ticket: ticket, instance: instance.instance)
        } catch {
            model.reportActionFailure(Self.reason(for: error, verb: "join \(invite.name)"))
        }
    }

    /// Leave, and take the frame down.
    ///
    /// **The frame comes down first, and the route is told afterwards.** The
    /// reader pressed Leave; a surface that stays up until a network call
    /// answers reads as a control that did not work. A failed leave is not
    /// reported either — the instance times out server-side, and a notice about
    /// a thing the reader already finished with is noise.
    func leaveActivity() async {
        guard let running = model.runningActivity else { return }
        model.activityRuntime?.stop()
        model.activityRuntime = nil
        model.runningActivity = nil
        // Before the route, and unconditionally: a presence left standing shows
        // everybody a game that ended, and it outlives the instance by far
        // longer than the server's own timeout.
        model.clearPublishedActivity()
        guard let sessionID = await socketSessionID() else { return }
        try? await rest.leaveActivity(
            running.instance,
            application: running.applicationID,
            sessionID: sessionID
        )
    }

    /// Grants what a consent sheet was asking about, and answers with the code
    /// the frame is waiting for.
    ///
    /// Nil on refusal *and* on failure, and both are the same thing to the
    /// frame: it asked for a grant and did not get one. A failure is still
    /// reported, because "Authorize did nothing" is the one outcome the reader
    /// cannot distinguish from a broken button.
    func authorizeActivity(_ request: ActivityConsentRequest) async -> String? {
        do {
            return try await rest.authorizeActivity(
                application: request.authorization.applicationID,
                scopes: request.authorization.scopes,
                state: request.state,
                channelID: request.channelID,
                guildID: request.guildID,
                channelKind: request.channelKind
            )
        } catch {
            model.reportActionFailure(
                Self.reason(for: error, verb: "authorize \(request.authorization.name)")
            )
            return nil
        }
    }

    // MARK: Shared

    func socketSessionID() async -> String? {
        await socket?.currentSessionID
    }

    /// Discord's own words where it gave any, and this app's where it did not.
    ///
    /// A launch is refused for reasons the reader can act on — the app is
    /// blocked in this server, the channel forbids it — and "Could not launch"
    /// throws all of that away.
    static func reason(for error: any Error, verb: String) -> String {
        if case DiscordREST.Failure.api(_, _, let message) = error,
           let message, !message.isEmpty {
            return message
        }
        return "Could not \(verb)."
    }
}

// MARK: - Waiting for the instance Discord minted

/// A launch that has been sent and whose instance is not yet known.
///
/// **The instance id cannot be predicted.** It is the launching *interaction's*
/// snowflake, minted server-side — the captured launch sent nonce
/// `1544784235997429760` and produced instance `1544784239373983785`, which are
/// different numbers — and `POST /interactions` answers `204` with an empty
/// body.
///
/// A client that invents one gets a frame URL the app forwards to its own
/// backend, which cannot resolve it — Watch Together answered that with "Oops!
/// We had trouble starting up." after a six-second wait.
///
/// **Two things can name it, and only one of them always arrives.**
/// `INTERACTION_SUCCESS` carries `{id, nonce}` about four hundred milliseconds
/// after the launch and is dispatched for *every* entry point; the invitation
/// message carries `activity_instance.id` but is only posted by the
/// `handler: 2` kind. Wordle's `play` is `handler: 1` and posts none, so a
/// client waiting on the message alone times out on it — which is exactly what
/// "Wordle did not start." was. The acknowledgement is the primary signal and
/// the message is the fallback.
@MainActor
final class PendingActivityLaunch {
    let applicationID: ApplicationID
    let channelID: ChannelID
    /// What the launch was posted with, so an acknowledgement can be told from
    /// somebody else's — a second client on the same account sends its own.
    let nonce: String

    /// **The answer can arrive before anybody is waiting for it.** Discord
    /// acknowledged one launch 9,493ms in while the waiter was still being set
    /// up — the dispatch beat the `await` on the POST that precedes it — and an
    /// answer with nowhere to go was dropped, leaving the launch to time out
    /// eight seconds later on an instance it had already been told. So the
    /// answer is *stored*, and a later reader takes it immediately.
    private var settled: String??
    private var continuation: CheckedContinuation<String?, Never>?

    init(applicationID: ApplicationID, channelID: ChannelID, nonce: String) {
        self.applicationID = applicationID
        self.channelID = channelID
        self.nonce = nonce
    }

    /// Answered exactly once — with the instance, or with nil on timeout.
    func answer(_ instance: String?) {
        guard settled == nil else { return }
        settled = .some(instance)
        continuation?.resume(returning: instance)
        continuation = nil
    }

    /// The instance, whenever it was named.
    func value() async -> String? {
        if case .some(let instance) = settled { return instance }
        return await withCheckedContinuation { continuation in
            if case .some(let instance) = settled {
                continuation.resume(returning: instance)
            } else {
                self.continuation = continuation
            }
        }
    }

    func matches(_ invite: ActivityInvite, in channelID: ChannelID) -> Bool {
        invite.applicationID == applicationID && channelID == self.channelID
    }
}

extension SessionController {

    /// Waits for the invitation message the launch produces, and reads the
    /// instance out of it.
    ///
    /// **Bounded.** A launch that produces no message — the app refused it, the
    /// socket dropped — must not leave the caller awaiting for ever, so this
    /// gives up and the launch reports a failure instead of opening a frame
    /// pointed at nothing.
    /// Starts listening **before** the launch is posted.
    ///
    /// The order is the whole point: Discord's acknowledgement can arrive
    /// before the `await` on `POST /interactions` even resumes, so a waiter
    /// registered afterwards misses it entirely. See `PendingActivityLaunch`.
    func beginActivityLaunch(
        application: ApplicationID,
        channelID: ChannelID,
        nonce: String
    ) -> PendingActivityLaunch {
        let pending = PendingActivityLaunch(
            applicationID: application,
            channelID: channelID,
            nonce: nonce
        )
        pendingActivityLaunch = pending
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.launchInstanceTimeout))
            guard let self, pendingActivityLaunch === pending else { return }
            Self.trace("activities: no interaction acknowledgement within timeout")
            pendingActivityLaunch = nil
            pending.answer(nil)
        }
        return pending
    }

    func awaitActivityInstance(_ pending: PendingActivityLaunch) async -> String? {
        let instance = await pending.value()
        if pendingActivityLaunch === pending { pendingActivityLaunch = nil }
        return instance
    }

    /// How long to wait for Discord to dispatch the invitation. Generous: it is
    /// a round trip through the gateway, and the alternative to waiting is a
    /// frame that cannot work.
    static let launchInstanceTimeout: Double = 8

    /// `INTERACTION_SUCCESS` — the primary signal.
    ///
    /// **This is what the reference client must use.** It names the interaction
    /// directly, arrives about four hundred milliseconds after the launch, and
    /// is dispatched for every entry point — where the invitation message is
    /// only posted by the `handler: 2` kind. Wordle's `play` is `handler: 1`
    /// and posts none, which is why waiting on a message alone timed out on it.
    func resolveActivityLaunch(interaction id: String, nonce: String?) {
        Self.trace("activities: ack id=\(id) nonce=\(nonce ?? "-") "
            + "pending=\(pendingActivityLaunch?.nonce ?? "-")")
        guard let pending = pendingActivityLaunch else { return }
        // A nonce this client did not send belongs to another session on the
        // same account. Discord echoes ours, so a mismatch is somebody else's
        // launch and must not answer this one.
        guard nonce == nil || nonce == pending.nonce else { return }
        pendingActivityLaunch = nil
        pending.answer(id)
    }

    /// The invitation message — a fallback, for an entry point whose
    /// acknowledgement never arrives but whose message does.
    func resolveActivityLaunch(with message: Message) {
        // **Logged even when nothing is waiting.** The acknowledgement and the
        // invitation message both claim to name the instance, and whether they
        // agree is the whole question — an id that differs from the one the
        // frame was opened with is the difference between an app that starts
        // and one that says "Oops! We had trouble starting up."
        if let invite = message.activityInvite, let instance = invite.instance?.instance {
            Self.trace("activities: message instance=\(instance) "
                + "running=\(model.runningActivity?.instance.instance ?? "-")")
        }
        guard let pending = pendingActivityLaunch,
              let invite = message.activityInvite,
              pending.matches(invite, in: message.channelID),
              let instance = invite.instance?.instance
        else { return }
        pendingActivityLaunch = nil
        pending.answer(instance)
    }
}


// MARK: - Keeping a GIF

extension SessionController {
    /// Whether the account already keeps this one.
    func isFavorite(_ gif: GIF) -> Bool {
        model.favoriteGIFs.contains { $0.url == gif.url }
    }

    /// Stars or un-stars a GIF.
    ///
    /// **Optimistic, and re-settled on the answer.** The star is a control on a
    /// picture under the pointer; waiting a round trip to fill it in reads as
    /// the click having missed. The route re-reads the account's whole
    /// favourites blob and returns what it wrote, so the second write is the
    /// truth rather than a guess.
    ///
    /// Guarded against a second press while the first is out: this route reads
    /// the blob, edits it and writes it back, so two overlapping toggles would
    /// both start from the state before either — and the later one would undo
    /// the earlier.
    func toggleFavorite(_ gif: GIF) {
        guard !favoriteWritesInFlight.contains(gif.url) else { return }
        let wasFavorite = isFavorite(gif)
        favoriteWritesInFlight.insert(gif.url)
        if wasFavorite {
            model.favoriteGIFs.removeAll { $0.url == gif.url }
        } else {
            model.favoriteGIFs.insert(gif, at: 0)
        }

        Task { [weak self] in
            guard let self else { return }
            defer { favoriteWritesInFlight.remove(gif.url) }
            do {
                model.favoriteGIFs = try await rest.setFavorite(gif, favorite: !wasFavorite)
            } catch {
                Self.log.error(
                    "favourite failed: \(Self.describe(error), privacy: .public)"
                )
                // Put it back. A star that stayed lit on a write that failed is
                // a client telling the reader something the account does not
                // agree with.
                if wasFavorite {
                    if !isFavorite(gif) { model.favoriteGIFs.insert(gif, at: 0) }
                } else {
                    model.favoriteGIFs.removeAll { $0.url == gif.url }
                }
            }
        }
    }
}

extension SessionController {

    /// Resolves applications this client knows only by id.
    ///
    /// The same route the Recents strip uses — see
    /// `DiscordREST.publicApplications` — reached from the two surfaces that
    /// need an application's *icon* rather than its page: a rich presence with
    /// no artwork of its own, and a recent-activity row for something
    /// `/games` does not answer for.
    func resolveApplications(_ ids: [ApplicationID]) {
        Task { [weak self] in
            guard let self else { return }
            defer { model.applicationsResolving.subtract(ids) }
            guard let resolved = try? await rest.publicApplications(ids: ids),
                  !resolved.isEmpty
            else { return }
            for app in resolved { model.activityDirectory.apps[app.id] = app }
            model.activityRevision &+= 1
        }
    }
}
