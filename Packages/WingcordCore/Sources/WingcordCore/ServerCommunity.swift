import Foundation

// MARK: - The join application, from the other side
//
// `MemberVerification` in `GuildSurfaces.swift` is the READER's view of this: the
// rules, and one `TERMS` field to agree to. It deliberately decodes nothing else,
// and §4.75 of the handoff records why — the other field types belonged to a form
// this client could not submit, so decoding them would have built a surface with
// nothing behind it.
//
// **A capture has now arrived, so that has to be re-earned** — `INVARIANTS.md`
// §5.5 states the rule and this is the second time it has applied. Turning on
// "Apply to Join" sent:
//
//     PATCH /guilds/{id}/member-verification
//     {"form_fields":[{"field_type":"TEXT_INPUT",
//                      "label":"Why do you want to join our server?",
//                      "required":true}],
//      "enabled":true}
//
// So the *editor* is real, and this file is the type behind it. The reader's
// side is `JoinApplication` — the same fields, answered.

/// A server's application form, as its administrator edits it.
public struct JoinApplicationForm: Hashable, Sendable {
    public var guildID: GuildID
    public var isEnabled: Bool
    /// The line above the questions. Null on every capture; carried because the
    /// route accepts it.
    public var detail: String?
    public var fields: [Field]
    /// The version the *reader's* agreement is recorded against.
    ///
    /// Echoed back byte for byte and never turned into a `Date` — the same rule
    /// `MemberVerification.version` states, for the same reason, and stated
    /// again here because this is the type that receives a fresh one on every
    /// save and would be the tempting place to "tidy" it.
    public var version: String?

    public init(
        guildID: GuildID,
        isEnabled: Bool = false,
        detail: String? = nil,
        fields: [Field] = [],
        version: String? = nil
    ) {
        self.guildID = guildID
        self.isEnabled = isEnabled
        self.detail = detail
        self.fields = fields
        self.version = version
    }

    /// Discord's own cap. Stated in the heading — "QUESTIONS (1/5)".
    public static let maximumQuestions = 5

    /// One question on the form.
    ///
    /// `id` is this client's, not Discord's: the route sends an array with no
    /// identity in it, and a `ForEach` over array indices loses a row's text
    /// field focus every time a question above it is deleted.
    public struct Field: Hashable, Sendable, Identifiable {
        public var id: UUID
        public var kind: Kind
        public var label: String
        public var isRequired: Bool
        public var detail: String?
        public var placeholder: String?
        /// Present on the wire, always null on every capture, and its meaning is
        /// not settled. Kept undecoded rather than guessed at — an unread key
        /// costs nothing.
        public var hasAutomations: Bool

        public init(
            id: UUID = UUID(),
            kind: Kind = .textInput,
            label: String,
            isRequired: Bool = true,
            detail: String? = nil,
            placeholder: String? = nil,
            hasAutomations: Bool = false
        ) {
            self.id = id
            self.kind = kind
            self.label = label
            self.isRequired = isRequired
            self.detail = detail
            self.placeholder = placeholder
            self.hasAutomations = hasAutomations
        }

        /// What kind of answer the question takes.
        ///
        /// `TERMS` is on the wire and is **not offered here**: it is the rules
        /// checkbox, which the Access page manages as its own control rather
        /// than as a question — offering it in the question menu would let
        /// somebody build a form with two of them.
        public enum Kind: Hashable, Sendable {
            case textInput
            case paragraph
            case multipleChoice([String])
            /// The rules, with the rules themselves — `values` on the wire.
            ///
            /// **Carried, not just named.** A save sends every field back, and a
            /// `TERMS` field sent without its `values` is a rules list emptied
            /// by somebody who only edited a question.
            case terms([String])
            /// A field type this client has not seen. Rendered as an unwritable
            /// row that states its own name, and **carried through a save
            /// untouched** — dropping it would silently delete a question the
            /// administrator built in Discord's own client.
            case unrecognised(String)

