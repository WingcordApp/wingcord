import Foundation
import WingcordCore

// MARK: - Acting on a member
//
// Every route here is Discord's own action creator (`66834`, `179552` and the
// member-safety store `144073`), read off the web bundle — the HAR behind this
// surface (`members + mod view.har`) watched the role writes, the search, the
// Mod View counts and the per-person audit log, and none of the moderation
// acts themselves. Two things about them are not guessable:
//
//   1. **A reason travels two ways.** Discord's HTTP layer turns a `reason`
//      option into `X-Audit-Log-Reason`, URL-encoded — that is how a ban, a
//      timeout and a bulk ban carry one. A kick does not: `kickUser` puts
//      `reason` in the QUERY of its DELETE. Both are matched.
//   2. **A member write answers with the member.** The PATCH routes return the
//      whole member object, so the store applies the answer rather than waiting
//      for an event — and `GUILD_MEMBER_UPDATE` confirms it after.

extension DiscordREST {

    /// Discord's audit-log reason header, URL-encoded as its client sends it.
    static func auditReasonHeaders(_ reason: String?) -> [String: String] {
        guard let reason, !reason.isEmpty,
              let encoded = reason.addingPercentEncoding(withAllowedCharacters: .urlUnreservedSet)
        else { return [:] }
        return ["X-Audit-Log-Reason": encoded]
    }

    /// Removes a member. They can come back with a new invite.
    ///
    /// The reason is a **query parameter** here — `kickUser`'s own shape.
    public func kickMember(_ userID: UserID, in guildID: GuildID, reason: String? = nil) async throws {
        var query: [URLQueryItem] = []
        if let reason, !reason.isEmpty { query.append(URLQueryItem(name: "reason", value: reason)) }
        _ = try await requestData(
            method: "DELETE",
            path: "/guilds/\(guildID.rawValue)/members/\(userID.rawValue)",
            route: "guilds/{id}/members/{id}",
            query: query,
            body: Optional<Never>.none
        )
    }

    /// Bans a member, or somebody who is not one.
    ///
    /// `delete_message_seconds` rather than the days the old route took — the
    /// two coexist and only one of them is current.
    public func banMember(
        _ userID: UserID,
        in guildID: GuildID,
        deleteMessageSeconds: Int = 0,
        reason: String? = nil
    ) async throws {
        struct Body: Encodable { var delete_message_seconds: Int }
        _ = try await requestData(
            method: "PUT",
            path: "/guilds/\(guildID.rawValue)/bans/\(userID.rawValue)",
            route: "guilds/{id}/bans/{id}",
            body: Body(delete_message_seconds: deleteMessageSeconds),
            headers: Self.auditReasonHeaders(reason)
        )
    }

    /// Bans several people at once — the Members page's selection.
    ///
    /// **Version two, and it answers before it is finished.** Discord's own
    /// client ignores the reply and learns the outcome from the gateway
    /// (`GUILD_BULK_BAN_UPDATE`); the bans themselves arrive as members
    /// leaving, which is what the table follows.
    public func bulkBan(
        _ userIDs: [UserID],
        in guildID: GuildID,
        deleteMessageSeconds: Int,
        reason: String?
    ) async throws {
        struct Body: Encodable {
            var user_ids: [String]
            var delete_message_seconds: Int
        }
        _ = try await requestData(
            method: "POST",
            path: "/guilds/\(guildID.rawValue)/bulk-ban/v2",
            route: "guilds/{id}/bulk-ban/v2",
            body: Body(
                user_ids: userIDs.map { String($0.rawValue) },
                delete_message_seconds: deleteMessageSeconds
            ),
            headers: Self.auditReasonHeaders(reason)
        )
    }

    /// Times a member out, or lifts one.
    ///
    /// `nil` lifts it, and is sent as an explicit `null`. **Not a duration** —
    /// the field is the instant it ends, and sending a duration produces a
    /// timeout that expired in 1970.
    @discardableResult
    public func timeOutMember(
        _ userID: UserID,
        in guildID: GuildID,
        until: Date?,
        reason: String? = nil
    ) async throws -> Member? {
        struct Body: Encodable { @ExplicitNull var communication_disabled_until: String? }
        return try await memberWrite(
            userID,
            in: guildID,
            body: Body(communication_disabled_until: until.map {
                ISO8601DateFormatter.eventTimestamp.string(from: $0)
            }),
            headers: Self.auditReasonHeaders(reason)
        )
    }

