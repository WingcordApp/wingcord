import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// The reader's own applications on the wire: READY's `guild_join_requests`,
/// the socket's three `GUILD_JOIN_REQUEST_*` events, and the routes behind the
/// Pending Applications folder.
///
/// The request object is the one `member-verification.har` caught the submit's
/// `PUT` answering with; READY and the events are Discord's own readers of the
/// same shape (`212455`'s `_`, and the socket handlers beside `INTERACTION_*`).
@Suite("The reader's own applications on the wire")
struct OwnJoinRequestWireTests {

    /// The captured answer, verbatim.
    private static let captured = #"""
    {"created_at":"2026-09-10T04:47:52.192000+00:00","reviewed_at":null,"join_request_id":"1547468630937201550","id":"1547468630937201550","rejection_reason":null,"application_status":"SUBMITTED","last_seen":null,"guild_id":"1520138745897241889","user_id":"987654321987654321","interview_channel_id":null}
    """#

    private let yoho = GuildID(rawValue: 1_520_138_745_897_241_889)
    private let reader = UserID(rawValue: 987_654_321_987_654_321)

    private static func snapshot(_ json: String) throws -> ReadySnapshot {
        ReadySnapshot(payload: try JSONDecoder().decode(ReadyPayload.self, from: Data(json.utf8)))
    }

    private static func update(_ json: String) throws -> GatewayUpdate? {
        let frame = try JSONDecoder().decode(GatewayFrame.self, from: Data(json.utf8))
        return GatewayUpdate(frame.payload)
    }

    @Test("The captured request reads as a submitted application with its id")
    func capturedRequest() throws {
        let dto = try JSONDecoder().decode(OwnJoinRequestDTO.self, from: Data(Self.captured.utf8))
        let request = try #require(dto.domain)
        #expect(request.guildID == yoho)
        #expect(request.requestID == JoinRequestID(rawValue: 1_547_468_630_937_201_550))
        #expect(request.status == .submitted)
        #expect(request.rejectionReason == nil)
        #expect(!request.isOutcomeSeen)
        #expect(dto.user_id == reader)
    }

    @Test("READY files every application under its server")
    func readyCarriesApplications() throws {
        let ready = try Self.snapshot("""
        {
          "session_id": "s",
          "user": { "id": "987654321987654321", "username": "reader" },
          "guild_join_requests": [
            \(Self.captured),
            { "guild_id": "2000", "user_id": "987654321987654321",
              "application_status": "REJECTED", "rejection_reason": "Not right now",
              "last_seen": "2026-09-11T10:00:00+00:00" }
          ]
        }
        """)
        #expect(ready.joinRequests.count == 2)
        #expect(ready.joinRequests[yoho]?.status == .submitted)
        let denied = try #require(ready.joinRequests[GuildID(rawValue: 2000)])
        #expect(denied.status == .rejected)
        #expect(denied.rejectionReason == "Not right now")
        #expect(denied.isOutcomeSeen)
    }

    @Test("A list READY cannot read costs the list, never the session")
    func malformedListIsDropped() throws {
        // An element of the wrong shape is skipped; the rest are kept.
        let partial = try Self.snapshot("""
        { "session_id": "s", "user": { "id": "1", "username": "reader" },
          "guild_join_requests": [ 7, \(Self.captured) ] }
        """)
        #expect(Array(partial.joinRequests.keys) == [yoho])

        // Not a list at all reads as none.
        let wrongShape = try Self.snapshot("""
        { "session_id": "s", "user": { "id": "1", "username": "reader" },
          "guild_join_requests": { "entries": [] } }
        """)
        #expect(wrongShape.joinRequests.isEmpty)

        let absent = try Self.snapshot(#"{ "session_id": "s", "user": { "id": "1", "username": "reader" } }"#)
        #expect(absent.joinRequests.isEmpty)
    }

    @Test("An entry with fields of other types is still filed under its server")
    func lenientEntry() throws {
        // READY's own entries have never been captured: a reason that is not a
        // string, an applicant that is not an id, a `last_seen` that is a
        // number, and keys nothing reads must not cost the application.
        let ready = try Self.snapshot("""
        { "session_id": "s", "user": { "id": "1", "username": "reader" },
          "guild_join_requests": [
            { "guild_id": "1520138745897241889", "join_request_id": "5",
              "application_status": "SUBMITTED", "rejection_reason": 5,
              "user_id": { "id": "987654321987654321" }, "last_seen": 1757500000000,
              "form_responses": [ { "field_type": "TERMS" } ] } ] }
        """)
        let request = try #require(ready.joinRequests[yoho])
        #expect(request.status == .submitted)
        #expect(request.requestID == JoinRequestID(rawValue: 5))
        #expect(request.rejectionReason == nil)
        #expect(request.isOutcomeSeen)
    }

    @Test("Create and update are one change, filed under the envelope's server, with the applicant")
    func upsertEvents() throws {
        for name in ["GUILD_JOIN_REQUEST_CREATE", "GUILD_JOIN_REQUEST_UPDATE"] {
            let update = try Self.update("""
            {"op": 0, "s": 9, "t": "\(name)", "d": {
              "guild_id": "1520138745897241889", "status": "REJECTED",
              "request": { "user_id": "987654321987654321", "application_status": "REJECTED",
                           "rejection_reason": "spam", "join_request_id": "5" } }}
            """)
            guard case .joinRequestChanged(let request, let userID) = update else {
                Issue.record("\(name) is not a join request change")
                continue
            }
            #expect(request.guildID == yoho)
            #expect(request.status == .rejected)
            #expect(request.rejectionReason == "spam")
            #expect(request.requestID == JoinRequestID(rawValue: 5))
            #expect(userID == reader)
        }
    }

    @Test("A create with no request in it is not a change")
    func emptyUpsertIsNothing() throws {
        let update = try Self.update("""
        {"op": 0, "s": 9, "t": "GUILD_JOIN_REQUEST_CREATE", "d": { "guild_id": "1", "request": null }}
        """)
        #expect(update == nil)
    }

    @Test("A delete names the server and the applicant")
    func deleteEvent() throws {
        let update = try Self.update("""
        {"op": 0, "s": 9, "t": "GUILD_JOIN_REQUEST_DELETE", "d": {
          "id": "5", "user_id": "987654321987654321", "guild_id": "1520138745897241889" }}
        """)
        guard case .joinRequestRemoved(let guildID, let userID) = update else {
            Issue.record("not a join request removal")
            return
        }
        #expect(guildID == yoho)
        #expect(userID == reader)
    }

    @Test("Statuses are Discord's four, and an approval seen is finished with")
    func statuses() {
        #expect(OwnJoinRequest.Status(rawValue: "STARTED") == .started)
        #expect(OwnJoinRequest.Status(rawValue: "SUBMITTED") == .submitted)
        #expect(OwnJoinRequest.Status(rawValue: "REJECTED") == .rejected)
        #expect(OwnJoinRequest.Status(rawValue: "APPROVED") == .approved)
        #expect(OwnJoinRequest.Status(rawValue: "MARINATING") == .unknown("MARINATING"))
        #expect(OwnJoinRequest.Status(rawValue: nil) == .unknown(""))

        #expect(OwnJoinRequest(guildID: yoho, status: .approved, isOutcomeSeen: true).isSettled)
        #expect(!OwnJoinRequest(guildID: yoho, status: .rejected, isOutcomeSeen: true).isSettled)
        #expect(OwnJoinRequest(guildID: yoho, status: .approved).isUnseenApproval)
    }

    // MARK: Routes

    @Test("The server list carries the splash and the features the page reads")
    func joinRequestGuilds() async throws {
        let (rest, token) = await RequestRecorder.client(
            status: 200,
            body: #"[{"id":"1520138745897241889","name":"yoho club","icon":"e052d03ae55fbb122f21b6b01f67c255","description":"welcome to yoho club","home_header":null,"splash":"abc","discovery_splash":null,"features":["GUILD_TAGS","MEMBER_VERIFICATION_GATE_ENABLED","COMMUNITY","MEMBER_VERIFICATION_MANUAL_APPROVAL"]}]"#
        )
        let guilds = try await rest.joinRequestGuilds()
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.method == "GET")
        #expect(request.path == "/api/v9/users/@me/join-request-guilds")

        let guild = try #require(guilds.first)
        #expect(guild.name == "yoho club")
        #expect(guild.splashHash == "abc")
        #expect(guild.acceptsApplications)
    }

    @Test("Reapply posts to the request path and reads the answer as the request")
    func reapply() async throws {
        let (rest, token) = await RequestRecorder.client(
            status: 200,
            body: #"{"guild_id":"1520138745897241889","user_id":"1","application_status":"STARTED","join_request_id":"9"}"#
        )
        let request = try await rest.resetJoinRequest(inGuild: yoho)
        let sent = try #require(RequestRecorder.requests(for: token).first)
        #expect(sent.method == "POST")
        #expect(sent.path == "/api/v9/guilds/1520138745897241889/requests/@me")
        #expect(request?.status == .started)
        #expect(request?.requestID == JoinRequestID(rawValue: 9))
    }

    @Test("An answer Reapply cannot read is still a success, with nothing to file")
    func reapplyUnreadable() async throws {
        let (rest, _) = await RequestRecorder.client(status: 204, body: "")
        #expect(try await rest.resetJoinRequest(inGuild: yoho) == nil)
    }

    @Test("Acknowledging an approval posts to the request's own ack path")
    func acknowledge() async throws {
        let (rest, token) = await RequestRecorder.client(status: 204, body: "")
        try await rest.acknowledgeJoinRequest(inGuild: yoho, requestID: JoinRequestID(rawValue: 9))
        let sent = try #require(RequestRecorder.requests(for: token).first)
        #expect(sent.method == "POST")
        #expect(sent.path == "/api/v9/guilds/1520138745897241889/requests/9/ack")
    }
}
