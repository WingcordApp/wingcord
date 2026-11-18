import Foundation
import WingcordCore

// MARK: - Wire types
//
// Discord's JSON, one struct per payload, each with a `domain` property that
// converts to the app's own model.
//
// TWO RULES RUN THROUGH ALL OF THEM, and both exist because Discord ships
// changes without warning:
//
//  1. **Every field that is not structurally required is optional.** A missing
//     key must never fail a decode — Discord adds and removes fields
//     continuously, and a client that throws on an unexpected shape fails to
//     decode the WHOLE guild rather than losing one value.
//  2. **Every enum decodes through a raw value with an `unknown` case.** A new
//     channel kind or message type is a row that renders plainly, not a
//     connection that cannot come up.
//
// The separation from the domain types is not ceremony: it is what lets `Message`
// be 80 bytes with its rare half boxed while the wire type stays a flat mirror of
// the JSON.

struct UserDTO: Decodable, Sendable {
    var id: UserID
    var username: String
    var global_name: String?
    var avatar: String?
    var discriminator: String?
    var bot: Bool?
    var system: Bool?
    var public_flags: UInt64?
    var flags: UInt64?
    var banner: String?
    var accent_color: UInt32?
    var bio: String?
    var avatar_decoration_data: AvatarDecorationDTO?
    var collectibles: CollectiblesDTO?
    var display_name_styles: DisplayNameStylesDTO?
    /// The account's custom typing indicator — on its own user object.
    var typing_indicator_style: TypingIndicatorStyleDTO?
    var primary_guild: PrimaryGuildDTO?
    /// Which Nitro the account carries. On the reader's own object — READY's
    /// `user`, `/users/@me`, `USER_UPDATE` — and read from there into
    /// `AccountEntitlements`, never off the shared user row; see `entitlements`.
    var premium_type: Int?
    /// Which age group Discord has placed the account in. The reader's own
    /// object only, like `premium_type`. See `AgeGroup`.
    var age_verification_status: Int?
    /// Whether the account is cleared for age-restricted content: what a friend
    /// request's note falls back on. The reader's own object only.
    var nsfw_allowed: Bool?
    /// Which perks the account holds and where each came from — the reader's
    /// own object only. See `AccountPerks`.
    var perks: PerksDTO?
    // **Only ever populated by `GET /users/@me`.** Every other route that
    // carries a user carries a *public* one, so these are nil for everybody
    // else and that is not a failure to decode — see `AccountDetails`.
    var email: String?
    var phone: String?
    var verified: Bool?
    var mfa_enabled: Bool?

    /// The reader's own account, when this is the reader's own object.
    var currentAccount: CurrentAccount {
        CurrentAccount(
            user: domain,
            premiumType: premium_type,
            ageVerificationStatus: age_verification_status,
            verification: accountVerification,
            typingIndicatorStyle: typing_indicator_style.map(\.domain).flatMap { $0.isPlain ? nil : $0 },
            isNSFWAllowed: nsfw_allowed,
            perks: perks?.domain
        )
    }

    /// Whether the reader has confirmed an e-mail and holds a phone — nil on
    /// an object that is not the reader's own private one. **`verified` is
    /// the test for private**: every public user object leaves it out, so a
    /// missing `phone` beside it is no phone rather than an unknown.
    var accountVerification: AccountVerification? {
        verified.map { AccountVerification(isEmailVerified: $0, isPhoneVerified: phone != nil) }
    }

    var domain: User {
        // The box is built only when there is something to put in it. One
        // allocation per user with cosmetics, none for the overwhelming
        // majority who have none.
        let decoration = UserDecoration(
            avatarDecorationHash: avatar_decoration_data?.asset,
            avatarDecorationSKU: avatar_decoration_data?.sku_id,
            nameplate: collectibles?.nameplate?.domain,
            displayNameStyle: display_name_styles?.domain,
            bannerHash: banner,
            accentColor: accent_color,
            bio: bio?.isEmpty == true ? nil : bio,
            premiumTier: premium_type.flatMap { PremiumTier(rawValue: $0) } ?? .none,
            primaryGuildTag: primary_guild?.tag,
            primaryGuildBadgeHash: primary_guild?.badge,
            primaryGuildID: primary_guild?.identity_guild_id
        )
        return User(
            id: id,
            username: username,
            displayName: global_name,
            avatarHash: avatar,
            discriminator: discriminator ?? "0",
            flags: UserFlags(rawValue: public_flags ?? flags ?? 0),
            isBot: bot ?? false,
            isSystem: system ?? false,
            decoration: decoration.isEmpty ? nil : decoration
        )
    }
}

extension UserDTO {
    /// The narrow row a mutual-friends list draws.
    ///
    /// **Not the whole `domain` user.** A mutual-friends list is up to a
    /// hundred entries and each `domain` allocates a decoration box; the row
    /// needs a name, a face and a tag, and building forty fields to draw three
    /// is the allocation this type exists to avoid.
    var mutualFriend: MutualFriend {
        let name = global_name?.isEmpty == false ? global_name! : username
        return MutualFriend(
            id: id,
            name: name,
            avatarHash: avatar,
            monogram: String(name.prefix(1)).uppercased(),
            tag: primary_guild?.tag,
            tagBadgeHash: primary_guild?.badge,
            tagGuildID: primary_guild?.identity_guild_id,
            discriminator: discriminator
        )
    }
}

struct AvatarDecorationDTO: Decodable, Sendable {
    var asset: String?
    /// **On the wire from the start and decoded past for as long.** Nothing that
    /// only *draws* a decoration needs it — the asset addresses the picture — so
    /// it went unnoticed until an editor had to say which product is worn. The
    /// same field, and the same omission, as `NameplateDTO.sku_id`.
    var sku_id: String?
}

/// `user.display_name_styles` — `{font_id, effect_id, colors}`.
struct DisplayNameStylesDTO: Decodable, Sendable {
    var font_id: Int?
    var effect_id: Int?
    /// Signed on the wire because JSON has one number type. Read through
    /// `UInt32(exactly:)` so a value that could not be a colour is dropped
    /// rather than trapping — this decodes on the READY path, where a throw
    /// costs the whole user.
    var colors: [Int]?

    /// **Decoded leniently in both directions, and differently in each.**
    ///
    /// An unknown `font_id` costs the *face* and nothing else: Discord adds
    /// fonts, four ids in its own range are already unassigned, and a name in
    /// the default face is a smaller loss than no style at all.
    ///
    /// An unknown `effect_id` falls back to Solid rather than being dropped,
    /// which keeps the colour its owner chose. Substituting some *other* effect
    /// would be inventing a decision they did not make; painting their colour
    /// flat is the honest half of the answer.
    var domain: DisplayNameStyle? {
        let style = DisplayNameStyle(
            font: font_id.flatMap(DisplayNameFont.init(rawValue:)) ?? .default,
            effect: effect_id.flatMap(DisplayNameEffect.init(rawValue:)) ?? .solid,
            colors: colors?.compactMap { UInt32(exactly: $0) } ?? []
        )
        // The default face with no effect and no colour is what the ordinary
        // label already draws, so it is stored as nothing rather than as a style
        // that every surface then has to test for.
        return style.isPlain ? nil : style
    }
}

struct CollectiblesDTO: Decodable, Sendable {
    var nameplate: NameplateDTO?

    struct NameplateDTO: Decodable, Sendable {
        var asset: String?
        var label: String?
        /// One of twelve named colours. **Decoded leniently**: Discord adds to
        /// this list, and an unrecognised name has to cost the wash rather than
        /// the plate.
        var palette: String?
        var sku_id: String?

        var domain: Nameplate? {
            guard let asset, !asset.isEmpty else { return nil }
            return Nameplate(
                asset: asset,
                palette: palette.flatMap(NameplatePalette.init(rawValue:)) ?? .none,
                label: label,
                skuID: sku_id
            )
        }
    }
}

struct PrimaryGuildDTO: Decodable, Sendable {
    var tag: String?
    var badge: String?
    var identity_guild_id: GuildID?
}

struct RoleDTO: Decodable, Sendable {
    var id: RoleID
    var name: String
    var color: UInt32?
    var hoist: Bool?
    var position: Int?
    var permissions: String?
    var managed: Bool?
    var mentionable: Bool?
    var icon: String?
    var unicode_emoji: String?
    var description: String?
    /// The gradient stops, beside the deprecated flat `color`. Decoded so the
    /// role editor can write them back — see `Role.colors`.
    var colors: RoleColorsDTO?
    var flags: Int?

    var domain: Role {
        Role(
            id: id,
            name: name,
            colorValue: color ?? 0,
            isHoisted: hoist ?? false,
            position: position ?? 0,
            permissions: Permissions(string: permissions ?? "0"),
            isManaged: managed ?? false,
            isMentionable: mentionable ?? false,
            iconHash: icon,
            unicodeEmoji: unicode_emoji,
            description: description.nonEmpty,
            colors: colors?.domain,
            flags: flags ?? 0
        )
    }
}

struct RoleColorsDTO: Decodable, Sendable {
    var primary_color: UInt32?
    var secondary_color: UInt32?
    var tertiary_color: UInt32?

    var domain: RoleColors {
        RoleColors(
            primary: primary_color ?? 0,
            secondary: secondary_color,
            tertiary: tertiary_color
        )
    }
}

struct MemberDTO: Decodable, Sendable {
    var user: UserDTO?
    /// The person, when the payload has already sent their user object
    /// somewhere else.
    ///
    /// **`DEDUPE_USER_OBJECTS` is why this exists.** The capability this client
    /// identifies with hoists every user object into READY's own `users` array
    /// and leaves an id behind in each member — so a member from
    /// `merged_members` or a passive update carries `user_id` and no `user`,
    /// and a decoder that only knows `user` reads every one of them as nobody.
    var user_id: UserID?
    var nick: String?
    var avatar: String?
    var roles: [RoleID]?
    var joined_at: Date?
    var premium_since: Date?
    var communication_disabled_until: Date?
    var pending: Bool?
    /// `GuildMemberFlags` — see `MemberFlags`.
    var flags: Int?
    var unusual_dm_activity_until: Date?
    /// The per-server profile's own cosmetics, on the member object as on a
    /// user — see `MemberCosmetics`.
    var avatar_decoration_data: AvatarDecorationDTO?
    var collectibles: CollectiblesDTO?
    var display_name_styles: DisplayNameStylesDTO?

    func domain(userID: UserID) -> Member {
        let cosmetics = MemberCosmetics(
            avatarDecorationHash: avatar_decoration_data?.asset,
            avatarDecorationSKU: avatar_decoration_data?.sku_id,
            nameplate: collectibles?.nameplate?.domain,
            displayNameStyle: display_name_styles?.domain
        )
        return Member(
            userID: userID,
            nickname: nick,
            avatarHash: avatar,
            roleIDs: roles ?? [],
            joinedAt: joined_at,
            premiumSince: premium_since,
            communicationDisabledUntil: communication_disabled_until,
            isPending: pending ?? false,
            flags: MemberFlags(rawValue: flags ?? 0),
            unusualDMActivityUntil: unusual_dm_activity_until,
            cosmetics: cosmetics.isEmpty ? nil : cosmetics
        )
    }
}

struct OverwriteDTO: Decodable, Sendable {
    var id: UInt64
    var type: Int
    var allow: String?
    var deny: String?

    var domain: PermissionOverwrite {
        PermissionOverwrite(
            id: id,
            subject: type == 1 ? .member : .role,
            allow: Permissions(string: allow ?? "0"),
            deny: Permissions(string: deny ?? "0")
        )
    }

    /// Discord sends overwrite ids as strings, like every other snowflake, but
    /// the field is a bare `UInt64` here because it is either a role id or a
    /// user id and a phantom type would need a wrapper every call site unwraps.
    private enum CodingKeys: String, CodingKey {
        case id, type, allow, deny
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decode(String.self, forKey: .id)
        id = UInt64(text) ?? 0
        // `type` is an integer on the gateway and a string on some REST routes.
        if let value = try? container.decode(Int.self, forKey: .type) {
            type = value
        } else {
            type = Int(try container.decode(String.self, forKey: .type)) ?? 0
        }
        allow = try container.decodeIfPresent(String.self, forKey: .allow)
        deny = try container.decodeIfPresent(String.self, forKey: .deny)
    }
}

struct ChannelDTO: Decodable, Sendable {
    var id: ChannelID
    var type: Int
    var guild_id: GuildID?
    var name: String?
    var topic: String?
    var parent_id: ChannelID?
    var position: Int?
    var nsfw: Bool?
    var last_message_id: MessageID?
    var rate_limit_per_user: Int?
    var permission_overwrites: [OverwriteDTO]?
    var member_list_id: String?
    var recipients: [UserDTO]?
    var recipient_ids: [UserID]?
    var icon: String?
    var owner_id: UserID?
    var message_count: Int?
    /// Voice channels only. The encoder is configured from it — see
    /// `Channel.bitrate`.
    var bitrate: Int?
    var user_limit: Int?
    /// What the room has been labelled with, by anybody sitting in it.
    ///
    /// **Only ever on the gateway's own guild object.** No REST channel route
    /// answers with it, which is why it is harvested into `VoiceChannelInfo`
    /// here rather than mapped into `Channel` — a field on the domain value
    /// would be wiped by the next plain channel object to arrive.
    var status: String?
    var thread_metadata: ThreadMetadataDTO?
    var applied_tags: [ForumTagID]?
    var available_tags: [ForumTagDTO]?
    var default_reaction_emoji: DefaultReactionDTO?
    var default_sort_order: Int?
    var default_forum_layout: Int?
    /// "match_some" or "match_all". Not captured; read as Discord's channel record reads it.
    var default_tag_setting: String?
    var default_thread_rate_limit_per_user: Int?
    var template: String?
    var flags: Int?
    var rtc_region: String?
    var video_quality_mode: Int?
    var default_auto_archive_duration: Int?
    var member_count: Int?
    var member_ids_preview: [UserID]?
    var total_message_sent: Int?
    /// The thread's creator, as a guild member.
    ///
    /// **Only `threads/search` sends it**, and it is not part of the channel
    /// object anywhere else. It is decoded here rather than in a wrapper because
    /// it arrives *on* the channel — but it is deliberately not mapped into
    /// `domain()`: `Channel` holds an `ownerID`, and the person behind it
    /// belongs in the user and member stores like every other.
    var owner: MemberDTO?
    /// A private channel's standing as a message request — Discord's
    /// `ChannelRecord.fromServer` reads both. Absent on every ordinary one.
    var is_message_request: Bool?
    var is_spam: Bool?

