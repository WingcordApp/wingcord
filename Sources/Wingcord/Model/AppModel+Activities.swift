import Foundation
import WingcordCore

// MARK: - The activity launcher's state
//
// What the launcher flyout reads, and nothing else. The store holds it; the
// session controller fills it. Both directions of that are `INVARIANTS.md`'s
// rule, not a preference: the store never reaches for the network.

/// Where the launcher is.
///
/// **A stack of two, not a navigation stack.** The flyout is 388 points wide
/// and has exactly one place to go — an app's own page — with one way back. A
/// `NavigationStack` inside a popover buys a chrome bar this design does not
/// draw and a transition this design animates itself.
enum ActivityLauncherPage: Hashable, Sendable {
    case directory
    case app(ApplicationID)
    /// One app's storefront. **Reached only from that app's page**, which is
    /// what keeps this a stack of two from anywhere the reader actually is —
    /// the directory never opens a store directly.
    case store(ApplicationID, name: String)
}

/// One row's worth of what the launcher draws.
///
/// A plain value with no store reference, for the reason every other
/// presentation type here has none: `.equatable()` is worth nothing on a type
/// that closes over the store.
struct ActivityRow: Hashable, Sendable, Identifiable {
    var id: ApplicationID
    var name: String
    var subtitle: String
    var iconURL: URL?
    /// The wide artwork, on a featured tile only. Nil on a list row, where it
    /// would be fetched and never drawn.
    var tileURL: URL?
    /// The app's preview loop (`activity_preview_video_asset_id`), which a
    /// featured card plays while hovered, as Discord's shelf does (decision 5).
    var previewVideoURL: URL? = nil
    var monogram: String
    var isLaunchable: Bool
    /// Discord's PROMOTED badge (`ActivityApp.isPromoted`).
    var isPromoted = false
}

/// A titled row of the directory.
struct ActivitySection: Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var isFeatured: Bool
    /// Every row; the view shows `collapsedCount` of them until See All.
    var rows: [ActivityRow]
    /// Whether the section has more than it is showing.
    var hasMore: Bool
    /// How many rows show before See All.
    var collapsedCount = Int.max
}

extension AppModel {

    /// The directory, once per launch.
    ///
    /// Kept rather than refetched per open: the shelf is 258 KB and the same
    /// for every account, and a fetch per popover open is a quarter of a
    /// megabyte for an answer that changes about as often as Discord ships a
    /// new game.
    func activitySections(for context: ActivityLauncherContext) -> [ActivitySection] {
        let key = ActivityMemoKey(
            revision: activityRevision,
            query: activityQuery.trimmingCharacters(in: .whitespaces),
            context: context
        )
        // Every observable input is read before the early return: a memo that
        // answers from its cache without touching them registers no dependency
        // and is never invalidated again. `INVARIANTS.md` §2.
        let directory = activityDirectory
        let recents = activityRecents
        let results = activitySearchResults

        if let activitySectionsCache, activitySectionsCache.key == key {
            return activitySectionsCache.value
        }

        let sections = key.query.isEmpty
            ? browseSections(directory: directory, recents: recents, context: context)
            : [searchSection(results)]
        activitySectionsCache = (key, sections)
        return sections
    }

    /// The app a launcher page is showing, as far as it is known.
    ///
    /// The directory's own copy first, because it is already here; the detail
    /// route fills in the description, the carousel and the server count and
    /// replaces it. A page that waited for the route would open blank for the
    /// length of a request on an app whose name and icon it already has.
    func activityApp(_ id: ApplicationID) -> ActivityApp? {
        activityDetails[id] ?? activityDirectory.apps[id]
    }

    // MARK: Building the sections

