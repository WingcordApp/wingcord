import AppKit
import Foundation
import WingcordCore

// MARK: - The three pages a server offers beside its channels
//
// Server Guide, Channels & Roles and Game Servers. Each is one route, cached by
// guild for the session, and each is drawn from a plain value built here — the
// panes hold no store reference, exactly like every other surface in this app.
//
// THE ROWS ARE GATED ON THE ANSWER, NOT ON A FEATURE FLAG. A row that opens onto
// "this server has not set one up" is the inert control §5.5 forbids, and none
// of the three has a flag on the guild object that reliably predicts it. So the
// guide and the game servers are asked about once when a server is opened, and
// their rows exist only once something has come back. Channels & Roles is the
// exception and needs no gate: a channel list is something every server has.

/// One per-guild fetch, as a key.
///
/// Its own small value rather than five loading sets: a page asks "is my thing
/// loading" once per body, and one lookup in one set beats five sets that each
/// have to be kept in step with a `defer`.
struct GuildSurfaceFetch: Hashable, Sendable {
    enum Subject: Hashable, Sendable {
        case guide
        case onboarding
        case memberCounts
        case rules
        case gameServers
    }

    var guildID: GuildID
    var subject: Subject
}

/// The connect sheet's subject.
///
/// **A snapshot of the server, not a pointer at the table.** The list can be
/// refetched or the guild switched while somebody has the sheet open, and
/// neither should take the address out from under them mid-copy.
struct GameServerConnectRequest: Hashable, Sendable, Identifiable {
    var server: GameServer
    var id: UInt64 { server.id }
}

/// An agreement in flight, and how it landed.
struct ServerRulesSubmission: Hashable, Sendable {
    enum State: Hashable, Sendable {
        case sending
        case pending
        case rejected(String?)
        case failed(String)

        /// The sentence the sheet shows. Nil while it is simply working — the
        /// button says that on itself.
        var message: String? {
            switch self {
            case .sending:
                nil
            case .pending:
                "Sent. A moderator has to look at it before you are in."
            case .rejected(let reason):
                reason.map { "Not accepted: \($0)" } ?? "Not accepted."
            case .failed(let reason):
                reason
            }
        }

        var isWorking: Bool { self == .sending }
    }

    var guildID: GuildID
    var state: State
}

/// What a row draws in its gutter.
///
/// Three sources for one slot: a server's own emoji, a Unicode glyph sent as a
/// shortcode, or the app's fallback symbol. Resolved once when the page's value
/// is built rather than at each row, so no view has to know that Discord sends
/// `"fire"` where it means 🔥.
enum SurfaceGlyph: Hashable, Sendable {
    case emoji(URL)
    case character(String)
    case symbol(String)
    /// A picture the server uploaded (a guide step's or resource's icon),
    /// drawn filling its well rather than as a small emoji inside it.
    case picture(URL)
}

// MARK: - Presentation values

struct ServerGuidePresentation: Hashable, Sendable {
    var guildID: GuildID
    var name: String
    var iconURL: URL?
    var monogram: String
    var bannerURL: URL?
    var memberCount: Int?
    /// Who is online, where the server's profile has said (`GuildProfile`).
    var onlineCount: Int? = nil
    var mark: GuildMark?
    var welcome: Welcome?
    var actions: [Row]
    var resources: [Row]
    /// Whether the server has rules worth a row of their own.
    var hasRules: Bool
    /// The channel that row leads to, named. Nil when the server keeps its rules
    /// nowhere the reader can go — the row then opens the sheet instead, which
    /// is what the missing destination line says.
    var rulesChannelName: String?
    var rulesChannelSymbolName: String
    /// Whether the reader has joined and not yet agreed.
    var isPendingMember: Bool
    var isLoading: Bool

    /// Whether anything below the header is worth drawing.
    var hasContent: Bool {
        welcome != nil || !actions.isEmpty || !resources.isEmpty || hasRules
    }

    struct Welcome: Hashable, Sendable {
        var authorName: String
        var authorMonogram: String
        var avatarURL: URL?
        /// Drawn as a crown, exactly as the group-DM owner is. It is a fact
        /// about who is speaking and it is why the sentence carries weight.
        var isOwner: Bool
        /// With `[@username]` already replaced by the reader's own name.
        var message: String
    }

    struct Row: Hashable, Sendable, Identifiable {
        var id: Int
        var channelID: ChannelID
        var title: String
        var detail: String?
        var glyph: SurfaceGlyph
        /// The channel this leads to, named. Nil when the reader cannot see it,
        /// which is what makes the row unclickable rather than a link into a
        /// wall.
        var channelName: String?
        var channelSymbolName: String
        /// A Get Started step's state for a new member — a green check or an
        /// empty ring, as Discord's list (`283012`); nil draws neither.
        var isDone: Bool? = nil
    }
}

/// The reader, as this server sees them.
///
/// **It is a preview of the answers, not a report of them.** A role granted by
/// an option the reader has just chosen is in the list before the gateway has
/// said so, because the write is already out and the card's whole promise is
/// "this is how you'll look" — a card that only caught up a round trip later
/// would be answering a different question.
struct GuildSelfPresentation: Hashable, Sendable {
    var name: String
    /// The account's own name, when a nickname is standing in front of it. Both,
    /// because a nickname that silently replaces somebody makes them unfindable
    /// — the same rule the profile card is built on.
    var accountName: String?
    var avatarURL: URL?
    var monogram: String
    var bio: String?
    var roles: [ProfileRole]
}