    func domain(guildID: GuildID? = nil) -> Channel {
        Channel(
            id: id,
            kind: ChannelKind(rawValue: type),
            guildID: guild_id ?? guildID,
            name: name ?? "",
            topic: topic,
            parentID: parent_id,
            position: position ?? 0,
            isNSFW: nsfw ?? false,
            lastMessageID: last_message_id,
            rateLimitPerUser: rate_limit_per_user ?? 0,
            overwrites: permission_overwrites?.map(\.domain) ?? [],
            recipientIDs: recipients?.map(\.id) ?? recipient_ids ?? [],
            iconHash: icon,
            ownerID: owner_id,
            messageCount: message_count,
            bitrate: bitrate,
            userLimit: user_limit,
            threadMetadata: thread_metadata?.domain,
            appliedTags: applied_tags ?? [],
            availableTags: available_tags?.map(\.domain) ?? [],
            defaultReaction: default_reaction_emoji?.domain,
            defaultSortOrder: default_sort_order.flatMap(ForumSortOrder.init(rawValue:)),
            defaultForumLayout: default_forum_layout.map(ForumLayout.init(rawChannelValue:)),
            defaultTagMatching: default_tag_setting.flatMap(TagMatching.init(rawValue:)),
            defaultThreadRateLimitPerUser: default_thread_rate_limit_per_user,
            template: template,
            flags: ChannelFlags(rawValue: flags ?? 0),
            rtcRegion: rtc_region,
            videoQualityMode: video_quality_mode,
            defaultAutoArchiveDuration: default_auto_archive_duration,
            memberCount: member_count,
            memberIDsPreview: member_ids_preview ?? [],
            totalMessageSent: total_message_sent,
            memberListID: member_list_id,
            messageRequest: MessageRequestStanding(
                isMessageRequest: is_message_request ?? false,
                isSpam: is_spam ?? false
            )
        )
    }
}

extension ChannelDTO {
    /// The three fields a message's thread chip draws.
    ///
    /// **`message_count`, and the capture settles it.** The thread in
    /// `threads.har` reports `message_count: 720` beside
    /// `total_message_sent: 728`, and Discord's own chip reads "720 Messages" —
    /// so the count people see is the one that *excludes* deleted messages, not
    /// the running total. `total_message_sent` is the fallback only for a thread
    /// old enough that Discord caps the other at 50.
    var threadSummary: MessageThread {
        MessageThread(
            id: id,
            name: name ?? "",
            messageCount: message_count ?? total_message_sent ?? 0,
            isArchived: thread_metadata?.archived ?? false
        )
    }
}

struct ThreadMetadataDTO: Decodable, Sendable {
    var archived: Bool?
    var archive_timestamp: Date?
    var auto_archive_duration: Int?
    var locked: Bool?
    var invitable: Bool?
    var create_timestamp: Date?

    var domain: ThreadMetadata {
        ThreadMetadata(
            isArchived: archived ?? false,
            archivedAt: archive_timestamp,
            // Discord's own default when it omits the field. Three days, not one
            // — a thread that reports no duration is not a thread that archives
            // in an hour.
            autoArchiveMinutes: auto_archive_duration ?? 4320,
            isLocked: locked ?? false,
            isInvitable: invitable,
            createdAt: create_timestamp
        )
    }
}

struct ForumTagDTO: Decodable, Sendable {
    var id: ForumTagID
    var name: String?
    var moderated: Bool?
    var emoji_id: EmojiID?
    var emoji_name: String?

    var domain: ForumTag {
        ForumTag(
            id: id,
            name: name ?? "",
            isModerated: moderated ?? false,
            emoji: Self.emoji(id: emoji_id, name: emoji_name)
        )
    }

    /// Discord sends both fields on every tag and nulls the one that does not
    /// apply — so "has an emoji" is "either field is set", never "the object is
    /// present".
    static func emoji(id: EmojiID?, name: String?) -> EmojiRef? {
        if let id { return EmojiRef(id: id, name: name ?? "") }
        guard let name, !name.isEmpty else { return nil }
        return EmojiRef(name: name)
    }
}

struct DefaultReactionDTO: Decodable, Sendable {
    var emoji_id: EmojiID?
    var emoji_name: String?

    var domain: EmojiRef? { ForumTagDTO.emoji(id: emoji_id, name: emoji_name) }
}

/// The current user's membership of a thread.
///
/// **Captured**, `forums.har` and `threads.har`: returned from
/// `PATCH /channels/{id}/thread-members/@me/settings` and carried in the
/// `members` array of `threads/search`.
struct ThreadMemberDTO: Decodable, Sendable {
    var id: ChannelID?
    var user_id: UserID?
    var join_timestamp: Date?
    var flags: Int?
    var muted: Bool?
    var mute_config: MuteConfigDTO?

    /// The thread id is not always in the payload.
    ///
    /// `THREAD_MEMBER_UPDATE` carries it, and so does every `members` entry —
    /// but the reply to a settings PATCH is about a thread the caller named in
    /// the URL, and a `GET /thread-members` row omits it for the same reason.
    /// The caller supplies what it asked about rather than this failing to
    /// decode.
    func domain(threadID: ChannelID, userID: UserID) -> ThreadMember {
        ThreadMember(
            id: id ?? threadID,
            userID: user_id ?? userID,
            joinedAt: join_timestamp,
            flags: ThreadMemberFlags(rawValue: flags ?? 0),
            isMuted: muted ?? false,
            muteConfig: mute_config?.domain
        )
    }
}

struct MuteConfigDTO: Decodable, Sendable {
    var end_time: Date?
    var selected_time_window: Int?

    var domain: ThreadMuteConfig {
        ThreadMuteConfig(endTime: end_time, selectedTimeWindow: selected_time_window)
    }
}

/// `THREAD_CREATE` — a channel object with two extra fields beside it.
///
/// The channel is decoded from the **same container**, not from a nested key:
/// Discord sends the thread's fields at the top level of `d` and hangs
/// `newly_created` and `member` alongside them.
struct ThreadCreateDTO: Decodable, Sendable {
    var channel: ChannelDTO
    /// Absent when the event is Discord re-announcing a thread the account has
    /// just gained access to, which is most of them. **Only a true here means a
    /// thread that did not exist a moment ago** — anything that animates or
    /// notifies keys off it rather than off the event's name.
    var newly_created: Bool?
    /// Our own membership, present when the event is about a thread we are in.
    var member: ThreadMemberDTO?

    private enum CodingKeys: String, CodingKey {
        case newly_created, member
    }

    init(from decoder: any Decoder) throws {
        channel = try ChannelDTO(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        newly_created = try container.decodeIfPresent(Bool.self, forKey: .newly_created)
        member = try container.decodeIfPresent(ThreadMemberDTO.self, forKey: .member)
    }
}

/// `THREAD_DELETE` — a partial channel: four fields, and no `name`.
struct ThreadDeleteDTO: Decodable, Sendable {
    var id: ChannelID
    var guild_id: GuildID?
    var parent_id: ChannelID?
    var type: Int?
}

/// Op 28, what `FORUM_UNREADS` answers: `s.REQUEST_FORUM_UNREADS=28` in the web
/// build, whose `requestForumUnreads` writes exactly these fields. **A wrong op closes
/// the socket with 4001**, so the number is pinned by a test. Not captured.
struct ForumUnreadsRequest: Encodable {
    struct Body: Encodable {
        struct Thread: Encodable {
            var thread_id: String
            var ack_message_id: String
        }

        var guild_id: String
        var channel_id: String
        var threads: [Thread]
    }

    var op = 28
    var d: Body

    init(guildID: GuildID, channelID: ChannelID, threads: [(threadID: ChannelID, ackMessageID: MessageID)]) {
        d = Body(
            guild_id: String(guildID.rawValue),
            channel_id: String(channelID.rawValue),
            threads: threads.map {
                Body.Thread(thread_id: String($0.threadID.rawValue), ack_message_id: String($0.ackMessageID.rawValue))
            }
        )
    }
}

/// `FORUM_UNREADS`: how many messages each of a board's posts has past the mark
/// it was asked about. Discord's `eV(["FORUM_UNREADS"], …)` in the web build reads
/// exactly these fields, and drops the whole answer on `permission_denied`.
struct ForumUnreadsDTO: Decodable, Sendable {
    struct Thread: Decodable, Sendable {
        var thread_id: ChannelID
        /// Absent where the server has lost track. Discord keeps no count for
        /// those, and a post with none says "1+".
        var count: Int?
    }

    var channel_id: ChannelID
    var permission_denied: Bool?
    var threads: [Thread]?
}

/// `THREAD_LIST_SYNC` — every thread the account can now see in the named
/// channels, with its own memberships for the ones it has joined.
struct ThreadListSyncDTO: Decodable, Sendable {
    var guild_id: GuildID?
    /// The parents this sync covers. **Nil means the whole guild**, and the
    /// difference is load-bearing: a client that treats nil as "no channels"
    /// keeps stale threads for every channel the event was meant to clear.
    var channel_ids: [ChannelID]?
    var threads: [ChannelDTO]?
    var members: [ThreadMemberDTO]?
}

/// `THREAD_MEMBER_UPDATE` — our own membership of one thread.
struct ThreadMemberUpdateDTO: Decodable, Sendable {
    var id: ChannelID?
    var user_id: UserID?
    var guild_id: GuildID?
    var join_timestamp: Date?
    var flags: Int?
    var muted: Bool?
    var mute_config: MuteConfigDTO?

    func domain(userID: UserID) -> ThreadMember? {
        guard let id else { return nil }
        return ThreadMember(
            id: id,
            userID: user_id ?? userID,
            joinedAt: join_timestamp,
            flags: ThreadMemberFlags(rawValue: flags ?? 0),
            isMuted: muted ?? false,
            muteConfig: mute_config?.domain
        )
    }
}

/// `THREAD_MEMBERS_UPDATE` — somebody else came or went.
struct ThreadMembersUpdateDTO: Decodable, Sendable {
    var id: ChannelID
    var guild_id: GuildID?
    /// The thread's count after the change. Caps at 50 like every other
    /// `member_count`.
    var member_count: Int?
    var added_members: [ThreadMemberDTO]?
    var removed_member_ids: [UserID]?
}

struct GuildDTO: Decodable, Sendable {
    var id: GuildID
    var name: String?
    var icon: String?
    var banner: String?
    var splash: String?
    /// The tag this server lends, when it has one.
    ///
    /// **Nested under `profile`, and it rides READY.** Discord's tag picker
    /// asks no route at all: it reads this off the guilds it already has. Only
    /// the two fields a tag is worn as are taken — the same object carries a
    /// description, traits and badge colours, and those belong to
    /// `GuildProfileDTO`, which fetches them when a tag card is opened.
    var profile: GuildIdentityDTO?
    var owner_id: UserID?
    var premium_tier: Int?
    var premium_subscription_count: Int?
    /// Whether the channel list shows the server's Boost progress bar.
    var premium_progress_bar_enabled: Bool?
    /// The Server Hub's switch and publishing state — never throws.
    var guild_space_settings: GuildSpaceSettingsField?
    var features: [String]?
    var member_count: Int?
    var rules_channel_id: ChannelID?
    var public_updates_channel_id: ChannelID?
    var afk_channel_id: ChannelID?
    var large: Bool?
    /// What the server tells a member who has set nothing. 0 all, 1 mentions.
    var default_message_notifications: Int?
    var roles: [RoleDTO]?
    /// A server's own emoji and stickers. Present on the READY guild objects and
    /// on GUILD_CREATE, which is what keeps the picker's catalog current without
    /// a fetch of its own.
    var emojis: [EmojiDTO]?
    var stickers: [StickerDTO]?
    var channels: [ChannelDTO]?
    /// The threads in this guild, beside its channels rather than among them.
    ///
    /// **A user account is sent only the threads it has joined**, not every
    /// active one — bots get the full set, this client does not. So this is the
    /// followed-thread list at launch, and a thread's absence here says nothing
    /// about whether it exists.
    var threads: [ChannelDTO]?
    var members: [MemberDTO]?
    var presences: [PresenceDTO]?
    /// A server's soundboard, when the payload carries one.
    ///
    /// **Free where it is present and harmless where it is not.** Reading an
    /// optional field costs nothing, and it is the only way to fill the
    /// picker's other sections without sending an opcode nobody has captured —
    /// which is a frame the gateway may close the socket over.
    var soundboard_sounds: [SoundboardSoundDTO]?
    /// Who is already in a voice channel, at the moment READY was built.
    ///
    /// **The only source for this at launch.** Voice states arrive as events
    /// afterwards, so a client that ignores them here shows every voice channel
    /// empty until somebody moves — which on a quiet server is for ever.
    var voice_states: [VoiceStateDTO]?
    /// The stages **already live** in this server when it arrived.
    ///
    /// A stage channel is in `channels` whether or not anything is happening
    /// in it; this is the small set that is on. Without it a client shows
    /// every stage channel as dark until somebody starts one while it is
    /// watching.
    var stage_instances: [StageInstanceDTO]?
    /// The activities **already running** in this server's channels when it
    /// arrived. Lossy, as the events are: one unreadable instance is dropped.
    var activity_instances: LossyList<ActivityInstanceDTO>?
    /// The server's scheduled events — what the inbox's Events group is
    /// drawn from, and how it knows one is new. **Lossy**: this rides in
    /// READY, and one event this client cannot read must not cost the reader
    /// every server they are in.
    var guild_scheduled_events: LossyList<ScheduledEventDTO>?
    /// Present on the READY payload's guild objects, absent on a plain fetch.
    var properties: GuildProperties?
    /// The server's apex experiment assignments — beside `properties` in
    /// READY and at the top level of GUILD_CREATE, never inside either.
    /// Discord's apex store reads a server's experiments (the Server Hub's
    /// among them) from nowhere else. Never throws.
    var experiments: GuildApexField?
    /// When the reader joined, at the top level. Nested on READY — see
    /// `GuildProperties.joined_at`.
    var joined_at: Date?
    /// The server's own theme. See `GuildThemeField` for why absent and null
    /// are told apart.
    var theme: GuildThemeField?
    /// 0 default, 1 explicit, 2 safe, 3 age-restricted — Discord's
    /// `GuildNSFWContentLevel`. Only "is it 1 or 3" is kept.
    var owner_configured_content_level: Int?
    /// What the server asks of an account before it may talk or apply.
    var verification_level: Int?
    /// How many may be in a stage with a camera on — see
    /// `Guild.maxStageVideoUsers`.
    var max_stage_video_channel_users: Int?