    private func browseSections(
        directory: ActivityDirectory,
        recents: [ApplicationID],
        context: ActivityLauncherContext
    ) -> [ActivitySection] {
        var sections: [ActivitySection] = []

        // Recents leads, and it is drawn as bare icons rather than rows — it is
        // a row of things you already know the names of.
        let recentRows = recents.prefix(Self.recentsShown).compactMap { id in
            directory.apps[id].map(Self.row(for:))
        }
        if !recentRows.isEmpty {
            sections.append(ActivitySection(
                id: "recents",
                title: "Recents",
                isFeatured: false,
                rows: Array(recentRows),
                hasMore: recents.count > recentRows.count
            ))
        }

        // **A call reads the voice launcher's collections**, as Discord's
        // does (`surface=3`); the text launcher's stand in until they land.
        let collections = context == .call && !directory.voiceCollections.isEmpty
            ? directory.voiceCollections
            : directory.collections
        for collection in collections {
            let rows = collection.apps.map(Self.row(for:))
            guard !rows.isEmpty else { continue }
            let collapsed = collection.isFeatured ? rows.count : Self.sectionRowsShown
            sections.append(ActivitySection(
                id: collection.id,
                title: collection.title,
                isFeatured: collection.isFeatured,
                rows: rows,
                hasMore: rows.count > collapsed,
                collapsedCount: collapsed
            ))
        }
        return sections
    }

    private func searchSection(_ results: [ActivityApp]) -> ActivitySection {
        ActivitySection(
            id: "search",
            title: "Apps",
            isFeatured: false,
            rows: results.map(Self.row(for:)),
            hasMore: false
        )
    }

    static func row(for app: ActivityApp) -> ActivityRow {
        ActivityRow(
            id: app.id,
            name: app.name,
            subtitle: app.rowSubtitle
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            // **Discord's own default where the app registered none**, rather
            // than this app's monogram: an application has a real fallback
            // picture and every surface Discord draws uses it. See
            // `CDN.defaultApplicationIcon`.
            iconURL: app.iconHash.flatMap {
                CDN.applicationIcon(id: app.id, hash: $0, side: Metrics.activityRowIcon)
            } ?? CDN.defaultApplicationIcon,
            tileURL: app.tileAssetID.flatMap {
                CDN.applicationAsset(id: app.id, assetID: $0, side: Metrics.activityTileWidth)
            },
            previewVideoURL: app.config?.previewVideoAssetID.flatMap {
                CDN.activityPreviewVideo(id: app.id, assetID: $0)
            },
            monogram: String(app.name.prefix(1)).uppercased(),
            isLaunchable: app.isLaunchable,
            isPromoted: app.isPromoted
        )
    }

    /// Discord's suggestions for a call — the shelf's top launchable apps, in
    /// its order (`getShelfActivities(guildId)`, five in the call's mini
    /// shelf, three on the voice tile).
    func suggestedActivities(_ count: Int) -> [ActivityRow] {
        // **Read first, because the directory is not observed.** It is
        // `@ObservationIgnored` and announces itself through this counter; a
        // view that read only the directory never heard it arrive, which is
        // the shelf that spun for ever.
        _ = activityRevision
        let directory = activityDirectory
        return directory.shelf.lazy
            .compactMap { directory.apps[$0] }
            .filter(\.isLaunchable)
            .prefix(count)
            .map(Self.row(for:))
    }

    /// How many icons the Recents row shows. Eight in the reference client, and
    /// eight is what fits the flyout's width at this icon size.
    static let recentsShown = 8
    /// How many rows a list section shows before "View More". Four in the
    /// reference client, and the same four here.
    static let sectionRowsShown = 4
}

extension AppModel {
    /// The frame finished its handshake.
    ///
    /// Until it has, the stage draws the app's own artwork — a `WKWebView`
    /// that has not painted yet is a white rectangle, and a white rectangle in
    /// the middle of a near-black window reads as a fault rather than as
    /// loading.
    func markActivityReady() {
        guard runningActivity?.isReady == false else { return }
        runningActivity?.isReady = true
    }
}

// MARK: - A running activity

