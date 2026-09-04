import Foundation

// MARK: - The values the editors hold
//
// A draft is what an editor holds *before* a save: a value that may be
// incomplete, that carries client-minted ids the server has not seen, and that
// knows which of its own states the route will refuse.
//
// They are separate from the read models on purpose. `GuildOnboarding.Prompt`
// has a snowflake id because the server gave it one; a prompt somebody is still
// typing has no snowflake and cannot borrow the type. Reusing one struct for
// both would mean an id that is sometimes real, which is the kind of "sometimes"
// that ends up in a URL.

// MARK: - Onboarding

/// The questions, as the editor holds them.
public struct OnboardingDraft: Hashable, Sendable {
    public var prompts: [Prompt]

    public init(prompts: [Prompt] = []) {
        self.prompts = prompts
    }

    /// Read the server's answer into an editable shape.
    public init(_ onboarding: GuildOnboarding) {
        prompts = onboarding.prompts.map(Prompt.init)
    }

    /// Discord's own cap, stated on the page.
    public static let maximumAnswers = 50

    public struct Prompt: Hashable, Sendable, Identifiable {
        /// **A string, and not always a snowflake.**
        ///
        /// The captured client mints a millisecond timestamp for a new prompt —
        /// `"1788513449849"` — and the server replaces it with a real snowflake
        /// in the response. So this is whatever the server last said, or what
        /// `newID()` minted, and it is never parsed as a number.
        public var id: String
        public var title: String
        public var options: [Option]
        /// The wire's `single_select`, inverted: the page's checkbox says
        /// "Allow multiple answers".
        public var isSingleSelect: Bool
        public var isRequired: Bool
        /// The wire's `in_onboarding`, and **the pre-join / post-join split** —
        /// nothing in the payload is named for that, and Discord's editor puts
        /// `true` under "Pre-join Questions".
        public var isPreJoin: Bool

        public init(
            id: String = OnboardingDraft.newID(),
            title: String = "",
            options: [Option] = [],
            isSingleSelect: Bool = false,
            isRequired: Bool = false,
            isPreJoin: Bool = true
        ) {
            self.id = id
            self.title = title
            self.options = options
            self.isSingleSelect = isSingleSelect
            self.isRequired = isRequired
            self.isPreJoin = isPreJoin
        }

        public init(_ prompt: GuildOnboarding.Prompt) {
            id = String(prompt.id)
            title = prompt.title
            options = prompt.options.map(Option.init)
            isSingleSelect = prompt.isSingleSelect
            isRequired = prompt.isRequired
            isPreJoin = prompt.isInOnboarding
        }

        /// Whether the route will take it.
        ///
        /// Discord refuses a prompt with no title or no answers. Said here so
        /// the page can grey Save rather than send it and translate a 400.
        public var isComplete: Bool {
            !title.trimmingCharacters(in: .whitespaces).isEmpty && !options.isEmpty
        }
    }

    public struct Option: Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var detail: String?
        public var emojiName: String?
        public var emojiID: EmojiID?
        public var roleIDs: [RoleID]
        public var channelIDs: [ChannelID]

        public init(
            id: String = OnboardingDraft.newID(),
            title: String = "",
            detail: String? = nil,
            emojiName: String? = nil,
            emojiID: EmojiID? = nil,
            roleIDs: [RoleID] = [],
            channelIDs: [ChannelID] = []
        ) {
            self.id = id
            self.title = title
            self.detail = detail
            self.emojiName = emojiName
            self.emojiID = emojiID
            self.roleIDs = roleIDs
            self.channelIDs = channelIDs
        }

        public init(_ option: GuildOnboarding.Option) {
            id = String(option.id)
            title = option.title
            detail = option.detail
            emojiName = option.emojiName
            emojiID = option.emojiID
            roleIDs = option.roleIDs
            channelIDs = option.channelIDs
        }

        /// An answer that grants nothing is a control that does nothing —
        /// choosing it changes no channel and no role. Discord allows it; the
        /// page warns about it.
        public var grantsNothing: Bool { roleIDs.isEmpty && channelIDs.isEmpty }
    }

    /// A new id, in the shape the captured client uses.
    ///
    /// Milliseconds since the epoch as a decimal string. It only has to be
    /// unique within one request — the server assigns the real snowflake — and
    /// matching the reference's scheme costs nothing and removes a question.
    public static func newID() -> String {
        String(Int(Date().timeIntervalSince1970 * 1000))
    }

    public var preJoin: [Prompt] { prompts.filter(\.isPreJoin) }
    public var postJoin: [Prompt] { prompts.filter { !$0.isPreJoin } }

    /// Whether every prompt would be accepted.
    public var isSavable: Bool { prompts.allSatisfy(\.isComplete) }
}

