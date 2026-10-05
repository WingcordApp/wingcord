import Foundation

/// A message AutoMod posted — Discord's `AUTO_MODERATION_ACTION`, read the way
/// its client reads one (`877133`): from the named fields of the **first**
/// embed, and only when that embed is AutoMod's.
///
/// **Two cards from one kind.** A message carrying an
/// `auto_moderation_notification` embed is a notice about the whole server — a
/// raid, a mention raid, Activity Alerts switched on (`iu`); every other one is
/// an alert about one member's message, name or join (`n0`).
public enum AutoModMessage: Hashable, Sendable {
    case alert(AutoModAlert)
    case notification(AutoModNotification)

    /// The people the card names besides the message's own author: the person
    /// an app's modal was shown to, and whoever switched Activity Alerts on.
    public var namedUserIDs: [UserID] {
        switch self {
        case .alert(let alert): [alert.interactionUserID].compactMap { $0 }
        case .notification(let notice): [notice.actionByUserID].compactMap { $0 }
        }
    }

    /// Nil for anything AutoMod did not post.
    public init?(_ message: Message) {
        guard message.kind == .autoModerationAction else { return nil }
        let fields = AutoModFields(message.embeds.first)
        if message.embeds.contains(where: { $0.kind == AutoModFields.notificationKind }) {
            self = .notification(AutoModNotification(fields))
        } else {
            // The words are the first embed's description, whatever its kind —
            // Discord's `rawDescription` read.
            self = .alert(AutoModAlert(fields, content: message.embeds.first?.description ?? ""))
        }
    }
}

/// An alert about one member: the message AutoMod blocked or flagged, the name
/// it refused, the join it held.
public struct AutoModAlert: Hashable, Sendable {
    /// What the member wrote, as AutoMod kept it.
    public var content: String
    public var ruleName: String?
    /// Where the member wrote it — not the alert channel this is posted in.
    public var channelID: ChannelID?
    public var keyword: String?
    /// The words in `content` the rule matched, lit in the card.
    public var keywordMatchedContent: String?
    /// The message itself, where it was flagged rather than blocked and still
    /// exists: the card opens it, and Delete User's Message removes it.
    public var flaggedMessageID: MessageID?
    /// "Timeout: 1 hour" — Discord's six lengths only (`getFriendlyDurationString`).
    public var timeoutLabel: String?
    /// "Reason: Nickname" — what a quarantine was over (`o2`).
    public var quarantineReason: String?
    /// The line under the footer, in its own plate.
    public var decisionReason: String?
    /// The app whose message or modal it was, when an app's.
    public var applicationName: String?
    /// The person an app's modal was shown to.
    public var interactionUserID: UserID?
    /// What moderators have done about it, newest kind first.
    public var executedActions: [AutoModExecutedAction]

    // The sentence's inputs — see `headline`.
    var quarantineUser: String?
    var quarantineUserAction: String?
    var quarantineEvent: String?
    var blockProfileUpdateType: String?
    var decisionOutcome: String?
    var interactionCallbackType: String?
    var voiceChannelStatusOutcome: String?
    var roomNoteOutcome: String?

    init(_ fields: AutoModFields, content: String) {
        self.content = content
        ruleName = fields["rule_name"]
        channelID = fields["channel_id"].flatMap(UInt64.init).map(ChannelID.init(rawValue:))
        keyword = fields["keyword"]
        keywordMatchedContent = fields["keyword_matched_content"]
        flaggedMessageID = fields["flagged_message_id"].flatMap(UInt64.init).map(MessageID.init(rawValue:))
        // `Number(raw)`, then one of the six — anything else draws no timeout.
        timeoutLabel = fields["timeout_duration"]
            .flatMap(Int.init)
            .flatMap(TimeoutDuration.init(rawValue:))?
            .title
        quarantineUser = fields["quarantine_user"]
        quarantineReason = quarantineUser.map(Self.quarantineReason)
        decisionReason = fields["decision_reason"]
        applicationName = fields["application_name"]
        interactionUserID = fields["interaction_user_id"].flatMap(UInt64.init).map(UserID.init(rawValue:))
        executedActions = AutoModExecutedAction.parse(fields["alert_actions_execution"])
        quarantineUserAction = fields["quarantine_user_action"]
        quarantineEvent = fields["quarantine_event"]
        blockProfileUpdateType = fields["block_profile_update_type"]
        decisionOutcome = fields["decision_outcome"]
        interactionCallbackType = fields["interaction_callback_type"]
        voiceChannelStatusOutcome = fields["voice_channel_status_outcome"]
        roomNoteOutcome = fields["guild_room_note_outcome"]
    }

