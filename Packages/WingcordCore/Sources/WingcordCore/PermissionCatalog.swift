import Foundation

// MARK: - The permissions, in words
//
// `Permissions` is the bitfield and says nothing about what a bit *means* to
// somebody editing a role. This is the other half: a name, a sentence, and the
// group it belongs to.
//
// **The grouping, the titles and the order are Discord's own**, read off its
// role editor rather than invented — which matters more here than it looks:
//
//   - The order is **not** the bit order. `manageChannels` is bit 4 and
//     `manageRoles` is bit 28, and both sit near the top of General; `connect`
//     through `useVAD` are contiguous but `prioritySpeaker` and `stream` are at
//     8 and 9, twelve bits earlier. A page laid out by bit index scatters the
//     voice permissions across four screens.
//   - Several titles are **wider than the flag's name**. `KICK_MEMBERS` is
//     labelled "Kick, Approve, and Reject Members", because the same bit gates
//     the join-request queue — which nothing in the flag's name says and which
//     an administrator turning it off very much needs to know.
//   - Four bits are **splits of older ones**: `createExpressions` out of
//     `manageExpressions`, `createEvents` out of `manageEvents`, and
//     `pinMessages` and `bypassSlowmode` out of `manageMessages`. The audit log
//     records the last two as their own migration actions, 212 and 213.
//
// **The sentence matters more than the name.** "Manage Messages" does not say
// that it deletes *other people's* messages and never edits them — a fact this
// client already had to write down for the message action policy, and the person
// granting the permission is exactly who needs it.

public enum PermissionCatalog {

    /// One permission, as a role editor lists it.
    public struct Entry: Hashable, Sendable, Identifiable {
        public var id: UInt64 { permission.rawValue }
        public var permission: Permissions
        public var title: String
        public var detail: String
        /// Whether granting this is effectively granting more than it says.
        /// Marked so the editor can warn rather than hand somebody the server
        /// behind a switch that looks like the eleven above it.
        public var isElevated: Bool

        public init(
            _ permission: Permissions,
            _ title: String,
            _ detail: String,
            isElevated: Bool = false
        ) {
            self.permission = permission
            self.title = title
            self.detail = detail
            self.isElevated = isElevated
        }
    }

    public struct Group: Hashable, Sendable, Identifiable {
        public var id: String { title }
        public var title: String
        public var entries: [Entry]
    }

