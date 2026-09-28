import Foundation

// MARK: - The three surfaces a server offers beside its channels
//
// Server Guide, Channels & Roles, and Game Servers. Each is answered by one
// route, none of them is on READY, and all three describe the *server* rather
// than any conversation in it — which is why they are one file: they share a
// lifetime (fetched per guild, cached for the session) and a shape (a value the
// pane draws and nothing mutates but its own route).
//
// Everything here is decoded from a captured response rather than from
// documentation. Where a field's meaning was not obvious from one capture it is
// named as unknown and dropped, because a decoder that guesses does not fail —
// it yields plausible nonsense.

// MARK: - Server Guide

/// `GET /guilds/{id}/new-member-welcome` — the page a server shows somebody who
/// has just arrived.
///
/// Three parts, and a server can have any subset: a sentence from a person
/// (usually the owner), a short list of first things to do, and a list of
/// channels worth reading. The Counter-Strike capture has a welcome message and
/// four actions and **no resources**; Orbit Hub has all three.
public struct ServerGuide: Hashable, Sendable {
    public var guildID: GuildID
    /// Whether the server has actually turned this on. A server can carry the
    /// route and answer `false`, which is not the same as an empty guide.
    public var isEnabled: Bool
    public var welcome: Welcome?
    public var actions: [Action]
    public var resources: [Resource]

    public init(
        guildID: GuildID,
        isEnabled: Bool,
        welcome: Welcome? = nil,
        actions: [Action] = [],
        resources: [Resource] = []
    ) {
        self.guildID = guildID
        self.isEnabled = isEnabled
        self.welcome = welcome
        self.actions = actions
        self.resources = resources
    }

    /// Whether there is anything at all to draw.
    public var isEmpty: Bool {
        welcome == nil && actions.isEmpty && resources.isEmpty
    }

    /// A sentence written by somebody in the server, addressed to the reader.
    ///
    /// **`[@username]` is a placeholder Discord substitutes on the client**, not
    /// text anybody typed — every captured message carries it, in the middle of
    /// a sentence, and a client that draws it literally prints a token at the
    /// reader. `substituting(_:)` is the whole of that.
    public struct Welcome: Hashable, Sendable {
        /// Who wrote it. A list on the wire; only the first is ever drawn,
        /// because a message signed by three people is a message signed by
        /// nobody.
        public var authorIDs: [UserID]
        public var message: String

        public init(authorIDs: [UserID], message: String) {
            self.authorIDs = authorIDs
            self.message = message
        }

        public var authorID: UserID? { authorIDs.first }

        /// The message with the reader's own name in it.
        public func substituting(_ name: String) -> String {
            message.replacingOccurrences(of: "[@username]", with: "@\(name)")
        }
    }

    /// One of the "get started" rows: a channel, and why to go there.
    public struct Action: Hashable, Sendable, Identifiable {
        /// Position in the server's own list. **The id, rather than the
        /// channel** — a guide may point twice at one channel for two different
        /// reasons, and a `ForEach` keyed on the channel would then draw one row.
        public var id: Int
        public var channelID: ChannelID
        public var kind: Kind
        public var title: String
        public var detail: String?
        public var emojiID: EmojiID?
        public var emojiName: String?
        public var isEmojiAnimated: Bool

        public init(
            id: Int,
            channelID: ChannelID,
            kind: Kind,
            title: String,
            detail: String? = nil,
            emojiID: EmojiID? = nil,
            emojiName: String? = nil,
            isEmojiAnimated: Bool = false
        ) {
            self.id = id
            self.channelID = channelID
            self.kind = kind
            self.title = title
            self.detail = detail
            self.emojiID = emojiID
            self.emojiName = emojiName
            self.isEmojiAnimated = isEmojiAnimated
        }

        /// `action_type`: 0 asks the reader to read, 1 asks them to write.
        ///
        /// Both open the same channel, so this decides only the glyph the row
        /// falls back to when the action carries no emoji of its own.
        public enum Kind: Int, Hashable, Sendable {
            case read = 0
            case write = 1

            public init(rawValue: Int) {
                self = rawValue == 1 ? .write : .read
            }
        }
    }

    /// A channel the server wants read, with a line saying why.
    public struct Resource: Hashable, Sendable, Identifiable {
        public var id: Int
        public var channelID: ChannelID
        public var title: String
        public var detail: String?

