import Foundation

// MARK: - The audit log
//
// One route, fifty entries a page, and a shape that is easy to read wrongly:
// **the entry does not carry the objects it names.** `user_id` is a snowflake and
// the users are in a sibling array; the same is true of the webhooks, the
// integrations, the threads and the AutoMod rules. Decoding an entry in isolation
// therefore produces a row that knows an action happened and cannot say to what.
//
// So `AuditLogPage` is the unit, not `AuditLogEntry` — the side tables come with
// the entries or neither is useful.

/// One page of a server's audit log, with the objects its entries refer to.
public struct AuditLogPage: Hashable, Sendable {
    public var entries: [AuditLogEntry]
    /// Everybody named by an entry, whether as the actor or the target.
    public var users: [UserID: AuditLogUser]
    /// Webhook and integration names, so a row can say *which* one was deleted.
    public var webhookNames: [UInt64: String]
    public var integrationNames: [UInt64: String]
    public var autoModRuleNames: [UInt64: String]

    public init(
        entries: [AuditLogEntry] = [],
        users: [UserID: AuditLogUser] = [:],
        webhookNames: [UInt64: String] = [:],
        integrationNames: [UInt64: String] = [:],
        autoModRuleNames: [UInt64: String] = [:]
    ) {
        self.entries = entries
        self.users = users
        self.webhookNames = webhookNames
        self.integrationNames = integrationNames
        self.autoModRuleNames = autoModRuleNames
    }

    /// The id to page from. The route pages on `before`, and the oldest entry on
    /// this page is where the next one starts.
    public var oldestEntryID: UInt64? { entries.last?.id }

    /// Merges a following page in.
    ///
    /// The side tables are merged rather than replaced: page two carries only
    /// the users page two mentions, and replacing would blank every name on the
    /// rows already drawn.
    public func appending(_ next: AuditLogPage) -> AuditLogPage {
        AuditLogPage(
            entries: entries + next.entries,
            users: users.merging(next.users) { current, _ in current },
            webhookNames: webhookNames.merging(next.webhookNames) { current, _ in current },
            integrationNames: integrationNames.merging(next.integrationNames) { current, _ in current },
            autoModRuleNames: autoModRuleNames.merging(next.autoModRuleNames) { current, _ in current }
        )
    }
}

/// Just enough of a user to name them on a log row.
///
/// Not `User`: that type carries collectibles, a banner, display-name styles and
/// a profile, and the log's own `users` array is fifty of them on a busy server.
/// A row needs a name and an avatar.
public struct AuditLogUser: Hashable, Sendable, Identifiable {
    public var id: UserID
    public var username: String
    public var displayName: String?
    public var avatarHash: String?

    public init(id: UserID, username: String, displayName: String? = nil, avatarHash: String? = nil) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.avatarHash = avatarHash
    }

    public var name: String { displayName ?? username }
}

/// One thing somebody did.
public struct AuditLogEntry: Hashable, Sendable, Identifiable {
    public var id: UInt64
    public var action: AuditLogAction
    /// Nil where Discord itself acted — an AutoMod block has no actor.
    public var userID: UserID?
    /// What was acted on. A snowflake for most actions and **nil for several**:
    /// a soundboard sound delete carries its identity in `changes` instead,
    /// which is why the row falls back to the changed fields for its subject.
    public var targetID: UInt64?
    public var reason: String?
    public var changes: [Change]
    /// The entry's `options`, rendered — an overwrite's role, a prune's count,
    /// an AutoMod rule's name, a message's channel. Discord compares them when
    /// it merges a run of entries (`AuditLogMerge`), so they are kept whole.
    public var options: [String: String]

    public init(
        id: UInt64,
        action: AuditLogAction,
        userID: UserID? = nil,
        targetID: UInt64? = nil,
        reason: String? = nil,
        changes: [Change] = [],
        options: [String: String] = [:]
    ) {
        self.id = id
        self.action = action
        self.userID = userID
        self.targetID = targetID
        self.reason = reason
        self.changes = changes
        self.options = options
    }

    /// When it happened, from the entry's own snowflake. Nothing to fetch and
    /// nothing that can disagree with the id.
    public var timestamp: Date { Snowflake<AuditLogTag>(rawValue: id).timestamp }

