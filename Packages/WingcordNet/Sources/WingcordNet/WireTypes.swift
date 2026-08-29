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
    /// Which Nitro the account carries. **Present on `/users/@me` and on
    /// nobody else**, which is exactly where it is needed: Nitro is what decides
    /// whether the reader may use another server's emoji, and that is a question
    /// only ever asked about the reader.
    var premium_type: Int?

    var domain: User {
        // The box is built only when there is something to put in it. One
        // allocation per user with cosmetics, none for the overwhelming
        // majority who have none.
        let decoration = UserDecoration(
            avatarDecorationHash: avatar_decoration_data?.asset,
            nameplate: collectibles?.nameplate?.domain,
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

struct AvatarDecorationDTO: Decodable, Sendable {
    var asset: String?
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

        var domain: Nameplate? {
            guard let asset, !asset.isEmpty else { return nil }
            return Nameplate(
                asset: asset,
                palette: palette.flatMap(NameplatePalette.init(rawValue:)) ?? .none,
                label: label
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
    var owner_id: UserID?
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
            ownerID: owner_id,
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
    var components: [ComponentDTO]?
    var poll: PollDTO?
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
            components: ComponentDTO.rows(components),
            displayComponents: ComponentDTO.display(components),
            poll: poll?.domain,
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
    /// nameplate, `3` profile frame. Only the frame is read from here — the
    /// other three arrive by routes this client already has, and taking the
    /// effect from both places would be two answers that can disagree.
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

        let decoration = UserDecoration(
            avatarDecorationHash: base.decoration?.avatarDecorationHash,
            nameplate: base.decoration?.nameplate,
            bannerHash: pick(\.banner) ?? base.decoration?.bannerHash,
            accentColor: pick(\.accent_color) ?? base.decoration?.accentColor,
            bio: bio ?? base.decoration?.bio,
            themeColorValues: theme,
            badges: badges?.compactMap(\.domain) ?? [],
            profileEffectSKU: effectSKU,
            profileFrameSKU: frameSKU,
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
    /// `type` (`"staple"`) and `responsive` are sent and not read: every
    /// captured layer is a non-responsive staple, so there is no observation of
    /// what either alternative does, and this file does not decode a field it
    /// cannot place.
    struct FrameLayer: Decodable, Sendable {
        var id: String?
        var order: String?
        var anchor: String?
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
                  let url = CDN.profileFrameLayer(sku: sku, layerID: id)
            else { return nil }
            return ProfileFrame.Layer(
                id: id,
                url: url,
                // An unrecognised anchor or order costs one misplaced picture,
                // never the frame: `.top` and `.front` are what every captured
                // layer says, and they are the safe reading of a value this
                // client has not seen before.
                anchor: layer.anchor.flatMap(ProfileFrame.Anchor.init(rawValue:)) ?? .top,
                order: layer.order.flatMap(ProfileFrame.Order.init(rawValue:)) ?? .front
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
            // The ordinary boost banner first, the tag profile's own second.
            // Both are drawn the same way, and a server with neither draws its
            // plate.
            bannerHash: banner_hash ?? custom_banner_hash,
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
            premiumTier: premium_tier ?? 0
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
    }

    private enum CodingKeys: String, CodingKey {
        case type, style, label, url, custom_id, disabled, placeholder, emoji
        case components, content, accent_color, divider, spacing, items, media, accessory
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
            } else {
                kind = .action
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
            // Every flavour of select menu. Drawn as its own placeholder, which
            // is the only thing about it a reader can act on the meaning of.
            let text = placeholder ?? "Select an option"
            return MessageComponent(
                id: custom_id ?? text,
                label: text,
                kind: .menu,
                style: .secondary,
                isDisabled: true
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
            .gallery((items ?? []).compactMap { $0.media?.domain })
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
}

struct MediaSourceDTO: Decodable, Sendable {
    var url: String?
    var proxy_url: String?
    var width: Int?
    var height: Int?

    var domain: Embed.Media? {
        guard let url, !url.isEmpty else { return nil }
        return Embed.Media(url: url, proxyURL: proxy_url, width: width, height: height)
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