        public init(id: Int, channelID: ChannelID, title: String, detail: String? = nil) {
            self.id = id
            self.channelID = channelID
            self.title = title
            self.detail = detail
        }
    }
}

// MARK: - Channels & Roles

/// `GET /guilds/{id}/onboarding` — the questions a community server asks, and
/// what answering them unlocks.
///
/// The same payload drives the full-screen flow a new member walks through and
/// the Channels & Roles page an existing member can revisit, which is why
/// `Prompt.isInOnboarding` exists: a prompt can be offered on the page and *not*
/// during the flow.
public struct GuildOnboarding: Hashable, Sendable {
    public var guildID: GuildID
    public var isEnabled: Bool
    public var prompts: [Prompt]
    /// What everybody can see before answering anything. Not drawn, but it is
    /// what makes "this option unlocks a channel" a true statement rather than
    /// a guess — a channel already in this list is unlocked for everyone.
    public var defaultChannelIDs: [ChannelID]
    /// The option ids the reader has chosen.
    public var responses: Set<UInt64>

    public init(
        guildID: GuildID,
        isEnabled: Bool,
        prompts: [Prompt] = [],
        defaultChannelIDs: [ChannelID] = [],
        responses: Set<UInt64> = []
    ) {
        self.guildID = guildID
        self.isEnabled = isEnabled
        self.prompts = prompts
        self.defaultChannelIDs = defaultChannelIDs
        self.responses = responses
    }

    /// The prompts worth drawing on the Channels & Roles page.
    ///
    /// A prompt with no options is a heading over nothing, and one that is
    /// disabled everywhere cannot be answered — both are dropped at the
    /// boundary rather than checked at each call site.
    public var answerablePrompts: [Prompt] {
        prompts.filter { !$0.options.isEmpty }
    }

    /// The reader's answers with one option toggled, honouring single-select.
    ///
    /// **The whole ballot, every time.** The route replaces a selection rather
    /// than adding to it, so this returns the complete set and the caller sends
    /// all of it — a client that sent only the id just clicked would drop every
    /// previous answer.
    public func responses(togglingOption optionID: UInt64, inPrompt prompt: Prompt) -> Set<UInt64> {
        var next = responses
        if next.contains(optionID) {
            next.remove(optionID)
            return next
        }
        if prompt.isSingleSelect {
            for option in prompt.options { next.remove(option.id) }
        }
        next.insert(optionID)
        return next
    }

    public struct Prompt: Hashable, Sendable, Identifiable {
        public var id: UInt64
        public var title: String
        public var options: [Option]
        public var isSingleSelect: Bool
        public var isRequired: Bool
        /// Whether the question is asked during the join flow as well as on the
        /// page.
        public var isInOnboarding: Bool

        public init(
            id: UInt64,
            title: String,
            options: [Option] = [],
            isSingleSelect: Bool = false,
            isRequired: Bool = false,
            isInOnboarding: Bool = true
        ) {
            self.id = id
            self.title = title
            self.options = options
            self.isSingleSelect = isSingleSelect
            self.isRequired = isRequired
            self.isInOnboarding = isInOnboarding
        }

        /// The sentence under the options, which is a fact about the prompt
        /// rather than a label somebody chose.
        public var guidance: String {
            isSingleSelect ? "Choose one." : "Choose all that apply."
        }
    }

    public struct Option: Hashable, Sendable, Identifiable {
        public var id: UInt64
        public var title: String
        public var detail: String?
        public var emojiID: EmojiID?
        public var emojiName: String?
        public var isEmojiAnimated: Bool
        /// The roles picking this grants.
        public var roleIDs: [RoleID]
        /// The channels picking this reveals.
        public var channelIDs: [ChannelID]

        public init(
            id: UInt64,
            title: String,
            detail: String? = nil,
            emojiID: EmojiID? = nil,
            emojiName: String? = nil,
            isEmojiAnimated: Bool = false,
            roleIDs: [RoleID] = [],
            channelIDs: [ChannelID] = []
        ) {
            self.id = id
            self.title = title
            self.detail = detail
            self.emojiID = emojiID
            self.emojiName = emojiName
            self.isEmojiAnimated = isEmojiAnimated
            self.roleIDs = roleIDs
            self.channelIDs = channelIDs
        }
    }
}

// MARK: - Server rules

