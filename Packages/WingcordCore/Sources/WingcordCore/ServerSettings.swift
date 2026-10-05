import Foundation

// MARK: - The editable slice of a server
//
// `Guild` is what the rail and the sidebar need: a name, an icon, a feature set
// and the counts. It deliberately stops there, because it is copied on every
// inbound message and every field on it is a field that copy carries.
//
// This is the *other* half — the twenty-odd fields only an administrator ever
// reads, fetched once when the settings window opens and never resident. Keeping
// them apart is the same argument `Guild`'s own doc comment makes about channels
// and roles, one level up.
//
// ONE WIRE FACT DECIDES THE WHOLE SHAPE OF THE WRITE SIDE, and it is not
// guessable: **a page sends the fields it owns, changed or not.** Three captures
// settle it, and they settle it by disagreeing —
//
//   - Community Overview sends its six every time, even when one changed.
//   - Access sends exactly one, `owner_configured_content_level`.
//   - Server Profile sends its eight every time.
//
// A client that sent only what changed would be right for Access and wrong for
// the other two; one that sent the whole guild would be wrong for all three.
// So there is no general "patch the guild" value in this file. Each page's write
// is its own route function with its own body — see `DiscordREST+ServerSettings`
// — which is what makes sending the wrong field group a compile error rather
// than a support ticket.

/// A server's settings, as `GET /guilds/{id}` and `PATCH /guilds/{id}` describe
/// them.
///
/// Read-only fields are carried too — `vanityURLCode`, `premiumTier`,
/// `maxMembers` — because several pages state a limit they cannot change, and a
/// page that has to fetch a second time to say "50 of 250 roles" is a page that
/// flickers.
public struct GuildSettings: Hashable, Sendable, Identifiable {
    public var id: GuildID
    public var name: String
    public var description: String?
    public var iconHash: String?
    public var bannerHash: String?
    public var splashHash: String?
    public var discoverySplashHash: String?
    /// The image behind the Server Guide's header. Distinct from the banner, and
    /// only shown where the guild has `BANNER`.
    public var homeHeaderHash: String?
    public var ownerID: UserID
    public var features: Set<String>

    // MARK: Engagement

    /// Where member-join and boost messages are posted. Nil disables them
    /// wholesale, which is a different thing from disabling each with a flag.
    public var systemChannelID: ChannelID?
    public var systemChannelFlags: SystemChannelFlags
    public var afkChannelID: ChannelID?
    /// Seconds. Discord accepts only 60, 300, 900, 1800 and 3600 — see
    /// `AFKTimeout`, which is the only place that set is written down.
    public var afkTimeout: Int
    public var defaultMessageNotifications: NotificationLevel
    public var isPremiumProgressBarEnabled: Bool

    // MARK: Community

    public var rulesChannelID: ChannelID?
    public var publicUpdatesChannelID: ChannelID?
    public var safetyAlertsChannelID: ChannelID?
    /// BCP-47, and Discord's own default is `en-US`.
    public var preferredLocale: String

    // MARK: Access and moderation

    public var verificationLevel: VerificationLevel
    public var explicitContentFilter: ExplicitContentFilter
    /// The Age-Restricted switch.
    ///
    /// **This, and not `nsfw`.** The capture is unambiguous: turning the switch
    /// on sent `{"owner_configured_content_level": 3}` and turning it off sent
    /// `0`. `nsfw` and `nsfwLevel` come back on the same response and are
    /// Discord's own classification — a client that wrote to them would be
    /// writing to a field the server owns.
    public var contentLevel: ContentLevel
    /// Discord's classification, which an administrator cannot set. Carried so
    /// the page can say *why* a server is age-gated when it was not the owner
    /// who gated it.
    public var nsfwLevel: Int
    public var mfaLevel: Int

    // MARK: Stated, never set

    public var vanityURLCode: String?
    public var premiumTier: Int
    public var premiumSubscriptionCount: Int
    public var maxMembers: Int?
    public var isWidgetEnabled: Bool
    public var widgetChannelID: ChannelID?
    /// Always null on every capture, and there is no route in Discord's own
    /// documentation that sets it. Decoded so the field is not silently lost the
    /// day one appears; nothing draws it. See `INVARIANTS.md` §5.5.
    public var themeHash: String?