            public init(wireName: String, choices: [String] = [], values: [String] = []) {
                self = switch wireName {
                case "TEXT_INPUT": .textInput
                case "PARAGRAPH": .paragraph
                case "MULTIPLE_CHOICE": .multipleChoice(choices)
                case "TERMS": .terms(values)
                default: .unrecognised(wireName)
                }
            }

            /// The rules agreement rather than a question — Discord's `i7`.
            public var isTerms: Bool {
                if case .terms = self { return true }
                return false
            }

            public var wireName: String {
                switch self {
                case .textInput: "TEXT_INPUT"
                case .paragraph: "PARAGRAPH"
                case .multipleChoice: "MULTIPLE_CHOICE"
                case .terms: "TERMS"
                case .unrecognised(let name): name
                }
            }

            public var title: String {
                switch self {
                case .textInput: "Short Answer"
                case .paragraph: "Paragraph"
                case .multipleChoice: "Multiple Choice"
                case .terms: "Rules Agreement"
                case .unrecognised(let name): name.replacingOccurrences(of: "_", with: " ").capitalized
                }
            }

            /// Whether this client can edit a field of this kind. An
            /// unrecognised one is shown and preserved, never rewritten.
            public var isEditable: Bool {
                if case .unrecognised = self { return false }
                return true
            }

            /// The kinds the "Add a question" menu offers.
            public static let selectable: [Kind] = [.textInput, .paragraph, .multipleChoice([])]
        }
    }

    /// The three Discord suggests under an empty form.
    public static let exampleQuestions = [
        "Do you play any of the same games as us?",
        "How did you find us?",
        "What makes you unique?",
    ]

    /// Whether the form can be turned on.
    ///
    /// Discord refuses an enabled form with no questions, and a switch that flips
    /// back a beat later is worse than one that will not flip — so the Access
    /// page states the requirement instead.
    public var canEnable: Bool { !fields.isEmpty }
}

// MARK: - Invites

/// One active invite link.
public struct GuildInvite: Hashable, Sendable, Identifiable {
    /// The code IS the identity. Discord also sends a snowflake `id`, and the
    /// delete route takes the **code** — so keying on the snowflake means
    /// carrying an id that nothing can act on.
    public var id: String
    public var inviterID: UserID?
    public var channelID: ChannelID?
    public var channelName: String?
    public var uses: Int
    /// Zero means unlimited, which is Discord's default and is why the column
    /// reads "∞" rather than "0".
    public var maxUses: Int
    /// Nil where the invite never expires.
    public var expiresAt: Date?
    public var createdAt: Date?
    /// Whether joining through this link grants membership only for as long as
    /// the person stays connected.
    public var isTemporary: Bool
    /// Roles the invite grants on join. A boosted-server feature; empty is the
    /// ordinary case.
    public var roleIDs: [RoleID]

    public init(
        id: String,
        inviterID: UserID? = nil,
        channelID: ChannelID? = nil,
        channelName: String? = nil,
        uses: Int = 0,
        maxUses: Int = 0,
        expiresAt: Date? = nil,
        createdAt: Date? = nil,
        isTemporary: Bool = false,
        roleIDs: [RoleID] = []
    ) {
        self.id = id
        self.inviterID = inviterID
        self.channelID = channelID
        self.channelName = channelName
        self.uses = uses
        self.maxUses = maxUses
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.isTemporary = isTemporary
        self.roleIDs = roleIDs
    }

    public var url: URL? { URL(string: "https://discord.gg/\(id)") }

    public var isUnlimitedUses: Bool { maxUses == 0 }

    /// Whether the link has already run out. Computed rather than stored,
    /// because a list opened five minutes ago holds invites that expired since.
    public func hasExpired(asOf now: Date = .now) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}

/// The options the "Create invite link" sheet offers.
///
/// Discord's own defaults, which are **not** the route's defaults: the route
/// defaults `max_age` to 86400, and every client sends 604800 because that is
/// what the menu opens on.
public struct InviteOptions: Hashable, Sendable {
    /// Seconds. Zero is "never".
    public var maxAge: Int
    /// Zero is unlimited.
    public var maxUses: Int
    public var isTemporary: Bool
    /// Whether to mint a fresh code rather than hand back an equivalent existing
    /// one. Discord reuses a matching invite otherwise, which surprises anybody
    /// generating a link per person.
    public var isUnique: Bool

