import Foundation

// MARK: - Being told something arrived
//
// The whole decision, as one pure function over one value. Nothing here posts a
// banner, reads a store or knows what a `UNNotification` is — which is what
// makes it checkable against a table of cases, and the reason it is here rather
// than beside the code that speaks to Notification Center.
//
// **Getting this wrong is worse in both directions and the two are not
// symmetric.** A notification that should not have fired interrupts somebody
// once; one that should have fired and did not is a message they never learn
// about. So where the evidence runs out, this errs toward telling them — the
// same rule §5.5 states about hiding what a client cannot prove is hidden.

/// What the reader has chosen to be told about a place.
///
/// Discord's own four values, and the fourth is the one that makes the other
/// three composable: a channel override of `inherit` means "whatever the server
/// says", and a server's own setting is itself layered over the server's
/// default. Reading `3` as a fourth kind of silence is the mistake that turns
/// every unconfigured channel off.
public enum MessageNotificationLevel: Int, Hashable, Sendable, Codable {
    case allMessages = 0
    case onlyMentions = 1
    case nothing = 2
    /// `3` on the wire — *ask the level above me*. Discord also expresses this
    /// as a missing key, and both mean the same thing.
    case inherit = 3

    public init(rawValue: Int) {
        self = switch rawValue {
        case 0: .allMessages
        case 1: .onlyMentions
        case 2: .nothing
        // Anything Discord adds later inherits rather than silencing: an
        // unrecognised value must never be the reason somebody stops being told.
        default: .inherit
        }
    }

    /// The reader-side view of a server's own default.
    ///
    /// **`NotificationLevel` is the SERVER owner's setting and this is the
    /// reader's**, which is why they are two types over one integer: a server
    /// may only set All Messages or Only @mentions, and offering its owner a
    /// "Nothing" it cannot save would be a control that lies. This is the one
    /// conversion between them.
    public init(guildDefault: NotificationLevel) {
        self = switch guildDefault {
        case .allMessages: .allMessages
        case .onlyMentions: .onlyMentions
        // A default Discord has added since this was written. Erring toward
        // being told, per the note at the top of this file.
        case .unrecognised: .allMessages
        }
    }
}

/// Everything the reader has said about where they want to be interrupted.
///
/// **One value rather than five tables on the store**, because the policy takes
/// all of it or none: a decision made from four of the five is a decision made
/// with a fact missing, and the missing one is always the mute.
public struct NotificationPreferences: Hashable, Sendable {
    public var mutedGuildIDs: Set<GuildID>
    public var mutedChannelIDs: Set<ChannelID>
    /// The reader's override for a whole server. Absent means they have not
    /// touched it, which is not the same as `allMessages` — the server's own
    /// default stands underneath.
    public var guildLevels: [GuildID: MessageNotificationLevel]
    public var channelLevels: [ChannelID: MessageNotificationLevel]
    /// Servers where the reader has turned `@everyone` and `@here` off.
    public var suppressEveryoneGuildIDs: Set<GuildID>
    /// Servers where they have turned role mentions off.
    public var suppressRoleMentionGuildIDs: Set<GuildID>

    public init(
        mutedGuildIDs: Set<GuildID> = [],
        mutedChannelIDs: Set<ChannelID> = [],
        guildLevels: [GuildID: MessageNotificationLevel] = [:],
        channelLevels: [ChannelID: MessageNotificationLevel] = [:],
        suppressEveryoneGuildIDs: Set<GuildID> = [],
        suppressRoleMentionGuildIDs: Set<GuildID> = []
    ) {
        self.mutedGuildIDs = mutedGuildIDs
        self.mutedChannelIDs = mutedChannelIDs
        self.guildLevels = guildLevels
        self.channelLevels = channelLevels
        self.suppressEveryoneGuildIDs = suppressEveryoneGuildIDs
        self.suppressRoleMentionGuildIDs = suppressRoleMentionGuildIDs
    }

    public static let none = NotificationPreferences()
}

/// Whether a message earns an interruption, and why.
public enum NotificationPolicy {

    /// Everything the decision needs, and nothing it does not.
    ///
    /// A parameter object rather than nine arguments: the call site is a gateway
    /// handler with all of this in scope, and a table of cases is the only way
    /// to check a rule set this shape.
    public struct Subject: Hashable, Sendable {
        public var channelID: ChannelID
        /// Nil for a direct message or a group.
        public var guildID: GuildID?
        public var isDirectMessage: Bool
        /// Whether the reader wrote it. Their own message is never news.
        public var isFromReader: Bool
        /// Whether the reader has blocked or ignored the author.
        public var isAuthorSilenced: Bool
        /// Whether the reader is **looking at this channel right now** — which
        /// is the channel being selected *and* the window being active. Either
        /// alone is not it: a selected channel in a hidden window is exactly the
        /// case a notification exists for.
        public var isOnScreen: Bool
        /// A direct mention of the reader, or of a role they hold.
        public var mentionsReader: Bool
        /// Whether that mention was a role rather than the person.
        public var isRoleMention: Bool
        public var mentionsEveryone: Bool
        /// The server's own default, for a channel with no override anywhere.
        public var guildDefault: MessageNotificationLevel

