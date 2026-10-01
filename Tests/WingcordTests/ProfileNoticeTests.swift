import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// The profile's own small rules from this batch: Discord's partial-profile
/// notice (`559506`) and where a mutual server goes.
@MainActor
@Suite("Profile notices")
struct ProfileNoticeTests {

    private let me = UserID(rawValue: 1)
    private let them = UserID(rawValue: 7)

    private func model() -> AppModel {
        let model = AppModel()
        model.currentUserID = me
        model.users[me] = User(id: me, username: "alex")
        model.users[them] = User(id: them, username: "stranger")
        return model
    }

    @Test("A refused profile says so — for a stranger, never for a friend or a request")
    func partialNotice() throws {
        let model = model()
        let request = ProfileRequest(userID: them, anchor: .zero)
        #expect(model.profilePresentation(for: request)?.isPartlyUnavailable == false)

        model.profileFetchFailures.insert(them)
        #expect(model.profilePresentation(for: request)?.isPartlyUnavailable == true)

        model.relationships[them] = .friend
        #expect(model.profilePresentation(for: request)?.isPartlyUnavailable == false)
        model.relationships[them] = .incomingRequest
        #expect(model.profilePresentation(for: request)?.isPartlyUnavailable == false)
        // An outgoing request is still a stranger's profile.
        model.relationships[them] = .outgoingRequest
        #expect(model.profilePresentation(for: request)?.isPartlyUnavailable == true)
    }

    @Test("A mutual server pressed goes there and closes the profile")
    func mutualServerOpens() {
        let model = model()
        let guildID = GuildID(rawValue: 100)
        model.guilds[guildID] = Guild(id: guildID, name: "Shared", ownerID: me)
        model.profileRequest = ProfileRequest(userID: them, anchor: .zero)
        model.openMutualServer(guildID)
        #expect(model.profileRequest == nil)
        #expect(model.selectedGuildID == guildID)
    }
}
