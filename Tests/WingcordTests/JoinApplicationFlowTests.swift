import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// Apply to Join, driven through the real store.
///
/// The button used to raise the onboarding gate — a surface drawn only for
/// the selected server, which an outsider cannot select — so it did nothing.
/// These pin where each way in now lands.
@Suite("Applying to join")
@MainActor
struct JoinApplicationFlowTests {

    private let guildID = GuildID(rawValue: 2000)
    private let readerID = UserID(rawValue: 1)

    private let applicationFeatures: Set<String> = [
        "MEMBER_VERIFICATION_GATE_ENABLED",
        "MEMBER_VERIFICATION_MANUAL_APPROVAL",
    ]

    @Test("Apply to Join on a server's card opens its application, not the gate")
    func applyOpensTheForm() {
        let model = AppModel()
        model.currentUserID = readerID
        model.guildProfiles[guildID] = GuildProfile(
            id: guildID,
            name: "Yoho Club",
            features: applicationFeatures,
            visibility: 3
        )
        #expect(model.guildEntry(for: guildID, profile: model.guildProfiles[guildID], isJoined: false) == .apply)

        model.enterGuild(guildID)
        #expect(model.joinApplicationRequest?.guildID == guildID)
        #expect(model.joinGate == nil)
    }

    @Test("A pending member whose server asks questions is offered the application, once")
    func pendingMemberGetsTheApplication() {
        let model = AppModel()
        model.currentUserID = readerID
        model.guilds[guildID] = Guild(
            id: guildID,
            name: "Yoho Club",
            ownerID: UserID(rawValue: 99),
            features: applicationFeatures
        )
        model.members[guildID] = [
            readerID: Member(userID: readerID, roleIDs: [], joinedAt: .now, isPending: true)
        ]
        model.selectedGuildID = guildID
        model.memberVerifications[guildID] = MemberVerification(
            guildID: guildID,
            version: "2026-09-04T04:22:35.782535+00:00",
            fields: [
                .init(kind: .terms(["Be kind."]), label: "Read and agree to the server rules"),
                .init(kind: .textInput, label: "Why do you want to join our server?"),
            ]
        )

        // An agreement alone is a form the server refuses.
        #expect(!model.joinGateHasRules(inGuild: guildID))

        model.offerJoinGateIfNeeded(guildID)
        #expect(model.joinApplicationRequest?.guildID == guildID)
        #expect(model.joinGate == nil)

        model.joinApplicationRequest = nil
        model.offerJoinGateIfNeeded(guildID)
        #expect(model.joinApplicationRequest == nil)
    }

    @Test("An application already waiting on a moderator is not offered again")
    func waitingApplicationIsNotReoffered() {
        let model = AppModel()
        model.currentUserID = readerID
        model.members[guildID] = [
            readerID: Member(userID: readerID, roleIDs: [], joinedAt: .now, isPending: true)
        ]
        model.selectedGuildID = guildID
        model.ownJoinRequests[guildID] = OwnJoinRequest(guildID: guildID, status: .submitted)
        model.memberVerifications[guildID] = MemberVerification(
            guildID: guildID,
            version: "v",
            fields: [.init(kind: .paragraph, label: "Tell us about yourself")]
        )
        model.offerJoinGateIfNeeded(guildID)
        #expect(model.joinApplicationRequest == nil)
    }

    @Test("The form's card names an outsider's server from the form itself")
    func cardFromOutsider() {
        let model = AppModel()
        let card = model.joinApplicationCard(
            for: guildID,
            outsider: JoinApplicationGuild(id: guildID, name: "Yoho Club", memberCount: 1200, onlineCount: 300)
        )
        #expect(card.name == "Yoho Club")
        #expect(card.memberCount == 1200)
        #expect(card.onlineCount == 300)
        #expect(card.entry == .none)
    }
}