    /// Changes somebody's nickname in a server. An empty string clears it —
    /// the Change Nickname dialog's Reset sends exactly that.
    @discardableResult
    public func setNickname(_ nickname: String, of userID: UserID, in guildID: GuildID) async throws -> Member? {
        struct Body: Encodable { var nick: String }
        return try await memberWrite(userID, in: guildID, body: Body(nick: nickname))
    }

    /// Replaces somebody's roles — **the whole list**, as captured: adding one
    /// role sent `{"roles": [every role they hold, plus it]}`.
    @discardableResult
    public func setRoles(_ roleIDs: [RoleID], of userID: UserID, in guildID: GuildID) async throws -> Member? {
        struct Body: Encodable { var roles: [String] }
        return try await memberWrite(
            userID, in: guildID, body: Body(roles: roleIDs.map { String($0.rawValue) })
        )
    }

    /// Verify / Unverify Member: the member's flags, with the bypass bit set
    /// or cleared and every other bit carried.
    @discardableResult
    public func setMemberFlags(_ flags: MemberFlags, of userID: UserID, in guildID: GuildID) async throws -> Member? {
        struct Body: Encodable { var flags: Int }
        return try await memberWrite(userID, in: guildID, body: Body(flags: flags.rawValue))
    }

    /// Server Mute.
    public func setServerMute(_ isMuted: Bool, of userID: UserID, in guildID: GuildID) async throws {
        struct Body: Encodable { var mute: Bool }
        _ = try await memberWrite(userID, in: guildID, body: Body(mute: isMuted))
    }

    /// Server Deafen.
    public func setServerDeafen(_ isDeafened: Bool, of userID: UserID, in guildID: GuildID) async throws {
        struct Body: Encodable { var deaf: Bool }
        _ = try await memberWrite(userID, in: guildID, body: Body(deaf: isDeafened))
    }

    /// Moves somebody to another voice channel, or with `nil`, disconnects
    /// them — Discord's `setChannel`.
    public func moveMember(_ userID: UserID, in guildID: GuildID, to channelID: ChannelID?) async throws {
        struct Body: Encodable { @ExplicitNull var channel_id: String? }
        _ = try await memberWrite(
            userID, in: guildID, body: Body(channel_id: channelID.map { String($0.rawValue) })
        )
    }