// MARK: - AutoMod

/// A rule, as the editor holds it.
///
/// The whole reason this is not just `AutoModRule` is that a draft has to be
/// **incomplete and still representable** — a rule being built has a trigger
/// chosen and no keywords yet — and `AutoModRule.Trigger` carries its metadata
/// as associated values that must always be present.
public struct AutoModDraft: Hashable, Sendable {
    public var name: String
    public var trigger: AutoModRule.Trigger
    public var actions: [Action]
    public var isEnabled: Bool
    public var exemptRoleIDs: [RoleID]
    public var exemptChannelIDs: [ChannelID]
    public var creatorID: UserID?

    public init(
        name: String = "",
        trigger: AutoModRule.Trigger = .keyword(filter: [], regexes: [], allowList: []),
        actions: [Action] = [.blockMessage(customMessage: nil)],
        isEnabled: Bool = true,
        exemptRoleIDs: [RoleID] = [],
        exemptChannelIDs: [ChannelID] = [],
        creatorID: UserID? = nil
    ) {
        self.name = name
        self.trigger = trigger
        self.actions = actions
        self.isEnabled = isEnabled
        self.exemptRoleIDs = exemptRoleIDs
        self.exemptChannelIDs = exemptChannelIDs
        self.creatorID = creatorID
    }

    public init(_ rule: AutoModRule) {
        name = rule.name
        trigger = rule.trigger
        actions = rule.actions.compactMap(Action.init)
        isEnabled = rule.isEnabled
        exemptRoleIDs = rule.exemptRoleIDs
        exemptChannelIDs = rule.exemptChannelIDs
        creatorID = rule.creatorID
    }

    /// What the rule does. A draft's own shape, because an action being edited
    /// has a kind before it has its metadata.
    public enum Action: Hashable, Sendable, Identifiable {
        case blockMessage(customMessage: String?)
        case alert(channelID: ChannelID?)
        case timeout(seconds: Int)
        case quarantine

        public var id: Int { wireType }

        public var wireType: Int {
            switch self {
            case .blockMessage: 1
            case .alert: 2
            case .timeout: 3
            case .quarantine: 4
            }
        }

        public var alertChannelID: ChannelID? {
            if case .alert(let id) = self { return id }
            return nil
        }

        public var timeoutSeconds: Int? {
            if case .timeout(let seconds) = self { return seconds }
            return nil
        }

        public var customMessage: String? {
            if case .blockMessage(let message) = self { return message }
            return nil
        }

        public var title: String {
            switch self {
            case .blockMessage: "Block the message"
            case .alert: "Send an alert"
            case .timeout: "Time the member out"
            case .quarantine: "Quarantine the member"
            }
        }

        public var detail: String {
            switch self {
            case .blockMessage:
                "Stop the message being posted. A custom explanation can be shown."
            case .alert:
                "Post the flagged content to a channel moderators watch."
            case .timeout:
                "Temporarily stop them sending messages or joining voice."
            case .quarantine:
                "Block the join or profile update outright."
            }
        }

        init?(_ action: AutoModRule.Action) {
            switch action {
            case .blockMessage(let message): self = .blockMessage(customMessage: message)
            case .alert(let channelID): self = .alert(channelID: channelID)
            case .timeout(let seconds): self = .timeout(seconds: seconds)
            case .quarantine: self = .quarantine
            // A rule carrying an action this client cannot express is not
            // editable — see `AutoModDraft.isEditable`.
            case .unrecognised: return nil
            }
        }

        /// The longest Discord accepts: 28 days.
        public static let maximumTimeoutSeconds = 2_419_200

        public static let timeoutChoices: [Int] = [60, 300, 3600, 21600, 86400, 604_800, 2_419_200]

        public static func timeoutTitle(_ seconds: Int) -> String {
            switch seconds {
            case ..<3600: "\(seconds / 60) minutes"
            case ..<86400: "\(seconds / 3600) hours"
            case ..<604_800: "\(seconds / 86400) days"
            default: "\(seconds / 86400) days"
            }
        }
    }

