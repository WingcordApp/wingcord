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

    var domain: EmojiRef {
        EmojiRef(id: id, name: name ?? "", isAnimated: animated ?? false)
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

    private enum CodingKeys: String, CodingKey { case id, name, format_type }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UInt64(try container.decode(String.self, forKey: .id)) ?? 0
        name = try container.decodeIfPresent(String.self, forKey: .name)
        format_type = try container.decodeIfPresent(Int.self, forKey: .format_type)
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
    public var folders: [GuildFolder]
    public var status: PresenceStatus
    public var customStatus: String?
}