    public static let groups: [Group] = [
        Group(title: "General Server Permissions", entries: [
            Entry(
                .viewChannel,
                "View Channels",
                "View channels by default, excluding private ones."
            ),
            Entry(
                .manageChannels,
                "Manage Channels",
                "Create, edit and delete channels."
            ),
            Entry(
                .manageRoles,
                "Manage Roles",
                "Create new roles and edit roles below their highest one. Also "
                    + "change the permissions of individual channels they have access to."
            ),
            Entry(
                .createExpressions,
                "Create Expressions",
                "Add custom emoji, stickers and sounds — and edit or delete the "
                    + "ones they added themselves."
            ),
            Entry(
                .manageExpressions,
                "Manage Expressions",
                "Edit or remove any custom emoji, sticker or sound in this server."
            ),
            Entry(
                .viewAuditLog,
                "View Audit Log",
                "See a record of who changed what in this server."
            ),
            Entry(
                .viewGuildInsights,
                "View Server Insights",
                "See growth, engagement and activity data. This also lets them "
                    + "see channel activity for channels they cannot access."
            ),
            Entry(
                .manageWebhooks,
                "Manage Webhooks",
                "Create, edit and delete webhooks, which can post messages from "
                    + "other apps or sites into this server."
            ),
            Entry(
                .manageGuild,
                "Manage Server",
                "Change this server's name, switch regions, view all invites, "
                    + "add apps, and create and update AutoMod rules.",
                isElevated: true
            ),
        ]),

        Group(title: "Membership Permissions", entries: [
            Entry(.createInvite, "Create Invite", "Invite new people to this server."),
            Entry(
                .changeNickname,
                "Change Nickname",
                "Change their own nickname — a custom name for just this server."
            ),
            Entry(.manageNicknames, "Manage Nicknames", "Change other members' nicknames."),
            Entry(
                .kickMembers,
                "Kick, Approve, and Reject Members",
                "Remove other members from this server; they can rejoin with a "
                    + "new invite. Where the server has Member Requirements on, "
                    + "this also approves and rejects the people who apply."
            ),
            Entry(
                .banMembers,
                "Ban Members",
                "Permanently remove members, and delete their recent message history.",
                isElevated: true
            ),
            Entry(
                .moderateMembers,
                "Timeout Members",
                "Stop a member sending messages, reacting, replying or speaking "
                    + "in voice and stage channels for a while."
            ),
        ]),

        Group(title: "Text Channel Permissions", entries: [
            Entry(
                .sendMessages,
                "Send Messages and Create Posts",
                "Post in text channels, and create posts in forum channels."
            ),
            Entry(
                .sendMessagesInThreads,
                "Send Messages in Threads and Posts",
                "Post inside threads and forum posts."
            ),
            Entry(
                .createPublicThreads,
                "Create Public Threads",
                "Start threads everyone who can see the channel can see."
            ),
            Entry(.createPrivateThreads, "Create Private Threads", "Start invite-only threads."),
            Entry(.embedLinks, "Embed Links", "Have their links unfurl into previews."),
            Entry(.attachFiles, "Attach Files", "Upload images and files."),
            Entry(
                .addReactions,
                "Add Reactions",
                "Put a **new** emoji on a message. With this off, members can "
                    + "still join a reaction that is already there."
            ),
            Entry(
                .useExternalEmojis,
                "Use External Emoji",
                "Use emoji from other servers, if they have Nitro."
            ),
            Entry(
                .useExternalStickers,
                "Use External Stickers",
                "Use stickers from other servers, if they have Nitro."
            ),
            Entry(
                .mentionEveryone,
                "Mention @everyone, @here, and All Roles",
                "Ping everyone in the server, everyone in a channel, or any role "
                    + "— including roles whose own \"Allow anyone to mention\" is off."
            ),
            Entry(
                .manageMessages,
                "Manage Messages",
                "Delete or remove embeds from other people's messages. "
                    + "It does not let anybody edit somebody else's message."
            ),
            Entry(.pinMessages, "Pin Messages", "Pin or unpin any message."),
            Entry(
                .bypassSlowmode,
                "Bypass Slowmode",
                "Send messages without waiting for slowmode."
            ),
            Entry(
                .manageThreads,
                "Manage Threads and Posts",
                "Rename, delete, close and turn on slow mode for threads and "
                    + "posts. They can also see private threads."
            ),
            Entry(
                .readMessageHistory,
                "Read Message History",
                "Read messages sent before they arrived. With this off, members "
                    + "only see messages sent while they are online."
            ),
            Entry(
                .sendTTSMessages,
                "Send Text-to-Speech Messages",
                "Send messages starting with /tts, which everyone focused on the "
                    + "channel hears out loud."
            ),
            Entry(.sendVoiceMessages, "Send Voice Messages", "Record and send voice notes."),
            Entry(.sendPolls, "Create Polls", "Start a poll in a channel."),
        ]),

        Group(title: "Voice Channel Permissions", entries: [
            Entry(.connect, "Connect", "Join voice channels and hear others."),
            Entry(
                .speak,
                "Speak",
                "Talk in voice channels. With this off, members arrive muted "
                    + "until somebody with Mute Members unmutes them."
            ),
            Entry(.stream, "Video", "Share video, share a screen, or stream a game."),
            Entry(.useSoundboard, "Use Soundboard", "Play this server's sounds in voice."),
            Entry(
                .useExternalSounds,
                "Use External Sounds",
                "Play sounds from other servers, if they have Nitro."
            ),
            Entry(
                .useVAD,
                "Use Voice Activity",
                "Speak by simply talking. With this off, members must use "
                    + "push-to-talk — good for controlling background noise."
            ),
            Entry(
                .prioritySpeaker,
                "Priority Speaker",
                "Be heard more easily by lowering everybody else's volume while "
                    + "they talk. Activated with the push-to-talk (priority) key."
            ),
            Entry(.muteMembers, "Mute Members", "Mute other members for everyone."),
            Entry(
                .deafenMembers,
                "Deafen Members",
                "Deafen other members, so they can neither speak nor hear."
            ),
            Entry(
                .moveMembers,
                "Move Members",
                "Disconnect other members, or move them between voice channels "
                    + "this member can access."
            ),
            Entry(
                .setVoiceChannelStatus,
                "Set Voice Channel Status",
                "Create and edit the status line on a voice channel."
            ),
        ]),

        Group(title: "Apps Permissions", entries: [
            Entry(
                .useApplicationCommands,
                "Use Application Commands",
                "Use commands from apps, including slash commands and context "
                    + "menu commands."
            ),
            Entry(.useEmbeddedActivities, "Use Activities", "Launch activities in a voice channel."),
            Entry(
                .useExternalApps,
                "Use External Apps",
                "Let apps they added to their own account post messages here. "
                    + "With this off, those messages are only visible to them."
            ),
        ]),

        Group(title: "Stage Channel Permissions", entries: [
            Entry(
                .requestToSpeak,
                "Request to Speak",
                "Ask to speak in a stage channel. Stage moderators approve or "
                    + "deny each request."
            ),
        ]),

        Group(title: "Events Permissions", entries: [
            Entry(
                .createEvents,
                "Create Events",
                "Create events — and edit or cancel the ones they created."
            ),
            Entry(.manageEvents, "Manage Events", "Edit and cancel any event."),
        ]),

        Group(title: "Advanced Permissions", entries: [
            Entry(
                .administrator,
                "Administrator",
                "Every permission, and every channel-specific restriction "
                    + "bypassed — including access to all private channels. "
                    + "This is a dangerous permission to grant.",
                isElevated: true
            ),
        ]),
    ]

    /// Every permission this catalog names, as one set.
    public static let known: Permissions = groups
        .flatMap(\.entries)
        .reduce(into: Permissions()) { $0.insert($1.permission) }

    /// The bits a role holds that nothing here can draw.
    ///
    /// **Preserved through an edit rather than cleared**, and this is not a
    /// nicety: the role editor writes the whole bitfield back, Discord adds
    /// permissions every few months, and a client that zeroed what it did not
    /// recognise would quietly strip them from every role anybody renamed. Six
    /// of the flags in this file were missing from this client until a capture
    /// arrived, which is exactly how often that happens.
    public static func unknownBits(in permissions: Permissions) -> Permissions {
        Permissions(rawValue: permissions.rawValue & ~known.rawValue)
    }

    /// Entries matching a search, group by group, with empty groups dropped.
    public static func groups(matching query: String) -> [Group] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return groups }
        return groups.compactMap { group in
            let kept = group.entries.filter {
                $0.title.lowercased().contains(trimmed)
                    || $0.detail.lowercased().contains(trimmed)
            }
            return kept.isEmpty ? nil : Group(title: group.title, entries: kept)
        }
    }
}
