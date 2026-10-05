import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// A moderator's side of Apply to Join on the wire: the list's verdict and
/// interview fields, Reject's reason, and Interview.
@Suite("Application review on the wire")
struct ApplicationReviewWireTests {

    private let guild = GuildID(rawValue: 1)

    @Test("A judged application carries who judged it, when, and its interview")
    func verdictFields() async throws {
        let body = """
        {"guild_join_requests":[
          {"id":"5","user_id":"7","user":{"id":"7","username":"sailor"},
           "application_status":"REJECTED","rejection_reason":"Not right now",
           "interview_channel_id":"900","actioned_at":"1547468630937201550",
           "actioned_by_user":{"id":"2","username":"captain","global_name":"The Captain"}},
          {"id":"6","user_id":"8","user":{"id":"8","username":"deckhand"},
           "application_status":"APPROVED","actioned_at":"2026-09-10T04:47:52+00:00"}
        ],"total":2}
        """
        let (rest, token) = await RequestRecorder.client(body: body)
        let requests = try await rest.joinRequests(in: guild, status: .rejected)
        let sent = try #require(RequestRecorder.requests(for: token).first)
        #expect(sent.path == "/api/v9/guilds/1/requests")
        #expect(sent.query["status"] == "REJECTED")

        let rejected = try #require(requests.first)
        #expect(rejected.interviewChannelID == ChannelID(rawValue: 900))
        #expect(rejected.actionedByName == "The Captain")
        // A snowflake's own moment: 2026-09-10.
        let day = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: try #require(rejected.actionedAt))
        #expect(day.year == 2026 && day.month == 9 && day.day == 10)
        #expect(rejected.rejectionReason == "Not right now")

        // A date where a snowflake was expected is still read, never a failure.
        #expect(requests[1].actionedAt != nil)
        #expect(requests[1].actionedByName == nil)
    }

    @Test("Reject sends its reason; Approve never does")
    func rejectReason() async throws {
        let (rest, token) = await RequestRecorder.client(status: 200, body: "{}")
        try await rest.resolveJoinRequest(5, in: guild, approve: false, reason: "Spam")
        try await rest.resolveJoinRequest(6, in: guild, approve: true, reason: "ignored")
        let requests = RequestRecorder.requests(for: token)
        #expect(requests[0].method == "PATCH")
        #expect(requests[0].path == "/api/v9/guilds/1/requests/5")
        #expect(requests[0].json?["action"] as? String == "REJECTED")
        #expect(requests[0].json?["rejection_reason"] as? String == "Spam")
        #expect(requests[1].json?["action"] as? String == "APPROVED")
        #expect(requests[1].json?["rejection_reason"] == nil)
    }

    @Test("Interview posts to the request's interview path and reads the channel")
    func interview() async throws {
        let (rest, token) = await RequestRecorder.client(
            status: 200,
            body: #"{"id":"900","type":1,"recipients":[{"id":"7","username":"sailor"}]}"#
        )
        let channel = try await rest.openJoinRequestInterview(5)
        let sent = try #require(RequestRecorder.requests(for: token).first)
        #expect(sent.method == "POST")
        #expect(sent.path == "/api/v9/join-requests/5/interview")
        #expect(channel.id == ChannelID(rawValue: 900))
        #expect(channel.kind == .directMessage)
    }
}