struct ChannelsAndRolesPresentation: Hashable, Sendable {
    /// **In the value, though no view draws it.** Two servers with the same
    /// (empty) channel list would otherwise compare equal, and `.equatable()`
    /// would stop SwiftUI from ever updating the page across the switch — and
    /// the pane keys its tab reset on this.
    var guildID: GuildID
    /// Nil when the server asks no questions, which is what collapses the page
    /// to its channel list and removes the segmented control entirely.
    var prompts: [Prompt]
    var categories: [BrowseCategory]
    var channelCount: Int
    /// Whether the checkboxes and the Follow switches are offered.
    ///
    /// **Only where the server actually has opt-in channels**, which is what
    /// onboarding being enabled means. A plain server's channel list is not
    /// something anybody opts into, and a checkbox there would be a control
    /// writing a flag with no effect.
    var offersFollowing: Bool
    /// Nil before the account has arrived, which is real during bootstrap.
    var me: GuildSelfPresentation?
    var isLoading: Bool
    var isSaving: Bool

    var asksQuestions: Bool { !prompts.isEmpty }

    struct Prompt: Hashable, Sendable, Identifiable {
        var id: UInt64
        var title: String
        var guidance: String
        var isRequired: Bool
        /// One answer, not several: its options are radios, not checkboxes.
        var isSingleSelect = false
        var options: [Option]
    }

    struct Option: Hashable, Sendable, Identifiable {
        var id: UInt64
        var promptID: UInt64
        var title: String
        var detail: String?
        var glyph: SurfaceGlyph
        var isSelected: Bool
        /// What picking this does, in one line — the roles it grants and the
        /// channels it reveals. Nil when it does neither, which happens.
        var unlocks: String?
        /// The colour of the first role it grants, when that role has one. The
        /// only colour on the chip, and it belongs to the server.
        var roleColorValue: UInt32?
        /// How many people already hold that role.
        var memberCount: Int?
    }

    struct BrowseCategory: Hashable, Sendable, Identifiable {
        var id: UInt64
        /// Nil for the channels that sit above the first category.
        var title: String?
        /// The real category id, for the Follow switch. Nil for the loose rows
        /// above the first category, which belong to no category and therefore
        /// have nothing to follow.
        var channelID: ChannelID?
        /// Whether the reader follows this category — which means "show me
        /// whatever gets added to it", not "show me its channels". They are
        /// independent overrides, and Discord treats them that way.
        var isFollowed: Bool
        var isFollowWorking: Bool
        var channels: [BrowseChannel]
    }

    struct BrowseChannel: Hashable, Sendable, Identifiable {
        var id: ChannelID
        var name: String
        var symbolName: String
        /// The topic, its markup drawn: see `ChannelTopicPreview`.
        var topic: AttributedString?
        /// When something was last said here. From the channel's newest message
        /// id, so it costs no request and cannot disagree with the transcript.
        var lastActivity: Date?
        var isUnread: Bool
        /// Whether the reader has opted into this channel — its own override,
        /// or its category's.
        var isFollowed: Bool
        /// Whether that is its category's doing rather than its own, in which
        /// case the tick is shown and cannot be pressed.
        var isFollowLocked: Bool
        /// Whether a write for it is in flight.
        var isFollowWorking: Bool
        /// `name` and `topic`, folded once, for the search field.
        ///
        /// Built with the row rather than at each keystroke: a five-hundred
        /// channel server otherwise case-folds and allocates two strings per row
        /// per character typed.
        var searchKey: String

        func matches(_ folded: String) -> Bool {
            folded.isEmpty || searchKey.contains(folded)
        }
    }
}

/// The rules sheet.
struct ServerRulesPresentation: Hashable, Sendable {
    var guildID: GuildID
    var serverName: String
    var detail: String?
    var rules: [String]
    /// Whether an agreement can be sent from here at all.
    var canAgree: Bool
    var isWorking: Bool
    /// What happened to the last one, in the reader's words.
    var outcomeMessage: String?
}

struct GameServersPresentation: Hashable, Sendable {
    /// In the value for the same reason the channel page's is: without it two
    /// servers that rent nothing compare equal, and the pane never updates
    /// across the switch.
    var guildID: GuildID
    /// The domain values, unwrapped. Everything a card draws is already on
    /// them — the address, the status's word, the game line — so a second
    /// projection would be a copy with nothing added.
    var servers: [GameServer]
    /// Each server's game, resolved for drawing — its name and box art — by
    /// application id. Absent until `/games` answers, and for a server that
    /// names no game: its card keeps the plate.
    var games: [ApplicationID: BoardGame] = [:]
    var isLoading: Bool
}

// MARK: - Projections

extension AppModel {

    /// What the sidebar is pointing at.
    ///
    /// One value, so a channel and a server page cannot both be lit.
    var sidebarTarget: SidebarTarget {
        if isFriendsShown { return .friends }
        if isMessageRequestsShown { return .messageRequests }
        if let openGuildSurface { return .surface(openGuildSurface) }
        if let selectedChannelID { return .channel(selectedChannelID) }
        return .none
    }

    /// Opens one of a server's own pages, from that server's channel list.
    ///
    /// **The list says which server, and that server is selected first.** The
    /// sidebar's Servers page keeps the last server's channels on it after the
    /// reader has gone Home — the Messages and Servers switch only moves the
    /// pages — so its rows can be clicked while no server is selected at all.
    /// A server page is drawn only for the selected server, and a row clicked
    /// from that state lit up and opened nothing: Alex's "I can select them in
    /// the channel list, but nothing happens".
    func openSurface(_ surface: GuildSurface, inGuild guildID: GuildID?) {
        if let guildID, guildID != selectedGuildID { selectGuild(guildID) }
        openSurface(surface)
    }