    public init(
        maxAge: Int = 604_800,
        maxUses: Int = 0,
        isTemporary: Bool = false,
        isUnique: Bool = true
    ) {
        self.maxAge = maxAge
        self.maxUses = maxUses
        self.isTemporary = isTemporary
        self.isUnique = isUnique
    }

    public static let ageChoices: [Int] = [0, 1800, 3600, 21600, 43200, 86400, 604_800, 2_592_000]
    public static let useChoices: [Int] = [0, 1, 5, 10, 25, 50, 100]

    public static func ageTitle(_ seconds: Int) -> String {
        switch seconds {
        case 0: "Never"
        case 1800: "30 minutes"
        case 3600: "1 hour"
        case 21600: "6 hours"
        case 43200: "12 hours"
        case 86400: "1 day"
        case 604_800: "7 days"
        case 2_592_000: "30 days"
        default: "\(seconds) seconds"
        }
    }

    public static func usesTitle(_ uses: Int) -> String {
        uses == 0 ? "No limit" : "\(uses) use\(uses == 1 ? "" : "s")"
    }
}

// MARK: - Bans

public struct GuildBan: Hashable, Sendable, Identifiable {
    public var id: UserID
    public var username: String
    public var displayName: String?
    public var avatarHash: String?
    public var reason: String?

    public init(
        id: UserID,
        username: String,
        displayName: String? = nil,
        avatarHash: String? = nil,
        reason: String? = nil
    ) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.avatarHash = avatarHash
        self.reason = reason
    }

    /// When the ban was issued is **not** available. Discord's ban object
    /// carries no timestamp, and the user's own snowflake dates the account
    /// rather than the ban — so the page states the reason and nothing about
    /// when, which is the honest answer.
    public var bannedAt: Date? { nil }
}

// MARK: - Templates

/// A server template, as `GET`/`POST /guilds/{id}/templates` answer.
///
/// A server has **at most one**, which is why the route answers with an array
/// and the page draws a form: the array is empty or it has exactly one entry,
/// and "create" and "edit" are the same page in two states.
public struct GuildTemplate: Hashable, Sendable, Identifiable {
    /// The code, which is also the delete route's path segment and the shared
    /// link's last component.
    public var id: String
    public var name: String
    public var description: String?
    public var usageCount: Int
    public var creatorID: UserID?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var sourceGuildID: GuildID?
    /// Whether the server has changed since the template was last synced.
    ///
    /// **Null is not false.** Discord sends `null` for a template that is in
    /// step, and `true` for one that is behind — there is no `false` on the
    /// wire. Kept as a three-state so the Sync button is offered on `true`
    /// alone rather than on "not false", which would offer it always.
    public var isDirty: Bool?

    public init(
        id: String,
        name: String,
        description: String? = nil,
        usageCount: Int = 0,
        creatorID: UserID? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        sourceGuildID: GuildID? = nil,
        isDirty: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.usageCount = usageCount
        self.creatorID = creatorID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceGuildID = sourceGuildID
        self.isDirty = isDirty
    }

    public var url: URL? { URL(string: "https://discord.new/\(id)") }

    /// What the template carries, and what it leaves behind. Stated on the page
    /// because a template that quietly did not copy the server icon is a
    /// surprise somebody discovers after sharing the link.
    public static let copies = [
        "Channels and channel topics",
        "Roles and permissions",
        "Default server settings",
    ]

    public static let doesNotCopy = [
        "Messages or any content",
        "Members or bots",
        "Your server icon, Boosts, or other perks",
    ]
}

// MARK: - The members table
//
// `POST /guilds/{id}/members-search` is Elasticsearch behind a JSON body, and
// what it answers with is **not a member object**: each row is a wrapper that
// puts the member inside it and adds how they got in. That is the whole reason
// this type exists — the Members page's most useful column, "Join Method", is
// on the wrapper and on nothing else.