    /// One field that moved.
    ///
    /// **Both values are rendered strings, not the raw JSON.** The wire sends
    /// anything at all here — a bool, a float, a snowflake, a whole permission
    /// bitfield as a decimal string, an array of overwrite objects — and a log
    /// row's job is to say what changed in words. The conversion happens once,
    /// at the decoder, so no view branches on a JSON value.
    public struct Change: Hashable, Sendable, Identifiable {
        public var id: String { key }
        public var key: String
        public var before: String?
        public var after: String?

        public init(key: String, before: String? = nil, after: String? = nil) {
            self.key = key
            self.before = before
            self.after = after
        }

        /// The field's name in words. Unrecognised keys are de-snaked rather
        /// than dropped — "rate_limit_per_user" reads as "Rate limit per user",
        /// which is worse than a hand-written label and much better than a row
        /// that lists nothing.
        public var title: String {
            switch key {
            case "name": "Name"
            case "description": "Description"
            case "icon_hash", "icon": "Icon"
            case "permissions": "Permissions"
            case "color", "colors": "Colour"
            case "hoist": "Displayed separately"
            case "mentionable": "Mentionable"
            case "position": "Position"
            case "topic": "Topic"
            case "nsfw": "Age-restricted"
            case "rate_limit_per_user": "Slowmode"
            case "bitrate": "Bitrate"
            case "user_limit": "User limit"
            case "allow": "Allowed"
            case "deny": "Denied"
            case "type": "Type"
            case "enabled", "available": "Enabled"
            case "volume": "Volume"
            case "emoji_name", "emoji_id": "Emoji"
            case "tags": "Related emoji"
            case "max_age": "Expires after"
            case "max_uses": "Maximum uses"
            case "temporary": "Temporary membership"
            case "code": "Invite code"
            case "channel_id": "Channel"
            case "system_channel_id": "System messages channel"
            case "rules_channel_id": "Rules channel"
            case "public_updates_channel_id": "Community updates channel"
            case "safety_alerts_channel_id": "Safety alerts channel"
            case "afk_channel_id": "Inactive channel"
            case "afk_timeout": "Inactive timeout"
            case "preferred_locale": "Primary language"
            case "verification_level": "Verification level"
            case "explicit_content_filter": "Explicit content filter"
            case "default_message_notifications": "Default notifications"
            case "owner_configured_content_level": "Age-restricted server"
            case "features": "Features"
            case "prompts": "Onboarding questions"
            case "default_channel_ids": "Default channels"
            case "vanity_url_code": "Vanity URL"
            case "trigger_metadata", "trigger_type": "Trigger"
            case "actions": "Actions"
            case "exempt_roles": "Exempt roles"
            case "exempt_channels": "Exempt channels"
            default:
                key.replacingOccurrences(of: "_", with: " ")
                    .prefix(1).uppercased() + key.replacingOccurrences(of: "_", with: " ").dropFirst()
            }
        }
    }
}

/// Discord's snowflake tag for an audit log entry. Its own type so an entry id
/// cannot be passed where a message id belongs.
public enum AuditLogTag {}

/// What kind of thing an audit log entry records.
///
/// The full table, because a log that says "Action 84" for a stage instance is a
/// log that stops being read. An unrecognised code keeps its number rather than
/// folding into a catch-all — the set grows every release, and "Unknown" tells
/// the reader strictly less than "Action 220" does.
public enum AuditLogAction: Hashable, Sendable {
    case guildUpdate
    case channelCreate, channelUpdate, channelDelete
    case overwriteCreate, overwriteUpdate, overwriteDelete
    case memberKick, memberPrune, memberBanAdd, memberBanRemove
    case memberUpdate, memberRoleUpdate, memberMove, memberDisconnect, botAdd
    case roleCreate, roleUpdate, roleDelete
    case inviteCreate, inviteUpdate, inviteDelete
    case webhookCreate, webhookUpdate, webhookDelete
    case emojiCreate, emojiUpdate, emojiDelete
    case messageDelete, messageBulkDelete, messagePin, messageUnpin
    case integrationCreate, integrationUpdate, integrationDelete
    case stageInstanceCreate, stageInstanceUpdate, stageInstanceDelete
    case stickerCreate, stickerUpdate, stickerDelete
    case eventCreate, eventUpdate, eventDelete
    case threadCreate, threadUpdate, threadDelete
    case commandPermissionUpdate
    case soundboardCreate, soundboardUpdate, soundboardDelete
    case autoModRuleCreate, autoModRuleUpdate, autoModRuleDelete
    case autoModBlockMessage, autoModFlagToChannel, autoModTimeout, autoModQuarantine
    case onboardingPromptCreate, onboardingPromptUpdate, onboardingPromptDelete
    case onboardingCreate, onboardingUpdate
    case homeSettingsCreate, homeSettingsUpdate
    case memberVerificationUpdate
    case guildProfileUpdate
    case unrecognised(Int)

