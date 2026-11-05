import Foundation
import WingcordCore

// Resolving an invite, and accepting one.
//
// **Captured**, `forza onboarding1.har`, entries 3, 4 and 9. Two routes on one
// path, and the method is the whole difference:
//
// ```
// GET  /invites/forza?inputValue=forza&with_counts=true
//                    &with_expiration=true&with_permissions=true   → the preview
// POST /invites/forza      body {"session_id": "<gateway session>"} → the join
// ```
//
// Three things that shape the code below:
//
//  1. **The POST body is the gateway session id and nothing else.** The same
//     field the lurk route takes as a query parameter — see
//     `DiscordREST+Preview` — and for the same reason: Discord ties the join to
//     the socket that is about to receive the `GUILD_CREATE`.
//  2. **The 200 does not carry the server.** It carries the invite's *guild
//     half* — thirteen fields, no channels, no roles, no members — exactly as
//     the preview does. The membership arrives over the socket, so a caller
//     waiting on this value for a channel list waits for ever.
//  3. **The first POST was refused with a captcha.** That is not special to this
//     route and is not handled here: `requestData` recognises the challenge and
//     retries, so this file contains no captcha code at all.

extension DiscordREST {

    /// Looks up an invite without joining anything.
    ///
    /// The three `with_` parameters are the captured ones and each buys a field
    /// the card draws: `with_counts` the member and online numbers,
    /// `with_expiration` whether the link has run out, `with_permissions` what
    /// the account would be able to do. `inputValue` is what was typed — Discord
    /// echoes it for analytics — and is sent because it was captured.
    public func resolveInvite(_ code: String, input: String? = nil) async throws -> InvitePreview {
        let dto = try await get(
            "/invites/\(code)",
            route: "invites/{code}",
            query: [
                URLQueryItem(name: "inputValue", value: input ?? code),
                URLQueryItem(name: "with_counts", value: "true"),
                URLQueryItem(name: "with_expiration", value: "true"),
                URLQueryItem(name: "with_permissions", value: "true"),
            ],
            as: InviteDTO.self
        )
        guard let preview = dto.preview else { throw Failure.notFound }
        return preview
    }

    /// What an invite posted in a message is — the card the transcript draws.
    ///
    /// **Discord's own request**, captured in `invites.har` as the chat opened:
    /// `GET /invites/{code}?with_counts=true&with_expiration=true&with_permissions=true`.
    /// A 404 is an expired or unknown invite, which is an answer, not a failure:
    /// Discord draws a card saying so.
    ///
    /// `key` is `InviteCard.codes(in:)`'s: a link with `?event=` on it asks
    /// for the event too, `guild_scheduled_event_id` in the place Discord's
    /// `resolveInvite` puts it, and the answer carries it whole.
    public func inviteCard(_ key: String) async throws -> InviteLookup {
        var query = [
            URLQueryItem(name: "with_counts", value: "true"),
            URLQueryItem(name: "with_expiration", value: "true"),
        ]
        if let eventID = InviteCard.eventID(ofKey: key) {
            query.append(URLQueryItem(name: "guild_scheduled_event_id", value: String(eventID)))
        }
        query.append(URLQueryItem(name: "with_permissions", value: "true"))
        do {
            let dto = try await get(
                "/invites/\(InviteCard.code(ofKey: key))",
                route: "invites/{code}",
                query: query,
                as: InviteDTO.self
            )
            return dto.card.map(InviteLookup.resolved) ?? .invalid
        } catch Failure.notFound {
            return .invalid
        }
    }

    /// Accepts a group conversation's invite or a friend link — the same
    /// `POST /invites/{code}` a server's takes. Answers with the conversation
    /// a group invite put the reader in, and nil for a friend link.
    public func acceptInviteWithoutGuild(
        _ code: String,
        sessionID: String,
        location: String = "Invite Button Embed"
    ) async throws -> ChannelID? {
        struct Body: Encodable { var session_id: String }
        let data = try await requestData(
            method: "POST",
            path: "/invites/\(code)",
            route: "invites/{code}",
            body: Body(session_id: sessionID),
            headers: Self.inviteContext(location: location)
        )
        return (try? Self.decoder.decode(InviteDTO.self, from: data))?.channel?.id
    }