    /// Discord's `o2`. A bio has no case of its own there, so it reads
    /// "Username", as Discord's does.
    static func quarantineReason(_ type: String) -> String {
        switch type {
        case "nickname": "Nickname"
        case "display_name": "Display Name"
        case "clan_tag": "Tag"
        default: "Username"
        }
    }

    /// Whether a moderator already deleted the member's message — Discord takes
    /// the button away then.
    public var deletedFlaggedMessage: Bool {
        executedActions.contains { $0.kind == .deleteUserMessage }
    }

    /// The sentence after "AutoMod ✓ OFFICIAL" — Discord's `fu`, in its order:
    /// a quarantine or a refused name says what happened and names no channel;
    /// a voice status, a Living Room note, an app's message or modal, and then
    /// the ordinary message, each "blocked" or "flagged" by the decision.
    ///
    /// - Parameter knowsInteractionUser: whether the person an app's modal was
    ///   shown to can be named — Discord falls back to the app's message
    ///   sentence when it cannot.
    public func headline(knowsInteractionUser: Bool) -> [AutoModHeadlineRun] {
        if quarantineUser != nil, let fixed = quarantineSentence {
            return [.text(fixed)]
        }
        if let outcome = voiceChannelStatusOutcome {
            let verb = outcome == "blocked" ? "has blocked" : "has flagged"
            return [.text("\(verb) a voice channel status for "), .channel]
        }
        if let outcome = roomNoteOutcome {
            let verb = outcome == "blocked" ? "has blocked" : "has flagged"
            return [.text("\(verb) a Living Room note for "), .channel]
        }
        let blocked = decisionOutcome == "blocked"
        if let app = applicationName {
            if interactionCallbackType == "MODAL", knowsInteractionUser {
                return blocked
                    ? [.text("has blocked "), .bold(app), .text("\u{2019}s modal from being shown to "),
                       .interactionUser, .text(". The interaction with "), .bold(app),
                       .text(" was started by "), .author, .text(".")]
                    : [.text("has flagged "), .bold(app), .text("\u{2019}s modal, shown to "),
                       .interactionUser, .text(". The interaction with "), .bold(app),
                       .text(" was started by "), .author, .text(".")]
            }
            return [.text(blocked ? "has blocked " : "has flagged "), .bold(app),
                    .text("\u{2019}s message in "), .channel, .text(", sent by "), .author]
        }
        return [.text(blocked ? "has blocked a message in " : "has flagged a message in "), .channel]
    }

    /// The fixed sentences for a refused profile change or a quarantine.
    private var quarantineSentence: String? {
        switch quarantineUserAction {
        case "block_profile_update":
            switch blockProfileUpdateType {
            case "nickname_update": "blocked a nickname update"
            case "nickname_reset": "blocked a nickname reset"
            default: nil
            }
        case "quarantine_user":
            switch quarantineEvent {
            case "message_send": "quarantined a member at message send"
            case "guild_join": "quarantined a member at server join"
            case "username_update": "quarantined a member at username update"
            case "clan_tag_update": "quarantined a member at tag adoption"
            default: nil
            }
        case "block_guest_join": "blocked a guest at server join"
        default: nil
        }
    }

    /// Where `keywordMatchedContent` is lit in `content`.
    public var highlightRanges: [Range<String.Index>] {
        keywordMatchedContent.map { Self.highlightRanges(of: $0, in: content) } ?? []
    }

    /// Discord's `highlightWord` rule: each occurrence of `word` standing
    /// between whitespace or the ends of the text, at most eleven — the rule
    /// stops ten levels down.
    public static func highlightRanges(of word: String, in text: String) -> [Range<String.Index>] {
        guard !word.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while ranges.count < 11, let found = boundedMatch(of: word, in: text, from: searchStart) {
            ranges.append(found)
            searchStart = found.upperBound
        }
        return ranges
    }

    /// The first occurrence from `start` with whitespace, or an end of the
    /// remaining text, on both sides — Discord's `eT` and `em`, which judge
    /// against the text the rule is matching at that depth.
    private static func boundedMatch(
        of word: String, in text: String, from start: String.Index
    ) -> Range<String.Index>? {
        var from = start
        while let found = text.range(of: word, range: from..<text.endIndex) {
            let before = found.lowerBound == start || text[text.index(before: found.lowerBound)].isWhitespace
            let after = found.upperBound == text.endIndex || text[found.upperBound].isWhitespace
            if before, after { return found }
            from = text.index(after: found.lowerBound)
        }
        return nil
    }
}

