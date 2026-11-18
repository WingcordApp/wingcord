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
        // The voice launcher's own (Alex, 2026-11-18): its Activities and its
        // promoted games are not the text launcher's.
        async let voice = try? rest.activityCollections(locale: locale, surface: 3)
        let (shelfApps, rows, voiceRows) = await (shelf, collections, voice)

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
        func enrich(_ collections: [ActivityCollection]) -> [ActivityCollection] {
            collections.map { collection in
                var collection = collection
                collection.apps = collection.apps.map { app in
                    var app = app
                    app.tileAssetID = apps[app.id]?.tileAssetID ?? app.tileAssetID
                    if app.coverHash == nil { app.coverHash = apps[app.id]?.coverHash }
                    merged[app.id] = app
                    return app
                }
                return collection
            }
        }
        let enriched = enrich(rows)
        let voiceEnriched = enrich(voiceRows ?? [])

        model.activityDirectory = ActivityDirectory(
            collections: enriched,
            apps: merged,
            shelf: ranked.map(\.id),
            voiceCollections: voiceEnriched
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

    // MARK: Starting, launching and joining
    //
    // docs/ACTIVITIES-CALLS-PICKER.md, decisions 1 and 2. **A frame opens only
    // when Discord says this session is in an instance**
    // (`EMBEDDED_ACTIVITY_UPDATE_V2`, `reconcileActivity`), with that
    // instance's own ids. Launching where the app already runs puts you in the
    // running one, so a frame opened on the launching interaction's id pointed
    // at an instance that didn't exist: the "works half the time" bug.

    /// Starts an app in a channel the way Discord's client does: joins the
    /// instance of it already running there, or launches a new one.
    func startActivity(_ app: ActivityApp, in channelID: ChannelID, section: String?, guildID: GuildID? = nil) async {
        if model.activityInstances.instance(of: app.id, in: channelID) != nil {
            await joinActivity(app, in: channelID, guildID: guildID)
        } else {
            await launchActivity(app, in: channelID, section: section, guildID: guildID)
        }
    }

    /// Launches a new instance: the app's entry-point command, then waiting for
    /// Discord to list this session in what it made.
    /// - Parameter guildID: the channel's server where the caller knows it
    ///   better than the channel list does (the Server Hub's own channel).
    func launchActivity(_ app: ActivityApp, in channelID: ChannelID, section: String?, guildID: GuildID? = nil) async {
        guard app.isLaunchable else {
            model.reportActionFailure("\(app.name) can\u{2019}t be launched here.")
            return
        }
        guard let sessionID = await currentGatewaySessionID() else {
            model.reportActionFailure("Not connected.")
            return
        }
        let place = guildID ?? model.channelIndex[channelID]?.guildID
        model.activityStarting = ActivityStarting(applicationID: app.id, channelID: channelID, name: app.name)
        defer { if model.activityStarting?.applicationID == app.id { model.activityStarting = nil } }
        do {
            guard let entryPoint = try await rest.activityEntryPoint(for: app.id) else {
                model.reportActionFailure("\(app.name) has nothing to launch.")
                return
            }
            // Fetched before the launch, as Discord does (`$.D2` beside the
            // command), so the frame can open the moment the update lands.
            let ticket = try await rest.activityProxyTicket(application: app.id, channelID: channelID)
            let nonce = Self.nonce()
            // **Registered before the post**: the update can outrun the
            // request's own answer.
            let pending = beginActivityConnect(app: app, channelID: channelID, nonce: nonce, ticket: ticket)
            do {
                try await rest.launchActivity(
                    entryPoint, channelID: channelID, guildID: place, sessionID: sessionID,
                    nonce: nonce, analyticsSection: section
                )
            } catch {
                endActivityConnect(pending)
                throw error
            }
            guard await pending.value() != nil else {
                model.reportActionFailure("\(app.name) didn\u{2019}t start. Try again in a moment.")
                return
            }
        } catch DiscordREST.Failure.forbidden {
            model.reportActionFailure("You cannot start Activities in this channel.")
        } catch {
            model.reportActionFailure(Self.reason(for: error, verb: "launch \(app.name)"))
        }
    }

    /// Joins the instance of this app already running in a channel.
    ///
    /// **Discord's join** (modules 211449 and 730602): in a voice channel the
    /// call first; the current activity left first (one at a time); then
    /// `POST /activities/{channel}/{app}` with the gateway session, and the
    /// frame opens when the update lists this session.
    func joinActivity(_ app: ActivityApp, in channelID: ChannelID, guildID: GuildID? = nil) async {
        let channel = model.channelIndex[channelID]
        let place = guildID ?? channel?.guildID
        if let channel, channel.kind == .voice || channel.kind == .stage,
           model.connectedVoiceChannelID != channelID {
            model.joinVoice(channelID)
            guard await waitUntilConnected(to: channelID) else {
                model.reportActionFailure("Join the voice channel to play \(app.name).")
                return
            }
        }
        guard let sessionID = await currentGatewaySessionID() else {
            model.reportActionFailure("Not connected.")
            return
        }
        if let running = model.runningActivity,
           !(running.applicationID == app.id && running.instance.location.channelID == channelID) {
            await leaveActivity()
        }
        model.activityStarting = ActivityStarting(applicationID: app.id, channelID: channelID, name: app.name)
        defer { if model.activityStarting?.applicationID == app.id { model.activityStarting = nil } }
        do {
            let ticket = try await rest.activityProxyTicket(application: app.id, channelID: channelID)
            let pending = beginActivityConnect(app: app, channelID: channelID, nonce: nil, ticket: ticket)
            do {
                try await rest.joinActivity(
                    application: app.id, channelID: channelID, guildID: place, sessionID: sessionID
                )
            } catch {
                endActivityConnect(pending)
                throw error
            }
            guard await pending.value() != nil else {
                if model.activityInstances.instance(of: app.id, in: channelID) == nil {
                    // Discord's words, and its offer: the one you meant to
                    // join is gone, so start your own.
                    model.activityEndedPrompt = ActivityEndedPrompt(app: app, channelID: channelID, guildID: place)
                } else {
                    model.reportActionFailure("Couldn\u{2019}t join \(app.name). Try again in a moment.")
                }
                return
            }
        } catch DiscordREST.Failure.notFound {
            model.activityEndedPrompt = ActivityEndedPrompt(app: app, channelID: channelID, guildID: place)
        } catch DiscordREST.Failure.forbidden {
            model.reportActionFailure("You cannot join Activities in this channel.")
        } catch {
            model.reportActionFailure(Self.reason(for: error, verb: "join \(app.name)"))
        }
    }

    /// Launch into the reader's direct message with the application's own bot.
    ///
    /// **"Launch in DM" is the same launch into a different channel**, and the
    /// reader goes with it, as Discord's does: the stage is drawn only in the
    /// channel an instance runs in. **A bot's user id is its application id**,
    /// which is what makes the DM resolvable without a directory lookup.
    func launchActivityInDirectMessage(_ app: ActivityApp) async {
        do {
            let channel = try await rest.openDirectMessage(
                with: UserID(rawValue: app.id.rawValue)
            )
            model.channelIndex.upsert(channel)
            model.openDirectMessage(channel.id)
            await startActivity(app, in: channel.id, section: nil)
        } catch {
            model.reportActionFailure(
                Self.reason(for: error, verb: "open a direct message with \(app.name)")
            )
        }
    }

    /// Play or Join on an invitation card: the app's instance in that channel
    /// if it's still running, a new one if it ended (Discord's "Activity has
    /// ended. Start a new one?").
    func joinActivity(_ invite: ActivityInvite, in channelID: ChannelID) async {
        let app = model.activityApp(invite.applicationID)
            ?? ActivityApp(
                id: invite.applicationID,
                name: invite.name,
                iconHash: invite.iconHash,
                config: EmbeddedActivityConfig(supportedPlatforms: ["web"])
            )
        await startActivity(app, in: channelID, section: nil)
    }

    /// Puts an instance this session is in on screen.
    ///
    /// **Every id comes from the instance**, never from a launch: the frame's
    /// `instance_id`, `launch_id` and `location_id` name the instance Discord
    /// put this session in.
    func openActivity(_ instance: ActivityInstance, app: ActivityApp, ticket: String) {
        guard let url = ActivityFrame.url(
            application: app.id,
            instance: instance,
            proxyTicket: ticket,
            isServerHubChannel: model.channelIndex[instance.channelID]?.kind == .guildSpace
        ) else {
            model.reportActionFailure("Couldn\u{2019}t open \(app.name).")
            return
        }
        // One activity at a time: an old frame is stopped, not left running
        // behind the new one.
        model.activityRuntime?.stop()
        let running = RunningActivity(
            instance: instance.id,
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
        Self.trace("activities: opened \(instance.frameInstanceID) for \(app.id)")
    }

    /// Leave, and take the frame down.
    ///
    /// **The frame comes down first, and the route is told afterwards.** The
    /// reader pressed Leave; a surface that stays up until a network call
    /// answers reads as a control that did not work.
    func leaveActivity() async {
        guard let running = model.runningActivity else { return }
        closeRunningActivity()
        guard let sessionID = await currentGatewaySessionID() else { return }
        try? await rest.leaveActivity(
            running.instance,
            application: running.applicationID,
            sessionID: sessionID
        )
    }

    /// Takes the running frame down without telling the server: the reader
    /// left, or Discord said this session isn't in it any more.
    func closeRunningActivity() {
        guard model.runningActivity != nil else { return }
        model.activityRuntime?.stop()
        model.activityRuntime = nil
        model.runningActivity = nil
        // A presence left standing shows everybody a game that ended.
        model.clearPublishedActivity()
    }

    /// The gateway session, as the participant records name it.
    func currentGatewaySessionID() async -> String? {
        if let gatewaySessionID { return gatewaySessionID }
        let fresh = await socketSessionID()
        gatewaySessionID = fresh
        return fresh
    }

    /// Waits for the reader's own voice state to land in a channel: Discord
    /// joins the call before the activity, and the join is refused outside it.
    private func waitUntilConnected(to channelID: ChannelID) async -> Bool {
        for _ in 0..<80 {
            if let me = model.currentUserID, model.voiceStates[me]?.channelID == channelID { return true }
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return false }
        }
        return false
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

// MARK: - Waiting for Discord to put this session in

/// A launch or a join that has been sent, waiting for the update that lists
/// this session in an instance.
///
/// **The update is the answer, not the acknowledgement.** `INTERACTION_SUCCESS`
/// names the interaction, which is the instance's id only when the launch made
/// a new one; the update names the instance Discord actually put this session
/// in, and carries the launch's nonce on this session's participant record
/// (Discord's store matches on exactly that, module 933958).
@MainActor
final class PendingActivityConnect {
    let app: ActivityApp
    let channelID: ChannelID
    /// The launch's nonce. Nil for a join, which sends none.
    let nonce: String?
    let ticket: String

    /// **The answer can arrive before anybody is waiting for it**, so it is
    /// stored and a later reader takes it at once.
    private var settled: ActivityInstance??
    private var continuation: CheckedContinuation<ActivityInstance?, Never>?

    init(app: ActivityApp, channelID: ChannelID, nonce: String?, ticket: String) {
        self.app = app
        self.channelID = channelID
        self.nonce = nonce
        self.ticket = ticket
    }

    /// Answered exactly once: with the instance, or nil on timeout.
    func answer(_ instance: ActivityInstance?) {
        guard settled == nil else { return }
        settled = .some(instance)
        continuation?.resume(returning: instance)
        continuation = nil
    }

    var isSettled: Bool { settled != nil }

    func value() async -> ActivityInstance? {
        if case .some(let instance) = settled { return instance }
        return await withCheckedContinuation { continuation in
            if case .some(let instance) = settled {
                continuation.resume(returning: instance)
            } else {
                self.continuation = continuation
            }
        }
    }

    /// Whether an instance, with this session's record in it, answers this.
    func matches(_ instance: ActivityInstance, record: ActivityParticipant) -> Bool {
        guard instance.applicationID == app.id, instance.channelID == channelID else { return false }
        // A launch's record carries its nonce; a different one is another
        // launch of ours. A record without one still answers (a join sends
        // none, and the server doesn't always echo it).
        if let nonce, let theirs = record.nonce { return theirs == nonce }
        return true
    }
}

extension SessionController {

    /// Starts listening **before** the request is posted.
    func beginActivityConnect(
        app: ActivityApp,
        channelID: ChannelID,
        nonce: String?,
        ticket: String
    ) -> PendingActivityConnect {
        pendingActivityConnect?.answer(nil)
        let pending = PendingActivityConnect(app: app, channelID: channelID, nonce: nonce, ticket: ticket)
        pendingActivityConnect = pending
        // An instance that already lists this session (a join into one we're
        // somehow still in) answers at once.
        if let me = model.currentUserID, let session = gatewaySessionID,
           let instance = model.activityInstances.instance(of: app.id, in: channelID),
           let record = instance.participant(me, session: session),
           nonce == nil, pending.matches(instance, record: record) {
            settle(pending, with: instance)
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.connectTimeout))
            guard let self, pendingActivityConnect === pending, !pending.isSettled else { return }
            Self.trace("activities: no update listing this session within \(Int(Self.connectTimeout)) s")
            pendingActivityConnect = nil
            pending.answer(nil)
        }
        return pending
    }

    func endActivityConnect(_ pending: PendingActivityConnect) {
        if pendingActivityConnect === pending { pendingActivityConnect = nil }
        pending.answer(nil)
    }

    /// Generous: a round trip through the app's own backend for a handler-1
    /// launch, then the gateway.
    static let connectTimeout: Double = 15

    /// `EMBEDDED_ACTIVITY_UPDATE_V2`, after the store has it: open the frame if
    /// this session was put in, close it if it was taken out.
    ///
    /// **Discord's rule** (`z` in module 933958): a session listed in an
    /// instance it isn't showing opens it; the instance it is showing that no
    /// longer lists it (left elsewhere, removed, ended) closes.
    func reconcileActivity(_ instance: ActivityInstance) {
        guard let me = model.currentUserID, let session = gatewaySessionID else { return }
        let running = model.runningActivity
        let isShowing = running.map {
            $0.applicationID == instance.applicationID && $0.instance.location == instance.location
        } ?? false

        if let record = instance.participant(me, session: session) {
            if isShowing, running?.instance.instance == instance.launchID {
                // Already on screen: tell the frame who's there now.
                model.activityRuntime?.participantsChanged(instance)
                return
            }
            if let pending = pendingActivityConnect, pending.matches(instance, record: record) {
                settle(pending, with: instance)
                return
            }
            // Put in from somewhere else (another surface's join, a launch
            // answered after a timeout): open it the same way.
            openUnasked(instance)
        } else if isShowing, running?.instance.instance == instance.launchID {
            Self.trace("activities: this session left \(instance.frameInstanceID); closing")
            closeRunningActivity()
        }
    }

    /// The bootstrap's whole list: a frame whose instance isn't in it any more,
    /// with the reader in it, closes (Discord's `CONNECTION_OPEN_SUPPLEMENTAL`).
    func reconcileActivitiesAfterConnecting() {
        guard let running = model.runningActivity, let me = model.currentUserID,
              running.instance.location.guildID != nil
        else { return }
        let instance = model.activityInstances.instance(
            of: running.applicationID, in: running.instance.location.channelID
        )
        guard let instance, instance.launchID == running.instance.instance, instance.includes(me) else {
            Self.trace("activities: the running instance didn't survive the reconnect; closing")
            closeRunningActivity()
            return
        }
    }

    private func settle(_ pending: PendingActivityConnect, with instance: ActivityInstance) {
        if pendingActivityConnect === pending { pendingActivityConnect = nil }
        openActivity(instance, app: pending.app, ticket: pending.ticket)
        pending.answer(instance)
    }

    /// An instance this session is in that nobody here asked for: its ticket
    /// and its app are fetched, then it opens.
    private func openUnasked(_ instance: ActivityInstance) {
        Task { [weak self] in
            guard let self else { return }
            if model.activityApp(instance.applicationID) == nil {
                await loadActivityApp(instance.applicationID)
            }
            let app = model.activityApp(instance.applicationID)
                ?? ActivityApp(
                    id: instance.applicationID,
                    name: "Activity",
                    config: EmbeddedActivityConfig(supportedPlatforms: ["web"])
                )
            guard let ticket = try? await rest.activityProxyTicket(
                application: instance.applicationID, channelID: instance.channelID
            ) else { return }
            // Still in it, and still not showing it?
            guard let me = model.currentUserID, let session = gatewaySessionID,
                  model.activityInstances.instance(of: instance.applicationID, in: instance.channelID)?
                      .includes(me, session: session) == true,
                  model.runningActivity?.instance != instance.id
            else { return }
            openActivity(instance, app: app, ticket: ticket)
        }
    }

    /// `INTERACTION_SUCCESS` for a launch: traced, and nothing else. The update
    /// listing this session is what opens the frame (see the type above).
    func noteActivityAcknowledged(interaction id: String, nonce: String?) {
        guard let pending = pendingActivityConnect, let nonce, nonce == pending.nonce else { return }
        Self.trace("activities: launch \(nonce) acknowledged as \(id); waiting for the update")
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