    /// Opens one of the server's own pages.
    func openSurface(_ surface: GuildSurface) {
        guard openGuildSurface != surface else { return }
        if surface == .members, let guildID = selectedGuildID {
            prepareMemberSafety(for: guildID)
        }
        openGuildSurface = surface
        // A preview belongs to the page that raised it, so moving to another
        // page takes it away rather than leaving somebody else's resource open
        // beside the game servers.
        previewedChannelID = nil
        // Every card raised from a transcript is dismissed on the way out: they
        // are anchored to rects in a view that is about to be replaced.
        profileRequest = nil
        expressionInfoRequest = nil
        // The page's bar has no inbox for the flyout to hang from.
        closeInbox()
    }

    /// Opens a channel *beside* the page rather than instead of it.
    ///
    /// The permission check is the same one every other way into a channel
    /// takes: a guide can name a channel the reader may not see, and a preview
    /// that opened onto a refusal is the inert control §5.5 forbids — which is
    /// why the row that raises this is not a button at all in that case.
    func previewChannel(_ channelID: ChannelID) {
        guard canOpen(channelID) else { return }
        // **A forum opens; it is not previewed** (Alex, 2026-11-18: the column
        // stood empty). Its posts are a board, not a transcript, and the
        // column has only a transcript to show.
        if channelIndex[channelID]?.isForumLike == true {
            previewedChannelID = nil
            selectChannel(channelID)
            return
        }
        // A second click on the row you are already previewing closes it, which
        // is what every disclosure in this app does.
        guard previewedChannelID != channelID else {
            previewedChannelID = nil
            return
        }
        previewedChannelID = channelID
    }

    func closeChannelPreview() {
        guard previewedChannelID != nil else { return }
        previewedChannelID = nil
    }