/// One row of the members table.
public struct GuildMemberRow: Hashable, Sendable, Identifiable {
    public var id: UserID
    public var username: String
    public var displayName: String?
    public var nickname: String?
    /// The account's own avatar.
    public var avatarHash: String?
    /// The avatar they wear in this server, which wins where it is set.
    public var guildAvatarHash: String?
    public var joinedAt: Date?
    public var roleIDs: [RoleID]
    /// Whether they have yet to agree to the rules. READY carries the same flag
    /// on the reader's own record — see `Member.isPending`.
    public var isPending: Bool
    /// Timed out until, or nil. **A past date is not a timeout**, which is why
    /// this is compared rather than tested for presence.
    public var timedOutUntil: Date?
    public var joinSource: JoinSource
    /// A pre-pomelo account's tag, "9576" — drawn as `name#9576` the way
    /// Discord's table draws it. Nil or "0" for everybody else.
    public var discriminator: String?
    public var isBot: Bool
    public var flags: MemberFlags
    /// When Discord last flagged them for unusual DMs, or nil. A signal for
    /// `MemberSearchQuery.unusualDMWindow` after it.
    public var unusualDMActivityUntil: Date?
    /// Discord's own `SPAMMER` flag on the account — "Engaged in suspected
    /// spam activity".
    public var isSpammer: Bool

    public init(
        id: UserID,
        username: String,
        displayName: String? = nil,
        nickname: String? = nil,
        avatarHash: String? = nil,
        guildAvatarHash: String? = nil,
        joinedAt: Date? = nil,
        roleIDs: [RoleID] = [],
        isPending: Bool = false,
        timedOutUntil: Date? = nil,
        joinSource: JoinSource = .unspecified,
        discriminator: String? = nil,
        isBot: Bool = false,
        flags: MemberFlags = [],
        unusualDMActivityUntil: Date? = nil,
        isSpammer: Bool = false
    ) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.nickname = nickname
        self.avatarHash = avatarHash
        self.guildAvatarHash = guildAvatarHash
        self.joinedAt = joinedAt
        self.roleIDs = roleIDs
        self.isPending = isPending
        self.timedOutUntil = timedOutUntil
        self.joinSource = joinSource
        self.discriminator = discriminator
        self.isBot = isBot
        self.flags = flags
        self.unusualDMActivityUntil = unusualDMActivityUntil
        self.isSpammer = isSpammer
    }

    /// `username#1234` for a pre-pomelo account, the bare username otherwise —
    /// Discord's `getUserTag`.
    public var tag: String {
        guard let discriminator, discriminator != "0", !discriminator.isEmpty else { return username }
        return "\(username)#\(discriminator)"
    }

    /// Whether the unusual-DM signal still stands.
    public func hasUnusualDMActivity(asOf now: Date = .now) -> Bool {
        guard let unusualDMActivityUntil else { return false }
        return unusualDMActivityUntil > now.addingTimeInterval(-MemberSearchQuery.unusualDMWindow)
    }

    /// What this server calls them.
    public var name: String { nickname ?? displayName ?? username }

    public func isTimedOut(asOf now: Date = .now) -> Bool {
        guard let timedOutUntil else { return false }
        return timedOutUntil > now
    }

    /// How somebody got in — Discord's `JoinSourceType` (`11541`).
    public enum JoinSource: Hashable, Sendable {
        case unspecified
        case bot
        case integration
        case discovery
        case hub
        case invite(code: String?, inviterID: UserID?)
        case vanityURL(code: String?)
        case manualVerification(code: String?)
        case linkedChannel
        case unrecognised(Int)

        public init(rawValue: Int?, code: String?, inviterID: UserID?) {
            switch rawValue {
            case 0, nil: self = .unspecified
            case 1: self = .bot
            case 2: self = .integration
            case 3: self = .discovery
            case 4: self = .hub
            case 5: self = .invite(code: code, inviterID: inviterID)
            case 6: self = .vanityURL(code: code)
            case 7: self = .manualVerification(code: code)
            case 8: self = .linkedChannel
            case let other?: self = .unrecognised(other)
            }
        }

        /// The wire number, for the Join Method filter.
        public var rawValue: Int {
            switch self {
            case .unspecified: 0
            case .bot: 1
            case .integration: 2
            case .discovery: 3
            case .hub: 4
            case .invite: 5
            case .vanityURL: 6
            case .manualVerification: 7
            case .linkedChannel: 8
            case .unrecognised(let value): value
            }
        }

        /// What the column says — Discord's own labels (`f` in `11541`). An
        /// invite shows its code, as Discord's chip does.
        public var title: String {
            switch self {
            case .unspecified, .unrecognised: "Unknown"
            case .bot: "Bot Invite"
            case .integration: "Integration"
            case .discovery: "Server Discovery"
            case .hub: "Student Hub"
            case .invite(let code, _): code ?? "Server Invite"
            case .vanityURL(let code): code.map { "\($0) (Vanity)" } ?? "Vanity URL"
            case .manualVerification(let code): code.map { "Manual Verification (\($0))" } ?? "Manual Verification"
            case .linkedChannel: "Linked Channel"
            }
        }

        /// Whether the chip carries a link mark — an invite or a vanity code.
        public var isLink: Bool {
            switch self {
            case .invite, .vanityURL: true
            default: false
            }
        }

        public var inviterID: UserID? {
            if case .invite(_, let id) = self { return id }
            return nil
        }
    }

    /// How the table is ordered.
    public enum Sort: Int, Hashable, Sendable, CaseIterable, Identifiable {
        case joinedNewest = 1
        case joinedOldest = 2
        case accountNewest = 3
        case accountOldest = 4

        public var id: Int { rawValue }

        /// Discord's sort menu (`779662`).
        public var title: String {
            switch self {
            case .joinedNewest: "Member Since (Newest first)"
            case .joinedOldest: "Member Since (Oldest first)"
            case .accountNewest: "Joined Discord (Newest first)"
            case .accountOldest: "Joined Discord (Oldest first)"
            }
        }
    }
}