    public init(rawValue: Int) {
        self = switch rawValue {
        case 1: .guildUpdate
        case 10: .channelCreate
        case 11: .channelUpdate
        case 12: .channelDelete
        case 13: .overwriteCreate
        case 14: .overwriteUpdate
        case 15: .overwriteDelete
        case 20: .memberKick
        case 21: .memberPrune
        case 22: .memberBanAdd
        case 23: .memberBanRemove
        case 24: .memberUpdate
        case 25: .memberRoleUpdate
        case 26: .memberMove
        case 27: .memberDisconnect
        case 28: .botAdd
        case 30: .roleCreate
        case 31: .roleUpdate
        case 32: .roleDelete
        case 40: .inviteCreate
        case 41: .inviteUpdate
        case 42: .inviteDelete
        case 50: .webhookCreate
        case 51: .webhookUpdate
        case 52: .webhookDelete
        case 60: .emojiCreate
        case 61: .emojiUpdate
        case 62: .emojiDelete
        case 72: .messageDelete
        case 73: .messageBulkDelete
        case 74: .messagePin
        case 75: .messageUnpin
        case 80: .integrationCreate
        case 81: .integrationUpdate
        case 82: .integrationDelete
        case 83: .stageInstanceCreate
        case 84: .stageInstanceUpdate
        case 85: .stageInstanceDelete
        case 90: .stickerCreate
        case 91: .stickerUpdate
        case 92: .stickerDelete
        case 100: .eventCreate
        case 101: .eventUpdate
        case 102: .eventDelete
        case 110: .threadCreate
        case 111: .threadUpdate
        case 112: .threadDelete
        case 121: .commandPermissionUpdate
        case 130: .soundboardCreate
        case 131: .soundboardUpdate
        case 132: .soundboardDelete
        case 140: .autoModRuleCreate
        case 141: .autoModRuleUpdate
        case 142: .autoModRuleDelete
        case 143: .autoModBlockMessage
        case 144: .autoModFlagToChannel
        case 145: .autoModTimeout
        case 146: .autoModQuarantine
        case 163: .onboardingPromptCreate
        case 164: .onboardingPromptUpdate
        case 165: .onboardingPromptDelete
        case 166: .onboardingCreate
        case 167: .onboardingUpdate
        case 190: .homeSettingsCreate
        case 191: .homeSettingsUpdate
        case 210: .memberVerificationUpdate
        case 211: .guildProfileUpdate
        default: .unrecognised(rawValue)
        }
    }