/// An activity that is on screen.
///
/// **The frame's URL is built once, here, and never rebuilt.** Every parameter
/// in it — the instance, the proxy ticket, the frame id — names *this* run; a
/// URL recomputed on a redraw would hand the app a different frame id and it
/// would reconnect.
struct RunningActivity: Identifiable, Hashable, Sendable {
    var id: ActivityInstanceID { instance }
    var instance: ActivityInstanceID
    var applicationID: ApplicationID
    var name: String
    var iconURL: URL?
    var frameURL: URL
    /// Whether the frame has finished its handshake. Until it has, the surface
    /// draws the app's own artwork rather than a white rectangle.
    var isReady = false
}

/// What the consent sheet is asking about.
///
/// **Raised by the running activity, not by pressing Launch.** The captured
/// order is launch, frame, then this: the app asks for a grant over its own
/// channel once it is running, and the reply it is waiting for is an
/// authorization code. `continuation` is that reply.
@MainActor
final class ActivityConsentRequest: Identifiable, Sendable {
    let id = UUID()
    let authorization: ActivityAuthorization
    let channelID: ChannelID
    let guildID: GuildID?
    let channelKind: Int
    let state: String
    /// Answered exactly once — with a code on Authorize, with nil on Cancel or
    /// on the sheet being dismissed any other way. A frame left waiting on a
    /// promise nobody resolves is an activity that hangs on a blank screen.
    private var reply: ((String?) -> Void)?

    init(
        authorization: ActivityAuthorization,
        channelID: ChannelID,
        guildID: GuildID?,
        channelKind: Int,
        state: String,
        reply: @escaping (String?) -> Void
    ) {
        self.authorization = authorization
        self.channelID = channelID
        self.guildID = guildID
        self.channelKind = channelKind
        self.state = state
        self.reply = reply
    }

    func answer(_ code: String?) {
        reply?(code)
        reply = nil
    }

    /// The scopes, in this app's own words rather than Discord's.
    ///
    /// `OAuthScope` already carries the table — it was written for the
    /// Authorized Apps pane — and the consent sheet asks the same question
    /// about the same strings.
    var permissions: [String] {
        authorization.scopes.map(OAuthScope.description)
    }
}

struct ActivityMemoKey: Hashable, Sendable {
    /// Moves when the directory, the Recents table or a search result changes,
    /// and on nothing else. Deliberately **not** a counter that a message
    /// arriving touches.
    var revision: UInt64
    var query: String
    /// The text launcher and the voice launcher read different collections.
    var context: ActivityLauncherContext
}

// MARK: - Publishing a running activity as presence

extension AppModel {

    /// Takes what an activity sent through `SET_ACTIVITY` and broadcasts it.
    ///
    /// **Decoded from a loose dictionary rather than a typed payload**, for the
    /// same reason the RPC frames are: these are open-ended JSON objects an app
    /// composes, and a `Decodable` here would reject an app that sends a field
    /// this client has never seen — which is most of them. Everything
    /// unrecognised is dropped; everything recognised is carried through
    /// unchanged.
    func publishActivity(_ payload: [String: Any], application: ApplicationID) {
        guard let name = payload["name"] as? String, !name.isEmpty else { return }
        let assets = payload["assets"] as? [String: Any]
        let timestamps = payload["timestamps"] as? [String: Any]
        let party = payload["party"] as? [String: Any]

        let activity = RichPresenceActivity(
            // Echoed rather than validated: a type this client has no name for
            // must still round-trip rather than becoming "Playing".
            type: payload["type"] as? Int ?? 0,
            name: name,
            details: payload["details"] as? String,
            state: payload["state"] as? String,
            assets: assets.map {
                RichPresenceActivity.Assets(
                    largeImage: $0["large_image"] as? String,
                    largeText: $0["large_text"] as? String,
                    largeURL: ($0["large_url"] as? String).flatMap(URL.init(string:)),
                    smallImage: $0["small_image"] as? String,
                    smallText: $0["small_text"] as? String,
                    smallURL: ($0["small_url"] as? String).flatMap(URL.init(string:))
                )
            },
            timestamps: timestamps.map {
                RichPresenceActivity.Timestamps(
                    start: Self.milliseconds($0["start"]),
                    end: Self.milliseconds($0["end"])
                )
            },
            party: party.map {
                RichPresenceActivity.Party(
                    // **A string, but not a tidy one.** Watch Together sends
                    // its party id as the instance reversed and comma-joined —
                    // `"5,2,3,7,…-,c,p,-,…"` — which is JavaScript stringifying
                    // an array. Passed through unchanged: it is the app's own
                    // key for who is together, and this client has no business
                    // tidying it. Anything that is not a string at all is
                    // dropped rather than coerced into nonsense.
                    id: $0["id"] as? String,
                    size: ($0["size"] as? [Int]).map { Array($0.prefix(2)) }
                )
            },
            buttons: (payload["buttons"] as? [String]) ?? [],
            applicationID: application
        )
        guard publishedActivity != activity else { return }
        publishedActivity = activity
        reflectOwnPresence()
        sessionController.publishPresence()
    }