    /// Joins the server an invite points at.
    ///
    /// - Parameter sessionID: the **gateway** session. Required: it is the whole
    ///   body, and it is what the `GUILD_CREATE` that follows is dispatched to.
    /// - Parameter source: the `x-context-properties` location. Captured as
    ///   `{"location":"Join Guild", …}`; sent because Discord's own client sends
    ///   it and nothing here depends on the value. An invite card in a message
    ///   sends "Invite Button Embed".
    ///
    /// A captcha on the first attempt is handled below this call — see the note
    /// at the top of this file — so by the time this returns, the join either
    /// happened or was refused for a reason worth reporting.
    public func acceptInvite(
        _ code: String,
        sessionID: String,
        source: String = "Join Guild"
    ) async throws -> InviteAcceptance {
        struct Body: Encodable { var session_id: String }
        let data = try await requestData(
            method: "POST",
            path: "/invites/\(code)",
            route: "invites/{code}",
            body: Body(session_id: sessionID),
            headers: Self.inviteContext(location: source)
        )
        guard let dto = try? Self.decoder.decode(InviteDTO.self, from: data),
              let guildID = dto.guildID
        else { throw Failure.decoding("invite accept carried no guild") }
        let features = Set(dto.guild?.features ?? [])
        // Discord files the request and the server only when both are there.
        let joinRequest = dto.guild == nil ? nil : dto.join_request?.domain(guildID: guildID)
        return InviteAcceptance(
            guildID: guildID,
            channelID: dto.channel?.id,
            requiresVerification: dto.show_verification_form ?? false,
            isNewMember: dto.new_member ?? false,
            isApplication: features.contains("MEMBER_VERIFICATION_GATE_ENABLED")
                && features.contains("MEMBER_VERIFICATION_MANUAL_APPROVAL"),
            joinRequest: joinRequest,
            applicationGuild: joinRequest == nil ? nil : dto.guild.map {
                JoinRequestGuild(
                    id: guildID,
                    name: $0.name ?? "",
                    iconHash: $0.icon,
                    description: $0.description.nonEmpty,
                    splashHash: $0.splash,
                    features: features
                )
            },
            welcomeScreen: dto.guild?.welcome_screen?.domain,
            features: features
        )
    }
}

extension DiscordREST {
    /// An accept's `x-context-properties`: `{"location": …}`, base64'd.
    ///
    /// **`location`, not `source`** — captured on every accept in `forza
    /// onboarding.har` as `{"location":"Join Guild","location_guild_id":…}`.
    /// The accept used to send the discovery routes' `{"source":…}`, a key
    /// Discord's own accept never carries.
    static func inviteContext(location: String) -> [String: String] {
        struct Properties: Encodable { var location: String }
        guard let json = try? JSONEncoder().encode(Properties(location: location)) else { return [:] }
        return ["x-context-properties": json.base64EncodedString()]
    }
}

/// One shape for both routes, because Discord answers both with one object —
/// the accept adds two keys to the resolve and changes nothing else.
///
/// Decoded **defensively**, like every other secondary surface: an invite that
/// gains a key must not become an invite that cannot be read.
struct InviteDTO: Decodable, Sendable {
    var code: String?
    /// `0` a server, `1` a group conversation, `2` a friend link.
    var type: Int?
    var guild: GuildHalfDTO?
    var guild_id: GuildID?
    var channel: ChannelHalfDTO?
    /// Who made it — drawn on the card, and the whole of a friend link.
    var inviter: UserDTO?
    var expires_at: String?
    var approximate_member_count: Int?
    var approximate_presence_count: Int?
    /// The server's profile — captured on `invites.har`'s Lumen Club invite,
    /// the same object `/guilds/{id}/profile` answers with. Discord's current
    /// server card is drawn from nothing else.
    var profile: GuildProfileDTO?
    /// Accept only.
    var show_verification_form: Bool?
    /// Accept only.
    var new_member: Bool?
    /// Accept only, into a server that reviews applications: the request the
    /// accept opened — Discord's `INVITE_ACCEPT_SUCCESS` reads it. Not captured.
    var join_request: OwnJoinRequestDTO?
    /// The event a link's `?event=` asked about, whole — what Discord's
    /// invite card turns into while it is not over (`346542`'s `ly`).
    var guild_scheduled_event: InviteEventDTO?
    /// Whether the sheet may offer a Server Nickname (`504394`). Not captured.
    var is_nickname_changeable: Bool?
    /// What accepting grants: "Roles Granted" (`897288`). Read one by one, so a
    /// role this can't read costs that role, never the invite. Not captured.
    var roles: [Lossy<InviteRoleDTO>]?
    /// `1` is `IS_GUEST_INVITE`. Not captured.
    var flags: Int?

    /// A role, as far as "Roles Granted" draws one.
    struct InviteRoleDTO: Decodable, Sendable {
        var id: RoleID
        var name: String?
        var color: Int?
    }

    /// One element that may fail on its own.
    struct Lossy<Element: Decodable & Sendable>: Decodable, Sendable {
        var value: Element?
        init(from decoder: any Decoder) throws {
            value = try? Element(from: decoder)
        }
    }

    private var grantedRoles: [InviteGrantedRole] {
        (roles ?? []).compactMap(\.value).map {
            InviteGrantedRole(
                id: $0.id,
                name: $0.name ?? "",
                colorValue: $0.color.flatMap { $0 > 0 ? UInt32(exactly: $0) : nil }
            )
        }
    }

    /// The invite's event, read on its own: one this cannot read costs the
    /// card its event, never the invite.
    struct InviteEventDTO: Decodable, Sendable {
        var event: ScheduledEventDTO?