    /// Discord moved a guild's own fields into a nested `properties` object on
    /// the READY payload while leaving them at the top level everywhere else.
    /// Both shapes are read, top level first.
    struct GuildProperties: Decodable, Sendable {
        var id: GuildID?
        var name: String?
        var icon: String?
        var banner: String?
        var splash: String?
        var owner_id: UserID?
        var premium_tier: Int?
        /// Nested here on READY too — §5.9. The count was read from the top
        /// level only, so on READY every server counted zero boosts.
        var premium_subscription_count: Int?
        var premium_progress_bar_enabled: Bool?
        /// Nested here on READY with everything else — §5.9.
        var guild_space_settings: GuildSpaceSettingsField?
        var features: [String]?
        var rules_channel_id: ChannelID?
        var public_updates_channel_id: ChannelID?
        /// Nested here on READY with everything else — §5.9.
        var afk_channel_id: ChannelID?
        /// **The server's own notification floor, and READY is the only place
        /// it arrives.** It was declared at the top level and nowhere here, so
        /// on a payload where Discord nests a guild's fields — which is every
        /// READY this client asks for, since it sets
        /// `PRIORITIZED_READY_PAYLOAD` — it was absent and fell back to
        /// `allMessages` for **every server on the account**.
        ///
        /// Nothing failed. Most large servers set Only @mentions, so the
        /// inbox's Unreads tab listed every channel with anything unread in it
        /// rather than the handful that would have told the reader anything,
        /// and the notification policy read the same wrong floor. See the
        /// neighbours above: `features` and `rules_channel_id` already carry
        /// the fallback this one was missing.
        var default_message_notifications: Int?
        /// When the reader joined. Nested here on READY like everything else.
        var joined_at: Date?
        /// **Read from here as well as from the top level.** READY sends most
        /// guilds unavailable-then-filled and puts the same fields under
        /// `properties`; a tag decoded from only one of the two shapes is a tag
        /// that appears for some servers and not others.
        var profile: GuildIdentityDTO?
        /// Nested here on READY, like every field beside it — `INVARIANTS.md`
        /// §5.9: a type with a nested form reads every field from both.
        var theme: GuildThemeField?
        var owner_configured_content_level: Int?
        /// Nested here on READY, like every field beside it — §5.9.
        var verification_level: Int?
        /// Nested here on READY, like every field beside it — §5.9.
        var max_stage_video_channel_users: Int?
    }

    /// Whether this payload said anything about the theme at all.
    ///
    /// **A GUILD_UPDATE is applied by replacement**, so a payload that left the
    /// key out would otherwise take a server's theme away. Discord's own record
    /// keeps the previous theme when the key is absent (`void 0 === e.theme`),
    /// and the session does the same with this.
    var carriesTheme: Bool { theme != nil || properties?.theme != nil }

    /// `guild.profile`, reduced to the two fields a tag is *worn* as.
    struct GuildIdentityDTO: Decodable, Sendable {
        var tag: String?
        var badge: String?
    }

    var domain: Guild {
        var guild = Guild(
            id: id,
            name: name ?? properties?.name ?? "Unknown",
            iconHash: icon ?? properties?.icon,
            bannerHash: banner ?? properties?.banner,
            splashHash: splash ?? properties?.splash,
            ownerID: owner_id ?? properties?.owner_id ?? UserID(rawValue: 0),
            premiumTier: premium_tier ?? properties?.premium_tier ?? 0,
            premiumSubscriptionCount: premium_subscription_count ?? properties?.premium_subscription_count ?? 0,
            features: Set(features ?? properties?.features ?? []),
            tag: profile?.tag ?? properties?.profile?.tag,
            tagBadgeHash: profile?.badge ?? properties?.profile?.badge,
            memberCount: member_count,
            rulesChannelID: rules_channel_id ?? properties?.rules_channel_id,
            publicUpdatesChannelID: public_updates_channel_id ?? properties?.public_updates_channel_id,
            afkChannelID: afk_channel_id ?? properties?.afk_channel_id,
            isLarge: large ?? false,
            defaultMessageNotifications: NotificationLevel(
                rawValue: default_message_notifications
                    ?? properties?.default_message_notifications
                    ?? 0
            ),
            joinedAt: joined_at ?? properties?.joined_at,
            theme: (theme ?? properties?.theme)?.domain,
            isAgeRestricted: (owner_configured_content_level
                ?? properties?.owner_configured_content_level)
                .map { $0 == 1 || $0 == 3 } ?? false,
            verificationLevel: (verification_level ?? properties?.verification_level)
                .map(VerificationLevel.init(rawValue:)),
            maxStageVideoUsers: max_stage_video_channel_users
                ?? properties?.max_stage_video_channel_users
        )
        guild.premiumProgressBarEnabled = premium_progress_bar_enabled
            ?? properties?.premium_progress_bar_enabled ?? false
        guild.spaceSettings = guild_space_settings?.settings ?? properties?.guild_space_settings?.settings
        guild.apexAssignments = experiments?.assignments
        return guild
    }
}

/// A guild's `theme` as it can arrive: an object, an explicit `null`, or not
/// at all.
///
/// **Absent and null are different answers**, and the synthesised
/// `decodeIfPresent` folds them together — see `GuildDTO.carriesTheme` for the
/// one place that asks. The overload below is what keeps them apart: it is more
/// specific than the generic one, so the synthesised initialiser picks it.
///
/// **And it never throws.** The object rides every READY, and a field nobody
/// else reads is exactly the kind that takes a bootstrap down when its shape
/// moves (`INVARIANTS.md` §5.58.5). A theme this client cannot read draws as no
/// theme.
enum GuildThemeField: Decodable, Sendable {
    case cleared
    case set(GuildTheme)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard !container.decodeNil(),
              let dto = try? container.decode(GuildThemeDTO.self)
        else {
            self = .cleared
            return
        }
        self = .set(dto.domain)
    }

    var domain: GuildTheme? {
        if case .set(let theme) = self { theme } else { nil }
    }
}

extension KeyedDecodingContainer {
    /// Present-and-null is `.cleared`; absent is nil. See `GuildThemeField`.
    func decodeIfPresent(_ type: GuildThemeField.Type, forKey key: Key) throws -> GuildThemeField? {
        guard contains(key) else { return nil }
        return try decode(GuildThemeField.self, forKey: key)
    }
}

/// A reply's `referenced_message` as it can arrive: the quoted message, an
/// explicit `null`, or not at all.
///
/// **Discord's documented contract, and its client draws the difference.**
/// `null` is a message that was deleted; an absent key is a server that did
/// not try to fetch it, so nobody knows. The synthesised `decodeIfPresent`
/// folds the two together — the header then called every unfetched quote
/// deleted — so the overload below keeps them apart, as `GuildThemeField`'s
/// does.
enum QuotedField: Decodable, Sendable {
    case deleted
    case message(MessageDTO.QuotedDTO)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = container.decodeNil() ? .deleted : .message(try container.decode(MessageDTO.QuotedDTO.self))
    }

    var message: MessageDTO.QuotedDTO? {
        if case .message(let quoted) = self { quoted } else { nil }
    }

    var isDeleted: Bool {
        if case .deleted = self { true } else { false }
    }
}

extension KeyedDecodingContainer {
    /// Present-and-null is `.deleted`; absent is nil. See `QuotedField`.
    func decodeIfPresent(_ type: QuotedField.Type, forKey key: Key) throws -> QuotedField? {
        guard contains(key) else { return nil }
        return try decode(QuotedField.self, forKey: key)
    }
}

/// `guild.theme`, captured: `{"preset_id": null, "custom_user_theme_settings":
/// {"colors": ["#77C579"], "gradient_color_stops": [], "gradient_angle": 0,
/// "base_mix": 0}, "enabled": true}`.
struct GuildThemeDTO: Decodable, Sendable {
    var enabled: Bool?
    var preset_id: Int?
    var custom_user_theme_settings: Custom?

    struct Custom: Decodable, Sendable {
        var colors: [String]?
        /// Only whether there are any: Discord's test refuses a custom theme
        /// that carries stops, and the capture's are empty — so their element
        /// shape has never been seen and is not assumed.
        var gradient_color_stops: ElementCount?
        var gradient_angle: Double?
        var base_mix: Double?
    }

    /// How many elements a JSON array holds, whatever they are.
    struct ElementCount: Decodable, Sendable {
        var count: Int

        init(from decoder: any Decoder) throws {
            count = (try? decoder.unkeyedContainer())?.count ?? 0
        }
    }

    /// Discord's own conversion (module `679787`): the angle and the mix
    /// default to zero, and a colour list with anything unreadable in it is no
    /// colour list — dropping the bad entry could turn two colours into the one
    /// a custom theme needs.
    var domain: GuildTheme {
        let custom = custom_user_theme_settings
        let parsed = (custom?.colors ?? []).map(Self.rgb)
        return GuildTheme(
            isEnabled: enabled ?? false,
            presetID: preset_id,
            colors: parsed.contains(nil) ? [] : parsed.compactMap(\.self),
            hasGradientStops: (custom?.gradient_color_stops?.count ?? 0) > 0,
            angle: custom?.gradient_angle ?? 0,
            baseMix: custom?.base_mix ?? 0
        )
    }

    /// `#RRGGBB` → 24-bit, or nil.
    private static func rgb(_ hex: String) -> UInt32? {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6 else { return nil }
        return UInt32(digits, radix: 16)
    }
}

struct AttachmentDTO: Decodable, Sendable {
    var id: AttachmentID
    var filename: String
    var url: String
    var proxy_url: String
    var content_type: String?
    var size: Int?
    var width: Int?
    var height: Int?
    var description: String?
    var waveform: String?
    var duration_secs: Double?
    var flags: Int?
    var placeholder: String?
    var placeholder_version: Int?
    // A clip's fields (docs/CLIPS-PRESENCE.md, Phase 4.1) — what Discord's
    // player reads off a shared clip.
    var is_clip: Bool?
    var title: String?
    var application: ClipApplicationDTO?
    var application_id: ApplicationID?
    /// A string, read here: a shape this cannot read costs the date, never
    /// the message.
    var clip_created_at: String?
    var clip_participants: [LenientUser]?
    var clip_events_timeline: [LenientTimelineEvent]?
    var clip_remote_id: String?

    /// One participant, or nothing for an object that will not read.
    struct LenientUser: Decodable, Sendable {
        var user: UserDTO?

        init(from decoder: any Decoder) throws {
            user = try? UserDTO(from: decoder)
        }
    }

    struct ClipApplicationDTO: Decodable, Sendable {
        var id: ApplicationID?
        var name: String?
    }

    /// One timeline entry, or nothing for a kind this build does not know —
    /// a new kind costs that entry, never the clip.
    struct LenientTimelineEvent: Decodable, Sendable {
        var event: ClipTimelineEvent?

        init(from decoder: any Decoder) throws {
            event = try? ClipTimelineEvent(from: decoder)
        }
    }

    /// `IS_ANIMATED` in an attachment's `flags` — web `d4c7976eccf337f1`'s
    /// attachment flag enum; captured on both GIF attachments in the HARs.
    static let isAnimatedFlag = 1 << 5
    /// `IS_THUMBNAIL`, a media post's own picture for the board (`sbO` in the web
    /// build; read by `256265`).
    static let isThumbnailFlag = 1 << 1
    /// `HAS_TIMELINE_COMMENTS` — somebody has replied at a moment of the clip
    /// (web build 641803).
    static let hasTimelineCommentsFlag = 1 << 8
    /// `IS_CLIP` — what Discord's own client reads a clip by (module 650019's
    /// `isClip`); `is_clip` is only what a send writes.
    static let isClipFlag = 1 << 0

    /// The clip half, when this attachment is one.
    var clip: AttachmentClip? {
        let isClip = is_clip == true || (flags ?? 0) & Self.isClipFlag != 0
            || clip_created_at != nil || clip_participants != nil || clip_events_timeline != nil
        guard isClip else { return nil }
        return AttachmentClip(
            title: title,
            applicationID: (application?.id ?? application_id)?.rawValue,
            applicationName: application?.name,
            createdAt: clip_created_at.flatMap {
                ISO8601DateFormatter.withFraction.date(from: $0) ?? ISO8601DateFormatter.plain.date(from: $0)
            },
            participants: clip_participants?.compactMap { $0.user?.domain } ?? [],
            timeline: clip_events_timeline?.compactMap(\.event) ?? [],
            remoteID: clip_remote_id,
            hasTimelineComments: (flags ?? 0) & Self.hasTimelineCommentsFlag != 0
        )
    }

    var domain: Attachment {
        Attachment(
            id: id,
            filename: filename,
            url: url,
            proxyURL: proxy_url,
            contentType: content_type,
            size: size ?? 0,
            width: width,
            height: height,
            description: description,
            waveform: waveform,
            durationSeconds: duration_secs,
            isMarkedAnimated: (flags ?? 0) & Self.isAnimatedFlag != 0,
            placeholder: MediaPlaceholder.accepted(placeholder, version: placeholder_version),
            clip: clip,
            isThumbnail: (flags ?? 0) & Self.isThumbnailFlag != 0
        )
    }
}

struct EmojiDTO: Decodable, Sendable {
    var id: EmojiID?
    var name: String?
    var animated: Bool?
    /// False for an emoji the server has lost the boost tier to keep. Discord
    /// keeps sending them; nothing may use them.
    var available: Bool?

    var domain: EmojiRef {
        EmojiRef(id: id, name: name ?? "", isAnimated: animated ?? false)
    }

    /// The picker's form: a **custom** emoji that is usable. Unicode entries
    /// have no id and belong to the generated table, not to a server.
    var catalogEntry: EmojiRef? {
        guard id != nil, available != false, let name, !name.isEmpty else { return nil }
        return EmojiRef(id: id, name: name, isAnimated: animated ?? false)
    }
}

