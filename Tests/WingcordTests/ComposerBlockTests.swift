import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The bar in the message box's place, Discord's list in Discord's order
/// (docs/BETA3.md §2.3).
@MainActor
@Suite("Composer bars")
struct ComposerBlockTests {
    private let guildID = GuildID(rawValue: 1_000)
    private let channelID = ChannelID(rawValue: 2_000)
    /// A made-up account from Discord's first days (a small id dates to 2015),
    /// so the account-age wait never applies by accident.
    private let readerID = UserID(rawValue: 42)

    private func model(
        level: VerificationLevel? = nil,
        features: Set<String> = [],
        isPending: Bool = false,
        roles: [RoleID] = [],
        joinedAt: Date = .distantPast,
        verification: AccountVerification? = AccountVerification(isEmailVerified: true, isPhoneVerified: true),
        kind: ChannelKind = .text
    ) -> AppModel {
        let model = AppModel()
        model.currentUserID = readerID
        model.guilds[guildID] = Guild(
            id: guildID,
            name: "Somewhere",
            ownerID: UserID(rawValue: 99),
            features: features,
            verificationLevel: level
        )
        model.members[guildID] = [
            readerID: Member(userID: readerID, roleIDs: roles, joinedAt: joinedAt, isPending: isPending)
        ]
        var index = ChannelIndex()
        index.replaceChannels([Channel(id: channelID, kind: kind, guildID: guildID, name: "general")], inGuild: guildID)
        model.channelIndex = index
        model.accountVerification = verification
        return model
    }

    @Test("A pending member in a server with rules gets Complete")
    func pendingMemberCompletes() {
        let model = model(features: [SessionController.verificationFeature], isPending: true)
        let block = model.composerBlock(in: channelID)
        #expect(block == .completeSteps)
        #expect(block?.message == "You must complete a few more steps before you can talk.")
        #expect(block?.button?.title == "Complete")
        #expect(block?.button?.action == .complete)
    }

    @Test("An application in review, and a refused one, say so")
    func applicationStates() {
        let model = model(features: [SessionController.verificationFeature], isPending: true)
        model.ownJoinRequests[guildID] = OwnJoinRequest(guildID: guildID, status: .submitted)
        #expect(model.composerBlock(in: channelID) == .applicationAwaitingReview)
        #expect(model.composerBlock(in: channelID)?.button?.title == "Withdraw Application")
        model.ownJoinRequests[guildID] = OwnJoinRequest(guildID: guildID, status: .rejected, rejectionReason: "No.")
        #expect(model.composerBlock(in: channelID) == .applicationRejected(reason: "No."))
    }

    @Test("A server at Low turns away an unverified e-mail, and offers to resend")
    func unverifiedEmail() {
        let model = model(
            level: .low,
            verification: AccountVerification(isEmailVerified: false, isPhoneVerified: false)
        )
        #expect(model.composerBlock(in: channelID) == .email)
        #expect(model.composerBlock(in: channelID)?.button?.action == .resendEmail)
    }

    @Test("A server at High makes a new member wait ten minutes, with a countdown")
    func newMemberWaits() throws {
        let joined = Date.now.addingTimeInterval(-120)
        let model = model(level: .high, joinedAt: joined)
        let block = try #require(model.composerBlock(in: channelID))
        guard case .memberAge(let until) = block else {
            Issue.record("expected the member wait, got \(block)"); return
        }
        #expect(abs(until.timeIntervalSince(joined) - AppModel.memberAgeRequirement) < 1)
        #expect(block.message == "You must be a member for at least 10 minutes to send messages in this server.")
        #expect(ComposerBlockBar.countdown(to: until, now: joined.addingTimeInterval(121)) == "7:59")
        // And it lifts by itself.
        #expect(model.composerBlock(in: channelID, now: until.addingTimeInterval(1)) == nil)
    }

    @Test("A member with any role is past the server's level, as in Discord")
    func roleBypassesTheLevel() {
        let model = model(
            level: .veryHigh,
            roles: [RoleID(rawValue: 5)],
            verification: AccountVerification(isEmailVerified: false, isPhoneVerified: false)
        )
        #expect(model.composerBlock(in: channelID) == nil)
    }

    @Test("Without the reader's own record, nothing is guessed")
    func unknownMemberSaysNothing() {
        let model = model(level: .high, joinedAt: .now)
        model.members[guildID] = [:]
        #expect(model.composerBlock(in: channelID) == nil)
    }

    @Test("A direct message has no server to turn anybody away")
    func directMessagesAreFree() {
        let model = model(level: .veryHigh)
        let dm = ChannelID(rawValue: 3_000)
        var index = model.channelIndex
        index.replacePrivateChannels([Channel(id: dm, kind: .directMessage)])
        model.channelIndex = index
        #expect(model.composerBlock(in: dm) == nil)
    }
}