    /// Whether this rule can be edited here at all.
    ///
    /// A rule whose trigger or an action is one this client has never seen is
    /// shown and left alone: saving it would rewrite the parts it cannot draw.
    public static func isEditable(_ rule: AutoModRule) -> Bool {
        if case .unrecognised = rule.trigger { return false }
        return rule.actions.allSatisfy {
            if case .unrecognised = $0 { return false }
            return true
        }
    }

    /// Whether the route would take it.
    public var isSavable: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard !actions.isEmpty else { return false }
        // An alert with nowhere to post is the one action that can be
        // half-filled, and Discord refuses it.
        if actions.contains(where: { if case .alert(let id) = $0 { return id == nil }; return false }) {
            return false
        }
        switch trigger {
        case .keyword(let filter, let regexes, _), .userProfile(let filter, let regexes, _):
            return !filter.isEmpty || !regexes.isEmpty
        case .keywordPreset(let presets, _):
            return !presets.isEmpty
        case .spam, .mentionSpam, .guildPolicy:
            return true
        case .unrecognised:
            return false
        }
    }
}

// MARK: - What a trigger permits
//
// Four things are decided by the trigger type, and offering a control the
// trigger refuses is the inert control `INVARIANTS.md` §5.5 is about. All four
// are confirmed on the wire by `community and onboarding.har`.

extension AutoModRule.Trigger {
    public var wireType: Int {
        switch self {
        case .keyword: 1
        case .spam: 3
        case .keywordPreset: 4
        case .mentionSpam: 5
        case .userProfile: 6
        case .guildPolicy: 7
        case .unrecognised(let value): value
        }
    }

    /// **Derived, never asked for.** 2 for `USER_PROFILE` — a member joining or
    /// updating a profile — and 1 for everything else, which is a message being
    /// sent or edited. Both halves are captured.
    public var eventType: Int {
        if case .userProfile = self { return 2 }
        return 1
    }

    /// Which actions this trigger will accept.
    ///
    /// `TIMEOUT_USER` only on keyword and mention-spam; `QUARANTINE_USER` only
    /// on user-profile; `GUILD_POLICY` takes **only** an alert. `BLOCK_MESSAGE`
    /// is the only one always available.
    public var permittedActions: [AutoModDraft.Action] {
        switch self {
        case .guildPolicy:
            [.alert(channelID: nil)]
        case .userProfile:
            [.blockMessage(customMessage: nil), .alert(channelID: nil), .quarantine]
        case .keyword, .mentionSpam:
            [.blockMessage(customMessage: nil), .alert(channelID: nil), .timeout(seconds: 3600)]
        // Timeout is refused on these two — the documentation restricts it to
        // keyword and mention-spam, and the wire has never been seen doing
        // otherwise.
        case .keywordPreset, .spam, .unrecognised:
            [.blockMessage(customMessage: nil), .alert(channelID: nil)]
        }
    }

    /// Whether a channel exemption list means anything. It does not for
    /// `USER_PROFILE`, which fires on a member rather than in a channel.
    public var allowsChannelExemptions: Bool {
        if case .userProfile = self { return false }
        return true
    }

    /// How many of this kind a guild may have.
    public var perGuildLimit: Int {
        if case .keyword = self { return 6 }
        return 1
    }

    /// The kinds the "create a rule" menu offers.
    ///
    /// `guildPolicy` is absent: it is Discord's own server-rules rule, created
    /// by Discord, and a client offering to make one would be offering something
    /// that is not its to make.
    public static var creatable: [AutoModRule.Trigger] {
        [
            .keyword(filter: [], regexes: [], allowList: []),
            .keywordPreset(presets: [], allowList: []),
            .mentionSpam(limit: 20, raidProtection: true),
            .spam,
            .userProfile(filter: [], regexes: [], allowList: []),
        ]
    }

    /// The metadata limits, stated where they are drawn.
    public enum Limits {
        public static let keywordCount = 1000
        public static let keywordLength = 60
        public static let regexCount = 10
        public static let regexLength = 260
        public static let allowListCount = 100
        public static let mentionLimit = 50
    }
}

extension AutoModRule.KeywordPreset {
    public var rawValue: Int {
        switch self {
        case .profanity: 1
        case .sexualContent: 2
        case .slurs: 3
        case .unrecognised(let value): value
        }
    }

    public static let selectable: [AutoModRule.KeywordPreset] = [
        .profanity, .sexualContent, .slurs,
    ]