/// One piece of Discord's AutoMod sentence.
public enum AutoModHeadlineRun: Hashable, Sendable {
    case text(String)
    case bold(String)
    /// The channel — Discord's channel pill, or "unknown-channel" where it
    /// cannot be named.
    case channel
    /// The member the alert is about: the message's own author.
    case author
    /// The person an app's modal was shown to.
    case interactionUser
}

/// What a moderator did about an alert (`alert_actions_execution`).
public struct AutoModExecutedAction: Hashable, Sendable {
    public enum Kind: Int, Hashable, Sendable {
        case setCompleted = 1
        case unsetCompleted = 2
        case deleteUserMessage = 3
        case submitFeedback = 4
    }

    public var kind: Kind
    public var actorID: UserID
    public var date: Date?

    /// The field is JSON in a string: `{"actions": {"3": {"actor": …, "ts": …}}}`.
    /// Discord orders them by kind, highest first.
    static func parse(_ raw: String?) -> [AutoModExecutedAction] {
        guard let data = raw?.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let actions = root["actions"] as? [String: Any]
        else { return [] }
        return actions.compactMap { key, value -> AutoModExecutedAction? in
            guard let kind = Int(key).flatMap(Kind.init(rawValue:)),
                  let entry = value as? [String: Any],
                  let actor = (entry["actor"] as? String).flatMap(UInt64.init)
                    ?? (entry["actor"] as? NSNumber)?.uint64Value
            else { return nil }
            return AutoModExecutedAction(kind: kind, actorID: UserID(rawValue: actor), date: date(entry["ts"]))
        }
        .sorted { $0.kind.rawValue > $1.kind.rawValue }
    }

    /// moment's reading: a number is milliseconds, a string an ISO date.
    private static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue / 1000) }
        guard let text = value as? String else { return nil }
        if let milliseconds = Double(text) { return Date(timeIntervalSince1970: milliseconds / 1000) }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// Discord's tooltip over the action's mark (`nQ`), or nil for one it
    /// draws nothing for.
    public func sentence(actorName: String, now: Date = .now) -> String? {
        let when = date.map { MomentRelativeTime.fromNow($0, now: now) } ?? ""
        switch kind {
        case .deleteUserMessage: return "\(actorName) deleted message \(when)"
        case .setCompleted: return "\(actorName) marked complete \(when)"
        case .submitFeedback: return "\(actorName) reported issues \(when)"
        case .unsetCompleted: return nil
        }
    }
}

/// A notice about the whole server (`iu`) — the card under "AutoMod ✓ OFFICIAL".
public struct AutoModNotification: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Unusual joins, or unusual DMs — also what a notice without a type is.
        case raid(isDirectMessageRaid: Bool)
        case mentionRaid
        case activityAlertsEnabled
        case interactionBlocked
        /// A type this client does not know — Discord's own "Unsupported
        /// Message" card.
        case unsupported
    }

    public var kind: Kind
    public var joinAttempts: Int?
    public var directMessagesSent: Int?
    public var raidDate: Date?
    public var decisionID: String?
    /// Who switched Activity Alerts on.
    public var actionByUserID: UserID?

    init(_ fields: AutoModFields) {
        switch fields["notification_type"] {
        case nil, "raid": kind = .raid(isDirectMessageRaid: fields["raid_type"] == "DM_RAID")
        case "mention_raid": kind = .mentionRaid
        case "activity_alerts_enabled": kind = .activityAlertsEnabled
        case "interaction_blocked": kind = .interactionBlocked
        default: kind = .unsupported
        }
        joinAttempts = fields["join_attempts"].flatMap(Int.init)
        directMessagesSent = fields["dms_sent"].flatMap(Int.init)
        raidDate = fields["raid_datetime"].flatMap(Self.date)
        decisionID = fields["decision_id"]
        actionByUserID = fields["action_by_user_id"].flatMap(UInt64.init).map(UserID.init(rawValue:))
    }

    /// "safety alert!" after the tag — a raid's, and no other notice's.
    public var saysSafetyAlert: Bool {
        if case .raid = kind { true } else { false }
    }

    private static func date(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// AutoMod's named fields, from the first embed when it is AutoMod's —
/// Discord's `M`. The first field of a name wins, as `find` does.
struct AutoModFields {
    static let messageKind = "auto_moderation_message"
    static let notificationKind = "auto_moderation_notification"

    private var values: [String: String] = [:]

    init(_ embed: Embed?) {
        guard let embed, embed.kind == Self.messageKind || embed.kind == Self.notificationKind else { return }
        for field in embed.fields where values[field.name] == nil {
            values[field.name] = field.value
        }
    }

    subscript(_ name: String) -> String? { values[name] }
}