    /// Stops broadcasting, when the activity closes.
    func clearPublishedActivity() {
        guard publishedActivity != nil else { return }
        publishedActivity = nil
        reflectOwnPresence()
        sessionController.publishPresence()
    }

    /// Shows the reader their own activity.
    ///
    /// **Discord does not tell you about yourself.** `PRESENCE_UPDATE` carries
    /// other people; the presence this client publishes never comes back, so
    /// a profile card reading the presence table finds nothing and says
    /// "Nothing right now" about an activity the reader is looking at. The
    /// write is mirrored locally for the same reason an optimistic message row
    /// exists.
    /// Re-mirrors the reader's own presence from outside this file.
    ///
    /// The private one below is the implementation; this is the seam the
    /// session uses when a *game* changes, which is the one writer that does
    /// not go through `publishedActivity`.
    func reflectOwnPresenceNow() { reflectOwnPresence() }

    private func reflectOwnPresence() {
        guard let userID = currentUserID else { return }
        var list = (presences[userID]?.activities?.list ?? [])
            // Everything except a previously mirrored activity of ours. A
            // custom status is somebody's own text and must survive this.
            .filter { $0.kind == .custom }
        // **Everything this client publishes, not just the embedded one** —
        // otherwise a reader looking at their own profile sees "Nothing right
        // now" while their roster row says Playing.
        for (index, activity) in publishedActivities.enumerated() {
            // **Everything the card draws**, so the reader's own card is the
            // one everybody else sees — the Rich Presence builder's links,
            // buttons and party included. The buttons' links are this
            // client's to know: nobody fetches the reader's own metadata.
            let session = activity.buttonURLs.isEmpty ? nil : "own-\(index)"
            if let session { activityButtonURLs[session] = activity.buttonURLs }
            list.append(Activity(published: activity, sessionID: session))
        }
        presences[userID] = Presence(
            userID: userID,
            status: selfStatus,
            isOnMobile: presences[userID]?.isOnMobile ?? false,
            activities: list.isEmpty ? nil : PresenceActivities(list: list)
        )
        noteEveryPresenceChanged()
    }

    /// **Milliseconds, whatever the app sent.** The wire is milliseconds and
    /// some apps send seconds; a ten-digit number is seconds, a thirteen-digit
    /// one is already milliseconds. Sent as seconds, an elapsed clock reads as
    /// decades.
    private static func milliseconds(_ value: Any?) -> Int? {
        let number: Double? = (value as? Double) ?? (value as? Int).map(Double.init)
        guard let number, number > 0 else { return nil }
        return number < 100_000_000_000 ? Int(number * 1000) : Int(number)
    }
}

// MARK: - An invitation's live state

