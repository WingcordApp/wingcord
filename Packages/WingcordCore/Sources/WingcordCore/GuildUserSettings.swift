import Foundation

/// Whether a server's Highlights are suppressed.
///
/// **Three values for a two-state switch, and the third is not a bug.** Discord
/// distinguishes "never answered" from "answered yes", because the default can
/// move; a client that collapsed `default` into `enabled` would keep showing the
/// reader's own choice after Discord changed what the absence means.
///
/// Walked out of `serveroptions + privacy.har` — the Suppress Highlights switch
/// turned on sent `notify_highlights: 1` — and named from Discord's own
/// `Highlight Level` table.
public enum HighlightLevel: Int, Hashable, Sendable, Codable {
    /// Never set. Behaves as `.enabled`.
    case unset = 0
    /// Highlights suppressed — the switch the menu draws is ON.
    case disabled = 1
    case enabled = 2

    public init(rawValue: Int) {
        self = switch rawValue {
        case 1: .disabled
        case 2: .enabled
        // Anything Discord adds later leaves the reader being told, for the
        // reason `MessageNotificationLevel` gives at the top of its own file.
        default: .unset
        }
    }

    /// What the *switch* reads, which is the inverse of what the field is called.
    public var suppressesHighlights: Bool { self == .disabled }

    public init(suppressed: Bool) { self = suppressed ? .disabled : .enabled }
}

/// The bits on a server's own `flags`, in the reader's guild settings.
///
/// **Not the channel's** — `ChannelSettingsFlags` is a different table at
/// overlapping numbers, and `16384` means one thing on a guild and another on a
/// channel. Read out of Discord's bundle, where the two objects sit side by
/// side.
public enum GuildUserSettingsFlags {
    /// The reader sees only the channels they opted into.
    ///
    /// **The polarity is the reverse of the menu's.** The switch says *Show All
    /// Channels*, so it is ON exactly when this bit is CLEAR. Discord's own
    /// reader is `isOptInEnabled = hasFlag(OPT_IN_CHANNELS_ON)` and its channel
    /// list draws a channel when `!optInEnabled || optedIn.contains(id)`.
    public static let optInChannelsOn = 1 << 14
    /// The explicit opposite. Discord writes it from the onboarding flow; this
    /// client only ever clears `optInChannelsOn`, which is what the capture
    /// shows its own menu doing.
    public static let optInChannelsOff = 1 << 13
    public static let unreadsOnlyMentions = 1 << 12
    public static let unreadsAllMessages = 1 << 11
}

/// One channel's override inside a server's settings.
public struct ChannelUserSettings: Hashable, Sendable {
    public var messageNotifications: MessageNotificationLevel
    public var isMuted: Bool
    public var muteConfig: ThreadMuteConfig?
    public var flags: Int

    public init(
        messageNotifications: MessageNotificationLevel = .inherit,
        isMuted: Bool = false,
        muteConfig: ThreadMuteConfig? = nil,
        flags: Int = 0
    ) {
        self.messageNotifications = messageNotifications
        self.isMuted = isMuted
        self.muteConfig = muteConfig
        self.flags = flags
    }

    /// Whether the mute is still running. A lapsed mute is not un-muted on the
    /// wire — see `ThreadMuteConfig.isActive`.
    public func isMuted(at date: Date = .now) -> Bool {
        isMuted && (muteConfig?.isActive(at: date) ?? true)
    }
}

/// Everything the reader has said about one server, as one record.
///
/// **One value rather than eight tables**, for the reason
/// `NotificationPreferences` gives: the notification sheet shows all of it at
/// once and writes one field at a time, and a sheet assembled from eight stores
/// is eight chances to draw a switch that disagrees with the one beside it.
///
/// `NotificationPreferences` stays where it is and keeps its own sets. That is
/// not duplication: it is the *decision* input — read on every arriving message,
/// on a hot path, from a shape built for membership tests — and this is the
/// *editor's* input, read once when a menu opens.
public struct GuildUserSettings: Hashable, Sendable {
    public var guildID: GuildID
    public var isMuted: Bool
    public var muteConfig: ThreadMuteConfig?
    public var messageNotifications: MessageNotificationLevel
    public var suppressEveryone: Bool
    public var suppressRoles: Bool
    public var highlights: HighlightLevel
    public var muteScheduledEvents: Bool
    public var mobilePush: Bool
    public var hideMutedChannels: Bool
    public var flags: Int
    public var channelOverrides: [ChannelID: ChannelUserSettings]