    private func memberWrite<Body: Encodable>(
        _ userID: UserID,
        in guildID: GuildID,
        body: Body,
        headers: [String: String] = [:]
    ) async throws -> Member? {
        let data = try await requestData(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)/members/\(userID.rawValue)",
            route: "guilds/{id}/members/{id}",
            body: body,
            headers: headers
        )
        guard !data.isEmpty, let member = try? Self.decoder.decode(MemberDTO.self, from: data) else {
            return nil
        }
        return member.domain(userID: member.user?.id ?? userID)
    }

    // MARK: Pruning

    /// How many people a prune would remove — Discord's `updateEstimate`. The
    /// roles go as repeated keys, the way its HTTP layer writes an array.
    public func pruneEstimate(in guildID: GuildID, days: Int, includeRoles: [RoleID]) async throws -> Int {
        struct Answer: Decodable { var pruned: Int? }
        var query = [URLQueryItem(name: "days", value: String(days))]
        for role in includeRoles {
            query.append(URLQueryItem(name: "include_roles", value: String(role.rawValue)))
        }
        return try await get(
            "/guilds/\(guildID.rawValue)/prune",
            route: "guilds/{id}/prune",
            query: query,
            as: Answer.self
        ).pruned ?? 0
    }

    /// Prunes. `compute_prune_count: false`, as Discord's own button sends it —
    /// the count was the estimate.
    public func prune(in guildID: GuildID, days: Int, includeRoles: [RoleID]) async throws {
        struct Body: Encodable {
            var days: Int
            var compute_prune_count: Bool
            var include_roles: [String]
        }
        _ = try await requestData(
            method: "POST",
            path: "/guilds/\(guildID.rawValue)/prune",
            route: "guilds/{id}/prune",
            body: Body(
                days: days,
                compute_prune_count: false,
                include_roles: includeRoles.map { String($0.rawValue) }
            )
        )
    }

    // MARK: Mod View

    /// How people got in — Mod View's Join Method, for somebody the Members
    /// table did not search for. `{user_ids}` up, and one
    /// `{user_id, join_source_type, source_invite_code, inviter_id}` back per
    /// person: the fields Discord's member-safety store maps (`151781`).
    public func memberSupplemental(
        in guildID: GuildID,
        userIDs: [UserID]
    ) async throws -> [UserID: GuildMemberRow.JoinSource] {
        struct Body: Encodable { var user_ids: [String] }
        struct Entry: Decodable {
            var user_id: UserID
            var join_source_type: Int?
            var source_invite_code: String?
            var inviter_id: UserID?
        }
        let entries = try await request(
            method: "POST",
            path: "/guilds/\(guildID.rawValue)/members/supplemental",
            route: "guilds/{id}/members/supplemental",
            body: Body(user_ids: userIDs.map { String($0.rawValue) }),
            as: [Entry].self
        )
        var sources: [UserID: GuildMemberRow.JoinSource] = [:]
        for entry in entries {
            sources[entry.user_id] = GuildMemberRow.JoinSource(
                rawValue: entry.join_source_type,
                code: entry.source_invite_code,
                inviterID: entry.inviter_id
            )
        }
        return sources
    }

    /// Mod View's Server Activity: how many messages, links and media somebody
    /// has posted here — `POST /messages/search/tabs`, the captured body to the
    /// key, answered with three `total_results`.
    public func activityCounts(of userID: UserID, in guildID: GuildID) async throws -> MemberActivityCounts {
        let author = [String(userID.rawValue)]
        let body = SearchTabsBody(tabs: .init(
            messages: .init(author_id: author),
            links: .init(author_id: author, has: ["link"]),
            media: .init(author_id: author, attachment_extension: MemberActivityCounts.mediaExtensions)
        ))
        let answer = try await request(
            method: "POST",
            path: "/guilds/\(guildID.rawValue)/messages/search/tabs",
            route: "guilds/{id}/messages/search/tabs",
            body: body,
            as: SearchTabsDTO.self
        )
        return MemberActivityCounts(
            messages: answer.tabs?.messages?.total_results ?? 0,
            links: answer.tabs?.links?.total_results ?? 0,
            media: answer.tabs?.media?.total_results ?? 0
        )
    }
}

/// Discord's URL encoding for a header value: everything but the unreserved
/// set — what `encodeURIComponent` leaves alone.
extension CharacterSet {
    static let urlUnreservedSet: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-_.!~*'()")
        return set
    }()
}

// MARK: - Search tabs

struct SearchTabsBody: Encodable {
    var tabs: Tabs
    var track_exact_total_hits = true
    var include_nsfw = true

    struct Tabs: Encodable {
        var messages: Tab
        var links: Tab
        var media: Tab
    }

    /// One tab of the captured body: `limit: 1` and an explicit `cursor:
    /// null`, which the capture sends on all three.
    struct Tab: Encodable {
        var author_id: [String]
        var has: [String]?
        var attachment_extension: [String]?
        var limit = 1
        @ExplicitNull var cursor: String?

        init(author_id: [String], has: [String]? = nil, attachment_extension: [String]? = nil) {
            self.author_id = author_id
            self.has = has
            self.attachment_extension = attachment_extension
            self.cursor = nil
        }
    }
}

struct SearchTabsDTO: Decodable, Sendable {
    var tabs: Tabs?

    struct Tabs: Decodable, Sendable {
        var messages: Tab?
        var links: Tab?
        var media: Tab?
    }

    struct Tab: Decodable, Sendable {
        var total_results: Int?
    }
}