/// Somebody waiting to be let in.
public struct GuildJoinRequest: Hashable, Sendable, Identifiable {
    public var id: UInt64
    public var userID: UserID
    public var username: String
    public var displayName: String?
    public var avatarHash: String?
    public var createdAt: Date?
    public var status: Status
    /// Their answers, in the form's own order.
    public var answers: [Answer]
    public var rejectionReason: String?
    /// The conversation a moderator opened with the applicant — Discord's
    /// Interview. Nil until somebody has.
    public var interviewChannelID: ChannelID?
    /// When a moderator approved or rejected it, and who — Discord's "By
    /// {name}" under the verdict.
    public var actionedAt: Date?
    public var actionedByName: String?

    public init(
        id: UInt64,
        userID: UserID,
        username: String,
        displayName: String? = nil,
        avatarHash: String? = nil,
        createdAt: Date? = nil,
        status: Status = .submitted,
        answers: [Answer] = [],
        rejectionReason: String? = nil,
        interviewChannelID: ChannelID? = nil,
        actionedAt: Date? = nil,
        actionedByName: String? = nil
    ) {
        self.id = id
        self.userID = userID
        self.username = username
        self.displayName = displayName
        self.avatarHash = avatarHash
        self.createdAt = createdAt
        self.status = status
        self.answers = answers
        self.rejectionReason = rejectionReason
        self.interviewChannelID = interviewChannelID
        self.actionedAt = actionedAt
        self.actionedByName = actionedByName
    }

    public struct Answer: Hashable, Sendable, Identifiable {
        public var id: Int
        public var question: String
        public var response: String

        public init(id: Int, question: String, response: String) {
            self.id = id
            self.question = question
            self.response = response
        }
    }

    /// The three tabs, and the query each sends.
    public enum Status: String, Hashable, Sendable, CaseIterable, Identifiable {
        case submitted = "SUBMITTED"
        case approved = "APPROVED"
        case rejected = "REJECTED"

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .submitted: "Pending"
            case .approved: "Approved"
            case .rejected: "Rejected"
            }
        }
    }
}