    /// What the row says, with `%@` standing for the actor's name.
    ///
    /// Written as a sentence per action rather than as "verb + noun" assembled
    /// at the view, because English does not assemble: "created a role" and
    /// "updated the server profile" take different articles, and a generic
    /// builder produces "updated a server profile" on half of them.
    public var sentence: String {
        switch self {
        case .guildUpdate: "updated the server settings"
        case .channelCreate: "created a channel"
        case .channelUpdate: "updated a channel"
        case .channelDelete: "deleted a channel"
        case .overwriteCreate: "added a permission to a channel"
        case .overwriteUpdate: "updated a channel's permissions"
        case .overwriteDelete: "removed a permission from a channel"
        case .memberKick: "removed a member"
        case .memberPrune: "pruned inactive members"
        case .memberBanAdd: "banned a member"
        case .memberBanRemove: "lifted a ban"
        case .memberUpdate: "updated a member"
        case .memberRoleUpdate: "changed a member's roles"
        case .memberMove: "moved a member between voice channels"
        case .memberDisconnect: "disconnected a member from voice"
        case .botAdd: "added a bot"
        case .roleCreate: "created a role"
        case .roleUpdate: "edited a role"
        case .roleDelete: "deleted a role"
        case .inviteCreate: "created an invite"
        case .inviteUpdate: "updated an invite"
        case .inviteDelete: "revoked an invite"
        case .webhookCreate: "created a webhook"
        case .webhookUpdate: "updated a webhook"
        case .webhookDelete: "deleted a webhook"
        case .emojiCreate: "added an emoji"
        case .emojiUpdate: "renamed an emoji"
        case .emojiDelete: "removed an emoji"
        case .messageDelete: "deleted a message"
        case .messageBulkDelete: "deleted several messages"
        case .messagePin: "pinned a message"
        case .messageUnpin: "unpinned a message"
        case .integrationCreate: "added an integration"
        case .integrationUpdate: "updated an integration"
        case .integrationDelete: "removed an integration"
        case .stageInstanceCreate: "started a stage"
        case .stageInstanceUpdate: "updated a stage"
        case .stageInstanceDelete: "ended a stage"
        case .stickerCreate: "added a sticker"
        case .stickerUpdate: "updated a sticker"
        case .stickerDelete: "removed a sticker"
        case .eventCreate: "created an event"
        case .eventUpdate: "updated an event"
        case .eventDelete: "cancelled an event"
        case .threadCreate: "created a thread"
        case .threadUpdate: "updated a thread"
        case .threadDelete: "deleted a thread"
        case .commandPermissionUpdate: "changed a command's permissions"
        case .soundboardCreate: "added a soundboard sound"
        case .soundboardUpdate: "updated a soundboard sound"
        case .soundboardDelete: "removed a soundboard sound"
        case .autoModRuleCreate: "created an AutoMod rule"
        case .autoModRuleUpdate: "updated an AutoMod rule"
        case .autoModRuleDelete: "deleted an AutoMod rule"
        case .autoModBlockMessage: "had a message blocked by AutoMod"
        case .autoModFlagToChannel: "had a message flagged by AutoMod"
        case .autoModTimeout: "was timed out by AutoMod"
        case .autoModQuarantine: "was quarantined by AutoMod"
        case .onboardingPromptCreate: "created an onboarding question"
        case .onboardingPromptUpdate: "updated an onboarding question"
        case .onboardingPromptDelete: "deleted an onboarding question"
        case .onboardingCreate: "set up onboarding"
        case .onboardingUpdate: "updated onboarding"
        case .homeSettingsCreate: "set up the Server Guide"
        case .homeSettingsUpdate: "updated the Server Guide"
        case .memberVerificationUpdate: "updated the join application"
        case .guildProfileUpdate: "updated the server profile"
        case .unrecognised(let code): "performed action \(code)"
        }
    }

    /// The glyph on the row. Grouped by *what was touched* rather than by verb,
    /// so a column of them reads as a grouped list.
    public var symbolName: String {
        switch self {
        case .guildUpdate, .guildProfileUpdate: "gearshape.fill"
        case .channelCreate, .channelUpdate, .channelDelete: "number"
        case .overwriteCreate, .overwriteUpdate, .overwriteDelete: "lock.fill"
        case .memberKick, .memberPrune, .memberUpdate, .memberRoleUpdate,
             .memberMove, .memberDisconnect, .botAdd: "person.fill"
        case .memberBanAdd, .memberBanRemove: "hand.raised.fill"
        case .roleCreate, .roleUpdate, .roleDelete: "shield.fill"
        case .inviteCreate, .inviteUpdate, .inviteDelete: "link"
        case .webhookCreate, .webhookUpdate, .webhookDelete: "arrow.triangle.branch"
        case .emojiCreate, .emojiUpdate, .emojiDelete: "face.smiling.inverse"
        case .stickerCreate, .stickerUpdate, .stickerDelete: "seal.fill"
        case .soundboardCreate, .soundboardUpdate, .soundboardDelete: "speaker.wave.2.fill"
        case .messageDelete, .messageBulkDelete, .messagePin, .messageUnpin: "bubble.left.fill"
        case .integrationCreate, .integrationUpdate, .integrationDelete,
             .commandPermissionUpdate: "puzzlepiece.extension.fill"
        case .stageInstanceCreate, .stageInstanceUpdate, .stageInstanceDelete: "mic.fill"
        case .eventCreate, .eventUpdate, .eventDelete: "calendar"
        case .threadCreate, .threadUpdate, .threadDelete: "bubble.left.and.bubble.right.fill"
        case .autoModRuleCreate, .autoModRuleUpdate, .autoModRuleDelete,
             .autoModBlockMessage, .autoModFlagToChannel, .autoModTimeout,
             .autoModQuarantine: "exclamationmark.shield.fill"
        case .onboardingPromptCreate, .onboardingPromptUpdate, .onboardingPromptDelete,
             .onboardingCreate, .onboardingUpdate: "square.grid.2x2"
        case .homeSettingsCreate, .homeSettingsUpdate: "signpost.right.fill"
        case .memberVerificationUpdate: "envelope.fill"
        case .unrecognised: "questionmark"
        }
    }