/// What an invitation card knows about the instance right now.
///
/// **Assembled from presence, because that is the only place it exists.** The
/// launch message carries the app and the instance and nothing else; the line
/// a reader wants — what is happening, for how long, with how many people —
/// is published by the activity itself through `SET_ACTIVITY` and broadcast as
/// the participants' presence. See `AppModel.publishActivity`.
struct ActivityInviteState: Hashable, Sendable {
    /// "Adding videos". The activity's own `details`.
    var detail: String?
    /// When the instance started, for the elapsed clock.
    var startedAt: Date?
    /// How many people are in it, when that is knowable.
    var playerCount: Int?
    /// Whether the reader is one of them, which is what makes the button read
    /// "Joined" rather than "Play".
    var isParticipating: Bool
    /// Whether the instance is over.
    ///
    /// **Only ever true where absence is evidence.** In a direct message the
    /// guest list is closed, so no presence carrying the app means it really
    /// has ended; in a server it means nothing at all, and the card says
    /// nothing rather than guessing. See `AppModel.activityInviteState`.
    var hasEnded: Bool
}

extension AppModel {

    /// The live state of an invitation, or nil when nobody is in it.
    ///
    /// **Matched on the application, not on the instance.** An activity's
    /// presence carries no instance id that this client can rely on — the only
    /// candidate is `party.id`, and apps spell it however they like (Watch
    /// Together sends the instance reversed and comma-joined). So the match is
    /// the application plus the people who can see this channel, which is
    /// exact in a direct message and can be ambiguous in a server running two
    /// instances of one app. Ambiguous is the right failure here: it counts
    /// people who really are in that app, just possibly in a different room.
    func activityInviteState(for invite: ActivityInvite, in channelID: ChannelID) -> ActivityInviteState? {
        let channel = channelIndex[channelID]
        let participants = channel?.recipientIDs ?? []
        let candidates = Set(participants + [currentUserID].compactMap { $0 })
        guard !candidates.isEmpty else { return nil }

        var detail: String?
        var startedAt: Date?
        var declaredCount: Int?
        var present = 0
        var isParticipating = false

        for userID in candidates {
            guard let activity = presences[userID]?.activities?.list.first(where: {
                $0.applicationID == invite.applicationID
            }) else { continue }
            present += 1
            if userID == currentUserID { isParticipating = true }
            // The first one that says anything wins: every participant in an
            // instance publishes the same state, and a reader does not benefit
            // from this client picking a different one each frame.
            if detail == nil { detail = activity.details }
            if startedAt == nil { startedAt = activity.startedAt }
            if declaredCount == nil, let size = activity.partySize?.first, size > 0 {
                declaredCount = size
            }
        }

        // **"Nobody is in this" is only sayable where it can be known.** A
        // direct message has a closed guest list, so no presence carrying this
        // app really does mean the instance is over. A guild channel does not:
        // `recipientIDs` is empty there, so the only presence this ever
        // examines is the reader's own, and announcing that nobody is playing
        // would be a claim about five people it never looked at.
        let isClosedRoom = channel?.kind == .directMessage
            || channel?.kind == .groupDirectMessage
        guard present > 0 else {
            return isClosedRoom
                ? ActivityInviteState(
                    detail: nil, startedAt: nil, playerCount: nil,
                    isParticipating: false, hasEnded: true
                )
                : nil
        }
        return ActivityInviteState(
            detail: detail,
            startedAt: startedAt,
            // **The app's own count first.** `party.size` counts everybody in
            // the instance; this client can only see presences it receives,
            // which in a server is a fraction of them.
            playerCount: declaredCount ?? present,
            isParticipating: isParticipating,
            hasEnded: false
        )
    }
}

extension AppModel {
    /// Every invitation state a channel's transcript needs, resolved once.
    ///
    /// Once per layout rather than once per card: a channel can hold a dozen
    /// invitations for the same app, and each would otherwise sweep the
    /// presence table again for the same answer.
    func activityInviteStates(in channelID: ChannelID) -> [ApplicationID: ActivityInviteState] {
        guard let box = messages(in: channelID) else { return [:] }
        var applications: Set<ApplicationID> = []
        for message in box.messages {
            if let invite = message.activityInvite { applications.insert(invite.applicationID) }
        }
        guard !applications.isEmpty else { return [:] }
        var states: [ApplicationID: ActivityInviteState] = [:]
        for application in applications {
            let invite = ActivityInvite(applicationID: application, name: "")
            if let state = activityInviteState(for: invite, in: channelID) {
                states[application] = state
            }
        }
        return states
    }
}