/// One emoji's reactions on a message.
///
/// **Captured**, `lottiesuperreaction.har`, for an emoji with nothing but super
/// reactions:
///
/// ```json
/// {"emoji": {"id": "1122960370512957560", "name": "x_shaq"},
///  "count": 194, "count_details": {"burst": 194, "normal": 0},
///  "burst_colors": ["#000000", "#301111", "#401b17", …ten…],
///  "me_burst": false, "burst_me": false, "me": false, "burst_count": 194}
/// ```
///
/// `count` is the **total** of both kinds. Discord's client replaces it with
/// `count_details.normal` the moment a message is decoded, and so does this —
/// reading `count` as the plain tally is what drew every super reaction twice.
struct ReactionDTO: Decodable, Sendable {
    var emoji: EmojiDTO
    var count: Int?
    var me: Bool?
    var me_burst: Bool?
    /// The same bit under a second name. Both arrive, carrying the same value.
    var burst_me: Bool?
    /// Only read when `count_details` is absent, exactly as Discord does.
    var burst_count: Int?
    var count_details: CountDetails?
    var burst_colors: [String]?

    struct CountDetails: Decodable, Sendable {
        var burst: Int?
        var normal: Int?
    }

    var domain: Reaction {
        // Discord's own normalisation, from the message record's builder: the
        // details win when they are there, and neither count goes below zero.
        let normal = count_details.map { $0.normal ?? 0 } ?? (count ?? 0)
        let burst = count_details.map { $0.burst ?? 0 } ?? (burst_count ?? 0)
        return Reaction(
            emoji: emoji.domain,
            count: max(0, normal),
            isMine: me ?? false,
            burstCount: max(0, burst),
            isMineBurst: me_burst ?? burst_me ?? false,
            burstColors: Self.palette(burst_colors)
        )
    }

    /// The first three `burst_colors`, packed. See `Reaction.burstColors` for
    /// why three.
    static func palette(_ colors: [String]?) -> [UInt32] {
        guard let colors else { return [] }
        return colors.prefix(3).compactMap { text in
            let hex = text.hasPrefix("#") ? text.dropFirst() : Substring(text)
            guard hex.utf8.count == 6 else { return nil }
            return UInt32(hex, radix: 16)
        }
    }
}

struct EmbedDTO: Decodable, Sendable {
    var title: String?
    var type: String?
    var description: String?
    var url: String?
    var timestamp: Date?
    var color: UInt32?
    var author: AuthorDTO?
    var footer: FooterDTO?
    var image: MediaDTO?
    var thumbnail: MediaDTO?
    var video: MediaDTO?
    var fields: [FieldDTO]?
    var provider: ProviderDTO?
    var components: [ComponentDTO]?

    struct AuthorDTO: Decodable, Sendable {
        var name: String?
        var url: String?
        var icon_url: String?
    }

    struct FooterDTO: Decodable, Sendable {
        var text: String?
        var icon_url: String?
    }

    struct MediaDTO: Decodable, Sendable {
        var url: String?
        var proxy_url: String?
        var width: Int?
        var height: Int?
        var flags: Int?
        var placeholder: String?
        var placeholder_version: Int?

        /// `IS_ANIMATED` in an embed picture's `flags` — the same bit as an
        /// attachment's, in a flag enum of its own; captured on an animated
        /// Tenor GIF and an animated sticker's unfurl, and on no still.
        static let isAnimatedFlag = 1 << 5

        var domain: Embed.Media? {
            guard let url else { return nil }
            return Embed.Media(
                url: url,
                proxyURL: proxy_url,
                width: width,
                height: height,
                isMarkedAnimated: (flags ?? 0) & Self.isAnimatedFlag != 0,
                placeholder: MediaPlaceholder.accepted(placeholder, version: placeholder_version)
            )
        }
    }

    struct FieldDTO: Decodable, Sendable {
        var name: String?
        var value: String?
        var inline: Bool?
    }

    struct ProviderDTO: Decodable, Sendable {
        var name: String?
    }

    var domain: Embed {
        Embed(
            title: title,
            kind: type,
            description: description,
            url: url,
            timestamp: timestamp,
            colorValue: color,
            author: author?.name.map {
                Embed.Author(name: $0, url: author?.url, iconURL: author?.icon_url)
            },
            footer: footer?.text.map { Embed.Footer(text: $0, iconURL: footer?.icon_url) },
            image: image?.domain,
            thumbnail: thumbnail?.domain,
            video: video?.domain,
            fields: fields?.compactMap { field in
                guard let name = field.name, let value = field.value else { return nil }
                return Embed.Field(name: name, value: value, isInline: field.inline ?? false)
            } ?? [],
            providerName: provider?.name,
            components: ComponentDTO.display(components)
        )
    }
}

struct StickerDTO: Decodable, Sendable {
    var id: UInt64
    var name: String?
    var format_type: Int?
    /// As on `EmojiDTO`: a sticker the server can no longer offer.
    var available: Bool?
    /// 1 for one of Discord's own, 2 for a server's. Only `GET /stickers/{id}`
    /// and the pack routes send it; a message's `sticker_items` do not.
    var type: Int?
    /// Strings on the wire, like every id — see `INVARIANTS.md` §5.58.5.
    var pack_id: String?
    var guild_id: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, format_type, available, type, pack_id, guild_id
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UInt64(try container.decode(String.self, forKey: .id)) ?? 0
        name = try container.decodeIfPresent(String.self, forKey: .name)
        format_type = try container.decodeIfPresent(Int.self, forKey: .format_type)
        available = try container.decodeIfPresent(Bool.self, forKey: .available)
        type = try container.decodeIfPresent(Int.self, forKey: .type)
        pack_id = try container.decodeIfPresent(String.self, forKey: .pack_id)
        guild_id = try container.decodeIfPresent(String.self, forKey: .guild_id)
    }

    var catalogEntry: StickerRef? {
        guard id != 0, available != false else { return nil }
        return domain
    }

    var domain: StickerRef {
        StickerRef(
            id: id,
            name: name ?? "",
            format: StickerRef.Format(rawValue: format_type ?? 1)
        )
    }

    var detail: StickerDetail {
        StickerDetail(
            sticker: domain,
            packID: pack_id.flatMap { $0.isEmpty ? nil : $0 },
            guildID: guild_id.flatMap(UInt64.init).map(GuildID.init(rawValue:)),
            isStandard: type == 1
        )
    }
}

struct MessageDTO: Decodable, Sendable {
    var id: MessageID
    var channel_id: ChannelID
    var author: UserDTO?
    var content: String?
    var edited_timestamp: Date?
    var type: Int?
    var flags: UInt32?
    var attachments: [AttachmentDTO]?
    var embeds: [EmbedDTO]?
    var reactions: [ReactionDTO]?
    var sticker_items: [StickerDTO]?
    var components: [ComponentDTO]?
    var poll: PollDTO?
    /// A custom theme shared into the conversation — Discord's theme card.
    var shared_client_theme: SharedClientThemeDTO?
    /// A timeline comment's moment — `{attachment_id, timestamp}`, plus the
    /// `message_id` Discord's own list adds.
    var media_mention: MediaMentionDTO?
    /// What a Server Hub message (type 69) is about. Never throws.
    var guild_space_data: GuildSpaceMessageDataField?
    /// A call's record on a `CALL` message. Never throws.
    var call: MessageCallDTO?
    var mentions: [UserDTO]?
    var mention_roles: [RoleID]?
    var mention_everyone: Bool?
    var message_reference: ReferenceDTO?
    /// The thread started from this message.
    ///
    /// **Captured**, `threads.har`: a whole channel object, nested. It is
    /// decoded as one — rather than as the three fields the chip draws — because
    /// the caller puts it into `ChannelIndex` so that opening the chip resolves.
    var thread: ChannelDTO?
    /// The message a reply quotes, sent inline — or `null`, which is Discord
    /// saying it was deleted, or absent, which is Discord not having looked it
    /// up. See `QuotedField` for why the last two are kept apart.
    ///
    /// **A narrow type, not another `MessageDTO`.** Two reasons and both are
    /// load-bearing: a message may quote a message that quotes a message, which
    /// no struct can hold, and the header needs four fields out of the forty a
    /// full decode would build — embeds, component trees and polls included —
    /// only to throw them away, once per reply on every page of history.
    var referenced_message: QuotedField?
    /// What a forward carries. An array in the payload and always of one, so it
    /// is read as one.
    var message_snapshots: [SnapshotDTO]?
    var pinned: Bool?
    var webhook_id: UserID?
    /// The application that owns this message's controls.
    ///
    /// **Documented, and absent from every capture here** — the messages in
    /// `slash help.har` arrived over the socket, which a HAR does not record. It
    /// is decoded because Discord sends it on exactly the messages a button can
    /// live on, and `Message.componentApplicationID` falls back to the author
    /// when it is missing: the capture's interaction names `949479338275913799`,
    /// which is both the application and the bot user who posted the message.
    var application_id: ApplicationID?
    var nonce: NonceDTO?
    /// The app behind an activity invitation. Only ever present on a message
    /// an application posted, and the invitation card's only source for the
    /// name and icon it draws — the message itself carries no content, no
    /// embed and no components.
    var application: InviteApplicationDTO?
    /// `{"id": "i-{interaction}-pc-{channel}"}`. Its presence is what makes a
    /// `type: 23` message an activity invitation rather than an ordinary
    /// context-menu command.
    var activity_instance: InstanceDTO?
    /// An invitation to join somebody's activity — a listen-along when its
    /// party is Spotify's. See `ListenAlongInvite`.
    var activity: MessageActivityDTO?
    /// **The newer of the two, and the one to prefer.** Discord sends both on a
    /// launch and has been removing `interaction`; a client reading only the
    /// old key loses the header when it goes.
    var interaction_metadata: InteractionDTO?
    var interaction: InteractionDTO?

    struct InviteApplicationDTO: Decodable, Sendable {
        var id: ApplicationID?
        var name: String?
        var icon: String?
    }

    struct InstanceDTO: Decodable, Sendable {
        var id: String?
    }

    /// `interaction_metadata`, and the older `interaction` beside it.
    struct InteractionDTO: Decodable, Sendable {
        var name: String?
        var user: UserDTO?
        /// Only on `interaction_metadata`; the legacy object has `type`
        /// instead, which means something else.
        var command_type: Int?
    }

    struct ReferenceDTO: Decodable, Sendable {
        /// 0 is a reply, 1 is a forward. Absent means 0 — the field postdates
        /// replies by years.
        var type: Int?
        var message_id: MessageID?
        var channel_id: ChannelID?
        /// The referenced message's server — a crosspost's source.
        var guild_id: GuildID?
    }

    /// Only what the reply header draws.
    ///
    /// The **author is a whole `UserDTO`**, deliberately, where the rest is
    /// narrowed to nothing: a quoted message is very often the only place this
    /// client ever learns who that person is. Somebody who wrote once, three
    /// hundred messages back, is in no roster and on no page of history the
    /// reader loaded — and a header naming them "Unknown" over a grey circle is
    /// the whole feature failing on the case it exists for.
    struct QuotedDTO: Decodable, Sendable {
        /// `IS_VOICE_MESSAGE` lives here, and a reply says so of what it answers.
        var flags: UInt32?
        var author: UserDTO?
        var content: String?
        var attachments: [Anything]?
        var sticker_items: [Anything]?

        /// A stand-in for an element whose only interesting property is that it
        /// exists. Decoding the real shape here would parse every attachment of
        /// every quoted message to answer one `Bool`.
        struct Anything: Decodable, Sendable {
            init(from decoder: any Decoder) throws {}
        }
    }

    /// The person a reply quotes, when the payload carried them.
    ///
    /// Harvested beside the page's own authors — see `DiscordREST.messages` —
    /// so the header can name and picture them with no second request.
    var quotedAuthor: UserDTO? { referenced_message?.message?.author }

    /// **Search only.** Marks the matching message inside a result group. The
    /// groups once carried surrounding context and no longer do, so today it is
    /// true on every message that comes back — read anyway, because it costs
    /// nothing and is correct again the day context returns.
    var hit: Bool?

    /// One forwarded message. Deliberately authorless — see `ForwardedMessage`.
    struct SnapshotDTO: Decodable, Sendable {
        var message: Body?

        struct Body: Decodable, Sendable {
            var content: String?
            var attachments: [AttachmentDTO]?
            var embeds: [EmbedDTO]?
            var sticker_items: [StickerDTO]?
            var timestamp: Date?
        }
    }

    /// Discord echoes back whatever nonce was sent, and clients send both
    /// strings and integers. Accepting only one shape means a send that was
    /// echoed as the other kind never matches its optimistic row and shows
    /// twice.
    enum NonceDTO: Decodable, Sendable {
        case string(String)
        case number(Int)