    /// Whether this action removed something. The row's glyph tile is tinted by
    /// it — one bit, three colours, and no per-case colour table to drift.
    public var isDestructive: Bool {
        switch self {
        case .channelDelete, .overwriteDelete, .memberKick, .memberPrune, .memberBanAdd,
             .memberDisconnect, .roleDelete, .inviteDelete, .webhookDelete, .emojiDelete,
             .messageDelete, .messageBulkDelete, .integrationDelete, .stageInstanceDelete,
             .stickerDelete, .eventDelete, .threadDelete, .soundboardDelete,
             .autoModRuleDelete, .autoModBlockMessage, .autoModTimeout, .autoModQuarantine,
             .onboardingPromptDelete:
            true
        default:
            false
        }
    }

    public var isCreation: Bool {
        switch self {
        case .channelCreate, .overwriteCreate, .roleCreate, .inviteCreate, .webhookCreate,
             .emojiCreate, .integrationCreate, .stageInstanceCreate, .stickerCreate,
             .eventCreate, .threadCreate, .soundboardCreate, .autoModRuleCreate,
             .onboardingPromptCreate, .onboardingCreate, .homeSettingsCreate, .botAdd:
            true
        default:
            false
        }
    }
}

// MARK: - AutoMod

/// One AutoMod rule.
public struct AutoModRule: Hashable, Sendable, Identifiable {
    public var id: UInt64
    public var name: String
    public var creatorID: UserID?
    public var isEnabled: Bool
    public var trigger: Trigger
    public var actions: [Action]
    public var exemptRoleIDs: [RoleID]
    public var exemptChannelIDs: [ChannelID]

    public init(
        id: UInt64,
        name: String,
        creatorID: UserID? = nil,
        isEnabled: Bool = true,
        trigger: Trigger = .unrecognised(0),
        actions: [Action] = [],
        exemptRoleIDs: [RoleID] = [],
        exemptChannelIDs: [ChannelID] = []
    ) {
        self.id = id
        self.name = name
        self.creatorID = creatorID
        self.isEnabled = isEnabled
        self.trigger = trigger
        self.actions = actions
        self.exemptRoleIDs = exemptRoleIDs
        self.exemptChannelIDs = exemptChannelIDs
    }

    /// What sets the rule off, with the metadata that belongs to that kind.
    ///
    /// An enum with associated values rather than a code plus a bag of optional
    /// fields: `keywordFilter` is meaningless on a mention-spam rule and
    /// `mentionLimit` is meaningless on a keyword one, and a struct carrying
    /// both has two fields that are always nil on every rule.
    public enum Trigger: Hashable, Sendable {
        case keyword(filter: [String], regexes: [String], allowList: [String])
        case spam
        case keywordPreset(presets: [KeywordPreset], allowList: [String])
        case mentionSpam(limit: Int, raidProtection: Bool)
        case userProfile(filter: [String], regexes: [String], allowList: [String])
        case guildPolicy
        case unrecognised(Int)

        public var title: String {
            switch self {
            case .keyword: "Blocked Words"
            case .spam: "Spam Content"
            case .keywordPreset: "Commonly Flagged Words"
            case .mentionSpam: "Mention Spam"
            case .userProfile: "Blocked Words in Profiles"
            case .guildPolicy: "Server Rules"
            case .unrecognised(let code): "Trigger \(code)"
            }
        }

        public var detail: String {
            switch self {
            case .keyword(let filter, let regexes, _):
                let count = filter.count + regexes.count
                return count == 1 ? "1 term" : "\(count) terms"
            case .spam:
                return "Generic spam Discord recognises"
            case .keywordPreset(let presets, _):
                return presets.isEmpty
                    ? "No word sets selected"
                    : presets.map(\.title).formatted(.list(type: .and))
            case .mentionSpam(let limit, let raid):
                return raid
                    ? "More than \(limit) mentions, and raids"
                    : "More than \(limit) mentions"
            case .userProfile(let filter, let regexes, _):
                let count = filter.count + regexes.count
                return count == 1 ? "1 term" : "\(count) terms"
            case .guildPolicy:
                return "Behaviour that breaks this server's rules"
            case .unrecognised:
                return "This client does not know what sets this rule off"
            }
        }
    }