    public init(
        guildID: GuildID,
        isMuted: Bool = false,
        muteConfig: ThreadMuteConfig? = nil,
        messageNotifications: MessageNotificationLevel = .inherit,
        suppressEveryone: Bool = false,
        suppressRoles: Bool = false,
        highlights: HighlightLevel = .unset,
        muteScheduledEvents: Bool = false,
        // Discord's own default for an account that has never touched it.
        mobilePush: Bool = true,
        hideMutedChannels: Bool = false,
        flags: Int = 0,
        channelOverrides: [ChannelID: ChannelUserSettings] = [:]
    ) {
        self.guildID = guildID
        self.isMuted = isMuted
        self.muteConfig = muteConfig
        self.messageNotifications = messageNotifications
        self.suppressEveryone = suppressEveryone
        self.suppressRoles = suppressRoles
        self.highlights = highlights
        self.muteScheduledEvents = muteScheduledEvents
        self.mobilePush = mobilePush
        self.hideMutedChannels = hideMutedChannels
        self.flags = flags
        self.channelOverrides = channelOverrides
    }

    /// Whether the mute is running right now.
    public func isMuted(at date: Date = .now) -> Bool {
        isMuted && (muteConfig?.isActive(at: date) ?? true)
    }

    /// The menu's *Show All Channels* switch. See `GuildUserSettingsFlags`.
    public var showsAllChannels: Bool {
        flags & GuildUserSettingsFlags.optInChannelsOn == 0
    }

    /// The duration row the menu should tick, or nil when the server is not
    /// muted.
    ///
    /// **Taken from the stored window rather than inferred from the time left**,
    /// which drifts the moment the sheet is open — a "For 8 Hours" mute set
    /// three hours ago would tick "For 3 Hours" and then nothing.
    ///
    /// **It takes a date, because it asks whether the mute is still running**
    /// and a lapsed mute has no duration to show. An implicit `.now` here reads
    /// as a pure accessor and is not one.
    public func muteDuration(at date: Date = .now) -> MuteDuration? {
        guard isMuted(at: date) else { return nil }
        guard let window = muteConfig?.selectedTimeWindow else { return .untilTurnedBackOn }
        return MuteDuration(rawValue: window) ?? .untilTurnedBackOn
    }
}

// MARK: - The one change a write carries

/// One field of one server's settings, as the wire takes it.
///
/// **A case per control rather than a whole record**, because the route is a
/// partial merge: sending the record back would re-assert every value the reader
/// did not touch, and any of them could have moved on another client between the
/// menu opening and the switch being flipped.
public enum GuildUserSettingsChange: Hashable, Sendable {
    /// Muting, with the duration. `nil` unmutes.
    case mute(MuteDuration?)
    case messageNotifications(MessageNotificationLevel)
    case suppressEveryone(Bool)
    case suppressRoles(Bool)
    case suppressHighlights(Bool)
    case muteScheduledEvents(Bool)
    case mobilePush(Bool)
    case hideMutedChannels(Bool)
    /// The *menu's* polarity: true means Show All Channels. The flag written is
    /// the inverse — see `GuildUserSettingsFlags`.
    case showAllChannels(Bool)
    /// One channel's own level. `.inherit` is how Discord expresses "follow the
    /// server", and it is a value on the wire (3), not a deletion.
    case channelLevel(ChannelID, MessageNotificationLevel)
    case channelMuted(ChannelID, MuteDuration?)
    /// Puts a channel back on the server's default, which is what the sheet's
    /// remove control does.
    ///
    /// **It is a reset, not a deletion.** There is no route that deletes one
    /// override: Discord's own control writes `message_notifications: 3` — the
    /// inherit value — with the mute off and the two unread bits cleared, and
    /// the entry stays on the wire carrying nothing. Which is why the sheet
    /// lists an override by what it *says* rather than by its existence: every
    /// channel in an opt-in server has an entry, and almost none of them is a
    /// setting anybody made.
    case clearChannelOverride(ChannelID)