        public init(
            channelID: ChannelID,
            guildID: GuildID? = nil,
            isDirectMessage: Bool = false,
            isFromReader: Bool = false,
            isAuthorSilenced: Bool = false,
            isOnScreen: Bool = false,
            mentionsReader: Bool = false,
            isRoleMention: Bool = false,
            mentionsEveryone: Bool = false,
            guildDefault: MessageNotificationLevel = .allMessages
        ) {
            self.channelID = channelID
            self.guildID = guildID
            self.isDirectMessage = isDirectMessage
            self.isFromReader = isFromReader
            self.isAuthorSilenced = isAuthorSilenced
            self.isOnScreen = isOnScreen
            self.mentionsReader = mentionsReader
            self.isRoleMention = isRoleMention
            self.mentionsEveryone = mentionsEveryone
            self.guildDefault = guildDefault
        }
    }

    /// Whether to interrupt.
    ///
    /// The order below is the whole rule set, and it is an order rather than a
    /// set of conditions: each step can only ever say *no*, except the last.
    public static func shouldNotify(
        _ subject: Subject,
        preferences: NotificationPreferences
    ) -> Bool {
        // 1. Nothing about the reader's own message is news, and a person they
        //    have blocked has already been answered.
        guard !subject.isFromReader, !subject.isAuthorSilenced else { return false }

        // 2. They are looking at it. **Both halves** — see `isOnScreen`.
        guard !subject.isOnScreen else { return false }

        // 3. Muted, at either level. A muted server silences a channel inside it
        //    that has no opinion; a muted channel silences itself even in a
        //    server the reader wants everything from.
        if preferences.mutedChannelIDs.contains(subject.channelID) { return false }
        if let guildID = subject.guildID, preferences.mutedGuildIDs.contains(guildID) {
            // **Unless the channel says otherwise.** A channel the reader has
            // explicitly set to All Messages inside a muted server is a channel
            // they went out of their way to keep — Discord honours that, and a
            // client that did not would silence the one thing somebody asked to
            // hear.
            guard preferences.channelLevels[subject.channelID] == .allMessages else {
                return false
            }
        }

        // 4. A direct message is always news. There is no level to consult —
        //    Discord offers none for a conversation, and the mute above is the
        //    only control it has.
        if subject.isDirectMessage { return true }

        // 5. What the reader asked for here, most specific first.
        switch resolvedLevel(subject, preferences: preferences) {
        case .nothing:
            return false
        case .allMessages:
            return true
        case .onlyMentions, .inherit:
            // `.inherit` cannot survive `resolvedLevel` — it falls through to
            // the server's default, which is never `.inherit` — but treating it
            // as "only mentions" here rather than trapping keeps an unforeseen
            // value quiet rather than fatal.
            return isMention(subject, preferences: preferences)
        }
    }

    /// The level that actually applies: the channel's, then the server's, then
    /// the server's own default.
    ///
    /// **`inherit` is a step, not an answer**, at both levels. A channel set to
    /// inherit asks the server; a server the reader has not touched asks the
    /// server's default.
    public static func resolvedLevel(
        _ subject: Subject,
        preferences: NotificationPreferences
    ) -> MessageNotificationLevel {
        if let channel = preferences.channelLevels[subject.channelID], channel != .inherit {
            return channel
        }
        if let guildID = subject.guildID,
           let guild = preferences.guildLevels[guildID],
           guild != .inherit
        {
            return guild
        }
        return subject.guildDefault
    }

    /// Whether this message counts as addressed to the reader.
    ///
    /// The two suppressions are per-server and apply only to the kind of mention
    /// they name — somebody typing the reader's own name still gets through a
    /// server where `@everyone` is suppressed, which is the whole point of the
    /// setting being about `@everyone` rather than about mentions.
    public static func isMention(
        _ subject: Subject,
        preferences: NotificationPreferences
    ) -> Bool {
        let guildID = subject.guildID
        if subject.mentionsEveryone {
            let suppressed = guildID.map(preferences.suppressEveryoneGuildIDs.contains) ?? false
            if !suppressed { return true }
        }
        guard subject.mentionsReader else { return false }
        guard subject.isRoleMention else { return true }
        return !(guildID.map(preferences.suppressRoleMentionGuildIDs.contains) ?? false)
    }
}