    public enum KeywordPreset: Hashable, Sendable {
        case profanity
        case sexualContent
        case slurs
        case unrecognised(Int)

        public init(rawValue: Int) {
            self = switch rawValue {
            case 1: .profanity
            case 2: .sexualContent
            case 3: .slurs
            default: .unrecognised(rawValue)
            }
        }

        public var title: String {
            switch self {
            case .profanity: "Profanity"
            case .sexualContent: "Sexual content"
            case .slurs: "Slurs"
            case .unrecognised(let value): "Set \(value)"
            }
        }
    }

    /// What the rule does when it fires.
    public enum Action: Hashable, Sendable, Identifiable {
        case blockMessage(explanation: String?)
        case alert(channelID: ChannelID?)
        case timeout(seconds: Int)
        case quarantine
        case unrecognised(Int)

        public var id: Int {
            switch self {
            case .blockMessage: 1
            case .alert: 2
            case .timeout: 3
            case .quarantine: 4
            case .unrecognised(let code): code
            }
        }

        public var title: String {
            switch self {
            case .blockMessage: "Block the message"
            case .alert: "Send an alert"
            case .timeout(let seconds): "Time the member out for \(Self.duration(seconds))"
            case .quarantine: "Quarantine the member"
            case .unrecognised(let code): "Action \(code)"
            }
        }

        private static func duration(_ seconds: Int) -> String {
            switch seconds {
            case ..<3600: "\(max(1, seconds / 60)) minutes"
            case ..<86400: "\(seconds / 3600) hours"
            default: "\(seconds / 86400) days"
            }
        }
    }
}

// MARK: - Safety Setup's counts

/// "3 of 5 enabled" — what Discord's Safety Setup overview (`uP`, `uM`) says
/// under each of its four rows.
public enum SafetyCounts {
    /// Raid Protection and CAPTCHA: Activity Alerts, and Discord's two CAPTCHA
    /// statements, which are always on.
    public static func raidProtection(features: Set<String>) -> (enabled: Int, total: Int) {
        (features.contains("RAID_ALERTS_DISABLED") ? 2 : 3, 3)
    }

    /// DM and Spam Protection: the Verification Level row and four always-on
    /// statements — five, all enabled.
    public static let dmAndSpam = (enabled: 5, total: 5)

    /// AutoMod: every kind of rule Discord offers counts once even with no
    /// rule of it, and every rule of a kind counts once — enabled ones as
    /// enabled. A kind this client cannot name does not count.
    public static func autoMod(_ rules: [AutoModRule]) -> (enabled: Int, total: Int) {
        var enabled = 0
        var total = 0
        for kind in AutoModRule.Trigger.offeredKinds {
            let ofKind = rules.filter { $0.trigger.kind == kind }
            if ofKind.isEmpty {
                total += 1
            } else {
                total += ofKind.count
                enabled += ofKind.filter(\.isEnabled).count
            }
        }
        return (enabled, total)
    }

    /// Permissions: two-factor for moderators, member prune for admins only,
    /// and no risky permissions on `@everyone`.
    public static func permissions(
        mfaLevel: Int,
        features: Set<String>,
        everyonePermissions: Permissions?
    ) -> (enabled: Int, total: Int) {
        var enabled = 0
        if mfaLevel == 1 { enabled += 1 }
        if features.contains("PRUNE_REQUIRES_ADMIN") { enabled += 1 }
        if let everyonePermissions, everyonePermissions.isDisjoint(with: .risky) { enabled += 1 }
        return (enabled, 3)
    }

    /// Discord's sentence: "{enabled} of {total} enabled".
    public static func sentence(_ count: (enabled: Int, total: Int)) -> String {
        "\(count.enabled) of \(count.total) enabled"
    }
}

extension AutoModRule.Trigger {
    /// The rule kinds Safety Setup counts — Discord's own, in its order:
    /// keyword, spam, keyword preset, mention spam, member profile.
    public static let offeredKinds = [1, 3, 4, 5, 6]

    /// The trigger's wire type, or nil for one this client cannot name.
    public var kind: Int? {
        switch self {
        case .keyword: 1
        case .spam: 3
        case .keywordPreset: 4
        case .mentionSpam: 5
        case .userProfile: 6
        case .guildPolicy, .unrecognised: nil
        }
    }
}