/// `GET /guilds/{id}/member-verification` — the rules a server makes people
/// agree to before they can speak.
///
/// **Only the `TERMS` field is decoded**, and that is a decision rather than an
/// omission: the other field types (`TEXT_INPUT`, `PARAGRAPH`,
/// `MULTIPLE_CHOICE`) belong to an application form, and this client has no
/// route that submits one. Decoding a question nobody can answer would be
/// building half of a control that cannot work.
public struct MemberVerification: Hashable, Sendable {
    public var guildID: GuildID
    /// The server's own line above the rules.
    public var detail: String?
    public var rules: [String]

    /// The version the reader's agreement is recorded against, **kept as the
    /// raw string Discord sent**.
    ///
    /// It looks like a timestamp — `2020-12-28T20:15:57.529000+00:00` — and
    /// decoding it to a `Date` and re-serialising it would produce a different
    /// string for the same instant. The server matches on the *string*, so this
    /// is echoed byte for byte or the agreement is recorded against nothing.
    public var version: String?
    /// The label and the required flag on the `TERMS` field, kept for the same
    /// reason: the submission echoes the whole field back.
    public var termsLabel: String?
    public var isTermsRequired: Bool

    public init(
        guildID: GuildID,
        detail: String? = nil,
        rules: [String] = [],
        version: String? = nil,
        termsLabel: String? = nil,
        isTermsRequired: Bool = true
    ) {
        self.guildID = guildID
        self.detail = detail
        self.rules = rules
        self.version = version
        self.termsLabel = termsLabel
        self.isTermsRequired = isTermsRequired
    }

    public var isEmpty: Bool { rules.isEmpty }

    /// Whether an agreement can be sent at all. Without the version there is
    /// nothing to record it against, and a button that submits a null version
    /// is a button that reports success and changes nothing.
    public var canSubmit: Bool { version != nil && !rules.isEmpty }
}

/// The reader's per-channel opt-in, as `user_guild_settings` records it.
///
/// **One flag serves both controls in Browse Channels.** A channel's checkbox
/// and a category's "Follow Category" switch are the same override on the same
/// key — a category is a channel, and the only difference is what following it
/// means: for a channel, "show me this"; for a category, "and show me whatever
/// gets added to it".
///
/// The bit is `1 << 12`, read off two captures that differ in nothing else:
/// setting it checks the box, clearing it unchecks it. And **clearing it removes
/// the override entirely** — the response comes back one entry shorter — so
/// "followed" is exactly "an override exists with this bit", and absence is the
/// opted-out state rather than an unknown one.
public enum ChannelSettingsFlags {
    /// `1 << 12`. Set on every channel the reader has opted into.
    public static let followed = 4096

    /// `1 << 11`. A direct message the reader pinned to the top of the list.
    ///
    /// **Discord's own name for it is FAVORITED, and its UI calls it Pin.** The
    /// name is kept as the wire has it so a capture can be read against this
    /// file; the word a person sees belongs to the menu, not here.
    ///
    /// Captured, both directions, on `PATCH /users/@me/guilds/@me/settings`:
    /// `{"channel_overrides":{"<channel>":{"flags":2048}}}` pins, and `0`
    /// unpins. **Unpinning removes the override entirely** — the reply comes
    /// back one entry shorter, exactly as `followed` does — so pinned is
    /// "an override exists carrying this bit" and absence is the answer, not an
    /// unknown.
    public static let favorited = 2048

    /// `1 << 14` / `1 << 13`. Whether a forum channel's new threads are
    /// followed. Not offered by this client, and carried across every write —
    /// see `clearingUnreadPreference`.
    public static let newForumThreadsOn = 16384
    public static let newForumThreadsOff = 8192

    /// `1 << 10` / `1 << 9`. Which messages count as unread in this channel,
    /// which is a separate question from which ones notify.
    ///
    /// **Read out of Discord's bundle**, where the guild's own flag table sits
    /// beside this one at overlapping numbers — `16384` is opt-in on a guild and
    /// "new forum threads on" here. Neither is offered by this client; they are
    /// named so a write can leave the ones it does not draw alone, and cleared
    /// only where Discord clears them.
    public static let unreadsAllMessages = 1024
    public static let unreadsOnlyMentions = 512

