import Foundation

// MARK: - A channel's permissions, in words
//
// `PermissionCatalog` is the role editor's list. A channel's Permissions page
// is a different list (`generateChannelPermissionSpec`, `bac7706d`): its own
// sections per kind of channel, and its own words — "Manage Channel" where a
// role says "Manage Channels", "Manage Permissions" for the bit a role calls
// Manage Roles, "Create Posts" for Send Messages in a forum, and a sentence that
// talks about *this* channel, *these* channels or *this channel's threads*.
// Every title and sentence here is Discord's (`719366`); a sentence that names
// a link drops the link and keeps its words.

public enum ChannelPermissionCatalog {

    public struct Section: Hashable, Sendable, Identifiable {
        public var id: String { title }
        public var title: String
        public var entries: [Entry]
    }

    public struct Entry: Hashable, Sendable, Identifiable {
        public var id: UInt64 { permission.rawValue }
        public var permission: Permissions
        public var title: String
        public var detail: String
    }

    /// The sections a kind of channel lists, in Discord's order.
    ///
    /// `isEveryone` changes two sentences: on `@everyone`, View Channel and
    /// Connect say that turning them off makes the channel private.
    public static func sections(for kind: ChannelKind, isEveryone: Bool = false) -> [Section] {
        let plan: [(String, [Permissions])] = switch kind {
        case .category: [
            ("General Category Permissions", general(webhooks: true)),
            ("Membership Permissions", [.createInvite]),
            ("Text Channel Permissions", text(privateThreads: true, createThreads: true)),
            ("Voice Channel Permissions", voice),
            ("Apps Permissions", apps(activities: true)),
            ("Events Permissions", events),
        ]
        case .voice: [
            ("General Channel Permissions", general(webhooks: true)),
            ("Membership Permissions", [.createInvite]),
            ("Voice Channel Permissions", voice),
            ("Voice Channel Chat Permissions", voiceChat),
            ("Events Permissions", events),
            ("Apps Permissions", apps(activities: true)),
        ]
        case .stage: [
            ("General Channel Permissions", general(webhooks: false)),
            ("Membership Permissions", [.createInvite]),
            ("Voice Channel Permissions", [.connect, .stream, .muteMembers, .moveMembers]),
            ("Stage Channel Permissions", [.requestToSpeak, .mentionEveryone]),
            ("Events Permissions", events),
            ("Voice Channel Chat Permissions", voiceChat),
            ("Apps Permissions", apps(activities: false)),
        ]
        case .forum: [
            ("General Channel Permissions", general(webhooks: true)),
            ("Membership Permissions", [.createInvite]),
            ("Forum Channel Permissions", text(privateThreads: false, createThreads: false)),
            ("Apps Permissions", apps(activities: true)),
        ]
        case .media: [
            ("General Channel Permissions", general(webhooks: true)),
            ("Membership Permissions", [.createInvite]),
            ("Media Channel Permissions", text(privateThreads: false, createThreads: false)),
            ("Apps Permissions", apps(activities: true)),
        ]
        default: [
            ("General Channel Permissions", general(webhooks: true)),
            ("Membership Permissions", [.createInvite]),
            ("Text Channel Permissions", text(privateThreads: kind != .announcement, createThreads: true)),
            ("Apps Permissions", apps(activities: true)),
        ]
        }
        return plan.map { title, permissions in
            Section(
                title: title,
                entries: permissions.map { entry($0, kind: kind, isEveryone: isEveryone) }
            )
        }
    }

    // MARK: Section contents (`225419`)

    private static func general(webhooks: Bool) -> [Permissions] {
        webhooks
            ? [.viewChannel, .manageChannels, .manageRoles, .manageWebhooks]
            : [.viewChannel, .manageChannels, .manageRoles]
    }

    private static func text(privateThreads: Bool, createThreads: Bool) -> [Permissions] {
        var list: [Permissions] = [
            .sendMessages, .sendMessagesInThreads, .createPublicThreads, .createPrivateThreads,
            .embedLinks, .attachFiles, .addReactions, .useExternalEmojis, .useExternalStickers,
            .mentionEveryone, .manageMessages, .pinMessages, .bypassSlowmode, .manageThreads,
            .readMessageHistory, .sendTTSMessages, .sendVoiceMessages, .sendPolls,
        ]
        if !(privateThreads && createThreads) { list.removeAll { $0 == .createPrivateThreads } }
        if !createThreads { list.removeAll { $0 == .createPublicThreads } }
        return list
    }