    public init(
        id: GuildID,
        name: String,
        description: String? = nil,
        iconHash: String? = nil,
        bannerHash: String? = nil,
        splashHash: String? = nil,
        discoverySplashHash: String? = nil,
        homeHeaderHash: String? = nil,
        ownerID: UserID,
        features: Set<String> = [],
        systemChannelID: ChannelID? = nil,
        systemChannelFlags: SystemChannelFlags = [],
        afkChannelID: ChannelID? = nil,
        afkTimeout: Int = 300,
        defaultMessageNotifications: NotificationLevel = .allMessages,
        isPremiumProgressBarEnabled: Bool = false,
        rulesChannelID: ChannelID? = nil,
        publicUpdatesChannelID: ChannelID? = nil,
        safetyAlertsChannelID: ChannelID? = nil,
        preferredLocale: String = "en-US",
        verificationLevel: VerificationLevel = .none,
        explicitContentFilter: ExplicitContentFilter = .disabled,
        contentLevel: ContentLevel = .default,
        nsfwLevel: Int = 0,
        mfaLevel: Int = 0,
        vanityURLCode: String? = nil,
        premiumTier: Int = 0,
        premiumSubscriptionCount: Int = 0,
        maxMembers: Int? = nil,
        isWidgetEnabled: Bool = false,
        widgetChannelID: ChannelID? = nil,
        themeHash: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.iconHash = iconHash
        self.bannerHash = bannerHash
        self.splashHash = splashHash
        self.discoverySplashHash = discoverySplashHash
        self.homeHeaderHash = homeHeaderHash
        self.ownerID = ownerID
        self.features = features
        self.systemChannelID = systemChannelID
        self.systemChannelFlags = systemChannelFlags
        self.afkChannelID = afkChannelID
        self.afkTimeout = afkTimeout
        self.defaultMessageNotifications = defaultMessageNotifications
        self.isPremiumProgressBarEnabled = isPremiumProgressBarEnabled
        self.rulesChannelID = rulesChannelID
        self.publicUpdatesChannelID = publicUpdatesChannelID
        self.safetyAlertsChannelID = safetyAlertsChannelID
        self.preferredLocale = preferredLocale
        self.verificationLevel = verificationLevel
        self.explicitContentFilter = explicitContentFilter
        self.contentLevel = contentLevel
        self.nsfwLevel = nsfwLevel
        self.mfaLevel = mfaLevel
        self.vanityURLCode = vanityURLCode
        self.premiumTier = premiumTier
        self.premiumSubscriptionCount = premiumSubscriptionCount
        self.maxMembers = maxMembers
        self.isWidgetEnabled = isWidgetEnabled
        self.widgetChannelID = widgetChannelID
        self.themeHash = themeHash
    }

    /// Whether this server has opted into Discord's community tooling.
    ///
    /// The gate on six of the settings pages, and the one feature string that
    /// genuinely predicts something: without it there is no rules channel, no
    /// onboarding, no discovery and no safety alerts, because the server has not
    /// been given any of them.
    public var isCommunity: Bool { features.contains("COMMUNITY") }

    /// Whether the Engagement page offers Channel Summaries — Discord's
    /// `432371`: the server is in the general release.
    public var offersChannelSummaries: Bool { features.contains("SUMMARIES_ENABLED_GA") }

    /// Whether an administrator has turned them on.
    public var hasChannelSummaries: Bool { features.contains("SUMMARIES_ENABLED_BY_USER") }

    /// Whether the Activity Feed shows here — Discord's `376261`: what an
    /// administrator chose, and where nobody has, on for a server of fewer than
    /// ten thousand members. An unknown count is off.
    public func showsActivityFeed(memberCount: Int?) -> Bool {
        if features.contains("ACTIVITY_FEED_ENABLED_BY_USER") { return true }
        if features.contains("ACTIVITY_FEED_DISABLED_BY_USER") { return false }
        return memberCount.map { $0 < 10_000 } ?? false
    }

    /// Whether the tag pages may be offered at all.
    public var canSetTag: Bool { features.contains("GUILD_TAGS") }

    /// The boost tier a banner needs. Stated by the page rather than enforced by
    /// it — Discord refuses the upload, and a client that greys the control out
    /// on its own arithmetic is a client that gets it wrong the week the tiers
    /// change.
    public var canUploadBanner: Bool {
        features.contains("BANNER") || premiumTier >= 2
    }
}