        var text: String {
            switch self {
            case .string(let value): value
            case .number(let value): String(value)
            }
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                self = .string(value)
            } else {
                self = .number(try container.decode(Int.self))
            }
        }
    }

    var domain: Message {
        let payload = MessagePayload(
            attachments: attachments?.map(\.domain) ?? [],
            embeds: embeds?.map(\.domain) ?? [],
            reactions: reactions?.map(\.domain) ?? [],
            stickers: sticker_items?.map(\.domain) ?? [],
            components: ComponentDTO.rows(components),
            displayComponents: ComponentDTO.display(components),
            poll: poll?.domain,
            mentionedUserIDs: mentions?.map(\.id) ?? [],
            mentionedRoleIDs: mention_roles ?? [],
            mentionsEveryone: mention_everyone ?? false,
            reference: replyReference,
            forwarded: forwardedMessage,
            webhookID: webhook_id,
            nonce: nonce?.text,
            activityInvite: activityInvite,
            listenAlong: activity?.listenAlong,
            interaction: messageInteraction,
            applicationID: application_id,
            thread: thread.map(\.threadSummary),
            sharedTheme: shared_client_theme?.domain,
            mediaMention: media_mention?.domain,
            guildSpaceData: guild_space_data?.data,
            contentEntry: ComponentDTO.contentEntry(components),
            call: call?.domain
        )
        return Message(
            id: id,
            channelID: channel_id,
            authorID: author?.id ?? UserID(rawValue: 0),
            content: content ?? "",
            editedAt: edited_timestamp,
            kind: MessageKind(rawValue: type ?? 0),
            flags: MessageFlags(rawValue: flags ?? 0),
            isPinned: pinned ?? false,
            payload: payload.isEmpty ? nil : payload
        )
    }

    /// The reply header's inputs, or nil for anything that is not a reply.
    ///
    /// A forward also carries a `message_reference`, and reading one as a reply
    /// is what would draw a quote header over a message that has no target the
    /// reader can reach.
    private var replyReference: MessageReference? {
        guard let message_reference, (message_reference.type ?? 0) == 0 else { return nil }
        let quoted = referenced_message?.message
        return MessageReference(
            messageID: message_reference.message_id,
            channelID: message_reference.channel_id,
            guildID: message_reference.guild_id,
            authorID: quoted?.author?.id,
            isAuthorBot: quoted?.author?.bot ?? false,
            // Flattened here, once, rather than per row per frame. A quoted
            // body is one line in the header, so its markdown is folded away
            // and its newlines with it — a header that wrapped would push the
            // message it belongs to down the page.
            // A voice message has no words to quote and says so, rather than asking for
            // a click to see an attachment.
            excerpt: MessageFlags(rawValue: quoted?.flags ?? 0).contains(.isVoiceMessage)
                ? MessageReference.voiceMessageExcerpt
                : MessageReference.excerpt(of: quoted?.content ?? ""),
            hasAttachment: !(quoted?.attachments?.isEmpty ?? true)
                || !(quoted?.sticker_items?.isEmpty ?? true),
            isDeleted: referenced_message?.isDeleted == true
        )
    }

    /// The invitation card's inputs, or nil for every message that is not one.
    ///
    /// **Gated on `activity_instance`, not on the message type.** A `type: 23`
    /// is a context-menu command — an app's reply to somebody right-clicking a
    /// message — and the overwhelming majority of them are not activities. The
    /// instance is the thing that says a launch happened, and the card cannot
    /// draw without it anyway.
    private var activityInvite: ActivityInvite? {
        guard let activity_instance, let application,
              let applicationID = application.id,
              let name = application.name, !name.isEmpty
        else { return nil }
        return ActivityInvite(
            applicationID: applicationID,
            name: name,
            iconHash: application.icon,
            instanceID: activity_instance.id
        )
    }

    /// Who ran the command this message answers.
    private var messageInteraction: MessageInteraction? {
        guard let source = interaction_metadata ?? interaction,
              let name = source.name, !name.isEmpty,
              let userID = source.user?.id
        else { return nil }
        return MessageInteraction(
            userID: userID,
            name: name,
            commandType: source.command_type ?? 1
        )
    }

    private var forwardedMessage: ForwardedMessage? {
        guard let body = message_snapshots?.first?.message else { return nil }
        return ForwardedMessage(
            content: body.content ?? "",
            attachments: body.attachments?.map(\.domain) ?? [],
            embeds: body.embeds?.map(\.domain) ?? [],
            stickers: body.sticker_items?.map(\.domain) ?? [],
            channelID: message_reference?.channel_id,
            guildID: message_reference?.guild_id,
            messageID: message_reference?.message_id,
            timestamp: body.timestamp
        )
    }


}

struct PresenceDTO: Decodable, Sendable {
    var user: PartialUser?
    /// The same dedupe the member objects get — see `MemberDTO.user_id`. A
    /// presence out of `merged_presences` names its person here and nowhere
    /// else.
    var user_id: UserID?
    var status: String?
    var activities: [ActivityDTO]?
    var client_status: ClientStatus?

    struct PartialUser: Decodable, Sendable { var id: UserID }

    struct ClientStatus: Decodable, Sendable {
        var desktop: String?
        var mobile: String?
        var web: String?
        var vr: String?
    }

    var domain: Presence? {
        guard let userID = user?.id ?? user_id else { return nil }
        let list = activities?.compactMap(\.domain) ?? []
        return Presence(
            userID: userID,
            status: PresenceStatus(rawValue: status ?? "offline") ?? .offline,
            // Discord's own two tests (`isMobileOnline`, `isVROnline`): online
            // on the phone and not online at a desk or in a headset — someone
            // at their desk with a phone in their pocket is at their desk. The
            // browser is not asked about, there as here.
            isOnMobile: client_status?.mobile == "online"
                && client_status?.desktop != "online"
                && client_status?.vr != "online",
            isOnVR: client_status?.vr == "online",
            activities: list.isEmpty ? nil : PresenceActivities(list: list)
        )
    }
}

struct ActivityDTO: Decodable, Sendable {
    var name: String?
    var type: Int?
    var state: String?
    var details: String?
    var application_id: ApplicationID?
    var assets: Assets?
    var emoji: EmojiDTO?
    var timestamps: Timestamps?
    var party: PartyDTO?
    /// **The half of a button that arrives over the gateway.** The URLs are a
    /// separate route — see `DiscordREST.activityMetadata` — and a client with
    /// only this array can name a button and not open it.
    var buttons: [String]?
    /// The other half of that route's address. Nullable on the wire and absent
    /// for most activities; an activity without one has no reachable metadata
    /// at all, so its buttons are not drawn.
    var session_id: String?
    var sync_id: String?
    /// Milliseconds. The last key of Discord's order — `ActivityOrder`.
    var created_at: Double?
    /// `EMBEDDED` (256) is the one bit anything here reads.
    var flags: Int?
    /// Which line a one-line summary names the activity by.
    var status_display_type: Int?
    /// Join and spectate secrets. **Only whether they are there is read**, so
    /// the value is never looked into — a shape nobody decodes cannot throw.
    var secrets: Opaque?
    /// `"xbox"`, `"ps5"`, `"desktop"` — where it is running.
    var platform: String?
    /// Where the details and state lines link to.
    var details_url: String?
    var state_url: String?
    /// A streaming activity's stream — Watch Stream's address.
    var url: String?

    /// Any JSON value, accepted and discarded.
    struct Opaque: Decodable, Sendable {
        init(from decoder: any Decoder) throws {}
    }

    /// `size` is `[current, maximum]`. The id is carried but not read: apps
    /// spell it however they like — Watch Together sends the instance reversed
    /// and comma-joined — so it is not a key this client can match on.
    struct PartyDTO: Decodable, Sendable {
        var id: String?
        var size: [Int]?
    }

    struct Assets: Decodable, Sendable {
        var large_image: String?
        var large_text: String?
        var large_url: String?
        var small_image: String?
        var small_text: String?
        var small_url: String?
    }

    struct Timestamps: Decodable, Sendable {
        var start: Double?
        var end: Double?
    }

    var domain: Activity? {
        guard let name else { return nil }
        return Activity(
            kind: Activity.Kind(rawValue: type ?? 0),
            name: name,
            state: state,
            details: details,
            applicationID: application_id,
            largeImageKey: assets?.large_image,
            smallImageKey: assets?.small_image,
            largeText: assets?.large_text,
            smallText: assets?.small_text,
            largeImageURL: assets?.large_url.flatMap(URL.init(string:)),
            smallImageURL: assets?.small_url.flatMap(URL.init(string:)),
            emoji: emoji?.domain,
            // Discord sends milliseconds; a client that reads them as seconds
            // dates every activity to 1970 and every "elapsed" reads as decades.
            startedAt: timestamps?.start.map { Date(timeIntervalSince1970: $0 / 1000) },
            endsAt: timestamps?.end.map { Date(timeIntervalSince1970: $0 / 1000) },
            partySize: party?.size.map { Array($0.prefix(2)) },
            sessionID: session_id,
            // At most two: the wire caps it there and a third would be a row
            // this layout has no room for.
            buttons: Array((buttons ?? []).prefix(2)),
            createdAt: created_at.map { Date(timeIntervalSince1970: $0 / 1000) },
            isEmbedded: (flags ?? 0) & 256 != 0,
            statusDisplay: status_display_type.flatMap(Activity.StatusDisplay.init(rawValue:)),
            partyID: party?.id,
            hasSecrets: secrets != nil,
            platform: platform,
            detailsURL: details_url.flatMap(URL.init(string:)),
            stateURL: state_url.flatMap(URL.init(string:)),
            syncID: sync_id,
            offersPlay: (flags ?? 0) & Activity.playFlag != 0,
            offersSync: (flags ?? 0) & Activity.syncFlag != 0,
            url: url.flatMap(URL.init(string:))
        )
    }
}

struct ReadStateDTO: Decodable, Sendable {
    var id: ChannelID
    var last_message_id: MessageID?
    var mention_count: Int?
    /// `0` or absent for a channel. **The rest are not channels** — `1` a
    /// server's scheduled events, `2` the notification centre, `3` the server
    /// home, `4` an onboarding question, `5` message requests — and their `id`
    /// is a SERVER's or the account's, which a server's oldest channel can
    /// share. Read into the channel table, one overwrote that channel's cursor.
    var read_state_type: Int?
    /// A non-channel state's cursor, where a channel's is `last_message_id`.
    var last_acked_id: MessageID?
}

struct ClientSettingsDTO: Decodable, Sendable {
    var guild_folders: [FolderDTO]?
    var status: String?
    var custom_status: CustomStatus?

    struct FolderDTO: Decodable, Sendable {
        var id: UInt64?
        var name: String?
        var color: UInt32?
        var guild_ids: [GuildID]?
    }

    struct CustomStatus: Decodable, Sendable {
        var text: String?
    }

    var domain: ClientSettings {
        ClientSettings(
            folders: guild_folders?.map {
                GuildFolder(
                    id: $0.id,
                    name: $0.name,
                    colorValue: $0.color,
                    guildIDs: $0.guild_ids ?? []
                )
            } ?? [],
            status: PresenceStatus(rawValue: status ?? "online") ?? .online,
            // The JSON branch, which Discord has stopped sending — it carries
            // the text and nothing else, where the proto carries all three.
            customStatus: custom_status?.text.map { WingcordCore.CustomStatus(text: $0) }
        )
    }
}

/// The settings' `guild_folders` message: the rail's arrangement, and the
/// stale order it carries beside it.
public struct GuildFolderSettings: Sendable, Equatable {
    public var folders: [GuildFolder]
    public var guildPositions: [GuildID]

    public init(folders: [GuildFolder], guildPositions: [GuildID]) {
        self.folders = folders
        self.guildPositions = guildPositions
    }
}

/// The account's own client settings, as the app uses them.
public struct ClientSettings: Sendable {
    /// The account's favourite GIFs, from the settings proto. Empty for an
    /// account with none, and empty for a blob this client could not read —
    /// see `UserSettingsProto.FavoritesField`.
    public var folders: [GuildFolder]
    /// The rail's order from before the folder list held every server.
    ///
    /// **Only an order when the folder list is empty** — Discord's own rule,
    /// see `GuildArrangement.resolve`. Once anything has been rearranged the
    /// folder list names every server (loose ones as entries without an id)
    /// and this goes stale; it is still sent back untouched on every folder
    /// write, which is the only reason it is kept.
    public var guildPositions: [GuildID] = []
    public var status: PresenceStatus
    /// What the reader wrote about themselves, with its emoji and its expiry.
    public var customStatus: CustomStatus?
    /// Which inbox tab the account had open last, across every client.
    ///
    /// Defaults to `.fallback` rather than being optional: an account that has
    /// never opened the inbox has no stored tab, and "none" and "Unreads" are
    /// the same answer to the only question anybody asks of this.
    public var inboxTab: InboxTab = .fallback

    /// Where the account shares what it is playing. See `ActivityPrivacy`.
    public var activityPrivacy = ActivityPrivacy()

    /// The `privacy` and `status` sub-messages, **exactly as they arrived**.
    ///
    /// Kept so a write can change one field and re-emit every other byte
    /// untouched — the argument is in `ActivityPrivacyProto.replacing`, and it
    /// is the difference between a settings write and a settings loss. Nil for
    /// an account whose blob carried neither, which is an account that has
    /// never opened the pane.
    public var privacyRaw: Data?
    public var statusRaw: Data?
    /// Whose theme a themed server is drawn in. See `GuildThemeSource`.
    public var serverThemes = ServerThemePreferences()
    /// The unread groups folded in the inbox. See `InboxCollapse`.
    public var inboxCollapse = InboxCollapse()
    /// Split view for threads, and the ignored-profile warning. See
    /// `SyncedPreferences`.
    public var preferences = SyncedPreferences()
    /// Each person's volume and mute, for their voice and their stream. See
    /// `AudioContextSettings`.
    public var audioContext = AudioContextSettings()

    public init(
        folders: [GuildFolder],
        guildPositions: [GuildID] = [],
        status: PresenceStatus,
        customStatus: CustomStatus?,
        inboxTab: InboxTab = .fallback,
        activityPrivacy: ActivityPrivacy = ActivityPrivacy(),
        privacyRaw: Data? = nil,
        statusRaw: Data? = nil,
        serverThemes: ServerThemePreferences = ServerThemePreferences(),
        inboxCollapse: InboxCollapse = InboxCollapse(),
        preferences: SyncedPreferences = SyncedPreferences(),
        audioContext: AudioContextSettings = AudioContextSettings()
    ) {
        self.folders = folders
        self.guildPositions = guildPositions
        self.status = status
        self.customStatus = customStatus
        self.inboxTab = inboxTab
        self.activityPrivacy = activityPrivacy
        self.privacyRaw = privacyRaw
        self.statusRaw = statusRaw
        self.serverThemes = serverThemes
        self.inboxCollapse = inboxCollapse
        self.preferences = preferences
        self.audioContext = audioContext
    }
}

// MARK: - Profile