    private static let voice: [Permissions] = [
        .connect, .speak, .stream, .useSoundboard, .useExternalSounds, .useVAD, .prioritySpeaker,
        .muteMembers, .deafenMembers, .moveMembers, .setVoiceChannelStatus,
    ]

    private static let voiceChat: [Permissions] = [
        .sendMessages, .embedLinks, .attachFiles, .addReactions, .useExternalEmojis,
        .useExternalStickers, .mentionEveryone, .manageMessages, .bypassSlowmode,
        .readMessageHistory, .sendTTSMessages, .sendVoiceMessages, .sendPolls,
    ]

    private static func apps(activities: Bool) -> [Permissions] {
        activities
            ? [.useApplicationCommands, .useEmbeddedActivities, .useExternalApps]
            : [.useApplicationCommands, .useExternalApps]
    }

    private static let events: [Permissions] = [.createEvents, .manageEvents]

    // MARK: Words (`719366`)

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func entry(_ permission: Permissions, kind: ChannelKind, isEveryone: Bool) -> Entry {
        let category = kind == .category
        let threadsOnly = kind == .forum || kind == .media
        let voiceLike = kind == .voice || kind == .stage
        let threads = kind == .text || kind == .forum || kind == .media
        func these(_ one: String, _ many: String) -> String { category ? many : one }

        let (title, detail): (String, String) = switch permission {
        case .viewChannel:
            (
                category ? "View Channels" : "View Channel",
                isEveryone
                    ? (category
                        ? "Allows members to view these channels by default. Disabling this for @everyone will make text channels private. Disabling this and the Connect permission for @everyone will make voice channels private."
                        : voiceLike
                            ? "Allows members to view this channel by default. Disabling this and the Connect permission for @everyone will make this channel private."
                            : "Allows members to view this channel by default. Disabling this for @everyone will make this channel private.")
                    : these(
                        "Allows members to view this channel by default.",
                        "Allows members to view these channels by default."
                    )
            )
        case .manageChannels:
            (
                category ? "Manage Channels" : "Manage Channel",
                category
                    ? "Allows members to change these channels’ name, description, and text / voice settings. They can also delete these channels."
                    : kind == .voice
                        ? "Allows members to change this channel’s name, description, and voice settings. They can also delete the channel."
                        : kind == .stage
                            ? "(Required for Stage moderator) Allow members to set a topic to start the Stage and enable or disable requests to speak. They can also delete the Stage channel."
                            : "Allows members to change this channel’s name, description, and text settings. They can also delete the channel."
            )
        case .manageRoles:
            (
                "Manage Permissions",
                category
                    ? "Allows members to change these channels’ permissions."
                    : kind == .stage
                        ? "Allow members to change this channel's permissions."
                        : "Allows members to change this channel’s permissions."
            )
        case .manageWebhooks:
            (
                "Manage Webhooks",
                these(
                    "Allows members to create, edit, or delete webhooks in this channel, which can post messages from other apps or sites.",
                    "Allows members to create, edit, or delete webhooks in these channels, which can post messages from other apps or sites."
                )
            )
        case .createInvite:
            (
                "Create Invite",
                category
                    ? "Allows members to invite new people to this server via a direct invite link to these channels."
                    : voiceLike
                        ? "Allows members to invite new people to this server via a direct invite link to this channel. The recipient will automatically join the voice channel if they have permission to connect."
                        : "Allows members to invite new people to this server via a direct invite link to this channel."
            )
        case .sendMessages:
            (
                threadsOnly ? "Create Posts" : category ? "Send Messages and Create Posts" : "Send Messages",
                category
                    ? "Allow members to send messages and create posts in these channels."
                    : threadsOnly
                        ? "Allow members to create posts in this channel."
                        : kind == .announcement
                            ? "Allows members to publish their own messages to all servers following this Announcement Channel."
                            : "Allows members to send messages in this channel."
            )
        case .embedLinks:
            (
                "Embed Links",
                these(
                    "Allows links that members share to show embedded content in this channel.",
                    "Allows links that members share to show embedded content in these channels."
                )
            )
        case .attachFiles:
            (
                "Attach Files",
                these(
                    "Allows members to upload files or media in this channel.",
                    "Allows members to upload files or media in these channels."
                )
            )
        case .addReactions:
            (
                "Add Reactions",
                category
                    ? "Allows members to add new emoji reactions to a message in these channels. If this permission is disabled, members can still react using any existing reactions on a message."
                    : kind == .voice
                        ? "Allows members to add new emoji reactions to a message in this channel and send reactions in voice channels. If this permission is disabled, members can still react using any existing reactions on a message."
                        : "Allows members to add new emoji reactions to a message in this channel. If this permission is disabled, members can still react using any existing reactions on a message."
            )
        case .useExternalEmojis:
            (
                "Use External Emoji",
                these(
                    "Allows members to use emoji from other servers in this channel, if they’re a Discord Nitro member.",
                    "Allows members to use emoji from other servers in these channels, if they’re a Discord Nitro member."
                )
            )
        case .useExternalStickers:
            (
                "Use External Stickers",
                these(
                    "Allows members to use stickers from other servers in this channel, if they’re a Discord Nitro member.",
                    "Allows members to use stickers from other servers in these channels, if they’re a Discord Nitro member."
                )
            )
        case .mentionEveryone:
            (
                kind == .stage ? "Mention @everyone when a Stage starts" : "Mention @everyone, @here, and All Roles",
                category
                    ? "Allows members to use @everyone or @here (only online members) in these channels. They can also @mention all roles in these channels, even if the role’s “Allow anyone to mention this role” permission is disabled."
                    : kind == .stage
                        ? "Allow Stage Moderators with this role to notify @everyone when a Stage starts. This is the same permission as Mention @everyone, @here, and All Roles."
                        : "Allows members to use @everyone or @here (only online members) in this channel. They can also @mention all roles in this channel, even if the role’s “Allow anyone to mention this role” permission is disabled."
            )
        case .manageMessages:
            (
                "Manage Messages",
                category
                    ? "Allows members to delete or remove embeds from messages by other members in these channels."
                    : kind == .announcement
                        ? "Allows members to delete or remove embeds from messages by other members in this channel. They can also publish messages by other members to all servers that follow this Announcement Channel."
                        : "Allows members to delete or remove embeds from messages by other members in this channel."
            )
        case .pinMessages:
            (
                "Pin Messages",
                these(
                    "Allows members to pin or unpin any message in this channel.",
                    "Allows members to pin or unpin any message in these channels."
                )
            )
        case .bypassSlowmode:
            (
                "Bypass Slowmode",
                these(
                    "Allows members to send messages in this channel without being affected by slowmode.",
                    "Allows members to send messages in these channels without being affected by slowmode."
                )
            )
        case .readMessageHistory:
            (
                threadsOnly ? "Read Post History" : "Read Message History",
                category
                    ? "Allows members to read previous messages sent in these channels. If this permission is disabled, members only see messages sent when they are online."
                    : threadsOnly
                        ? "Allows members to read previous messages and posts created in this channel. If this permission is disabled, members only see messages and posts created when they are online."
                        : "Allows members to read previous messages sent in this channel. If this permission is disabled, members only see messages sent when they are online."
            )
        case .sendTTSMessages:
            (
                "Send Text-to-Speech Messages",
                category
                    ? "Allows members to send text-to-speech messages in these channels by starting a message with /tts. These messages can be heard by anyone focused on that channel."
                    : "Allows members to send text-to-speech messages in this channel by starting a message with /tts. These messages can be heard by anyone focused on this channel."
            )
        case .useApplicationCommands:
            (
                "Use Application Commands",
                these(
                    "Allows members to use commands from applications in this channel, including slash commands and context menu commands.",
                    "Allows members to use commands from applications in these channels, including slash commands and context menu commands."
                )
            )
        case .sendVoiceMessages:
            (
                "Send Voice Messages",
                these(
                    "Allows members to send voice messages in this channel. Requires the \"Attach Files\" permission as well.",
                    "Allows members to send voice messages in these channels. Requires the \"Attach Files\" permission as well."
                )
            )
        case .sendPolls:
            (
                "Create Polls",
                these(
                    "Allows members to create polls in this channel.",
                    "Allows members to create polls in these channels."
                )
            )
        case .connect:
            (
                "Connect",
                category
                    ? (isEveryone
                        ? "Allows members to join these voice channels and hear others. Disabling this and the View Channel permissions for @everyone will make these channels private."
                        : "Allows members to join these voice channels and hear others.")
                    : kind == .stage
                        ? (isEveryone
                            ? "Allow members to join this Stage channel as the audience. Disabling this and the View Channel permissions for @everyone will make this channel private."
                            : "Allow members to join this Stage channel as the audience.")
                        : threads
                            ? "Allows members to talk in voice and hear others in this channel's threads."
                            : (isEveryone
                                ? "Allows members to join this voice channel and hear others. Disabling this and the View Channel permissions for @everyone will make this channel private."
                                : "Allows members to join this voice channel and hear others.")
            )
        case .speak:
            (
                "Speak",
                category
                    ? "Allows members to talk in these voice channels. If this permission is disabled, members are default muted until somebody with the “Mute Members” permission un-mutes them."
                    : kind == .stage
                        ? "Allow members to be Speakers in this channel."
                        : threads
                            ? "Allows members to talk in voice in this channel's threads. If this permission is disabled, members are default muted until somebody with the “Mute Members” permission un-mutes them."
                            : "Allows members to talk in this voice channel. If this permission is disabled, members are default muted until somebody with the “Mute Members” permission un-mutes them."
            )
        case .stream:
            (
                "Video",
                category
                    ? "Allows members to share their video, screen share, or stream a game in these voice channels."
                    : threads
                        ? "Allows members to share their video, screen share, or stream a game in this channel's threads."
                        : kind == .stage
                            ? "Allows speakers to share their video, screen share, or stream a game in this Stage channel."
                            : "Allows members to share their video, screen share, or stream a game in this voice channel."
            )
        case .useEmbeddedActivities:
            (
                "Use Activities",
                category
                    ? "Allows members to use Activities in these channels."
                    : threadsOnly
                        ? "Allows members to use Activities in this channel's threads."
                        : "Allows members to use Activities in this channel."
            )
        case .useExternalApps:
            (
                "Use External Apps",
                category
                    ? "Allows apps that members have added to their account to post messages in these channels. When disabled, the messages will be private."
                    : threadsOnly
                        ? "Allows members to use External Apps in this channel's threads."
                        : "Allows apps that members have added to their account to post messages in this channel. When disabled, the messages will be private."
            )
        case .useSoundboard:
            (
                "Use Soundboard",
                category
                    ? "Allows members to send sounds from server soundboard in these voice channels."
                    : threads
                        ? "Allows members to send sounds from server soundboard in this channel's threads."
                        : "Allows members to send sounds from server soundboard in this voice channel."
            )
        case .useExternalSounds:
            (
                "Use External Sounds",
                "Allows members to use sounds from other servers, if they're a Discord Nitro member."
            )
        case .useVAD:
            (
                "Use Voice Activity",
                category
                    ? "Allows members to speak in these voice channels by simply talking. If this permission is disabled, members are required to use Push-to-talk. Good for controlling background noise or noisy members."
                    : kind == .stage
                        ? "Allow Speaker voices to be heard automatically when they start talking. If this permission is disabled, Speakers will be required to use Push to Talk."
                        : threads
                            ? "Allows members to speak in this channel's threads by simply talking. If this permission is disabled, members are required to use Push-to-talk. Good for controlling background noise or noisy members."
                            : "Allows members to speak in this voice channel by simply talking. If this permission is disabled, members are required to use Push-to-talk. Good for controlling background noise or noisy members."
            )
        case .prioritySpeaker:
            (
                "Priority Speaker",
                category
                    ? "Allows members to be more easily heard in these voice channels. When activated, the volume of others without this permission will be automatically lowered. Priority Speaker is activated by using the Push to Talk (Priority) keybind."
                    : threads
                        ? "Allows members to be more easily heard in this channel's threads. When activated, the volume of others without this permission will be automatically lowered. Priority Speaker is activated by using the Push to Talk (Priority) keybind."
                        : "Allows members to be more easily heard in this voice channel. When activated, the volume of others without this permission will be automatically lowered. Priority Speaker is activated by using the Push to Talk (Priority) keybind."
            )
        case .muteMembers:
            (
                "Mute Members",
                category
                    ? "Allows members to mute other members in these voice channels for everyone."
                    : kind == .stage
                        ? "(Required for Stage moderator) Allow members to add or remove Speakers."
                        : threads
                            ? "Allows members to mute other members in this channel's threads for everyone."
                            : "Allows members to mute other members in this voice channel for everyone."
            )
        case .deafenMembers:
            (
                "Deafen Members",
                category
                    ? "Allows members to deafen other members in these voice channels, which means they won’t be able to speak or hear others."
                    : threads
                        ? "Allows members to deafen other members in this channel's threads, which means they won’t be able to speak or hear others."
                        : "Allows members to deafen other members in this voice channel, which means they won’t be able to speak or hear others."
            )
        case .moveMembers:
            (
                "Move Members",
                category
                    ? "Allows members to disconnect other members from these channels. They will also be able to move somebody into other channels that they have this permission in."
                    : kind == .stage
                        ? "(Required for Stage moderator) Allow members to force others to disconnect from this channel."
                        : threads
                            ? "Allows members to disconnect other members from this channel's threads. They will also be able to move somebody into other channels that they have this permission in."
                            : "Allows members to disconnect other members from this channel. They will also be able to move somebody into other channels that they have this permission in."
            )
        case .requestToSpeak:
            (
                "Request to Speak",
                these(
                    "Allow requests to speak in this Stage channel. Stage moderators manually approve or deny each request.",
                    "Allow requests to speak in these Stage channels. Stage moderators manually approve or deny each request."
                )
            )
        case .manageThreads:
            (
                threadsOnly ? "Manage Posts" : category ? "Manage Threads and Posts" : "Manage Threads",
                category
                    ? "Allows members to rename, delete, close, and turn on slow mode for threads and posts in these channels. They can also view private threads."
                    : threadsOnly
                        ? "Allows members to rename, delete, close, and turn on slow mode for posts in this channel."
                        : "Allows members to rename, delete, close, and turn on slow mode for threads in this channel. They can also view private threads."
            )
        case .createPublicThreads:
            (
                "Create Public Threads",
                these(
                    "Allow members to create threads that everyone in this channel can view.",
                    "Allow members to create threads that everyone in these channels can view."
                )
            )
        case .createPrivateThreads:
            (
                "Create Private Threads",
                these(
                    "Allow members to create invite-only threads in this channel.",
                    "Allow members to create invite-only threads in these channels."
                )
            )
        case .sendMessagesInThreads:
            (
                threadsOnly ? "Send Messages in Posts" : category ? "Send Messages in Threads and Posts" : "Send Messages in Threads",
                category
                    ? "Allow members to send messages in threads and posts under these channels."
                    : threadsOnly
                        ? "Allow members to send messages in threads and posts under this channel."
                        : "Allow members to send messages in threads under this channel."
            )
        case .manageEvents:
            (
                "Manage Events",
                these(
                    "Allows members to edit and cancel events in this channel.",
                    "Allows members to edit and cancel events in these channels."
                )
            )
        case .createEvents:
            (
                "Create Events",
                these(
                    "Allows members to create events in this channel.",
                    "Allows members to create events in these channels."
                )
            )
        case .setVoiceChannelStatus:
            ("Set Voice Channel Status", "Allows members to create and edit voice channel status.")
        default:
            (
                PermissionCatalog.groups.flatMap(\.entries).first { $0.permission == permission }?.title ?? "",
                ""
            )
        }
        return Entry(permission: permission, title: title, detail: detail)
    }
}