    public var detail: String {
        switch self {
        case .profanity: "Swearing and cursing."
        case .sexualContent: "Terms referring to sexually explicit behaviour."
        case .slurs: "Personal insults and terms that may be hate speech."
        case .unrecognised: "A word set this client does not know."
        }
    }
}

// MARK: - A channel's content visibility

/// The three radio buttons on the channel Overview page.
///
/// **Not one field on the wire.** It is a *product* of `nsfw` and one flag bit,
/// and setting either cleared the other in the capture:
///
/// | Choice | `nsfw` | `flags` |
/// |---|---|---|
/// | Default | false | 0 |
/// | Spoiler | false | `1 << 21` |
/// | Age-restricted | true | 0 |
///
/// Modelling it as one enum is right by accident until somebody sets both;
/// modelling it as two switches offers a state Discord's own UI cannot express.
/// So it is one enum *here* and two fields at the encoder, which is the only
/// arrangement that is right in both places.
public enum ChannelVisibility: Hashable, Sendable, CaseIterable, Identifiable {
    case `default`
    case spoiler
    case ageRestricted

    public var id: Self { self }

    /// `IS_SPOILER_CHANNEL`, and the only flag `PATCH /channels/{id}` may set.
    public static let spoilerFlag = 1 << 21

    public init(isAgeRestricted: Bool, flags: Int) {
        if isAgeRestricted { self = .ageRestricted }
        else if flags & Self.spoilerFlag != 0 { self = .spoiler }
        else { self = .default }
    }

    public var isAgeRestricted: Bool { self == .ageRestricted }
    public var isSpoiler: Bool { self == .spoiler }

    public var title: String {
        switch self {
        case .default: "Default"
        case .spoiler: "Spoiler Channel"
        case .ageRestricted: "Age-Restricted Channel"
        }
    }

    public var detail: String {
        switch self {
        case .default:
            "Channel content is always visible."
        case .spoiler:
            "Content is hidden until somebody chooses to view it."
        case .ageRestricted:
            "Members confirm they are over the legal age. Age-restricted "
                + "channels are exempt from the explicit content filter."
        }
    }
}

/// How long a thread stays in the channel list. Minutes, and only these four.
public enum ThreadArchiveDuration {
    public static let minutes: [Int] = [60, 1440, 4320, 10080]

    public static func title(_ value: Int) -> String {
        switch value {
        case 60: "1 hour"
        case 1440: "24 hours"
        case 4320: "3 days"
        case 10080: "1 week"
        default: "\(value) minutes"
        }
    }
}

// MARK: - Deleting a channel

/// Whether a channel may be deleted, and why not.
///
/// **Discord's own client refuses this locally and never asks the server** —
/// two dialogs, neither of which fired a request. So this is not a translation
/// of an error; it is the check that has to happen *before* the route, and
/// whether the server would also refuse is unknown.
///
/// That distinction is the whole reason this type exists. If the server accepts
/// the delete, this is the only thing standing between an administrator and a
/// Server Guide pointing at a channel that no longer exists.
public enum ChannelDeleteGate {
    public enum Refusal: Hashable, Sendable {
        /// The channel is the target of a Server Guide To Do.
        case guideTask(title: String)
        /// Removing it would leave onboarding with no channel `@everyone` can
        /// both read and send in.
        case lastDefaultChannel

        public var message: String {
            switch self {
            case .guideTask(let title):
                "Remove or replace the “\(title)” task in the Server Guide before "
                    + "this channel can be deleted."
            case .lastDefaultChannel:
                "Deleting this channel would leave onboarding with no default "
                    + "channel everyone can read and send in."
            }
        }
    }

    /// Nil where the channel may go.
    ///
    /// `chattableDefaults` is the count of default channels `@everyone` can send
    /// in — the page already knows it, and computing it here would need a
    /// permission walk this type has no business doing.
    public static func refusal(
        for channelID: ChannelID,
        guide: ServerGuide?,
        onboarding: GuildOnboarding?,
        chattableDefaults: Int
    ) -> Refusal? {
        if let task = guide?.actions.first(where: { $0.channelID == channelID }) {
            return .guideTask(title: task.title)
        }
        if let onboarding, onboarding.isEnabled,
           onboarding.defaultChannelIDs.contains(channelID),
           chattableDefaults <= 1
        {
            return .lastDefaultChannel
        }
        return nil
    }
}
