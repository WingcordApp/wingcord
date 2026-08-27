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
    var primary_guild: PrimaryGuildDTO?

    var domain: User {
        // The box is built only when there is something to put in it. One
        // allocation per user with cosmetics, none for the overwhelming
        // majority who have none.
        let decoration = UserDecoration(
            avatarDecorationHash: avatar_decoration_data?.asset,
            nameplateAsset: collectibles?.nameplate?.asset,
            bannerHash: banner,
            accentColor: accent_color,
            bio: bio?.isEmpty == true ? nil : bio,
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

struct AvatarDecorationDTO: Decodable, Sendable {
    var asset: String?
}

struct CollectiblesDTO: Decodable, Sendable {
    var nameplate: NameplateDTO?

    struct NameplateDTO: Decodable, Sendable {
        var asset: String?
        var label: String?
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
            unicodeEmoji: unicode_emoji
        )
    }
}

struct MemberDTO: Decodable, Sendable {
    var user: UserDTO?
    var nick: String?
    var avatar: String?
    var roles: [RoleID]?
    var joined_at: Date?
    var premium_since: Date?
    var communication_disabled_until: Date?
    var pending: Bool?

    func domain(userID: UserID) -> Member {
        Member(
            userID: userID,
            nickname: nick,
            avatarHash: avatar,
            roleIDs: roles ?? [],
            joinedAt: joined_at,
            premiumSince: premium_since,
            communicationDisabledUntil: communication_disabled_until,
            isPending: pending ?? false
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
    var recipients: [UserDTO]?
    var recipient_ids: [UserID]?
    var icon: String?
    var message_count: Int?

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
            messageCount: message_count
        )
    }
}

struct GuildDTO: Decodable, Sendable {
    var id: GuildID
    var name: String?
    var icon: String?
    var banner: String?
    var splash: String?
    var owner_id: UserID?
    var premium_tier: Int?
    var premium_subscription_count: Int?
    var features: [String]?
    var member_count: Int?
    var rules_channel_id: ChannelID?
    var large: Bool?
    var roles: [RoleDTO]?
    /// A server's own emoji and stickers. Present on the READY guild objects and
    /// on GUILD_CREATE, which is what keeps the picker's catalog current without
    /// a fetch of its own.
    var emojis: [EmojiDTO]?
    var stickers: [StickerDTO]?
    var channels: [ChannelDTO]?
    var members: [MemberDTO]?
    var presences: [PresenceDTO]?
    /// Present on the READY payload's guild objects, absent on a plain fetch.
    var properties: GuildProperties?

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
        var features: [String]?
        var rules_channel_id: ChannelID?
    }

    var domain: Guild {
        Guild(
            id: id,
            name: name ?? properties?.name ?? "Unknown",
            iconHash: icon ?? properties?.icon,
            bannerHash: banner ?? properties?.banner,
            splashHash: splash ?? properties?.splash,
            ownerID: owner_id ?? properties?.owner_id ?? UserID(rawValue: 0),
            premiumTier: premium_tier ?? properties?.premium_tier ?? 0,
            premiumSubscriptionCount: premium_subscription_count ?? 0,
            features: Set(features ?? properties?.features ?? []),
            memberCount: member_count,
            rulesChannelID: rules_channel_id ?? properties?.rules_channel_id,
            isLarge: large ?? false
        )
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
            durationSeconds: duration_secs
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

struct ReactionDTO: Decodable, Sendable {
    var emoji: EmojiDTO
    var count: Int?
    var me: Bool?
    var count_details: CountDetails?

    struct CountDetails: Decodable, Sendable {
        var burst: Int?
        var normal: Int?
    }

    var domain: Reaction {
        Reaction(
            emoji: emoji.domain,
            count: count ?? 0,
            isMine: me ?? false,
            burstCount: count_details?.burst ?? 0
        )
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

        var domain: Embed.Media? {
            guard let url else { return nil }
            return Embed.Media(url: url, proxyURL: proxy_url, width: width, height: height)
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
            providerName: provider?.name
        )
    }
}

struct StickerDTO: Decodable, Sendable {
    var id: UInt64
    var name: String?
    var format_type: Int?
    /// As on `EmojiDTO`: a sticker the server can no longer offer.
    var available: Bool?

    private enum CodingKeys: String, CodingKey { case id, name, format_type, available }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UInt64(try container.decode(String.self, forKey: .id)) ?? 0
        name = try container.decodeIfPresent(String.self, forKey: .name)
        format_type = try container.decodeIfPresent(Int.self, forKey: .format_type)
        available = try container.decodeIfPresent(Bool.self, forKey: .available)
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
    var mentions: [UserDTO]?
    var mention_roles: [RoleID]?
    var mention_everyone: Bool?
    var message_reference: ReferenceDTO?
    var webhook_id: UserID?
    var nonce: NonceDTO?

    struct ReferenceDTO: Decodable, Sendable {
        var message_id: MessageID?
        var channel_id: ChannelID?
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
            mentionedUserIDs: mentions?.map(\.id) ?? [],
            mentionedRoleIDs: mention_roles ?? [],
            mentionsEveryone: mention_everyone ?? false,
            referencedMessageID: message_reference?.message_id,
            referencedChannelID: message_reference?.channel_id,
            webhookID: webhook_id,
            nonce: nonce?.text
        )
        return Message(
            id: id,
            channelID: channel_id,
            authorID: author?.id ?? UserID(rawValue: 0),
            content: content ?? "",
            editedAt: edited_timestamp,
            kind: MessageKind(rawValue: type ?? 0),
            flags: MessageFlags(rawValue: flags ?? 0),
            payload: payload.isEmpty ? nil : payload
        )
    }
}

struct PresenceDTO: Decodable, Sendable {
    var user: PartialUser?
    var status: String?
    var activities: [ActivityDTO]?
    var client_status: ClientStatus?

    struct PartialUser: Decodable, Sendable { var id: UserID }

    struct ClientStatus: Decodable, Sendable {
        var desktop: String?
        var mobile: String?
        var web: String?
    }

    var domain: Presence? {
        guard let userID = user?.id else { return nil }
        let list = activities?.compactMap(\.domain) ?? []
        return Presence(
            userID: userID,
            status: PresenceStatus(rawValue: status ?? "offline") ?? .offline,
            // A phone glyph rather than a dot, and only when the phone is the
            // ONLY session — someone at their desk with a phone in their pocket
            // is at their desk.
            isOnMobile: client_status?.mobile != nil
                && client_status?.desktop == nil
                && client_status?.web == nil,
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

    struct Assets: Decodable, Sendable {
        var large_image: String?
        var small_image: String?
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
            emoji: emoji?.domain,
            // Discord sends milliseconds; a client that reads them as seconds
            // dates every activity to 1970 and every "elapsed" reads as decades.
            startedAt: timestamps?.start.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }
}

struct ReadStateDTO: Decodable, Sendable {
    var id: ChannelID
    var last_message_id: MessageID?
    var mention_count: Int?
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
            customStatus: custom_status?.text
        )
    }
}

/// The account's own client settings, as the app uses them.
public struct ClientSettings: Sendable {
    /// The account's favourite GIFs, from the settings proto. Empty for an
    /// account with none, and empty for a blob this client could not read —
    /// see `UserSettingsProto.FavoritesField`.
    public var favoriteGIFs: [GIF] = []
    public var folders: [GuildFolder]
    /// The rail's order for guilds that are not in a folder.
    ///
    /// Discord keeps this **separate** from the folder list, and a client that
    /// reads only the folders has no order for everything else — which on this
    /// account is most of it. Empty when the account has never rearranged.
    public var guildPositions: [GuildID] = []
    public var status: PresenceStatus
    public var customStatus: String?

    public init(
        folders: [GuildFolder],
        guildPositions: [GuildID] = [],
        status: PresenceStatus,
        customStatus: String?,
        favoriteGIFs: [GIF] = []
    ) {
        self.folders = folders
        self.guildPositions = guildPositions
        self.status = status
        self.customStatus = customStatus
        self.favoriteGIFs = favoriteGIFs
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
    var premium_since: String?
    var premium_type: Int?
    var legacy_username: String?
    var connected_accounts: [ConnectionDTO]?

    struct ConnectionDTO: Decodable, Sendable {
        var id: String?
        var type: String?
        var name: String?
        var verified: Bool?

        var domain: ConnectedAccount? {
            guard let id, let type, let name else { return nil }
            return ConnectedAccount(
                id: id, service: type, name: name, isVerified: verified ?? false
            )
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
    }

    struct EffectRef: Decodable, Sendable {
        var sku_id: String?
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

    /// The account, with every profile layer folded onto its decoration.
    ///
    /// Merged rather than replaced field by field: an empty guild layer must not
    /// erase a global banner, so each field takes the first non-empty answer in
    /// guild-then-global-then-account order.
    var domain: User {
        let base = user.domain
        func pick<T>(_ path: (ProfileLayer) -> T?) -> T? {
            if let value = guild_member_profile.flatMap(path) { return value }
            return user_profile.flatMap(path)
        }
        let bio = pick(\.bio).flatMap { $0.isEmpty ? nil : $0 }
        let theme = pick(\.theme_colors).flatMap { $0.isEmpty ? nil : $0 }

        let decoration = UserDecoration(
            avatarDecorationHash: base.decoration?.avatarDecorationHash,
            nameplateAsset: base.decoration?.nameplateAsset,
            bannerHash: pick(\.banner) ?? base.decoration?.bannerHash,
            accentColor: pick(\.accent_color) ?? base.decoration?.accentColor,
            bio: bio ?? base.decoration?.bio,
            themeColorValues: theme,
            badges: badges?.compactMap(\.domain) ?? [],
            profileEffectSKU: pick { $0.profile_effect?.sku_id },
            pronouns: pick(\.pronouns).flatMap { $0.isEmpty ? nil : $0 },
            connectedAccounts: connected_accounts?.compactMap(\.domain) ?? [],
            premiumTier: premium_type.flatMap { PremiumTier(rawValue: $0) } ?? .none,
            premiumSince: premium_since.flatMap(Self.date(from:)),
            legacyUsername: legacy_username,
            mutualGuilds: mutual_guilds?.compactMap(\.domain) ?? [],
            primaryGuildTag: base.decoration?.primaryGuildTag,
            primaryGuildBadgeHash: base.decoration?.primaryGuildBadgeHash,
            primaryGuildID: base.decoration?.primaryGuildID
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

// MARK: - Collectibles

/// `GET /collectibles-products/{sku_id}`.
///
/// How a profile effect's `sku_id` becomes artwork. Captured from a live
/// response: the payload is a store product whose `items` carry the actual
/// composition, and the fields that matter are camelCase inside an otherwise
/// snake_case API — which is worth writing down, because a decoder that assumes
/// one convention silently drops the other.
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
        var effects: [Effect]?
    }

    struct Effect: Decodable, Sendable {
        var src: String?
        /// Milliseconds, both of them.
        var start: Double?
        var duration: Double?
        var loop: Bool?
        var zIndex: Int?
        var width: Double?
        var height: Double?
    }

    var domain: ProfileEffect? {
        guard let item = items?.first, let sku = sku_id ?? item.sku_id else { return nil }
        let layers: [ProfileEffect.Layer] = (item.effects ?? []).compactMap { effect in
            guard let source = effect.src, let url = URL(string: source) else { return nil }
            return ProfileEffect.Layer(
                url: url,
                // Discord sends milliseconds; read as seconds they would each
                // last most of an hour.
                start: (effect.start ?? 0) / 1000,
                duration: (effect.duration ?? 0) / 1000,
                loops: effect.loop ?? false,
                zIndex: effect.zIndex ?? 0,
                size: CGSize(width: effect.width ?? 450, height: effect.height ?? 880)
            )
        }
        guard !layers.isEmpty else { return nil }
        return ProfileEffect(
            skuID: sku,
            title: item.title ?? name ?? "",
            accessibilityLabel: item.accessibilityLabel,
            reducedMotionURL: (item.reducedMotionSrc ?? item.staticFrameSrc)
                .flatMap { URL(string: $0) },
            layers: layers
        )
    }
}