// MARK: - Overwrites, edited

/// One permission in one overwrite: Discord's three-way switch.
public enum OverwriteState: Hashable, Sendable, CaseIterable {
    case deny
    case inherit
    case allow
}

extension PermissionOverwrite {
    public func state(of permission: Permissions) -> OverwriteState {
        if allow.contains(permission) { return .allow }
        if deny.contains(permission) { return .deny }
        return .inherit
    }

    public mutating func set(_ state: OverwriteState, for permission: Permissions) {
        allow.remove(permission)
        deny.remove(permission)
        switch state {
        case .allow: allow.insert(permission)
        case .deny: deny.insert(permission)
        case .inherit: break
        }
    }
}

/// Who can see a channel — the Permissions page's Private Channel switch.
public enum ChannelAccess {
    /// What "can access" means for a kind of channel — Discord's
    /// `accessPermissions`: View Channel, and Connect as well for voice.
    public static func permissions(for kind: ChannelKind) -> Permissions {
        kind == .voice || kind == .stage ? [.viewChannel, .connect] : .viewChannel
    }

    /// Private when `@everyone`'s overwrite denies every access permission
    /// (`k` in `495273`).
    public static func isPrivate(_ channel: Channel, guildID: GuildID) -> Bool {
        guard let everyone = channel.overwrites.first(where: { $0.id == guildID.rawValue }) else {
            return false
        }
        return everyone.deny.isSuperset(of: permissions(for: channel.kind))
    }

    /// `@everyone`'s overwrite after the switch flips — Discord's `B`: the
    /// access bits come off both sides, and going private denies them.
    public static func everyoneOverwrite(
        for channel: Channel,
        guildID: GuildID,
        makingPrivate: Bool
    ) -> PermissionOverwrite {
        let access = permissions(for: channel.kind)
        var everyone = channel.overwrites.first { $0.id == guildID.rawValue }
            ?? PermissionOverwrite(id: guildID.rawValue, subject: .role, allow: [], deny: [])
        everyone.allow.subtract(access)
        everyone.deny.subtract(access)
        if makingPrivate { everyone.deny.formUnion(access) }
        return everyone
    }

    /// Whether a channel's overwrites are its category's — "Permissions
    /// synced with category". Order does not matter; content does.
    public static func isSynced(_ channel: Channel, with category: Channel) -> Bool {
        Set(channel.overwrites) == Set(category.overwrites)
    }
}