    /// The flags a channel keeps when its override is reset to the server's
    /// default.
    ///
    /// **Only the two unread bits go.** Discord's own "use server default"
    /// writes `message_notifications: 3` alongside the flags with exactly these
    /// two cleared — every other bit is somebody's opt-in, their pin or their
    /// forum follow, and a reset that dropped those would be three settings
    /// undone by one.
    public static func clearingUnreadPreference(_ flags: Int) -> Int {
        flags & ~(unreadsAllMessages | unreadsOnlyMentions)
    }
}

/// Which messages count as unread in a channel — Discord's unread setting,
/// a separate question from which ones notify.
public enum UnreadSetting: Hashable, Sendable {
    case allMessages
    case onlyMentions

    /// A channel override's own choice, or nil where it made none.
    public init?(channelFlags: Int?) {
        guard let flags = channelFlags else { return nil }
        if flags & ChannelSettingsFlags.unreadsAllMessages != 0 {
            self = .allMessages
        } else if flags & ChannelSettingsFlags.unreadsOnlyMentions != 0 {
            self = .onlyMentions
        } else {
            return nil
        }
    }
}

/// What `PUT /guilds/{id}/requests/@me` answers with.
///
/// A rules-only gate approves instantly; a server that also asks questions on
/// its application form leaves the request **pending a moderator**, and one that
/// has already turned somebody away answers rejected. Three real outcomes, and a
/// client that treated the route as fire-and-forget would tell all three of them
/// they were in.
public enum MemberVerificationOutcome: Hashable, Sendable {
    case approved
    case pending
    case rejected(String?)
    /// A status this client has not seen. Reported as unfinished rather than as
    /// success: the set grows, and guessing "approved" is guessing in the one
    /// direction that misleads.
    case unknown(String)

    public init(status: String?, rejectionReason: String?) {
        switch status?.uppercased() {
        case "APPROVED": self = .approved
        // **SUBMITTED is what a real application actually answers**, and it
        // was falling through to `.unknown`. Captured: a `PUT` accepted with
        // 201 replies `{"application_status":"SUBMITTED", "reviewed_at":null,
        // "join_request_id":…}`, and Discord's own client then says "Your
        // application is pending!" — so this is the applicant's spelling of
        // the state the moderator's list calls `submitted` in
        // `GuildJoinRequest.Status`. The same string was already known on one
        // side of the same feature and unread on the other.
        case "PENDING", "STARTED", "SUBMITTED": self = .pending
        case "REJECTED": self = .rejected(rejectionReason)
        case let other?: self = .unknown(other)
        case nil: self = .unknown("")
        }
    }
}

// MARK: - Game Servers

/// `GET /guilds/{id}/game-servers` — a game server a community has rented
/// through Discord.
///
/// One instance, with everything needed to join it. The address is the whole
/// point of the surface: joining happens in the game, not here, so what this
/// client can honestly offer is the address, whether the server is up, and the
/// steps the game needs.
public struct GameServer: Hashable, Sendable, Identifiable {
    public var id: UInt64
    /// The plan's SKU. **The key the connection instructions are fetched
    /// under** — they belong to the product, not to the instance.
    public var skuID: String
    public var name: String
    public var status: Status
    /// Discord's own display name for the region, e.g. "France".
    public var regionName: String?
    /// The plan the community bought, e.g. "Pro Plan".
    public var planName: String?
    public var ip: String?
    public var port: String?
    public var playersOnline: Int
    public var maxPlayers: Int
    /// From `game_config`: the game and the build it runs.
    public var gameName: String?
    public var gameVersion: String?
    /// The hosting provider's own control panel. Opened in a browser, because
    /// it is somebody else's site and this client has no business rendering it.
    public var providerURL: URL?
    /// A stop or start the community has queued, and when it lands. Both halves
    /// or neither: an action with no time is a fact nobody can act on.
    public var scheduledAction: String?
    public var scheduledActionAt: Date?

    public init(
        id: UInt64,
        skuID: String,
        name: String,
        status: Status,
        regionName: String? = nil,
        planName: String? = nil,
        ip: String? = nil,
        port: String? = nil,
        playersOnline: Int = 0,
        maxPlayers: Int = 0,
        gameName: String? = nil,
        gameVersion: String? = nil,
        providerURL: URL? = nil,
        scheduledAction: String? = nil,
        scheduledActionAt: Date? = nil
    ) {
        self.id = id
        self.skuID = skuID
        self.name = name
        self.status = status
        self.regionName = regionName
        self.planName = planName
        self.ip = ip
        self.port = port
        self.playersOnline = playersOnline
        self.maxPlayers = maxPlayers
        self.gameName = gameName
        self.gameVersion = gameVersion
        self.providerURL = providerURL
        self.scheduledAction = scheduledAction
        self.scheduledActionAt = scheduledActionAt
    }