/// What an invitation card paints, reduced to the two things that change.
///
/// Deliberately not `ActivityInviteState`: the canvas compares this on every
/// update to decide whether to redraw, and comparing a rendered line is both
/// cheaper and exactly right — two different states that read the same do not
/// need a redraw.
struct ActivityInviteStatus: Hashable, Sendable {
    var line: String?
    var isJoined: Bool
}

extension AppModel {
    /// The painted state for every invitation in a channel.
    func activityInviteStatuses(in channelID: ChannelID) -> [ApplicationID: ActivityInviteStatus] {
        activityInviteStates(in: channelID).compactMapValues { state in
            let line = ActivityInviteLayoutEngine.statusLine(state)
            guard line != nil || state.isParticipating else { return nil }
            return ActivityInviteStatus(line: line, isJoined: state.isParticipating)
        }
    }
}

// MARK: - An application's own icon, as the last resort for artwork

extension AppModel {

    /// The icon an application registered, once anything has resolved it.
    ///
    /// **The fallback every activity surface was missing.** Rich presence
    /// artwork is optional — Roblox publishes a name and no `large_image` at
    /// all — and `/games` answers only for titles Discord tracks as games, so
    /// Wordle has neither. Both drew a grey plate with a controller in it
    /// while Discord drew the app's own icon, which it has for every one of
    /// them.
    ///
    /// Read from the directory table the activity shelf already fills, so an
    /// app resolved for one surface is resolved for all of them.
    func applicationIconURL(_ id: ApplicationID?, side: CGFloat) -> URL? {
        guard let id, let hash = activityDirectory.apps[id]?.iconHash else { return nil }
        return CDN.applicationIcon(id: id, hash: hash, side: side)
    }

    /// Asks for any of these applications this client cannot yet name.
    ///
    /// **One request for the lot.** `GET /applications/public?application_ids=…`
    /// takes repeated ids — the reference client sends seventy-two at once —
    /// and a call per row would be a rate-limit slot per row for one strip of
    /// icons.
    ///
    /// Silent on failure: the surfaces that read it already draw a placeholder,
    /// and an activity list is not worth an error banner.
    func resolveApplications(_ ids: [ApplicationID]) {
        let unknown = Set(ids).subtracting(activityDirectory.apps.keys)
            .subtracting(applicationsResolving)
        guard !unknown.isEmpty else { return }
        applicationsResolving.formUnion(unknown)
        sessionController.resolveApplications(Array(unknown))
    }
}

// MARK: - A published activity, as the read side draws it

extension Activity {
    /// What this client publishes, as a card or a member list reads it — the
    /// reader's own mirror and the Activity pane's preview both draw this.
    init(published activity: RichPresenceActivity, sessionID: String?) {
        self.init(
            kind: Activity.Kind(rawValue: activity.type),
            name: activity.name,
            state: activity.state,
            details: activity.details,
            applicationID: activity.applicationID,
            largeImageKey: activity.assets?.largeImage,
            smallImageKey: activity.assets?.smallImage,
            largeText: activity.assets?.largeText,
            smallText: activity.assets?.smallText,
            largeImageURL: activity.assets?.largeURL,
            smallImageURL: activity.assets?.smallURL,
            startedAt: activity.timestamps?.start.map {
                Date(timeIntervalSince1970: Double($0) / 1000)
            },
            endsAt: activity.timestamps?.end.map {
                Date(timeIntervalSince1970: Double($0) / 1000)
            },
            partySize: activity.party?.size,
            sessionID: sessionID,
            buttons: activity.buttons,
            // The line a member list names it by — YouTube Music's song.
            statusDisplay: activity.statusDisplayType.flatMap(Activity.StatusDisplay.init(rawValue:)),
            detailsURL: activity.detailsURL,
            stateURL: activity.stateURL,
            url: activity.url
        )
    }
}