/// `GET /users/{id}/profile`.
///
/// **The route exists because nothing else answers with a banner, a bio or a
/// theme.** The user objects READY and the member-list op deliver are the
/// *minimal* form — id, name, avatar, flags — and every profile surface built on
/// them draws a person with no banner, no colours and no words, which is exactly
/// what this client was doing. Those three fields are only ever sent here.
///
/// It answers in layers, and the layering is the point: `user` is the account,
/// `user_profile` is the account's profile, and `guild_member_profile` is the
/// per-guild override. Discord lets someone carry a different banner and bio in
/// one server than they do globally, so the guild layer wins where it is
/// present — and it is *often* present and empty, which is not the same as
/// absent and must not overwrite the global answer.
struct UserProfileDTO: Decodable, Sendable {
    var user: UserDTO
    var user_profile: ProfileLayer?
    var guild_member_profile: ProfileLayer?
    var badges: [BadgeDTO]?
    var mutual_guilds: [MutualGuildDTO]?
    /// Whole user objects, which is what makes the row drawable without a
    /// second request — the reader is very often in none of the servers these
    /// people are in, so the store has never heard of them.
    var mutual_friends: [UserDTO]?
    var premium_since: String?
    var premium_type: Int?
    var legacy_username: String?
    var connected_accounts: [ConnectionDTO]?
    /// Whether the account has turned its profile private.
    ///
    /// **A label, not a filter.** The same response still carries the mutual
    /// servers the reader can see for themselves, so a client that used this to
    /// hide them would be inventing a restriction the server did not make.
    var `private`: Bool?
    /// The profile board.
    ///
    /// **The one route that answers with it, and it arrives unasked.** There is
    /// no `GET /users/{id}/widgets`; the tiles come down beside the banner and
    /// the bio, in a key this client ignored until the board was built.
    var widgets: [ProfileWidgetDTO]?
    /// An app's own facts, beside a bot — see `ProfileApplicationDTO`.
    var application: ProfileApplicationDTO?

    struct ConnectionDTO: Decodable, Sendable {
        var id: String?
        var type: String?
        var name: String?
        var verified: Bool?
        /// **Almost every value is a string on the wire, and "almost" cost a
        /// whole profile.** Steam sends `"game_count": "16"`, Reddit
        /// `"total_karma": "20223"` and PayPal `"verified": "0"` — and TikTok
        /// sends `"verified": false`, a JSON boolean. Typed `[String: String]`
        /// this bag threw, and because it is decoded as part of the profile
        /// response the throw took **the entire profile** with it: the account's
        /// badges, bio, pronouns, premium tier, connections and theme colours
        /// all vanished, leaving a card drawn from the gateway's user object
        /// alone. One bool in one service's metadata, and the symptom was "the
        /// mini profile shows one badge".
        ///
        /// So it is decoded as *whatever scalar arrived*, rendered to the string
        /// form the rest of the wire uses — a boolean as `"1"` or `"0"`, which
        /// is exactly how PayPal and Twitter send the same field.
        /// `ConnectionFact` is what reads them and needs no change.
        var metadata: [String: MetadataValue]?

        var domain: ConnectedAccount? {
            guard let id, let type, let name else { return nil }
            return ConnectedAccount(
                id: id,
                service: type,
                name: name,
                isVerified: verified ?? false,
                metadata: metadata?.compactMapValues(\.rendered) ?? [:]
            )
        }
    }

    /// One value out of a connection's metadata bag.
    ///
    /// **A tolerant scalar, and a decoder that cannot throw.** The bag is
    /// free-form: Discord adds a key whenever a service starts reporting
    /// something, and the type of a key it already sends can change under you —
    /// which is what happened to `verified`. Anything unrecognised decodes to
    /// nothing and is dropped from the dictionary rather than failing the
    /// response it arrived in.
    enum MetadataValue: Decodable, Sendable {
        case text(String)
        case number(Double)
        case flag(Bool)
        case null

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() {
                self = .null
            } else if let text = try? value.decode(String.self) {
                self = .text(text)
            } else if let flag = try? value.decode(Bool.self) {
                self = .flag(flag)
            } else if let number = try? value.decode(Double.self) {
                self = .number(number)
            } else {
                self = .null
            }
        }