    /// The preview column's header.
    func channelPreviewChrome(for channelID: ChannelID) -> ChannelPreviewChrome {
        let channel = channelIndex[channelID]
        return ChannelPreviewChrome(
            channelID: channelID,
            name: channel.map(displayName(of:)) ?? "Channel",
            symbolName: channel?.kind.symbolName ?? "number",
            topic: channel?.topic.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// **Discord's own test for a Server Guide**: a Community server with both
    /// the guide and onboarding switched on (`!features.has(COMMUNITY) ||
    /// !features.has(GUILD_SERVER_GUIDE) || !features.has(GUILD_ONBOARDING)`
    /// rules it out). Known from the server itself, so the row is never drawn
    /// for a server without one — it used to be, until the guide's route came
    /// back and took it away again (Alex, 2026-11-18: "the server guide
    /// disappears after some time").
    func offersServerGuide(_ guildID: GuildID) -> Bool {
        guard let features = guilds[guildID]?.features,
              features.isSuperset(of: ["COMMUNITY", "GUILD_SERVER_GUIDE", "GUILD_ONBOARDING"])
        else { return false }
        // **And only for a newcomer who has not finished it** — Discord's
        // second test (`111487`'s neighbour): a server being previewed, or a
        // member who joined under a week ago with COMPLETED_HOME_ACTIONS unset.
        // Finished, or a member for longer, and the row is gone (Alex,
        // 2026-11-18: "after you finish the server guide it disappears").
        if isPreviewing(guildID) { return true }
        guard let me = currentUserID, let member = members[guildID]?[me], let joined = member.joinedAt
        else { return false }
        return !member.flags.contains(.completedHomeActions)
            && Date.now.timeIntervalSince(joined) < 7 * 24 * 60 * 60
    }

    /// The rows above the first category, in the order the server offers them.
    ///
    /// Called by the sidebar builder. The guide and the game servers appear only
    /// once their route has answered with something; the channel list's own row
    /// is always there and takes the name the answer earns.
    func guildSurfaceRows(for guildID: GuildID) -> [GuildSurface] {
        var rows: [GuildSurface] = []
        // **First**, as Discord puts it: the hub is the server's front page.
        if offersServerHub(guildID) {
            rows.append(.serverHub)
        }
        if offersServerGuide(guildID), let guide = serverGuides[guildID], guide.isEnabled, !guide.isEmpty {
            rows.append(.serverGuide)
        }
        // "Channels & Roles" only once there are questions to answer. Until the
        // route answers, the honest name is the one that is always true.
        let asksQuestions = guildOnboardings[guildID]?.answerablePrompts.isEmpty == false
        rows.append(asksQuestions ? .channelsAndRoles : .browseChannels)
        // Discord's order: after the channel browser, before the game servers.
        if let guild = guilds[guildID],
           ModerationPolicy.showsMembersRow(permissionGate.permissions(inGuild: guildID), features: guild.features)
        {
            rows.append(.members)
        }
        if gameServers[guildID]?.isEmpty == false {
            rows.append(.gameServers)
        }
        return rows
    }

    // MARK: Server Guide

    var serverGuidePresentation: ServerGuidePresentation? {
        guard let guildID = selectedGuildID, let guild = guilds[guildID] else { return nil }
        let guide = serverGuides[guildID]

        var actions: [ServerGuidePresentation.Row] = []
        actions.reserveCapacity(guide?.actions.count ?? 0)
        let tracksProgress = pendingGuideSteps(in: guildID) != nil
        for action in guide?.actions ?? [] {
            actions.append(ServerGuidePresentation.Row(
                id: action.id,
                channelID: action.channelID,
                title: action.title,
                detail: action.detail,
                // Discord's order (`283012`): the uploaded picture, then the
                // emoji, then the channel's own symbol.
                glyph: action.iconHash
                    .flatMap { CDN.guideIcon(kind: .step, channelID: action.channelID, hash: $0) }
                    .map(SurfaceGlyph.picture)
                    ?? glyph(
                        emojiID: action.emojiID,
                        emojiName: action.emojiName,
                        isAnimated: action.isEmojiAnimated,
                        fallback: channelIndex[action.channelID]?.kind.symbolName
                            ?? (action.kind == .write ? "bubble.left.and.pencil" : "book")
                    ),
                channelName: readableChannelName(action.channelID),
                channelSymbolName: channelIndex[action.channelID]?.kind.symbolName ?? "number",
                isDone: tracksProgress ? isGuideStepDone(action.channelID, in: guildID) : nil
            ))
        }

        var resources: [ServerGuidePresentation.Row] = []
        resources.reserveCapacity(guide?.resources.count ?? 0)
        for resource in guide?.resources ?? [] {
            resources.append(ServerGuidePresentation.Row(
                id: resource.id,
                channelID: resource.channelID,
                title: resource.title,
                detail: resource.detail,
                // The uploaded picture (Rockstar's R★), then an emoji, then
                // the first picture in the channel's first message, then a
                // page — Discord's order (`452849`), never a bare "#".
                glyph: resourceGlyph(resource),
                channelName: readableChannelName(resource.channelID),
                channelSymbolName: channelIndex[resource.channelID]?.kind.symbolName ?? "number"
            ))
        }

        return ServerGuidePresentation(
            guildID: guildID,
            name: guild.name,
            iconURL: guild.iconHash.flatMap {
                CDN.guildIcon(guildID: guildID, hash: $0, side: Metrics.avatarProfile)
            },
            monogram: guild.monogram,
            bannerURL: guild.bannerHash.flatMap {
                CDN.guildBanner(guildID: guildID, hash: $0, width: 720)
            },
            memberCount: guild.memberCount,
            onlineCount: guildProfiles[guild.id]?.onlineCount,
            mark: guild.mark,
            welcome: welcomePresentation(guide?.welcome, ownerID: guild.ownerID),
            actions: actions,
            resources: resources,
            hasRules: memberVerifications[guildID]?.isEmpty == false,
            // **No destination while the reader still has to agree**, because
            // the row does not go there for them — it opens the agreement. A
            // line naming a channel the press will not take you to is the row
            // lying about itself, which is worse than saying nothing.
            rulesChannelName: isPendingMember(inGuild: guildID)
                ? nil
                : guild.rulesChannelID.flatMap(readableChannelName),
            rulesChannelSymbolName: guild.rulesChannelID
                .flatMap { channelIndex[$0]?.kind.symbolName } ?? "checkmark.seal",
            isPendingMember: isPendingMember(inGuild: guildID),
            isLoading: guide == nil
                && loadingGuildSurfaces.contains(
                    GuildSurfaceFetch(guildID: guildID, subject: .guide)
                )
        )
    }

    private func welcomePresentation(
        _ welcome: ServerGuide.Welcome?,
        ownerID: UserID
    ) -> ServerGuidePresentation.Welcome? {
        guard let welcome else { return nil }
        let author = welcome.authorID.flatMap { users[$0] }
        // The reader's own name, which is what the placeholder is for. Falling
        // back to the bare word rather than to a blank keeps the sentence
        // grammatical for an account whose name has not arrived yet.
        let readerName = currentUserID.flatMap { users[$0]?.preferredName } ?? "you"
        return ServerGuidePresentation.Welcome(
            authorName: author?.preferredName ?? "The server",
            authorMonogram: author?.monogram ?? "?",
            avatarURL: author.flatMap { avatarURL(for: $0, side: Metrics.avatarRow) },
            isOwner: welcome.authorID == ownerID,
            message: welcome.substituting(readerName)
        )
    }

    // MARK: Channels & Roles

    /// The page behind Channels & Roles, memoized.
    ///
    /// **The key deliberately omits the message revision**, which is the counter
    /// that moves when a channel's newest message does. The only thing it would
    /// change on this page is the "Active 3 hours ago" line, and keying on it
    /// would rebuild a projection over every channel in the server several times
    /// a second on a busy account to move a relative timestamp nobody is
    /// watching. The staleness is bounded by how long the page is open, which is
    /// the same trade `ChannelIndex.patchLastMessage` already makes.
    var channelsAndRolesPresentation: ChannelsAndRolesPresentation? {
        // The guild is read rather than merely tested: a page for a server that
        // has not arrived yet is a page with no channels, and the read is what
        // registers the dependency that brings it back when it does.
        guard let guildID = selectedGuildID, guilds[guildID] != nil else { return nil }

        let onboarding = guildOnboardings[guildID]
        let key = GuildSurfaceMemoKey(
            guildID: guildID,
            structureRevision: channelIndex.structureRevision,
            roleRevision: roleRevision,
            identityRevision: identityRevision,
            // The browse rows bold an unread channel, which is read state. In
            // the KEY *and* read before the cache: a memo that consults its
            // cache first registers no observation dependency, so the page
            // would neither notice the change nor be re-evaluated by it.
            sidebarRevision: sidebarRevision &+ readRevision,
            // The profile aside draws the reader's own roles, so a role landing
            // has to rebuild the page. `memberRevision` is the counter that
            // moves when a member record does.
            memberRevision: memberRevision,
            // One integer rather than two sets. The sets are read by every row
            // on the page and by the channel list beside it; hashing a few
            // hundred ids per evaluation is what the revision exists to avoid.
            followRevision: followRevision,
            responses: onboarding?.responses ?? [],
            promptCount: onboarding?.prompts.count ?? 0,
            // **Whether onboarding is on, not only how many questions it
            // asks.** A server can enable it with no prompts, and that is
            // exactly the state that turns the follow controls on while leaving
            // the count at zero — keyed on the count alone the page keeps the
            // answer from before the route replied.
            isOnboardingEnabled: onboarding?.isEnabled ?? false,
            memberCountsCount: roleMemberCounts[guildID]?.count ?? 0,
            isLoading: loadingGuildSurfaces.contains(
                GuildSurfaceFetch(guildID: guildID, subject: .onboarding)
            ),
            isSaving: savingOnboardingGuilds.contains(guildID)
        )
        // Read before the cache is consulted, so a hit still registers the
        // dependency its reader needs.
        let roleTable = roles[guildID] ?? [:]
        let counts = roleMemberCounts[guildID] ?? [:]
        // The reader's own bio arrives on the profile route long after the page
        // is built. Nothing extra is needed for it: `loadProfile` bumps
        // `identityRevision` when the record actually changes, and that is
        // already in the key above.

        if let channelsAndRolesCache, channelsAndRolesCache.key == key {
            return channelsAndRolesCache.value
        }

        let categories = buildBrowseCategories(inGuild: guildID)
        let value = ChannelsAndRolesPresentation(
            guildID: guildID,
            prompts: buildPrompts(onboarding, roles: roleTable, counts: counts),
            categories: categories,
            // Counted off the list itself, so the badge cannot disagree with
            // what is drawn under it.
            channelCount: categories.reduce(0) { $0 + $1.channels.count },
            offersFollowing: onboarding?.isEnabled == true,
            me: buildSelf(inGuild: guildID, onboarding: onboarding, roles: roleTable),
            isLoading: key.isLoading,
            isSaving: key.isSaving
        )
        channelsAndRolesCache = (key, value)
        return value
    }

    private func buildPrompts(
        _ onboarding: GuildOnboarding?,
        roles roleTable: [RoleID: Role],
        counts: [RoleID: Int]
    ) -> [ChannelsAndRolesPresentation.Prompt] {
        guard let onboarding, onboarding.isEnabled else { return [] }
        var prompts: [ChannelsAndRolesPresentation.Prompt] = []
        prompts.reserveCapacity(onboarding.prompts.count)

        for prompt in onboarding.answerablePrompts {
            var options: [ChannelsAndRolesPresentation.Option] = []
            options.reserveCapacity(prompt.options.count)
            for option in prompt.options {
                let role = option.roleIDs.first.flatMap { roleTable[$0] }
                options.append(ChannelsAndRolesPresentation.Option(
                    id: option.id,
                    promptID: prompt.id,
                    title: option.title,
                    detail: option.detail,
                    glyph: glyph(
                        emojiID: option.emojiID,
                        emojiName: option.emojiName,
                        isAnimated: option.isEmojiAnimated,
                        fallback: option.roleIDs.isEmpty ? "number" : "person.fill"
                    ),
                    isSelected: onboarding.responses.contains(option.id),
                    unlocks: unlockSentence(for: option, roles: roleTable),
                    roleColorValue: role?.displayColorValue,
                    memberCount: option.roleIDs.first.flatMap { counts[$0] }
                ))
            }
            prompts.append(ChannelsAndRolesPresentation.Prompt(
                id: prompt.id,
                title: prompt.title,
                guidance: prompt.guidance,
                isRequired: prompt.isRequired,
                isSingleSelect: prompt.isSingleSelect,
                options: options
            ))
        }
        return prompts
    }

    /// The reader as this server sees them, with the answers already applied.
    ///
    /// Two sources for one list. The roles they **hold** come from the member
    /// record, which the gateway maintains; the roles their current answers
    /// **grant** come from the onboarding payload, and are added on top because
    /// the write that grants them is already out. Merged rather than
    /// concatenated — an option can grant a role somebody already has, and
    /// naming it twice is the card contradicting itself.
    private func buildSelf(
        inGuild guildID: GuildID,
        onboarding: GuildOnboarding?,
        roles roleTable: [RoleID: Role]
    ) -> GuildSelfPresentation? {
        guard let userID = currentUserID, let user = users[userID] else { return nil }
        let member = members[guildID]?[userID]

        var held = Set(member?.roleIDs ?? [])
        for prompt in onboarding?.prompts ?? [] {
            for option in prompt.options where onboarding?.responses.contains(option.id) == true {
                held.formUnion(option.roleIDs)
            }
        }

        let resolved = held
            .compactMap { roleTable[$0] }
            // `@everyone` is on every member and says nothing. Discord hides it
            // too, and a list whose first entry is always the same one trains
            // the eye to skip the list.
            .filter { $0.id.rawValue != guildID.rawValue }
            .sorted(by: Role.seniorityOrder)
            .map { ProfileRole(id: $0.id, name: $0.name, colorValue: $0.displayColorValue) }

        let nickname = member?.nickname.flatMap { $0.isEmpty ? nil : $0 }
        return GuildSelfPresentation(
            name: nickname ?? user.preferredName,
            accountName: nickname == nil ? nil : user.preferredName,
            avatarURL: avatarURL(forUserID: userID, inGuild: guildID, side: Metrics.avatarProfile),
            monogram: user.monogram,
            bio: user.decoration?.bio.flatMap { $0.isEmpty ? nil : $0 },
            roles: resolved
        )
    }

    /// What picking an option actually does, in one line.
    ///
    /// The roles by name, because a role is a thing the reader will see beside
    /// their own name afterwards; the channels by count, because listing six
    /// channel names is a paragraph inside a chip. A role the store has not
    /// seen is dropped rather than drawn as its id.
    private func unlockSentence(
        for option: GuildOnboarding.Option,
        roles roleTable: [RoleID: Role]
    ) -> String? {
        var parts: [String] = []
        let names = option.roleIDs.compactMap { roleTable[$0]?.name }
        if !names.isEmpty { parts.append(names.joined(separator: ", ")) }
        if !option.channelIDs.isEmpty {
            parts.append(option.channelIDs.count == 1
                ? "1 channel"
                : "\(option.channelIDs.count) channels")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Every channel in the server the reader can see, grouped by category.
    ///
    /// **The same permission filter as the sidebar's, and for the same reason**:
    /// a channel the reader cannot view does not exist. A browse list that
    /// showed them would be a list of doors that do not open — and clicking one
    /// would be stopped by `canOpen` anyway, which is the inert control §5.5
    /// forbids.
    ///
    /// Unlike the sidebar's list this ignores collapsed categories and never
    /// drops a category for being empty of *unread* — it is a table of contents
    /// for the whole server, which is the one thing the sidebar is not.
    private func buildBrowseCategories(
        inGuild guildID: GuildID
    ) -> [ChannelsAndRolesPresentation.BrowseCategory] {
        let channelIDs = channelIndex.channelIDs(inGuild: guildID)
        var byParent: [ChannelID?: [Channel]] = [:]
        var categories: [Channel] = []

        for channelID in channelIDs {
            guard let channel = channelIndex[channelID] else { continue }
            if channel.kind == .category {
                categories.append(channel)
            } else if channel.kind.isConversation
                || channel.kind == .forum
                || channel.kind == .media
            {
                guard permissionGate.canView(channel.id) else { continue }
                byParent[channel.parentID, default: []].append(channel)
            }
        }

        var result: [ChannelsAndRolesPresentation.BrowseCategory] = []
        result.reserveCapacity(categories.count + 1)
        // One table for every topic on the page, memoized on what it names.
        let mentions = mentionContextWithoutPeople(guildID: guildID)
        let guildMembers = members[guildID]
        let browseChannel = { (channel: Channel) in
            self.browseChannel(channel, mentions: mentions) { userID in
                guard let user = self.users[userID] else { return nil }
                return guildMembers?[userID]?.nickname ?? user.preferredName
            }
        }

        if let loose = byParent[nil], !loose.isEmpty {
            result.append(ChannelsAndRolesPresentation.BrowseCategory(
                id: 0,
                title: nil,
                channelID: nil,
                isFollowed: false,
                isFollowWorking: false,
                channels: loose.map(browseChannel)
            ))
        }
        for category in categories {
            guard let children = byParent[category.id], !children.isEmpty else { continue }
            result.append(ChannelsAndRolesPresentation.BrowseCategory(
                id: category.id.rawValue,
                title: category.name,
                channelID: category.id,
                isFollowed: followedChannelIDs.contains(category.id),
                isFollowWorking: followsInFlight.contains(category.id),
                channels: children.map(browseChannel)
            ))
        }
        return result
    }

    private func browseChannel(
        _ channel: Channel,
        mentions: MentionContext,
        userName: @escaping (UserID) -> String?
    ) -> ChannelsAndRolesPresentation.BrowseChannel {
        let topic = channel.topic.flatMap { $0.isEmpty ? nil : $0 }
        var key = channel.name.lowercased()
        if let topic {
            key.append(" ")
            key.append(topic.lowercased())
        }
        return ChannelsAndRolesPresentation.BrowseChannel(
            id: channel.id,
            name: channel.name,
            symbolName: channel.kind.symbolName,
            topic: topic.map { ChannelTopicPreview.attributed($0, mentions: mentions, userName: userName) },
            // The snowflake already carries the millisecond, so "active three
            // hours ago" costs no request and cannot disagree with the
            // transcript.
            lastActivity: channel.lastMessageID?.timestamp,
            isUnread: unreadState(of: channel).unread,
            isFollowed: isChannelFollowed(channel),
            isFollowLocked: isFollowLockedByCategory(channel),
            isFollowWorking: followsInFlight.contains(channel.id),
            searchKey: key
        )
    }

    // MARK: Game Servers

    var gameServersPresentation: GameServersPresentation? {
        guard let guildID = selectedGuildID else { return nil }
        let servers = gameServers[guildID] ?? []
        var resolved: [ApplicationID: BoardGame] = [:]
        for id in Set(servers.compactMap(\.gameID)) {
            guard let game = games[id] else { continue }
            resolved[id] = BoardGame(
                gameID: id,
                name: game.name,
                coverURL: gameArtURL(game, kind: .cover, side: GameServerArt.width * 2),
                isCoverArt: gameArtIsCover(game, kind: .cover),
                tags: []
            )
        }
        return GameServersPresentation(
            guildID: guildID,
            servers: servers,
            games: resolved,
            isLoading: gameServers[guildID] == nil
                && loadingGuildSurfaces.contains(
                    GuildSurfaceFetch(guildID: guildID, subject: .gameServers)
                )
        )
    }

    /// The rules sheet's contents.
    var serverRulesPresentation: ServerRulesPresentation? {
        guard let guildID = serverRulesGuildID,
              let rules = memberVerifications[guildID], !rules.isEmpty
        else { return nil }
        let submission = serverRulesSubmission.flatMap {
            $0.guildID == guildID ? $0.state : nil
        }
        return ServerRulesPresentation(
            guildID: guildID,
            serverName: guilds[guildID]?.name ?? "This server",
            detail: rules.detail,
            rules: rules.rules,
            // **The button exists only where it can work.** Somebody who has
            // already agreed is in — offering them a second agreement is a
            // control with nothing behind it — and a payload with no version has
            // nothing to record an agreement against.
            canAgree: rules.canSubmit
                && isPendingMember(inGuild: guildID)
                && submission?.isWorking != true,
            isWorking: submission?.isWorking ?? false,
            outcomeMessage: submission?.message
        )
    }

    /// Whether the reader has joined this server but not yet agreed to its
    /// rules.
    ///
    /// **Absent means agreed.** READY carries the reader's own member record for
    /// every guild, so a missing one is a guild still arriving rather than a
    /// gate — and defaulting the other way would put a rules banner on every
    /// server for the first second of every launch.
    func isPendingMember(inGuild guildID: GuildID) -> Bool {
        guard let userID = currentUserID else { return false }
        return members[guildID]?[userID]?.isPending ?? false
    }

    /// Sends the agreement.
    func agreeToServerRules() {
        guard let guildID = serverRulesGuildID,
              let rules = memberVerifications[guildID], rules.canSubmit
        else { return }
        // Questions too: the whole form is answered in the application.
        if rules.asksQuestions {
            serverRulesGuildID = nil
            openJoinApplication(guildID)
            return
        }
        sessionController.agreeToRules(rules, inGuild: guildID)
    }

    /// Where "Read the rules" goes.
    ///
    /// The channel when the server has one, which is what the row is for and
    /// what every other client does. The sheet is the fallback for a server with
    /// rules and no channel to read them in — the text is already in hand, and a
    /// row that led nowhere would be worse than either.
    func openServerRules(inGuild guildID: GuildID) {
        // **A reader who still has to agree gets the sheet, not the channel.**
        // The channel is where the rules are written; the sheet is where they
        // can be accepted, and sending somebody to read something when the thing
        // they need is a button is the row leading past its own point.
        if !isPendingMember(inGuild: guildID),
           let channelID = guilds[guildID]?.rulesChannelID,
           canOpen(channelID)
        {
            selectChannel(channelID)
            return
        }
        serverRulesGuildID = guildID
    }

    // MARK: Actions

    /// Records an answer, optimistically.
    ///
    /// **The local set moves first and the route follows**, because the whole
    /// point of a chip is that it responds on the press — a selection that waits
    /// for a round trip reads as a control that did not take the click. The
    /// server's answer replaces it when it lands, which is also how an option it
    /// refuses comes back off.
    func toggleOnboardingOption(_ optionID: UInt64, inPrompt promptID: UInt64) {
        guard let guildID = selectedGuildID,
              var onboarding = guildOnboardings[guildID],
              let prompt = onboarding.prompts.first(where: { $0.id == promptID })
        else { return }

        let next = onboarding.responses(togglingOption: optionID, inPrompt: prompt)
        guard next != onboarding.responses else { return }
        onboarding.responses = next
        guildOnboardings[guildID] = onboarding
        sessionController.saveOnboardingResponses(next, inGuild: guildID)
    }

    /// Opens a channel one of these pages pointed at.
    ///
    /// Goes through `selectChannel`, so the permission check, the remembered
    /// conversation and the history fetch all happen exactly as they do from the
    /// sidebar — and leaving the page is what selecting a channel means.
    func openChannelFromSurface(_ channelID: ChannelID) {
        guard canOpen(channelID) else { return }
        selectChannel(channelID)
    }

    /// Hands a link this app did not compose to the browser.
    ///
    /// **The scheme is re-checked here**, at the boundary, for the reason §5.5
    /// gives: a game server's control panel is a URL the hosting provider chose,
    /// and the decoder that built it is not the thing that should be trusted to
    /// have refused a `file:` or a `javascript:`.
    func openExternal(_ url: URL) {
        guard InlineScannerSchemeCheck.isSafe(url.absoluteString) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Following
    //
    // ONE PREDICATE, READ IN THREE PLACES: the browse row's tick, the channel
    // list, and the rail's unread badge. A second copy of "is this channel
    // followed" is a second place for the category rule to be forgotten, and the
    // failure is a channel that is ticked on one surface and missing from
    // another.

    /// Whether the reader has opted into this channel.
    ///
    /// **A followed category carries its channels.** Following a category is
    /// "show me this section", so every channel in it is in — which is why the
    /// browse list draws those ticks locked rather than merely ticked: the
    /// channel's own override is not what is deciding, and a control that looks
    /// like it decides is one nobody can predict.
    func isChannelFollowed(_ channel: Channel) -> Bool {
        if followedChannelIDs.contains(channel.id) { return true }
        guard let parentID = channel.parentID else { return false }
        return followedChannelIDs.contains(parentID)
    }

    /// Whether a channel's own tick is decided by its category rather than by
    /// itself.
    func isFollowLockedByCategory(_ channel: Channel) -> Bool {
        guard let parentID = channel.parentID else { return false }
        return followedChannelIDs.contains(parentID)
    }

    /// Whether this server's channel list is filtered by what the reader
    /// follows at all.
    ///
    /// **The reader's own switch decides, as it does in Discord.** Its settings
    /// store answers `isOptInEnabled` from one bit of the reader's guild
    /// settings, `OPT_IN_CHANNELS_ON` — the bit the menu's *Show All Channels*
    /// clears — and nothing about the server. This used to filter any server
    /// with onboarding in which the reader followed anything, which is most
    /// members of most onboarding servers: Discord opts members who joined
    /// before onboarding into their default channels without turning the
    /// filter on, so they saw one or two channels of a whole server (#8,
    /// WC-6RZS), and an owner lost every private category. And it read the
    /// onboarding, which is loaded only when a server is opened, so a hidden
    /// channel lit its server's dot until then (#16). The bit comes with READY
    /// for every server.
    ///
    /// **The second condition is the safety net.** A reader who turned the
    /// filter on and follows nothing in the server has an unknown state rather
    /// than an empty one — Discord onboards such a member into everything — so
    /// the list is never narrowed to nothing.
    ///
    /// **Only followed channels the reader can see count.** Settings outlive
    /// a membership: he left a server and joined again, his follows from before
    /// were all channels now hidden from him, and the filter took everything he
    /// could see out of the list (his image 242, 2026-11-19).
    func hidesUnfollowedChannels(inGuild guildID: GuildID) -> Bool {
        let gate = permissionGate
        return Self.hidesUnfollowedChannels(
            inGuild: guildID,
            settings: guildUserSettings,
            followed: followedChannelIDs,
            index: channelIndex,
            canView: { gate.canView($0) }
        )
    }

    static func hidesUnfollowedChannels(
        inGuild guildID: GuildID,
        settings: [GuildID: GuildUserSettings],
        followed: Set<ChannelID>,
        index: ChannelIndex,
        canView: (ChannelID) -> Bool = { _ in true }
    ) -> Bool {
        guard let flags = settings[guildID]?.flags,
              flags & GuildUserSettingsFlags.optInChannelsOn != 0
        else { return false }
        guard !followed.isEmpty else { return false }
        return index.channelIDs(inGuild: guildID).contains { followed.contains($0) && canView($0) }
    }

    /// Whether a channel belongs in the sidebar.
    ///
    /// The selected one always does. Browse Channels can open a channel the
    /// reader has opted out of, and a list with nothing lit while its transcript
    /// is on screen reads as the selection having been lost.
    ///
    /// **And the ones Discord keeps in an opted-in list** (its channel list
    /// store, `eN`): a channel that mentions the reader, and a voice channel
    /// somebody is in — a room with people talking in it is not something the
    /// reader opted out of knowing about.
    func isChannelInList(_ channel: Channel, filtered: Bool) -> Bool {
        guard filtered else { return true }
        if isChannelFollowed(channel) || channel.id == selectedChannelID { return true }
        if (readStates[channel.id]?.mentionCount ?? 0) > 0 { return true }
        guard channel.kind == .voice || channel.kind == .stage else { return false }
        return voiceStates.values.contains { $0.channelID == channel.id }
    }

    static func isChannelInList(
        _ channel: Channel,
        filtered: Bool,
        followed: Set<ChannelID>,
        selected: ChannelID?,
        mentions: Int = 0
    ) -> Bool {
        guard filtered else { return true }
        if followed.contains(channel.id) || channel.id == selected || mentions > 0 { return true }
        guard let parentID = channel.parentID else { return false }
        return followed.contains(parentID)
    }

    /// Follows or unfollows one channel or category from the browse list.
    ///
    /// The guild comes from the store rather than from the row: a page only ever
    /// lists one server's channels, and passing it down would be a second place
    /// for the two to disagree.
    func toggleChannelFollowed(_ channelID: ChannelID) {
        guard let guildID = selectedGuildID else { return }
        sessionController.setChannelFollowed(
            !followedChannelIDs.contains(channelID),
            channelID: channelID,
            inGuild: guildID
        )
    }

    func openGameServerConnect(_ server: GameServer) {
        gameServerConnect = GameServerConnectRequest(server: server)
        sessionController.loadGameServerProduct(sku: server.skuID)
    }

    /// The steps for the sheet that is open, if they have arrived.
    var gameServerInstructions: [String] {
        guard let sku = gameServerConnect?.server.skuID else { return [] }
        return gameServerProducts[sku]?.instructions ?? []
    }

    // MARK: Glyphs

    /// Resolves the three ways one of these payloads can name a picture.
    ///
    /// A custom emoji takes its CDN rung; a Unicode one arrives as a
    /// **shortcode** — `"fire"`, not 🔥 — and goes through the generated table;
    /// anything else falls back to a symbol the app chose. Done once here rather
    /// than at each row, so no view has to know about the shortcode form.
    func glyph(
        emojiID: EmojiID?,
        emojiName: String?,
        isAnimated: Bool,
        fallback: String
    ) -> SurfaceGlyph {
        if let emojiID,
           let url = CDN.emoji(id: emojiID, animated: isAnimated, side: Metrics.inlineEmojiSide)
        {
            return .emoji(url)
        }
        if let emojiName, !emojiName.isEmpty {
            // Discord sends the glyph itself on an onboarding option and a
            // shortcode on a guild trait, so both forms have to be accepted.
            if let glyph = UnicodeEmoji.glyph(for: emojiName) { return .character(glyph) }
            if emojiName.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) {
                return .character(emojiName)
            }
        }
        return .symbol(fallback)
    }

    /// A channel's name, only if the reader may go there.
    private func readableChannelName(_ channelID: ChannelID) -> String? {
        guard let channel = channelIndex[channelID], permissionGate.canView(channelID) else {
            return nil
        }
        return channel.name
    }
}

/// The memo key for the Channels & Roles page. See the note on the projection
/// for why the message revision is deliberately not in it.
struct GuildSurfaceMemoKey: Hashable, Sendable {
    var guildID: GuildID
    var structureRevision: UInt64
    var roleRevision: UInt64
    var identityRevision: UInt64
    var sidebarRevision: UInt64
    var memberRevision: UInt64
    var followRevision: UInt64
    var responses: Set<UInt64>
    var promptCount: Int
    var isOnboardingEnabled: Bool
    var memberCountsCount: Int
    var isLoading: Bool
    var isSaving: Bool
}

// MARK: - Server Guide pictures

extension AppModel {
    /// A resource's picture, in Discord's order (`452849`): the one the server
    /// uploaded, then its emoji, then the first picture in the channel's first
    /// message, then a page — never a bare "#".
    func resourceGlyph(_ resource: ServerGuide.Resource) -> SurfaceGlyph {
        if let hash = resource.iconHash,
           let url = CDN.guideIcon(kind: .resource, channelID: resource.channelID, hash: hash)
        {
            return .picture(url)
        }
        if resource.emojiID != nil || resource.emojiName != nil {
            return glyph(
                emojiID: resource.emojiID,
                emojiName: resource.emojiName,
                isAnimated: resource.isEmojiAnimated,
                fallback: "doc.text"
            )
        }
        if let url = guideFirstPictures[resource.channelID] { return .picture(url) }
        return .symbol("doc.text")
    }

    /// The first picture a message carries: an image file, then an embed's
    /// image or thumbnail.
    nonisolated static func firstPicture(in message: Message) -> URL? {
        if let image = message.attachments.first(where: \.isImage) {
            return URL(string: image.proxyURL.isEmpty ? image.url : image.proxyURL)
        }
        for embed in message.embeds {
            if let media = embed.image ?? embed.thumbnail {
                return URL(string: media.proxyURL ?? media.url)
            }
        }
        return nil
    }
}