// MARK: - System channel flags

/// Which of the four system messages are **suppressed**.
///
/// **Every bit is a negative**, which is the trap in this whole type: the
/// Engagement page draws four switches that read "send a welcome message", and
/// each is `!flags.contains(...)`. A client that maps the bit straight onto the
/// switch inverts all four, and the mistake is invisible on a server that has
/// never touched them because zero looks correct.
public struct SystemChannelFlags: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let suppressJoinNotifications = SystemChannelFlags(rawValue: 1 << 0)
    public static let suppressPremiumSubscriptions = SystemChannelFlags(rawValue: 1 << 1)
    public static let suppressGuildReminderNotifications = SystemChannelFlags(rawValue: 1 << 2)
    public static let suppressJoinNotificationReplies = SystemChannelFlags(rawValue: 1 << 3)
    public static let suppressRoleSubscriptionPurchaseNotifications = SystemChannelFlags(rawValue: 1 << 4)
    public static let suppressRoleSubscriptionPurchaseNotificationReplies = SystemChannelFlags(rawValue: 1 << 5)
    /// "A voice hangout has started" — Discord's `512`.
    public static let suppressVoiceSessionNotifications = SystemChannelFlags(rawValue: 1 << 9)

    /// The four the Engagement page offers, in the order it draws them.
    ///
    /// A stored order rather than the bit order: "prompt members to reply with a
    /// sticker" is a qualifier on the welcome message above it and belongs under
    /// it, and its bit is `1 << 3`.
    public static let engagementOrder: [(flag: SystemChannelFlags, label: String)] = [
        (.suppressJoinNotifications, "Send a random welcome message when someone joins this server."),
        (.suppressJoinNotificationReplies, "Prompt members to reply to welcome messages with a sticker."),
        (.suppressPremiumSubscriptions, "Send a message when someone boosts this server."),
        (.suppressGuildReminderNotifications, "Send helpful tips for server setup."),
    ]

    /// Every switch the Engagement page offers this server, in Discord's order
    /// (`1e901507`'s `pF`): the four, the two about Server Subscriptions where
    /// the server can sell them or one is already off, and the voice hangout.
    ///
    /// **The hangout's row is always offered.** Discord's waits on an
    /// experiment or on the flag being set; neither is anything this client
    /// can evaluate, and a row that appears only once its message is off is
    /// one that cannot be put back.
    public static func engagementRows(
        features: Set<String>,
        flags: SystemChannelFlags
    ) -> [(flag: SystemChannelFlags, label: String)] {
        // Discord's `936555`: it can sell subscriptions unless that was
        // switched off.
        let isMonetizable = !features.contains("CREATOR_MONETIZABLE_DISABLED")
            && (features.contains("CREATOR_MONETIZABLE") || features.contains("CREATOR_MONETIZABLE_PROVISIONAL"))
        var rows = engagementOrder
        if isMonetizable || flags.contains(.suppressRoleSubscriptionPurchaseNotifications) {
            rows.append((
                .suppressRoleSubscriptionPurchaseNotifications,
                "Send a message when someone purchases a Server Product or Server Subscription"
            ))
        }
        if isMonetizable || flags.contains(.suppressRoleSubscriptionPurchaseNotificationReplies) {
            rows.append((
                .suppressRoleSubscriptionPurchaseNotificationReplies,
                "Prompt members to reply to Server Subscription congratulation messages with a sticker"
            ))
        }
        rows.append((.suppressVoiceSessionNotifications, "Send a message when a voice hangout has started."))
        return rows
    }

    /// Whether the message this flag suppresses is being sent.
    ///
    /// The one place the inversion is written, so no pane repeats it.
    public func sends(_ flag: SystemChannelFlags) -> Bool { !contains(flag) }

    /// Turns one message on or off, answering a new flag set.
    public func setting(_ flag: SystemChannelFlags, sending: Bool) -> SystemChannelFlags {
        var next = self
        if sending { next.remove(flag) } else { next.insert(flag) }
        return next
    }
}