        /// The string form the rest of this bag is written in, or nil for a
        /// value there is nothing to render.
        var rendered: String? {
            switch self {
            case .text(let text): text
            // `"1"` and `"0"`, because that is how the services that send this
            // field as a string send it — so a flag reads the same whichever
            // type it arrived as.
            case .flag(let flag): flag ? "1" : "0"
            case .number(let number):
                number == number.rounded() && abs(number) < 1e15
                    ? String(Int64(number))
                    : String(number)
            case .null: nil
            }
        }
    }

    struct ProfileLayer: Decodable, Sendable {
        var banner: String?
        var accent_color: UInt32?
        var bio: String?
        /// Two 24-bit colours, primary first. Discord sends `[a, b]`.
        var theme_colors: [UInt32]?
        var pronouns: String?
        /// A purchase, not an asset: `{ sku_id, expires_at }`.
        var profile_effect: EffectRef?
        /// **Every** collectible worn on this layer, by type. The one field
        /// that names a profile frame — `profile_effect` above describes only
        /// the effect, so a client reading that alone never learns a frame is
        /// being worn at all.
        var collectibles: [CollectibleRef]?
    }

    struct EffectRef: Decodable, Sendable {
        var sku_id: String?
    }

    /// One worn collectible: which product, and which kind it is.
    ///
    /// Discord's type enum: `0` avatar decoration, `1` profile effect, `2`
    /// nameplate, `3` profile frame. Only the frame is *drawn* from here — the
    /// other three arrive by routes this client already has, and taking the
    /// effect from both places would be two answers that can disagree. The
    /// whole list is kept as well, for the save (`wornCollectibles`).
    struct CollectibleRef: Decodable, Sendable {
        var sku_id: String?
        var type: Int?

        static let profileFrame = 3
    }

    struct BadgeDTO: Decodable, Sendable {
        var id: String?
        var description: String?
        var icon: String?

        var domain: AccountBadge? {
            guard let id else { return nil }
            return AccountBadge(
                id: id,
                iconHash: icon,
                // The description is the hover text, so a badge that arrives
                // without one falls back to its id rather than to nothing —
                // an unlabelled badge is an icon nobody can identify.
                label: description ?? id
            )
        }
    }

    struct MutualGuildDTO: Decodable, Sendable {
        var id: GuildID?
        var nick: String?

        /// Dropped without an id: a mutual server nobody can name is not a fact
        /// the profile can show, and counting it would leave the card claiming
        /// one more server than the list it opens holds.
        var domain: MutualGuild? {
            guard let id else { return nil }
            return MutualGuild(id: id, nickname: nick.flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    /// Discord's ISO-8601 with fractional seconds. Parsed with a formatter that
    /// accepts them: the default `.iso8601` strategy rejects `.878000+00:00` and
    /// would silently yield nil for every subscription date.
    private static func date(from string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    /// The account's own profile — `user` with `user_profile` folded on, and
    /// **without** the per-guild layer.
    ///
    /// **The guild layer is kept apart rather than merged in, and that is the
    /// whole of per-server profiles.** This used to fold both together and hand
    /// back one `User`, which meant the account's own banner, bio, colours and
    /// effect were destroyed the moment a guild override existed — so "View
    /// Main Profile" had nothing left to show. Two layers arrive; two are kept.
    var domain: User { decoration(withGuildLayer: false) }

    /// The same account as it presents itself **in this server**, or nil when
    /// the response carried no guild layer at all.
    ///
    /// Still merged field by field, because `guild_member_profile` is *often
    /// present and empty* — which is not the same as absent and must not blank
    /// a global banner.
    var guildDomain: User? {
        guard guild_member_profile != nil else { return nil }
        return decoration(withGuildLayer: true)
    }

    private func decoration(withGuildLayer: Bool) -> User {
        let base = user.domain
        func pick<T>(_ path: (ProfileLayer) -> T?) -> T? {
            if withGuildLayer, let value = guild_member_profile.flatMap(path) { return value }
            return user_profile.flatMap(path)
        }
        /// A text field, where **empty is the server saying nothing**: Discord
        /// sends `"pronouns": ""` on the server's layer for a member who set
        /// none there, and its client shows the account's through
        /// (`isUsingGuildMemberPronouns`: not null and not `""`; the bio's rule
        /// is the same). Taken as the server's answer, the empty string hid the
        /// account's pronouns on every server profile.
        func pickText(_ path: (ProfileLayer) -> String?) -> String? {
            if withGuildLayer, let value = guild_member_profile.flatMap(path), !value.isEmpty { return value }
            return user_profile.flatMap(path).flatMap { $0.isEmpty ? nil : $0 }
        }
        let bio = pickText(\.bio)
        let theme = pick(\.theme_colors).flatMap { $0.isEmpty ? nil : $0 }
        let effectSKU: String? = pick { $0.profile_effect?.sku_id }
        // **Hoisted out of the initialiser, and not for tidiness.** This call
        // is already one the type-checker gives up on when it grows — see
        // `docs/HANDOFF.md` — and a closure argument inside it is exactly the
        // kind of growth that tips it over.
        let frameSKU: String? = pick { layer in
            layer.collectibles?
                .first { $0.type == CollectibleRef.profileFrame }?
                .sku_id
        }
        // **This layer's own list, with no fallback** — a server's save sends
        // the server's list back, never the account's. See
        // `UserDecoration.wornCollectibles`.
        let ownLayer = withGuildLayer ? guild_member_profile : user_profile
        let worn: [WornCollectible]? = ownLayer?.collectibles?.compactMap { entry in
            guard let sku = entry.sku_id, let type = entry.type else { return nil }
            return WornCollectible(skuID: sku, type: type)
        }

        let decoration = UserDecoration(
            avatarDecorationHash: base.decoration?.avatarDecorationHash,
            avatarDecorationSKU: base.decoration?.avatarDecorationSKU,
            nameplate: base.decoration?.nameplate,
            // Off the nested user object, like the nameplate above — **this
            // route is assigned WHOLE rather than merged**, so a cosmetic it
            // does not carry forward is a cosmetic that disappears the moment
            // the profile finishes loading, in front of the reader.
            displayNameStyle: base.decoration?.displayNameStyle,
            bannerHash: pick(\.banner) ?? base.decoration?.bannerHash,
            accentColor: pick(\.accent_color) ?? base.decoration?.accentColor,
            bio: bio ?? base.decoration?.bio,
            themeColorValues: theme,
            badges: badges?.compactMap(\.domain) ?? [],
            // Sent, even as `[]`, means Discord has said which badges show.
            badgesFromProfile: badges != nil,
            profileEffectSKU: effectSKU,
            profileFrameSKU: frameSKU,
            wornCollectibles: worn,
            pronouns: pickText(\.pronouns),
            connectedAccounts: connected_accounts?.compactMap(\.domain) ?? [],
            premiumTier: premium_type.flatMap { PremiumTier(rawValue: $0) } ?? .none,
            premiumSince: premium_since.flatMap(Self.date(from:)),
            legacyUsername: legacy_username,
            mutualGuilds: mutual_guilds?.compactMap(\.domain) ?? [],
            mutualFriends: mutual_friends?.map(\.mutualFriend) ?? [],
            isProfilePrivate: `private` ?? false,
            primaryGuildTag: base.decoration?.primaryGuildTag,
            primaryGuildBadgeHash: base.decoration?.primaryGuildBadgeHash,
            primaryGuildID: base.decoration?.primaryGuildID,
            application: application?.domain
        )
        return User(
            id: base.id,
            username: base.username,
            displayName: base.displayName,
            avatarHash: base.avatarHash,
            discriminator: base.discriminator,
            flags: base.flags,
            isBot: base.isBot,
            isSystem: base.isSystem,
            decoration: decoration.isEmpty ? nil : decoration
        )
    }
}

/// The `application` a bot's profile carries — the fields Discord's profile
/// store keeps (`id`, `flags`, `custom_install_url`, `install_params`,
/// `integration_types_config`, `storefront_available` and the two policy
/// links).
///
/// **Decoded field by field, and it cannot throw.** It rides inside the whole
/// profile, and a free-form object typed strictly is how one unexpected value
/// once took a profile's badges, bio and theme with it.
struct ProfileApplicationDTO: Decodable, Sendable {
    var id: ApplicationID?
    var flags: UInt64?
    var custom_install_url: String?
    var install_params: InstallDTO.ApplicationDTO.ParamsDTO?
    var integration_types_config: [String: InstallDTO.ApplicationDTO.ConfigDTO]?
    var storefront_available: Bool?
    var terms_of_service_url: String?
    var privacy_policy_url: String?

    private enum Keys: String, CodingKey {
        case id, flags, custom_install_url, install_params, integration_types_config
        case storefront_available, terms_of_service_url, privacy_policy_url
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: Keys.self) else { return }
        id = try? container.decodeIfPresent(ApplicationID.self, forKey: .id)
        flags = try? container.decodeIfPresent(UInt64.self, forKey: .flags)
        custom_install_url = try? container.decodeIfPresent(String.self, forKey: .custom_install_url)
        install_params = try? container.decodeIfPresent(InstallDTO.ApplicationDTO.ParamsDTO.self, forKey: .install_params)
        integration_types_config = try? container.decodeIfPresent(
            [String: InstallDTO.ApplicationDTO.ConfigDTO].self, forKey: .integration_types_config
        )
        storefront_available = try? container.decodeIfPresent(Bool.self, forKey: .storefront_available)
        terms_of_service_url = try? container.decodeIfPresent(String.self, forKey: .terms_of_service_url)
        privacy_policy_url = try? container.decodeIfPresent(String.self, forKey: .privacy_policy_url)
    }

    var domain: ProfileApplication? {
        guard let id else { return nil }
        return ProfileApplication(
            id: id,
            flags: flags ?? 0,
            customInstallURL: custom_install_url.flatMap(URL.init(string:)),
            // Discord's `Ie`: `install_params`, or any integration type that
            // carries `oauth2_install_params`.
            declaresInstall: install_params != nil
                || (integration_types_config?.values.contains { $0.oauth2_install_params != nil } ?? false),
            hasStorefront: storefront_available ?? false,
            termsOfServiceURL: terms_of_service_url.flatMap(URL.init(string:)),
            privacyPolicyURL: privacy_policy_url.flatMap(URL.init(string:))
        )
    }
}

// MARK: - Collectibles

/// `GET /collectibles-products/{sku_id}`.
///
/// How a worn collectible's `sku_id` becomes artwork. Captured from two live
/// responses — one profile effect, one profile frame — and they are different
/// shapes under one route, which is why `domain` answers a `Collectible` rather
/// than an effect.
///
/// Two things about the payload are worth writing down because a decoder gets
/// them silently wrong. The effect timings are in **milliseconds**. And the
/// keys are **camelCase inside an otherwise snake_case API** — but only on the
/// effect side: a frame's `inner_width` and `overflow_top` are snake_case in
/// the same object as the effect's `reducedMotionSrc`, so there is no single
/// convention to assume and each field is spelled as captured.
struct CollectiblesProductDTO: Decodable, Sendable {
    var sku_id: String?
    var name: String?
    var items: [Item]?

    struct Item: Decodable, Sendable {
        var sku_id: String?
        var title: String?
        var accessibilityLabel: String?
        var reducedMotionSrc: String?
        var staticFrameSrc: String?
        /// Profile effect: the animated timeline.
        var effects: [Effect]?

        // A profile frame instead describes pieces anchored to a card's edges,
        // and every number below is in ONE authored coordinate space — the one
        // its layer artwork is drawn in. Verified against Dark Roses: the
        // payload says `inner_width: 1200` and `overflow_horizontal: 56`, and
        // both of its layer PNGs are exactly 1312 pixels wide.
        var label: String?
        var layers: [FrameLayer]?
        var inner_width: Double?
        var overflow_top: Double?
        var overflow_bottom: Double?
        var overflow_horizontal: Double?
    }

    struct Effect: Decodable, Sendable {
        var src: String?
        /// Milliseconds, all three.
        var start: Double?
        var duration: Double?
        var loopDelay: Double?
        var loop: Bool?
        var zIndex: Int?
        var width: Double?
        var height: Double?
        // `position: {x, y}` is sent and is deliberately NOT read. Every
        // capture so far is `{0, 0}`, so nothing here can say whether it is
        // authored pixels or a fraction — and a decoder that guesses at a unit
        // does not fail, it yields plausible nonsense. See `docs/HANDOFF.md`.
    }

    /// One piece of a frame.
    ///
    /// **No `src`.** The payload names layers by id only; the artwork is at
    /// `CDN.profileFrameLayer(sku:layerID:)`, under the *product's* SKU. That
    /// is the whole of how a frame becomes pictures, and it is not derivable
    /// from any other collectible's path.
    ///
    /// `type` says how the piece is drawn — `staple`, `rail` or `border` — and
    /// `responsive` hides a rail on a short card. Fantasy Galaxy sends a
    /// responsive rail; drawn as the staple it was taken for, its 1312 × 2528
    /// artwork was fitted into the card and pulled its side clouds inward.
    struct FrameLayer: Decodable, Sendable {
        var id: String?
        var type: String?
        var order: String?
        var anchor: String?
        var responsive: Bool?
    }

    /// The product, as whichever kind of collectible it turned out to be.
    ///
    /// **Decided by SHAPE, not by the type integer.** The integer is present
    /// and correct today, but a payload whose kind this client does not
    /// recognise is still drawable when its shape is one of the two known
    /// ones — whereas a switch on the integer turns every future type into
    /// nothing at all.
    var domain: Collectible? {
        guard let item = items?.first, let sku = sku_id ?? item.sku_id else { return nil }
        if let frame = item.frame(sku: sku) { return .frame(frame) }
        if let effect = item.effect(sku: sku, productName: name) { return .effect(effect) }
        return nil
    }
}

extension CollectiblesProductDTO.Item {
    func effect(sku: String, productName: String?) -> ProfileEffect? {
        let layers: [ProfileEffect.Layer] = (effects ?? []).compactMap { effect in
            guard let source = effect.src, let url = URL(string: source) else { return nil }
            return ProfileEffect.Layer(
                url: url,
                // Discord sends milliseconds; read as seconds they would each
                // last most of an hour.
                start: (effect.start ?? 0) / 1000,
                duration: (effect.duration ?? 0) / 1000,
                loops: effect.loop ?? false,
                loopDelay: (effect.loopDelay ?? 0) / 1000,
                zIndex: effect.zIndex ?? 0,
                size: CGSize(width: effect.width ?? 450, height: effect.height ?? 880)
            )
        }
        guard !layers.isEmpty else { return nil }
        return ProfileEffect(
            skuID: sku,
            title: title ?? productName ?? "",
            accessibilityLabel: accessibilityLabel,
            reducedMotionURL: (reducedMotionSrc ?? staticFrameSrc).flatMap { URL(string: $0) },
            layers: layers
        )
    }

    func frame(sku: String) -> ProfileFrame? {
        let pieces: [ProfileFrame.Layer] = (layers ?? []).compactMap { layer in
            guard let id = layer.id,
                  let url = CDN.profileFrameLayer(sku: sku, layerID: id),
                  // A kind Discord itself draws nothing for (module `744808`)
                  // is skipped; a missing one is the staple every early
                  // capture was.
                  let kind = layer.type.map(ProfileFrame.Kind.init(rawValue:)) ?? .staple
            else { return nil }
            return ProfileFrame.Layer(
                id: id,
                url: url,
                kind: kind,
                // An unrecognised anchor or order costs one misplaced picture,
                // never the frame: `.top` and `.front` are what nearly every
                // captured layer says, and they are the safe reading of a value
                // this client has not seen before.
                anchor: layer.anchor.flatMap(ProfileFrame.Anchor.init(rawValue:)) ?? .top,
                order: layer.order.flatMap(ProfileFrame.Order.init(rawValue:)) ?? .front,
                isResponsive: layer.responsive ?? false
            )
        }
        guard !pieces.isEmpty, let inner = inner_width, inner > 0 else { return nil }
        return ProfileFrame(
            skuID: sku,
            label: label ?? accessibilityLabel,
            innerWidth: inner,
            overflowTop: overflow_top ?? 0,
            overflowBottom: overflow_bottom ?? 0,
            overflowHorizontal: overflow_horizontal ?? 0,
            layers: pieces
        )
    }
}

// MARK: - Guild profiles
//
// `GET /guilds/{id}/profile`. The route behind a server tag: what the letters
// beside somebody's name stand for.

struct GuildProfileDTO: Decodable, Sendable {
    var id: GuildID
    var name: String?
    var icon_hash: String?
    var banner_hash: String?
    /// The tag profile's own header artwork. Most servers carrying a tag have
    /// this and no `banner_hash` at all.
    var custom_banner_hash: String?
    var description: String?
    var member_count: Int?
    var online_count: Int?
    var tag: String?
    var badge_hash: String?
    /// `#rrggbb`, which is the one place in this API a colour is a string.
    var badge_color_primary: String?
    var badge_color_secondary: String?
    var traits: [TraitDTO]?
    var features: [String]?
    var premium_subscription_count: Int?
    var premium_tier: Int?
    /// The **Banner** swatch grid, despite the name. See
    /// `GuildProfile.brandColorPrimary`.
    var brand_color_primary: String?
    var visibility: Int?
    var badge: Int?
    var game_application_ids: [ApplicationID]?
    /// Keyed by the application's id **as a string**, which is how every map on
    /// this wire is keyed — a snowflake does not survive a JSON number.
    var game_activity: [String: GameActivityDTO]?

    struct GameActivityDTO: Decodable, Sendable {
        var activity_level: Int?
        var activity_score: Int?
    }

    struct TraitDTO: Decodable, Sendable {
        var emoji_id: EmojiID?
        var emoji_name: String?
        var emoji_animated: Bool?
        var label: String?
        var position: Int?

        /// Dropped without a label. The emoji is decoration; the word is the
        /// trait, and a chip holding only a picture says nothing.
        func domain(fallbackPosition: Int) -> GuildTrait? {
            guard let label, !label.isEmpty else { return nil }
            return GuildTrait(
                id: position ?? fallbackPosition,
                emojiID: emoji_id,
                emojiName: emoji_name,
                emojiAnimated: emoji_animated ?? false,
                label: label
            )
        }
    }

    var domain: GuildProfile {
        var traitList: [GuildTrait] = []
        for (index, trait) in (traits ?? []).enumerated() {
            guard let value = trait.domain(fallbackPosition: index) else { continue }
            traitList.append(value)
        }
        traitList.sort { $0.id < $1.id }

        return GuildProfile(
            id: id,
            name: name ?? "Unknown",
            iconHash: icon_hash,
            // **The two are NOT interchangeable, and folding them was a
            // bug.** `custom_banner_hash` is a discovery splash, a different
            // asset family — measured, see `GuildBannerArt.artworkURL` in the
            // app. Folded, every tagged server asked the banner path for a
            // picture that 404s.
            bannerHash: banner_hash,
            description: description.flatMap { $0.isEmpty ? nil : $0 },
            memberCount: member_count,
            onlineCount: online_count,
            tag: tag.flatMap { $0.isEmpty ? nil : $0 },
            badgeHash: badge_hash,
            badgeColorPrimary: Self.color(badge_color_primary),
            badgeColorSecondary: Self.color(badge_color_secondary),
            traits: traitList,
            features: Set(features ?? []),
            premiumSubscriptionCount: premium_subscription_count ?? 0,
            premiumTier: premium_tier ?? 0,
            brandColorPrimary: Self.color(brand_color_primary),
            visibility: visibility ?? 1,
            badge: badge ?? 0,
            customBannerHash: custom_banner_hash,
            gameApplicationIDs: game_application_ids ?? [],
            gameActivity: (game_activity ?? [:]).reduce(into: [:]) { table, entry in
                guard let id = UInt64(entry.key) else { return }
                table[ApplicationID(rawValue: id)] = GuildGameActivity(
                    level: entry.value.activity_level ?? 0,
                    score: entry.value.activity_score ?? 0
                )
            }
        )
    }

    /// `#2be12b` to `0x2BE12B`.
    ///
    /// Nil rather than black on anything unexpected: the badge falls back to the
    /// standing's own colour, and a silent zero would paint every unparsed
    /// badge as a black rosette.
    private static func color(_ text: String?) -> UInt32? {
        guard var text, !text.isEmpty else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 else { return nil }
        return UInt32(text, radix: 16)
    }
}


// MARK: - Message components
//
// Discord's component tree, read down to the two shapes a reading client can
// draw: the action row and the button. Everything past those is skipped rather
// than failed — the tree grows, and a decoder that throws on an unknown type
// throws away the whole message page.

struct ComponentDTO: Decodable, Sendable {
    /// Hand-written so the one recursive key can be boxed.
    ///
    /// Everything else is the synthesised behaviour; only `accessory` differs,
    /// because Discord sends it as a single object and the property has to be an
    /// array for the type to have a layout at all.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(Int.self, forKey: .type)
        style = try container.decodeIfPresent(Int.self, forKey: .style)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        custom_id = try container.decodeIfPresent(String.self, forKey: .custom_id)
        disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled)
        placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder)
        emoji = try container.decodeIfPresent(EmojiDTO.self, forKey: .emoji)
        components = try container.decodeIfPresent([ComponentDTO].self, forKey: .components)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        accent_color = try container.decodeIfPresent(UInt32.self, forKey: .accent_color)
        divider = try container.decodeIfPresent(Bool.self, forKey: .divider)
        spacing = try container.decodeIfPresent(Int.self, forKey: .spacing)
        items = try container.decodeIfPresent([MediaItemDTO].self, forKey: .items)
        media = try container.decodeIfPresent(MediaSourceDTO.self, forKey: .media)
        accessory = try container.decodeIfPresent(ComponentDTO.self, forKey: .accessory).map { [$0] }
        options = try container.decodeIfPresent([SelectOptionDTO].self, forKey: .options)
        min_values = try container.decodeIfPresent(Int.self, forKey: .min_values)
        max_values = try container.decodeIfPresent(Int.self, forKey: .max_values)
        min_length = try container.decodeIfPresent(Int.self, forKey: .min_length)
        max_length = try container.decodeIfPresent(Int.self, forKey: .max_length)
        required = try container.decodeIfPresent(Bool.self, forKey: .required)
        value = try container.decodeIfPresent(String.self, forKey: .value)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        `default` = try container.decodeIfPresent(Bool.self, forKey: .default)
        component = try container.decodeIfPresent(ComponentDTO.self, forKey: .component).map { [$0] }
        // Lenient: an entry in a shape this client can't read costs the card,
        // never the message.
        content_inventory_entry = try? container.decodeIfPresent(ContentEntryDTO.self, forKey: .content_inventory_entry)
    }

    private enum CodingKeys: String, CodingKey {
        case type, style, label, url, custom_id, disabled, placeholder, emoji
        case components, content, accent_color, divider, spacing, items, media, accessory
        case options, min_values, max_values
        case min_length, max_length, required, value, description, `default`, component
        case content_inventory_entry
    }

    var type: Int?
    var style: Int?
    var label: String?
    var url: String?
    var custom_id: String?
    var disabled: Bool?
    var placeholder: String?
    var emoji: EmojiDTO?
    var components: [ComponentDTO]?
    // Components V2 carries its content on the node itself.
    var content: String?
    var accent_color: UInt32?
    var divider: Bool?
    var spacing: Int?
    var items: [MediaItemDTO]?
    /// A section's trailing accessory — a thumbnail or a button.
    ///
    /// **Boxed in an array, because a struct cannot recursively contain
    /// itself.** `[ComponentDTO]` is a heap buffer, so the recursion is
    /// indirect; `ComponentDTO?` inside `ComponentDTO` is not a type Swift can
    /// lay out. Discord sends one object, and `decodeIfPresent` on an array
    /// would reject it — so the key is decoded by hand into a one-element array.
    var accessory: [ComponentDTO]?
    var media: MediaSourceDTO?
    /// A string select's options, and how many may be chosen.
    var options: [SelectOptionDTO]?
    var min_values: Int?
    var max_values: Int?
    /// A form's fields — see `InteractionModalDTO`. A label's one field is
    /// boxed for the reason `accessory` is.
    var min_length: Int?
    var max_length: Int?
    var required: Bool?
    var value: String?
    var description: String?
    var `default`: Bool?
    var component: [ComponentDTO]?
    /// Component 16's activity — what a reply to somebody's activity carries
    /// (Discord's `CONTENT_INVENTORY_ENTRY`).
    var content_inventory_entry: ContentEntryDTO?

    /// The activity a message is a reply to, from its top-level component 16.
    static func contentEntry(_ payload: [ComponentDTO]?) -> RecentActivity? {
        payload?.lazy.compactMap { $0.type == 16 ? $0.content_inventory_entry?.domain : nil }.first
    }

    struct SelectOptionDTO: Decodable, Sendable {
        var label: String?
        var value: String?
        var description: String?
        var emoji: EmojiDTO?
        var `default`: Bool?

        var domain: SelectMenu.Option? {
            guard let value, let label else { return nil }
            return SelectMenu.Option(
                label: label,
                value: value,
                description: description?.isEmpty == false ? description : nil,
                emoji: emoji?.domain,
                isDefault: self.default ?? false
            )
        }
    }

    /// The top-level rows, flattened to what can be drawn.
    ///
    /// Rows with nothing drawable in them are dropped rather than kept empty: an
    /// action row holding only a component type this client does not know is a
    /// blank strip of reserved height under a message.
    static func rows(_ payload: [ComponentDTO]?) -> [ActionRow] {
        guard let payload, !payload.isEmpty else { return [] }
        var rows: [ActionRow] = []
        rows.reserveCapacity(payload.count)
        for row in payload {
            // Type 1 is an action row; anything else at the top level is a
            // Components V2 container, which `Message.isComponentsOnly` already
            // flags and which this client does not lay out.
            guard row.type == 1 else { continue }
            var controls: [MessageComponent] = []
            for child in row.components ?? [] {
                guard let control = child.domain else { continue }
                controls.append(control)
            }
            guard !controls.isEmpty else { continue }
            rows.append(ActionRow(components: controls))
        }
        return rows
    }

    fileprivate var control: MessageComponent? { domain }

    private var domain: MessageComponent? {
        switch type {
        case 2:
            let style = MessageComponent.Style(rawValue: self.style ?? 2)
            let kind: MessageComponent.Kind
            if style == .link {
                // A link button with no URL is not a link button. It cannot be
                // pressed and it cannot say where it goes, so it is drawn as the
                // inert control it is rather than as a live one.
                guard let url, !url.isEmpty else { return nil }
                kind = .link(url)
            } else if let custom_id, !custom_id.isEmpty {
                // What `POST /interactions` sends back, verbatim. It is the
                // application's own opaque string — `help_page__next,5362364…`
                // in the capture — and nothing here reads it.
                kind = .action(customID: custom_id)
            } else {
                // Discord requires a `custom_id` on every non-link button, so
                // this is a bot that sent something malformed. Drawn dimmed
                // rather than dropped: a gap in the middle of a control row is
                // harder to understand than a control that says it is dead.
                kind = .inert
            }
            let text = label ?? ""
            // A button with neither words nor a glyph has nothing to draw.
            guard !text.isEmpty || emoji != nil else { return nil }
            return MessageComponent(
                id: custom_id ?? url ?? text,
                label: text,
                kind: kind,
                style: style,
                isDisabled: disabled ?? false,
                emoji: emoji?.domain
            )
        case 3, 5, 6, 7, 8:
            // Every flavour of select menu. A string select is answerable —
            // `SelectMenu.isAnswerable` — and the pickers are drawn as what
            // they say, dimmed.
            let menu = SelectMenu(
                customID: custom_id ?? "",
                type: type ?? SelectMenu.stringType,
                placeholder: placeholder,
                options: (options ?? []).compactMap(\.domain),
                minValues: min_values ?? 1,
                maxValues: max_values ?? 1
            )
            return MessageComponent(
                id: custom_id ?? menu.summary,
                label: menu.summary,
                kind: .select(menu),
                style: .secondary,
                isDisabled: (disabled ?? false) || !menu.isAnswerable
            )
        default:
            return nil
        }
    }
}