        init(from decoder: any Decoder) throws {
            event = try? ScheduledEventDTO(from: decoder)
        }
    }

    /// The guild as an invite describes it: thirteen fields, and none of the
    /// contents. **Deliberately not `GuildDTO`** — that type's `domain` builds a
    /// server, and a server built from this would be one with no channels that
    /// the store would then answer questions about.
    struct GuildHalfDTO: Decodable, Sendable {
        var id: GuildID?
        var name: String?
        var icon: String?
        var banner: String?
        var splash: String?
        var description: String?
        var features: [String]?
        var premium_tier: Int?
        var premium_subscription_count: Int?
        /// Where the server has one — Discord's `INVITE_RESOLVE_SUCCESS` and
        /// `INVITE_ACCEPT_SUCCESS` both file it. Not captured.
        var welcome_screen: WelcomeScreenDTO?
    }

    struct ChannelHalfDTO: Decodable, Sendable {
        var id: ChannelID?
        var name: String?
        /// The channel's type — 2 is a server's voice channel, whose invite is
        /// Discord's voice card.
        var type: Int?
        /// A group conversation's own icon.
        var icon: String?
        /// A group conversation's members, which name an unnamed group and are
        /// its member count (`oq` in Discord's embed chunk).
        var recipients: [RecipientDTO]?
    }

    struct RecipientDTO: Decodable, Sendable {
        var username: String?
        var global_name: String?
    }

    /// The card the transcript draws for this invite, or nil when the answer
    /// names nothing a card could be about.
    var card: InviteCard? {
        guard let code, !code.isEmpty else { return nil }
        let expiresAt = expires_at.flatMap(Self.timestamp.date(from:))
        let inviterName = inviter.map { $0.global_name.nonEmpty ?? $0.username }
        switch type ?? 0 {
        case 1:
            guard let channel else { return nil }
            let members = (channel.recipients ?? []).compactMap { $0.global_name.nonEmpty ?? $0.username.nonEmpty }
            return InviteCard(
                code: code, kind: .groupDirectMessage, channelID: channel.id,
                name: channel.name.nonEmpty ?? InviteCard.groupTitle(members),
                iconHash: channel.icon.nonEmpty,
                memberCount: channel.recipients.map(\.count),
                inviterID: inviter?.id, inviterName: inviterName, inviterUsername: inviter?.username,
                inviterAvatarHash: inviter?.avatar, expiresAt: expiresAt
            )
        case 2:
            guard let inviter, let inviterName else { return nil }
            return InviteCard(
                code: code, kind: .friend, name: inviterName,
                inviterID: inviter.id, inviterName: inviterName, inviterUsername: inviter.username,
                inviterAvatarHash: inviter.avatar, expiresAt: expiresAt
            )
        default:
            guard let guildID, let name = guild?.name.nonEmpty else { return nil }
            return InviteCard(
                code: code, kind: .server, guildID: guildID, channelID: channel?.id, name: name,
                iconHash: guild?.icon.nonEmpty, splashHash: guild?.splash.nonEmpty,
                features: Set(guild?.features ?? []),
                boostTier: guild?.premium_tier ?? 0,
                boostCount: guild?.premium_subscription_count ?? 0,
                memberCount: approximate_member_count, onlineCount: approximate_presence_count,
                channelName: channel?.name.nonEmpty,
                isVoiceChannel: channel?.type == 2,
                profile: profile?.domain,
                inviterID: inviter?.id, inviterName: inviterName, inviterUsername: inviter?.username,
                inviterAvatarHash: inviter?.avatar, expiresAt: expiresAt,
                event: guild_scheduled_event?.event?.domain(fallbackGuildID: guildID),
                isNicknameChangeable: is_nickname_changeable ?? false,
                grantedRoles: grantedRoles,
                isGuestInvite: (flags ?? 0) & 1 != 0
            )
        }
    }

    private nonisolated(unsafe) static let timestamp = ISO8601DateFormatter()

    var guildID: GuildID? { guild?.id ?? guild_id }

    var preview: InvitePreview? {
        guard let guildID, let code, !code.isEmpty else { return nil }
        return InvitePreview(
            code: code,
            guildID: guildID,
            // A server with no name is not one this can draw a card for, and
            // "Unknown Server" over a Join button is worse than the route
            // having answered nothing.
            name: guild?.name.nonEmpty ?? "",
            description: guild?.description.nonEmpty,
            iconHash: guild?.icon.nonEmpty,
            bannerHash: guild?.banner.nonEmpty,
            splashHash: guild?.splash.nonEmpty,
            memberCount: approximate_member_count,
            onlineCount: approximate_presence_count,
            features: Set(guild?.features ?? [])
        )
        .nonEmptyName
    }
}

private extension InvitePreview {
    /// Nil for a payload with no server name — see `preview`.
    var nonEmptyName: InvitePreview? { name.isEmpty ? nil : self }
}
