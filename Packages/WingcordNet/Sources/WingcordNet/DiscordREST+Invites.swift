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

    /// Joins the server an invite points at.
    ///
    /// - Parameter sessionID: the **gateway** session. Required: it is the whole
    ///   body, and it is what the `GUILD_CREATE` that follows is dispatched to.
    /// - Parameter source: the `x-context-properties` location. Captured as
    ///   `{"location":"Join Guild", …}`; sent because Discord's own client sends
    ///   it and nothing here depends on the value.
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
            headers: Self.contextProperties(source: source)
        )
        guard let dto = try? decoder.decode(InviteDTO.self, from: data),
              let guildID = dto.guildID
        else { throw Failure.decoding("invite accept carried no guild") }
        return InviteAcceptance(
            guildID: guildID,
            channelID: dto.channel?.id,
            requiresVerification: dto.show_verification_form ?? false,
            isNewMember: dto.new_member ?? false
        )
    }
}

/// One shape for both routes, because Discord answers both with one object —
/// the accept adds two keys to the resolve and changes nothing else.
///
/// Decoded **defensively**, like every other secondary surface: an invite that
/// gains a key must not become an invite that cannot be read.
struct InviteDTO: Decodable, Sendable {
    var code: String?
    var guild: GuildHalfDTO?
    var guild_id: GuildID?
    var channel: ChannelHalfDTO?
    var approximate_member_count: Int?
    var approximate_presence_count: Int?
    /// Accept only.
    var show_verification_form: Bool?
    /// Accept only.
    var new_member: Bool?

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
    }

    struct ChannelHalfDTO: Decodable, Sendable {
        var id: ChannelID?
        var name: String?
    }

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