// MARK: - Components V2

extension ComponentDTO {
    /// The display tree, or empty for a message built the ordinary way.
    ///
    /// **Empty is the answer for a V1 message**, and that is what keeps the two
    /// paths from drawing the same buttons twice: a payload whose top level is
    /// nothing but action rows is handled by `rows` above, and only a payload
    /// carrying a genuine V2 node — a container, a text display, a section, a
    /// gallery or a separator — becomes a tree. When it does, the rows come with
    /// it, in tree order, so a row declared inside a container is drawn inside
    /// it rather than hoisted underneath.
    static func display(_ payload: [ComponentDTO]?) -> [DisplayComponent] {
        guard let payload, payload.contains(where: { $0.isDisplayNode }) else { return [] }
        return nodes(payload)
    }

    private static func nodes(_ payload: [ComponentDTO]) -> [DisplayComponent] {
        var result: [DisplayComponent] = []
        result.reserveCapacity(payload.count)
        for child in payload {
            guard let node = child.node, !node.isEmpty else { continue }
            result.append(node)
        }
        return result
    }

    /// Whether this is a V2 node rather than a plain action row.
    private var isDisplayNode: Bool {
        switch type {
        case 9, 10, 12, 14, 17: true
        default: false
        }
    }

    private var node: DisplayComponent? {
        switch type {
        case 17:
            .container(
                // Discord sends `accent_color` as an integer here, unlike the
                // `#rrggbb` string on a guild profile. Zero is a real black
                // accent nobody picks and an unset one arrives as null, so it
                // is dropped rather than drawn as a black rule.
                accent: accent_color.flatMap { $0 == 0 ? nil : $0 },
                children: Self.nodes(components ?? [])
            )
        case 9:
            .section(
                children: Self.nodes(components ?? []),
                thumbnail: accessory?.first?.media?.domain
            )
        case 10:
            content.map { DisplayComponent.text($0) }
        case 12:
            .gallery((items ?? []).compactMap(\.domain))
        case 14:
            // Discord's spacing is 1 (small) or 2 (large); a divider defaults to
            // drawn, which is what an omitted flag means on this node.
            .separator(isDivider: divider ?? true, isLarge: (spacing ?? 1) >= 2)
        case 1:
            {
                var controls: [MessageComponent] = []
                for child in components ?? [] {
                    guard let control = child.control else { continue }
                    controls.append(control)
                }
                return controls.isEmpty ? nil : .row(ActionRow(components: controls))
            }()
        default:
            nil
        }
    }
}

struct MediaItemDTO: Decodable, Sendable {
    var media: MediaSourceDTO?
    var description: String?
    var spoiler: Bool?

    /// The item's picture, carrying the two facts that decide how it is drawn:
    /// whether it is a spoiler, and whether it is a video.
    var domain: Embed.Media? {
        guard var media = media?.domain else { return nil }
        media.isSpoiler = spoiler ?? false
        media.altText = description
        return media
    }
}

struct MediaSourceDTO: Decodable, Sendable {
    var url: String?
    var proxy_url: String?
    var width: Int?
    var height: Int?
    var placeholder: String?
    var placeholder_version: Int?
    var content_type: String?

    var domain: Embed.Media? {
        guard let url, !url.isEmpty else { return nil }
        var media = Embed.Media(
            url: url,
            proxyURL: proxy_url,
            width: width,
            height: height,
            placeholder: MediaPlaceholder.accepted(placeholder, version: placeholder_version)
        )
        media.isVideo = content_type?.hasPrefix("video/") == true
        return media
    }
}

// MARK: - Polls

struct PollDTO: Decodable, Sendable {
    var question: MediaTextDTO?
    var answers: [AnswerDTO]?
    var expiry: Date?
    var allow_multiselect: Bool?
    var results: ResultsDTO?

    struct MediaTextDTO: Decodable, Sendable {
        var text: String?
        var emoji: EmojiDTO?
    }

    struct AnswerDTO: Decodable, Sendable {
        var answer_id: Int?
        var poll_media: MediaTextDTO?
    }

    struct ResultsDTO: Decodable, Sendable {
        var is_finalized: Bool?
        var answer_counts: [CountDTO]?

        struct CountDTO: Decodable, Sendable {
            var id: Int?
            var count: Int?
            var me_voted: Bool?
        }
    }

    /// Nil for anything that is not a poll worth drawing.
    ///
    /// **The tally is a separate array keyed by answer id**, and an answer
    /// missing from it has genuinely had no votes — Discord omits the entry
    /// rather than sending a zero. Reading it as "absent means unknown" is what
    /// would leave a fresh poll with no bars at all.
    var domain: Poll? {
        guard let text = question?.text, !text.isEmpty else { return nil }
        var counts: [Int: (count: Int, mine: Bool)] = [:]
        for entry in results?.answer_counts ?? [] {
            guard let id = entry.id else { continue }
            counts[id] = (entry.count ?? 0, entry.me_voted ?? false)
        }

        var answers: [Poll.Answer] = []
        for answer in self.answers ?? [] {
            guard let id = answer.answer_id else { continue }
            let label = answer.poll_media?.text ?? ""
            let emoji = answer.poll_media?.emoji?.domain
            // An answer with neither words nor a glyph cannot be voted for by
            // anybody who can see it.
            guard !label.isEmpty || emoji != nil else { continue }
            let tally = counts[id]
            answers.append(Poll.Answer(
                id: id,
                text: label,
                emoji: emoji,
                count: tally?.count ?? 0,
                isMine: tally?.mine ?? false
            ))
        }
        guard !answers.isEmpty else { return nil }

        return Poll(
            question: text,
            answers: answers,
            expiresAt: expiry,
            allowsMultiselect: allow_multiselect ?? false,
            isFinalized: results?.is_finalized ?? false
        )
    }
}


// MARK: - Expression sources

struct ExpressionSourceDTO: Decodable, Sendable {
    var type: String?
    var guild: SourceGuildDTO?
    var application: SourceApplicationDTO?

    struct SourceGuildDTO: Decodable, Sendable {
        var id: GuildID?
        var name: String?
        var icon: String?
        var description: String?
        var approximate_member_count: Int?
        var approximate_presence_count: Int?
        var features: [String]?
        var emojis: [EmojiDTO]?
    }

    struct SourceApplicationDTO: Decodable, Sendable {
        var name: String?
        var icon: String?
    }

    /// Nil for a source this client has nothing to say about.
    ///
    /// Branching on the payload rather than on `type`: the string is advisory,
    /// and a guild object with a name in it is a guild whatever it is labelled.
    var domain: ExpressionSource? {
        if let guild, let id = guild.id, let name = guild.name, !name.isEmpty {
            // A sample, not the set. The route sends every emoji the server has
            // and the card shows a strip of them; holding hundreds to draw four
            // is a copy of somebody else's catalogue per hover.
            var sample: [EmojiRef] = []
            for emoji in guild.emojis ?? [] {
                guard let entry = emoji.catalogEntry else { continue }
                sample.append(entry)
                if sample.count == ExpressionSourceDTO.sampleLimit { break }
            }
            return .guild(ExpressionSource.Guild(
                id: id,
                name: name,
                iconHash: guild.icon,
                description: guild.description.flatMap { $0.isEmpty ? nil : $0 },
                memberCount: guild.approximate_member_count,
                onlineCount: guild.approximate_presence_count,
                features: Set(guild.features ?? []),
                sampleEmoji: sample
            ))
        }
        if let application, let name = application.name, !name.isEmpty {
            return .application(name: name, iconHash: application.icon)
        }
        return nil
    }

    /// How many of a server's expressions the card shows.
    static let sampleLimit = 6
}

/// `GET /stickers/{id}/guild`, which answers with the guild **directly** rather
/// than wrapping it — the emoji route nests one under `guild`, and this one does
/// not. Two shapes for one idea, so each gets its own reader and neither has to
/// guess.
struct StickerSourceDTO: Decodable, Sendable {
    var id: GuildID?
    var name: String?
    var icon: String?
    var description: String?
    var approximate_member_count: Int?
    var approximate_presence_count: Int?
    var features: [String]?
    var stickers: [StickerDTO]?

    var domain: ExpressionSource? {
        guard let id, let name, !name.isEmpty else { return nil }
        var sample: [StickerRef] = []
        for sticker in stickers ?? [] {
            guard let entry = sticker.catalogEntry else { continue }
            sample.append(entry)
            if sample.count == ExpressionSourceDTO.sampleLimit { break }
        }
        return .guild(ExpressionSource.Guild(
            id: id,
            name: name,
            iconHash: icon,
            description: description.flatMap { $0.isEmpty ? nil : $0 },
            memberCount: approximate_member_count,
            onlineCount: approximate_presence_count,
            features: Set(features ?? []),
            sampleStickers: sample
        ))
    }
}

/// A list decoded one element at a time: an element that cannot be read is
/// dropped rather than failing the payload it rides in.
struct LossyList<Element: Decodable & Sendable>: Decodable, Sendable {
    var elements: [Element]
    /// How many elements could not be read and were left out.
    var dropped = 0

    /// How many elements the payload carried, read or not.
    var wireCount: Int { elements.count + dropped }

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                // A failed element leaves the cursor where it was; stepping
                // over it with a type that reads anything moves it on.
                _ = try? container.decode(Skipped.self)
                dropped += 1
            }
        }
        self.elements = elements
    }

    private struct Skipped: Decodable {
        init(from decoder: any Decoder) throws {}
    }
}

/// A message's `activity`: what kind of invitation, and to which party.
struct MessageActivityDTO: Decodable, Sendable {
    var type: Int?
    var party_id: String?
    var name_override: String?
    var icon_override: String?

    /// Type 3 is LISTEN; a party that is not Spotify's is something else.
    var listenAlong: ListenAlongInvite? {
        guard type == 3, let party_id, SpotifyListening.isSpotifyParty(party_id) else { return nil }
        return ListenAlongInvite(partyID: party_id, name: name_override ?? "Spotify", iconKey: icon_override)
    }
}

/// `media_mention` as a message carries it and a send writes it.
///
/// A received one also names `message_id`: the reply's own id, which is the id
/// its copy in the clip's media thread is filed under (Discord's store, web
/// build 641803) — never written by a send.
struct MediaMentionDTO: Codable, Sendable {
    var attachment_id: String
    var timestamp: Int?
    var message_id: String?

    init(_ mention: MediaMention) {
        attachment_id = String(mention.attachmentID.rawValue)
        timestamp = mention.timestampMS
    }

    var domain: MediaMention? {
        UInt64(attachment_id).map { MediaMention(attachmentID: AttachmentID(rawValue: $0), timestampMS: timestamp ?? 0) }
    }
}

/// `user.perks` — `{active_perks_bitmask, config_by_perk: {"2": {source: [4], kind}}, rules_version}`.
struct PerksDTO: Decodable, Sendable {
    var config_by_perk: [String: ConfigDTO]?

    struct ConfigDTO: Decodable, Sendable {
        var source: [Int]?
    }

    var domain: AccountPerks {
        var sources: [String: Set<Int>] = [:]
        for (perk, config) in config_by_perk ?? [:] {
            if let list = config.source { sources[perk] = Set(list) }
        }
        return AccountPerks(sources: sources)
    }
}