    /// What somebody pastes into the game. Nil when either half is missing —
    /// half an address is worse than none, because it looks copyable.
    public var address: String? {
        guard let ip, !ip.isEmpty else { return nil }
        guard let port, !port.isEmpty else { return ip }
        return "\(ip):\(port)"
    }

    /// The game and its build on one line, when both are known.
    public var gameDescription: String? {
        switch (gameName, gameVersion) {
        case (let name?, let version?) where !name.isEmpty && !version.isEmpty:
            "\(name) · \(version)"
        case (let name?, _) where !name.isEmpty:
            name
        default:
            nil
        }
    }

    /// A server is only worth a Connect button when it is up and reachable.
    public var isJoinable: Bool { status == .online && address != nil }

    /// **A string with a known set, not an enum with a `default`.** Discord adds
    /// lifecycle states to this without warning, and an unknown one has to keep
    /// its own word — "provisioning" drawn as "Unknown" is a client telling the
    /// reader less than the server told it.
    public enum Status: Hashable, Sendable {
        case online
        case offline
        case starting
        case stopping
        case suspended
        case other(String)

        public init(_ raw: String) {
            self = switch raw.lowercased() {
            case "online", "running": .online
            case "offline", "stopped": .offline
            case "starting", "provisioning", "installing": .starting
            case "stopping": .stopping
            case "suspended", "deactivated": .suspended
            default: .other(raw)
            }
        }

        public var label: String {
            switch self {
            case .online: "Online"
            case .offline: "Offline"
            case .starting: "Starting"
            case .stopping: "Stopping"
            case .suspended: "Suspended"
            // Capitalised rather than uppercased: it is a word, and Discord
            // sends it lowercase.
            case .other(let raw): raw.isEmpty ? "Unknown" : raw.prefix(1).uppercased() + raw.dropFirst()
            }
        }

        /// Whether the server is in the middle of getting somewhere.
        public var isTransitional: Bool { self == .starting || self == .stopping }
    }
}

/// `GET /storefront/products/sku/{sku}` — the product a game server was bought
/// from, read for the one thing a *player* needs from it.
///
/// **The plans and their prices are deliberately not decoded.** This client
/// sells nothing and cannot change a plan, so a page of tiers with boost prices
/// would be a shop window over a control that does not exist. What is taken is
/// the connection instructions, which are the steps the game itself requires and
/// which no other route carries.
public struct GameServerProduct: Hashable, Sendable {
    public var skuID: String
    /// The steps, in order, in the product's own words. They carry `**bold**`
    /// runs naming menus and buttons, which is Discord's markdown and is
    /// rendered as such.
    public var instructions: [String]

    public init(skuID: String, instructions: [String] = []) {
        self.skuID = skuID
        self.instructions = instructions
    }

    public var isEmpty: Bool { instructions.isEmpty }
}

/// A server the reader has applied to and not yet heard back from.
///
/// `GET /users/@me/join-request-guilds` answers a **bare array of partial
/// guilds** — captured — with no request object beside them: an id, a name, an
/// icon and a description, and nothing about when the application went in or
/// what it said. So this says *which* servers are outstanding and the
/// application itself is still `GET /guilds/{id}/member-verification`.
///
/// It is what puts a submitted application back in front of the reader after a
/// relaunch. Without it the request is invisible until they happen to open the
/// invite again.
public struct JoinRequestGuild: Hashable, Sendable, Identifiable {
    public var id: GuildID
    public var name: String
    public var iconHash: String?
    public var description: String?

    public init(
        id: GuildID,
        name: String,
        iconHash: String? = nil,
        description: String? = nil
    ) {
        self.id = id
        self.name = name
        self.iconHash = iconHash
        self.description = description
    }

    public var iconURL: URL? {
        iconHash.flatMap { CDN.guildIcon(guildID: id, hash: $0, side: 48) }
    }

    public var monogram: String {
        String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }
}
