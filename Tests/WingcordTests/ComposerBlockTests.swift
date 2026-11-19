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

    /// An account with an e-mail and **no verified phone** unless told
    /// otherwise: a verified phone skips every one of a level's checks.
    private func model(
        level: VerificationLevel? = nil,
        features: Set<String> = [],
        isPending: Bool = false,
        roles: [RoleID] = [],
        serverRoles: [Role] = [],
        joinedAt: Date = .distantPast,
        serverJoinedAt: Date? = nil,
        verification: AccountVerification? = AccountVerification(isEmailVerified: true, isPhoneVerified: false),
        kind: ChannelKind = .text
    ) -> AppModel {
        let model = AppModel()
        model.currentUserID = readerID
        model.guilds[guildID] = Guild(
            id: guildID,
            name: "Somewhere",
            ownerID: UserID(rawValue: 99),
            features: features,
            joinedAt: serverJoinedAt,
            verificationLevel: level
        )
        model.members[guildID] = [
            readerID: Member(userID: readerID, roleIDs: roles, joinedAt: joinedAt, isPending: isPending)
        ]
        model.roles[guildID] = Dictionary(uniqueKeysWithValues: serverRoles.map { ($0.id, $0) })
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

    /// His rejoin (2026-11-19): a record that didn't carry `pending` had
    /// replaced the one that did, and the bar never came.
    @Test("An unapproved join request brings the Complete bar on its own")
    func joinRequestWitnessesPending() {
        let model = model(features: [SessionController.verificationFeature], isPending: false)
        #expect(model.composerBlock(in: channelID) == nil)
        model.ownJoinRequests[guildID] = OwnJoinRequest(guildID: guildID, status: .started)
        #expect(model.composerBlock(in: channelID) == .completeSteps)
        model.ownJoinRequests[guildID] = OwnJoinRequest(guildID: guildID, status: .approved)
        #expect(model.composerBlock(in: channelID) == nil)
    }

    @Test("A record that doesn't say pending keeps what was known")
    func pendingSurvivesASilentRecord() {
        let pending = Member(userID: readerID, isPending: true)
        var silent = Member(userID: readerID, roleIDs: [RoleID(rawValue: 5)])
        silent.statesPending = false
        let merged = silent.merged(over: pending)
        #expect(merged.isPending)
        #expect(merged.roleIDs == [RoleID(rawValue: 5)])
        // One that does say so wins.
        #expect(Member(userID: readerID, isPending: false).merged(over: pending).isPending == false)
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

    @Test("A member with a role the server gave is past its level, as in Discord")
    func roleBypassesTheLevel() {
        let model = model(
            level: .veryHigh,
            roles: [RoleID(rawValue: 5)],
            serverRoles: [Role(id: RoleID(rawValue: 5), name: "Member")],
            verification: AccountVerification(isEmailVerified: false, isPhoneVerified: false)
        )
        #expect(model.composerBlock(in: channelID) == nil)
    }

    /// Discord's check runs a level's requirements only for an account without
    /// a verified phone — his image 242 (2026-11-19): a ten-minute bar in a
    /// server where Discord showed none.
    @Test("A verified phone skips every wait, as in Discord")
    func verifiedPhoneSkipsTheLevel() {
        let model = model(
            level: .high,
            joinedAt: .now.addingTimeInterval(-45),
            verification: AccountVerification(isEmailVerified: true, isPhoneVerified: true)
        )
        #expect(model.composerBlock(in: channelID) == nil)
    }

    @Test("An integration's role doesn't count")
    func managedRoleDoesntCount() {
        let model = model(
            level: .low,
            roles: [RoleID(rawValue: 7)],
            serverRoles: [Role(id: RoleID(rawValue: 7), name: "A Bot", isManaged: true)],
            verification: AccountVerification(isEmailVerified: false, isPhoneVerified: false)
        )
        #expect(model.composerBlock(in: channelID) == .email)
    }

    /// Onboarding hands out roles, so in a server that has ever had it a role
    /// proves nothing for anyone who joined after onboarding existed.
    @Test("In an onboarding server, a newer member's role doesn't count")
    func onboardingEraRoleDoesntCount() {
        let after = Calendar.current.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        let before = Calendar.current.date(from: DateComponents(year: 2021, month: 1, day: 1))!
        func block(joined: Date) -> ComposerBlock? {
            model(
                level: .low,
                features: [AppModel.onboardingEverEnabledFeature],
                roles: [RoleID(rawValue: 5)],
                serverRoles: [Role(id: RoleID(rawValue: 5), name: "Member")],
                joinedAt: joined,
                verification: AccountVerification(isEmailVerified: false, isPhoneVerified: false)
            ).composerBlock(in: channelID)
        }
        #expect(block(joined: after) == .email)
        #expect(block(joined: before) == nil)
    }

    @Test("The member wait counts from the server's own joined-at")
    func memberWaitUsesTheServersJoin() throws {
        let joined = Date.now.addingTimeInterval(-60)
        let model = model(level: .high, joinedAt: .distantPast, serverJoinedAt: joined)
        let block = try #require(model.composerBlock(in: channelID))
        #expect(block == .memberAge(until: joined.addingTimeInterval(AppModel.memberAgeRequirement)))
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