    /// The optimistic result of applying this to a record, so the menu can draw
    /// the new state before the round trip lands and put it back if it fails.
    public func applied(to settings: GuildUserSettings) -> GuildUserSettings {
        var next = settings
        switch self {
        case .mute(let duration):
            next.isMuted = duration != nil
            next.muteConfig = duration.map {
                ThreadMuteConfig(endTime: $0.endTime(), selectedTimeWindow: $0.rawValue)
            }
        case .messageNotifications(let level): next.messageNotifications = level
        case .suppressEveryone(let on): next.suppressEveryone = on
        case .suppressRoles(let on): next.suppressRoles = on
        case .suppressHighlights(let on): next.highlights = HighlightLevel(suppressed: on)
        case .muteScheduledEvents(let on): next.muteScheduledEvents = on
        case .mobilePush(let on): next.mobilePush = on
        case .hideMutedChannels(let on): next.hideMutedChannels = on
        case .showAllChannels(let showsAll):
            if showsAll {
                next.flags &= ~GuildUserSettingsFlags.optInChannelsOn
            } else {
                next.flags |= GuildUserSettingsFlags.optInChannelsOn
            }
        case .channelLevel(let channelID, let level):
            var override = next.channelOverrides[channelID] ?? ChannelUserSettings()
            override.messageNotifications = level
            next.channelOverrides[channelID] = override
        case .channelMuted(let channelID, let duration):
            var override = next.channelOverrides[channelID] ?? ChannelUserSettings()
            override.isMuted = duration != nil
            override.muteConfig = duration.map {
                ThreadMuteConfig(endTime: $0.endTime(), selectedTimeWindow: $0.rawValue)
            }
            next.channelOverrides[channelID] = override
        case .clearChannelOverride(let channelID):
            guard var override = next.channelOverrides[channelID] else { break }
            override.messageNotifications = .inherit
            override.isMuted = false
            override.muteConfig = nil
            override.flags = ChannelSettingsFlags.clearingUnreadPreference(override.flags)
            next.channelOverrides[channelID] = override
        }
        return next
    }
}

// MARK: - Per-server privacy

/// The four switches on a server's Privacy Settings sheet.
///
/// **Every one of them is an absence.** Each lives as a list of guild IDs in
/// `PreloadedUserSettings.privacy`, and the server's presence in that list is
/// the *restriction* — so a switch is ON exactly when the id is NOT there. A
/// client that read the lists as allow-lists would turn every one of these off
/// for every server the reader had never touched.
public struct GuildPrivacy: Hashable, Sendable {
    /// "Allow DMs from other members in this server."
    public var allowsDirectMessages: Bool
    /// "Filter messages from server members you may not know."
    public var filtersMessageRequests: Bool
    /// "Share activity information from games and connected apps I use."
    public var sharesActivity: Bool
    /// "Allow users to join your activity in this server."
    public var allowsActivityJoining: Bool

    public init(
        allowsDirectMessages: Bool = true,
        filtersMessageRequests: Bool = true,
        sharesActivity: Bool = true,
        allowsActivityJoining: Bool = true
    ) {
        self.allowsDirectMessages = allowsDirectMessages
        self.filtersMessageRequests = filtersMessageRequests
        self.sharesActivity = sharesActivity
        self.allowsActivityJoining = allowsActivityJoining
    }
}

/// Which of the four privacy lists a write is about.
public enum GuildPrivacyToggle: Hashable, Sendable, CaseIterable {
    case directMessages
    case messageRequests
    case activitySharing
    case activityJoining

    public var title: String {
        switch self {
        case .directMessages: "Direct Messages"
        case .messageRequests: "Message requests"
        case .activitySharing: "Share my activity"
        case .activityJoining: "Activity joining"
        }
    }

    /// Discord's own copy, verbatim from the sheet.
    public var caption: String {
        switch self {
        case .directMessages: "Allow DMs from other members in this server"
        case .messageRequests:
            "Filter messages from server members you may not know."
        case .activitySharing:
            "Share activity information from games and connected apps I use, "
                + "including when and how I engage."
        case .activityJoining: "Allow users to join your activity in this server."
        }
    }

    public func value(in privacy: GuildPrivacy) -> Bool {
        switch self {
        case .directMessages: privacy.allowsDirectMessages
        case .messageRequests: privacy.filtersMessageRequests
        case .activitySharing: privacy.sharesActivity
        case .activityJoining: privacy.allowsActivityJoining
        }
    }
}