// MARK: - Enumerations
//
// Each of these is a closed set on the wire and an *open* one in this client:
// the initialiser takes any integer and keeps an unrecognised one rather than
// folding it into a default. The reason is the same one `GameServer.Status`
// records — a value drawn as "None" when the server said something else is the
// client telling the reader less than it was told — and here it is worse than
// cosmetic, because these values are written back. Folding an unknown
// verification level into `.none` would silently *lower* a server's gate the
// first time an administrator saved any unrelated field on the same page.

/// Who may talk in a server.
///
/// `Codable` as the wire's integer, because `Guild` carries one.
public enum VerificationLevel: Hashable, Sendable, Codable {
    case none
    case low
    case medium
    case high
    case veryHigh
    case unrecognised(Int)

    public init(rawValue: Int) {
        self = switch rawValue {
        case 0: .none
        case 1: .low
        case 2: .medium
        case 3: .high
        case 4: .veryHigh
        default: .unrecognised(rawValue)
        }
    }

    public var rawValue: Int {
        switch self {
        case .none: 0
        case .low: 1
        case .medium: 2
        case .high: 3
        case .veryHigh: 4
        case .unrecognised(let value): value
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(Int.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var title: String {
        switch self {
        case .none: "None"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .veryHigh: "Highest"
        case .unrecognised(let value): "Level \(value)"
        }
    }

    public var detail: String {
        switch self {
        case .none: "Unrestricted."
        case .low: "Must have a verified email."
        case .medium: "Must also be registered on Discord for longer than 5 minutes."
        case .high: "Must also be a member of this server for longer than 10 minutes."
        case .veryHigh: "Must have a verified phone number."
        case .unrecognised: "This client does not know what this level requires."
        }
    }

    /// The four this client offers, in order. `unrecognised` is never offered —
    /// only kept when it is what the server already holds.
    public static let selectable: [VerificationLevel] = [.none, .low, .medium, .high, .veryHigh]
}

/// Whether members are notified about every message or only mentions.
/// `Codable` because `Guild` is, and a guild now carries this.
///
/// **Coded as its raw integer, which is what makes an unrecognised value survive
/// a round trip.** A synthesised conformance over an enum with an associated
/// value writes a discriminated object; this writes the number Discord sent, so
/// a level added after this was written comes back out as the same number rather
/// than as a default. That is the same rule §1 states about a bitfield written
/// back carrying the bits this client cannot draw.
public enum NotificationLevel: Hashable, Sendable, Codable {
    case allMessages
    case onlyMentions
    case unrecognised(Int)

    public init(rawValue: Int) {
        self = switch rawValue {
        case 0: .allMessages
        case 1: .onlyMentions
        default: .unrecognised(rawValue)
        }
    }

    public var rawValue: Int {
        switch self {
        case .allMessages: 0
        case .onlyMentions: 1
        case .unrecognised(let value): value
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(Int.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var title: String {
        switch self {
        case .allMessages: "All Messages"
        case .onlyMentions: "Only @mentions"
        case .unrecognised(let value): "Level \(value)"
        }
    }
}

/// Whose messages are scanned for explicit media.
public enum ExplicitContentFilter: Hashable, Sendable {
    case disabled
    case membersWithoutRoles
    case allMembers
    case unrecognised(Int)

    public init(rawValue: Int) {
        self = switch rawValue {
        case 0: .disabled
        case 1: .membersWithoutRoles
        case 2: .allMembers
        default: .unrecognised(rawValue)
        }
    }

    public var rawValue: Int {
        switch self {
        case .disabled: 0
        case .membersWithoutRoles: 1
        case .allMembers: 2
        case .unrecognised(let value): value
        }
    }

    public var title: String {
        switch self {
        case .disabled: "Do not filter"
        case .membersWithoutRoles: "Filter members without a role"
        case .allMembers: "Filter all members"
        case .unrecognised(let value): "Level \(value)"
        }
    }

    public static let selectable: [ExplicitContentFilter] = [
        .disabled, .membersWithoutRoles, .allMembers,
    ]
}

/// The Age-Restricted switch's two states, and the values behind them.
///
/// Two named cases rather than a `Bool`, because the wire values are 0 and
/// **3** — not 0 and 1 — and a boolean at this layer would put that surprise in
/// whichever encoder happened to be written last.
public enum ContentLevel: Hashable, Sendable {
    case `default`
    case ageRestricted
    case unrecognised(Int)

    public init(rawValue: Int) {
        self = switch rawValue {
        case 0: .default
        case 3: .ageRestricted
        default: .unrecognised(rawValue)
        }
    }

    public var rawValue: Int {
        switch self {
        case .default: 0
        case .ageRestricted: 3
        case .unrecognised(let value): value
        }
    }

    public var isAgeRestricted: Bool {
        if case .ageRestricted = self { return true }
        return false
    }
}

/// The five values Discord's AFK timeout menu offers.
///
/// A stored list rather than a free integer field: the route refuses anything
/// else, and a text field that accepts 240 and answers 400 is a control that
/// looks like it works.
public enum AFKTimeout {
    public static let seconds: [Int] = [60, 300, 900, 1800, 3600]

    public static func title(_ value: Int) -> String {
        switch value {
        case 60: "1 minute"
        case 300: "5 minutes"
        case 900: "15 minutes"
        case 1800: "30 minutes"
        case 3600: "1 hour"
        default: "\(value) seconds"
        }
    }
}

// MARK: - Access

/// How people get into a server — the three tiles at the top of the Access page.
///
/// **Not one field.** Invite Only is the absence of the other two, Apply to Join
/// is `PATCH /guilds/{id}/member-verification` with `enabled: true`, and
/// Discoverable is the `DISCOVERABLE` feature — which Discord refuses outright
/// until the server meets six separate requirements. Three different routes
/// behind one segmented control, which is exactly why the mode is resolved in
/// one place here rather than at each tile.
public enum GuildAccessMode: Hashable, Sendable, CaseIterable, Identifiable {
    case inviteOnly
    case applyToJoin
    case discoverable

    public var id: Self { self }

    public var title: String {
        switch self {
        case .inviteOnly: "Invite Only"
        case .applyToJoin: "Apply to Join"
        case .discoverable: "Discoverable"
        }
    }

    public var detail: String {
        switch self {
        case .inviteOnly: "People can join your server directly with an invite"
        case .applyToJoin: "People must submit an application and be approved to join"
        case .discoverable: "Anyone can join your server directly through Server Discovery"
        }
    }

    public var symbolName: String {
        switch self {
        case .inviteOnly: "lock.fill"
        case .applyToJoin: "envelope.fill"
        case .discoverable: "globe"
        }
    }

    /// What the server is currently set to — Discord's `N` (`816e9b48`),
    /// read off the features alone.
    ///
    /// **An enabled form is not an application.** Rules Screening on an
    /// invite-only server is an enabled form too, with one `TERMS` field; what
    /// makes a server one that reviews who joins is the gate together with
    /// `MEMBER_VERIFICATION_MANUAL_APPROVAL`. Discovery wins over both.
    public init(features: Set<String>) {
        if features.contains("DISCOVERABLE") {
            self = .discoverable
        } else if features.contains("MEMBER_VERIFICATION_GATE_ENABLED"),
                  features.contains("MEMBER_VERIFICATION_MANUAL_APPROVAL")
        {
            self = .applyToJoin
        } else {
            self = .inviteOnly
        }
    }
}

/// Why Discord will or will not let a server into discovery.
///
/// Every field is a plain answer to one requirement, and the page draws one row
/// per field. `healthScorePending` is the third state the tick/cross pair cannot
/// express — "we cannot tell yet" — and it is the ordinary answer for a small
/// server, so a client that drew it as a failure would be telling most servers
/// they had failed something they have not been measured on.
public struct DiscoveryRequirements: Hashable, Sendable {
    public var guildID: GuildID
    public var isSafeEnvironment: Bool
    public var isHealthy: Bool
    public var isHealthScorePending: Bool
    public var meetsSize: Bool
    public var minimumSize: Int
    public var meetsAge: Bool
    /// Days.
    public var minimumAge: Int
    public var isProtected: Bool
    public var hasValidRulesChannel: Bool
    public var isSufficient: Bool

    public init(
        guildID: GuildID,
        isSafeEnvironment: Bool = false,
        isHealthy: Bool = false,
        isHealthScorePending: Bool = false,
        meetsSize: Bool = false,
        minimumSize: Int = 0,
        meetsAge: Bool = false,
        minimumAge: Int = 0,
        isProtected: Bool = false,
        hasValidRulesChannel: Bool = false,
        isSufficient: Bool = false
    ) {
        self.guildID = guildID
        self.isSafeEnvironment = isSafeEnvironment
        self.isHealthy = isHealthy
        self.isHealthScorePending = isHealthScorePending
        self.meetsSize = meetsSize
        self.minimumSize = minimumSize
        self.meetsAge = meetsAge
        self.minimumAge = minimumAge
        self.isProtected = isProtected
        self.hasValidRulesChannel = hasValidRulesChannel
        self.isSufficient = isSufficient
    }

    /// One requirement as the page states it.
    public struct Requirement: Hashable, Sendable, Identifiable {
        public enum Outcome: Hashable, Sendable {
            case met
            case unmet
            /// Measured only once a server is large enough. Drawn as a caution
            /// rather than a failure — see the type's own note.
            case pending
        }

        public var id: String
        public var title: String
        public var detail: String
        public var outcome: Outcome

        public init(id: String, title: String, detail: String, outcome: Outcome) {
            self.id = id
            self.title = title
            self.detail = detail
            self.outcome = outcome
        }
    }

    /// The rows, in the order Discord's own page lists them.
    public var requirements: [Requirement] {
        [
            Requirement(
                id: "safe",
                title: "Safe Environment",
                detail: isSafeEnvironment
                    ? "Thanks for abiding by the Community Guidelines and keeping your server safe."
                    : "This server has been actioned for breaking the Community Guidelines.",
                outcome: isSafeEnvironment ? .met : .unmet
            ),
            Requirement(
                id: "size",
                title: meetsSize ? "Meets Size Requirement" : "Fewer Than \(minimumSize.formatted()) Members",
                detail: "Your server must have at least \(minimumSize.formatted()) members to be eligible.",
                outcome: meetsSize ? .met : .unmet
            ),
            Requirement(
                id: "age",
                title: "Meets Age Requirement",
                detail: "Servers in Discovery have to be at least \(minimumAge) days old.",
                outcome: meetsAge ? .met : .unmet
            ),
            Requirement(
                id: "health",
                title: isHealthScorePending ? "Waiting on Server Activity Metrics" : "Server Activity",
                detail: isHealthScorePending
                    ? "Activity metrics cannot be calculated until your server is larger."
                    : "Servers in Discovery must meet certain activity requirements.",
                outcome: isHealthScorePending ? .pending : (isHealthy ? .met : .unmet)
            ),
            Requirement(
                id: "rules",
                title: "Rules Channel",
                detail: "A community server needs a channel where its rules are written.",
                outcome: hasValidRulesChannel ? .met : .unmet
            ),
            Requirement(
                id: "protected",
                title: "2FA Requirement For Moderation",
                detail: "Members with moderation powers must have 2FA enabled before they can act.",
                outcome: isProtected ? .met : .unmet
            ),
        ]
    }
}

/// What a server says about itself in discovery.
public struct DiscoveryMetadata: Hashable, Sendable {
    public var guildID: GuildID
    public var primaryCategoryID: Int
    public var categoryIDs: [Int]
    public var keywords: [String]
    /// Whether the server appears as the source behind an emoji or sticker that
    /// leaked out of it. `ExpressionSource.Guild.isPublic` is the reader's side
    /// of the same switch.
    public var isEmojiDiscoverable: Bool
    public var isPublished: Bool
    public var about: String?
    public var socialLinks: [String]
    public var reasonsToJoin: [String]

    public init(
        guildID: GuildID,
        primaryCategoryID: Int = 0,
        categoryIDs: [Int] = [],
        keywords: [String] = [],
        isEmojiDiscoverable: Bool = true,
        isPublished: Bool = false,
        about: String? = nil,
        socialLinks: [String] = [],
        reasonsToJoin: [String] = []
    ) {
        self.guildID = guildID
        self.primaryCategoryID = primaryCategoryID
        self.categoryIDs = categoryIDs
        self.keywords = keywords
        self.isEmojiDiscoverable = isEmojiDiscoverable
        self.isPublished = isPublished
        self.about = about
        self.socialLinks = socialLinks
        self.reasonsToJoin = reasonsToJoin
    }
}

// MARK: - The widget

public struct GuildWidgetSettings: Hashable, Sendable {
    public var isEnabled: Bool
    public var channelID: ChannelID?

    public init(isEnabled: Bool = false, channelID: ChannelID? = nil) {
        self.isEnabled = isEnabled
        self.channelID = channelID
    }
}
