import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The moderator's review on the Members page, through the real store with
/// its routes replaced: Reject's reason, Interview, and a list that moves with
/// the socket.
@Suite("Application review")
@MainActor
struct ApplicationReviewTests {

    private let guildID = GuildID(rawValue: 1)

    /// What the store asked its routes, in order.
    @MainActor
    final class Calls {
        var resolved: [(UInt64, Bool, String?)] = []
        var interviewed: [UInt64] = []
        var listed: [GuildJoinRequest.Status] = []
        var answers: [GuildJoinRequest.Status: [GuildJoinRequest]] = [:]
    }

    private func store(_ calls: Calls) -> MemberSafetyStore {
        MemberSafetyStore(
            guildID: guildID,
            applications: MemberSafetyStore.Applications(
                list: { _, status in
                    calls.listed.append(status)
                    return calls.answers[status] ?? []
                },
                resolve: { _, id, approve, reason in calls.resolved.append((id, approve, reason)) },
                interview: { request in calls.interviewed.append(request.id) }
            ),
            search: { _, _, _ in nil }
        )
    }

    private func request(_ id: UInt64, _ status: GuildJoinRequest.Status = .submitted) -> GuildJoinRequest {
        GuildJoinRequest(id: id, userID: UserID(rawValue: id), username: "u\(id)", status: status)
    }

    /// Lets the store's tasks run.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    @Test("A rejection carries its reason; an approval never does")
    func reasons() async {
        let calls = Calls()
        let store = store(calls)
        store.resolve(request(5), approve: false, reason: "Spam")
        await settle()
        store.resolve(request(6), approve: true, reason: "ignored")
        await settle()
        #expect(calls.resolved.map(\.0) == [5, 6])
        #expect(calls.resolved[0].2 == "Spam")
        #expect(calls.resolved[1].2 == nil)
    }

    @Test("Interview asks once per press, not twice while one is running")
    func interviewOnce() async {
        let calls = Calls()
        let store = store(calls)
        store.interview(request(5))
        store.interview(request(5))
        await settle()
        #expect(calls.interviewed == [5])
    }

    @Test("Somebody's application moving refreshes the open tab and forgets the others")
    func liveList() async {
        let calls = Calls()
        calls.answers[.submitted] = [request(1)]
        calls.answers[.rejected] = [request(2, .rejected)]
        let store = store(calls)
        store.show(.applications(.rejected))
        await settle()
        store.show(.applications(.submitted))
        await settle()
        #expect(store.applications[.rejected]?.count == 1)

        calls.answers[.submitted] = [request(1), request(3)]
        store.applicationsDidChange(in: guildID)
        // The rows stay up while the answer is on its way…
        #expect(store.applications[.submitted]?.count == 1)
        #expect(store.applications[.rejected] == nil)
        await settle()
        // …and the answer replaces them.
        #expect(store.applications[.submitted]?.map(\.id) == [1, 3])

        // Another server's moves are not this list's.
        store.applicationsDidChange(in: GuildID(rawValue: 99))
        #expect(calls.listed.last == .submitted)
    }

    @Test("An interview this client already has is opened without asking")
    func knownInterview() async throws {
        let model = AppModel()
        let channelID = ChannelID(rawValue: 900)
        var index = ChannelIndex()
        index.replacePrivateChannels([
            Channel(id: channelID, kind: .directMessage, recipientIDs: [UserID(rawValue: 7)]),
        ])
        model.channelIndex = index
        model.selectedGuildID = guildID

        var pending = request(5)
        pending.interviewChannelID = channelID
        try await model.enterJoinRequestInterview(pending)
        #expect(model.selectedGuildID == nil)
        #expect(model.selectedChannelID == channelID)
    }
}
