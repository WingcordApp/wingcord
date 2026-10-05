import Foundation
import Testing
@testable import WingcordCore
@testable import WingcordNet

/// The moderation routes, pinned on the requests the client makes.
///
/// The HAR behind this surface watched the role writes, the search, the Mod
/// View counts and the per-person audit log and none of the acts themselves,
/// so these are Discord's action creators (`66834`, `144073`) written down:
/// a kick's reason in its query, every other reason in `X-Audit-Log-Reason`,
/// a timeout as an instant, and nil as an explicit `null`.
@Suite("Moderation on the wire")
struct ModerationWireTests {

    private let guild = GuildID(rawValue: 1)
    private let user = UserID(rawValue: 2)

    @Test("Kick puts its reason in the query and sends no audit header")
    func kick() async throws {
        let (rest, token) = await RequestRecorder.client(status: 204, body: "")
        try await rest.kickMember(user, in: guild, reason: "spam links")
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.method == "DELETE")
        #expect(request.path == "/api/v9/guilds/1/members/2")
        #expect(request.query["reason"] == "spam links")
        #expect(request.headers["X-Audit-Log-Reason"] == nil)
    }

    @Test("Ban sends seconds of history and an encoded audit reason")
    func ban() async throws {
        let (rest, token) = await RequestRecorder.client(status: 204, body: "")
        try await rest.banMember(user, in: guild, deleteMessageSeconds: 3600, reason: "Breaking server rules")
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.method == "PUT")
        #expect(request.path == "/api/v9/guilds/1/bans/2")
        #expect(request.json?["delete_message_seconds"] as? Int == 3600)
        #expect(request.headers["X-Audit-Log-Reason"] == "Breaking%20server%20rules")
    }

    @Test("Bulk ban posts string ids to version two")
    func bulkBan() async throws {
        let (rest, token) = await RequestRecorder.client()
        try await rest.bulkBan(
            [UserID(rawValue: 7), UserID(rawValue: 8)],
            in: guild,
            deleteMessageSeconds: 0,
            reason: "Suspicious or spam account"
        )
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/v9/guilds/1/bulk-ban/v2")
        #expect(request.json?["user_ids"] as? [String] == ["7", "8"])
        #expect(request.json?["delete_message_seconds"] as? Int == 0)
        #expect(request.headers["X-Audit-Log-Reason"] == "Suspicious%20or%20spam%20account")
    }

    @Test("A timeout is the instant it ends, and lifting it sends null")
    func timeout() async throws {
        let (rest, token) = await RequestRecorder.client()
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try await rest.timeOutMember(user, in: guild, until: end, reason: "cool off")
        _ = try await rest.timeOutMember(user, in: guild, until: nil)
        let requests = RequestRecorder.requests(for: token)
        #expect(requests.count == 2)
        let set = try #require(requests.first)
        #expect(set.method == "PATCH")
        #expect(set.path == "/api/v9/guilds/1/members/2")
        let stamp = try #require(set.json?["communication_disabled_until"] as? String)
        #expect(stamp.hasPrefix("2027-01-15T08:00:00"))
        #expect(set.headers["X-Audit-Log-Reason"] == "cool%20off")
        #expect(requests.last?.json?["communication_disabled_until"] is NSNull)
    }

    @Test("Nickname, roles, flags and a disconnect are member PATCHes")
    func memberWrites() async throws {
        let (rest, token) = await RequestRecorder.client()
        _ = try await rest.setNickname("", of: user, in: guild)
        _ = try await rest.setRoles([RoleID(rawValue: 5), RoleID(rawValue: 6)], of: user, in: guild)
        _ = try await rest.setMemberFlags([.bypassesVerification, .completedOnboarding], of: user, in: guild)
        try await rest.moveMember(user, in: guild, to: nil)
        let requests = RequestRecorder.requests(for: token)
        #expect(requests.map(\.method) == ["PATCH", "PATCH", "PATCH", "PATCH"])
        #expect(requests[0].json?["nick"] as? String == "")
        #expect(requests[1].json?["roles"] as? [String] == ["5", "6"])
        #expect(requests[2].json?["flags"] as? Int == 6)
        #expect(requests[3].json?["channel_id"] is NSNull)
    }

    @Test("A member write answers with the member, decoded")
    func memberAnswer() async throws {
        let (rest, _) = await RequestRecorder.client(body: """
        {"user": {"id": "2", "username": "alex"}, "nick": "Al", "roles": ["5"],
         "joined_at": "2024-01-01T00:00:00+00:00", "flags": 4}
        """)
        let member = try #require(try await rest.setNickname("Al", of: user, in: guild))
        #expect(member.userID == user)
        #expect(member.nickname == "Al")
        #expect(member.roleIDs == [RoleID(rawValue: 5)])
        #expect(member.flags.contains(.bypassesVerification))
    }

    @Test("Prune's estimate repeats include_roles, and the prune does not count")
    func prune() async throws {
        let (rest, token) = await RequestRecorder.client(body: #"{"pruned": 12}"#)
        let count = try await rest.pruneEstimate(
            in: guild, days: 7, includeRoles: [RoleID(rawValue: 3), RoleID(rawValue: 4)]
        )
        #expect(count == 12)
        try await rest.prune(in: guild, days: 30, includeRoles: [RoleID(rawValue: 3)])
        let requests = RequestRecorder.requests(for: token)
        let estimate = try #require(requests.first)
        #expect(estimate.method == "GET")
        #expect(estimate.path == "/api/v9/guilds/1/prune")
        #expect(estimate.queryItems.filter { $0.name == "include_roles" }.map(\.value) == ["3", "4"])
        #expect(estimate.query["days"] == "7")
        let prune = try #require(requests.last)
        #expect(prune.method == "POST")
        #expect(prune.json?["days"] as? Int == 30)
        #expect(prune.json?["compute_prune_count"] as? Bool == false)
        #expect(prune.json?["include_roles"] as? [String] == ["3"])
    }

    @Test("Mod View's counts are the captured tabs body")
    func activityCounts() async throws {
        let (rest, token) = await RequestRecorder.client(body: """
        {"tabs": {"messages": {"total_results": 41}, "links": {"total_results": 3},
                  "media": {"total_results": 9}}}
        """)
        let counts = try await rest.activityCounts(of: user, in: guild)
        #expect(counts == MemberActivityCounts(messages: 41, links: 3, media: 9))
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.path == "/api/v9/guilds/1/messages/search/tabs")
        let body = try #require(request.json)
        #expect(body["track_exact_total_hits"] as? Bool == true)
        #expect(body["include_nsfw"] as? Bool == true)
        let tabs = try #require(body["tabs"] as? [String: Any])
        let links = try #require(tabs["links"] as? [String: Any])
        #expect(links["author_id"] as? [String] == ["2"])
        #expect(links["has"] as? [String] == ["link"])
        #expect(links["limit"] as? Int == 1)
        #expect(links["cursor"] is NSNull)
        let media = try #require(tabs["media"] as? [String: Any])
        #expect(media["attachment_extension"] as? [String] == MemberActivityCounts.mediaExtensions)
    }

    @Test("Mod View's audit log asks for one target, as captured")
    func auditLogForTarget() async throws {
        let (rest, token) = await RequestRecorder.client(body: #"{"audit_log_entries": []}"#)
        _ = try await rest.auditLog(in: guild, limit: 50, targetID: 2)
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.path == "/api/v9/guilds/1/audit-logs")
        #expect(request.queryItems.map(\.name) == ["limit", "target_id"])
        #expect(request.query["target_id"] == "2")
    }

    @Test("Join method comes from members/supplemental")
    func supplemental() async throws {
        let (rest, token) = await RequestRecorder.client(body: """
        [{"user_id": "2", "join_source_type": 5, "source_invite_code": "abc", "inviter_id": "9"}]
        """)
        let sources = try await rest.memberSupplemental(in: guild, userIDs: [user])
        #expect(sources[user] == .invite(code: "abc", inviterID: UserID(rawValue: 9)))
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/v9/guilds/1/members/supplemental")
        #expect(request.json?["user_ids"] as? [String] == ["2"])
    }

    @Test("GUILD_BULK_BAN_UPDATE says who was banned and who was not")
    func bulkBanOutcome() throws {
        let frame = try JSONDecoder().decode(GatewayFrame.self, from: Data("""
        {"op": 0, "s": 9, "t": "GUILD_BULK_BAN_UPDATE", "d": {"guild_id": "1",
          "bulk_ban": {"banned_users": ["7"], "failed_users": ["8"]}}}
        """.utf8))
        guard case .bulkBanFinished(let guildID, let banned, let failed)? = GatewayUpdate(frame.payload) else {
            Issue.record("not a bulk ban outcome")
            return
        }
        #expect(guildID == guild)
        #expect(banned == [UserID(rawValue: 7)])
        #expect(failed == [UserID(rawValue: 8)])
    }
}
