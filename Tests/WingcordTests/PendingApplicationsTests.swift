import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The applicant's side of Apply to Join, driven through the real store: the
/// Pending Applications folder, an application's page, taking one back, and
/// the approval.
@Suite("Pending applications")
@MainActor
struct PendingApplicationsTests {

    private let readerID = UserID(rawValue: 1)
    private let yoho = GuildID(rawValue: 1_520_138_745_897_241_889)
    private let forza = GuildID(rawValue: 2000)
    private let joined = GuildID(rawValue: 3000)

    private let reviewingFeatures: Set<String> = [
        "MEMBER_VERIFICATION_GATE_ENABLED",
        "MEMBER_VERIFICATION_MANUAL_APPROVAL",
    ]

    private func model() -> AppModel {
        let model = AppModel()
        model.currentUserID = readerID
        model.guilds[joined] = Guild(id: joined, name: "Already In", ownerID: UserID(rawValue: 9))
        return model
    }

    // MARK: The folder

    @Test("The folder holds servers with an application out, never one the reader is in")
    func folderHoldsOutsidersOnly() {
        let model = model()
        #expect(model.pendingApplicationsRail == nil)

        model.ownJoinRequests = [
            yoho: OwnJoinRequest(guildID: yoho, status: .submitted),
            joined: OwnJoinRequest(guildID: joined, status: .submitted),
        ]
        #expect(model.pendingApplicationGuildIDs == [yoho])
        // Discord draws the folder before it knows the servers, and the tiles
        // after.
        #expect(model.pendingApplicationsRail?.guilds.isEmpty == true)

        model.joinRequestGuilds = [JoinRequestGuild(id: yoho, name: "yoho club", iconHash: "5c05")]
        #expect(model.pendingApplicationsRail?.guilds.map(\.name) == ["yoho club"])
    }

    @Test("Tiles keep the server list's order, and only a denial is marked")
    func tilesOrderAndMark() {
        let model = model()
        model.ownJoinRequests = [
            yoho: OwnJoinRequest(guildID: yoho, status: .submitted),
            forza: OwnJoinRequest(guildID: forza, status: .rejected, rejectionReason: "no"),
        ]
        model.joinRequestGuilds = [
            JoinRequestGuild(id: forza, name: "Forza"),
            JoinRequestGuild(id: yoho, name: "yoho club"),
        ]
        let tiles = model.pendingApplicationsRail?.guilds ?? []
        #expect(tiles.map(\.id) == [forza, yoho])
        #expect(tiles.map(\.applicationMark) == [.denied, nil])
    }

    @Test("The coachmark waits for the form's sheet to close")
    func coachmarkWaitsForTheSheet() {
        let model = model()
        model.isApplicationCoachmarkQueued = true
        #expect(!model.showsApplicationCoachmark)

        model.raiseQueuedApplicationCoachmark()
        #expect(model.showsApplicationCoachmark)
        #expect(!model.isApplicationCoachmarkQueued)

        // A sheet closed without a submit raises nothing.
        model.showsApplicationCoachmark = false
        model.raiseQueuedApplicationCoachmark()
        #expect(!model.showsApplicationCoachmark)
    }

    @Test("Opening the folder clears the coachmark")
    func openingClearsCoachmark() {
        let model = model()
        model.ownJoinRequests[yoho] = OwnJoinRequest(guildID: yoho, status: .submitted)
        model.showsApplicationCoachmark = true
        #expect(model.pendingApplicationsRail?.showsCoachmark == true)

        model.togglePendingApplications()
        #expect(model.isPendingApplicationsOpen)
        #expect(!model.showsApplicationCoachmark)
    }

    // MARK: The page

    @Test("Picking an application opens its page as a takeover, and opens the folder")
    func pickingOpensThePage() {
        let model = model()
        model.ownJoinRequests[yoho] = OwnJoinRequest(guildID: yoho, status: .submitted)

        model.selectGuild(yoho)
        #expect(model.isPendingApplicationsOpen)
        #expect(model.shownJoinRequestGuildID == yoho)
        #expect(model.isColumnTakenOver)
        #expect(model.workspacePresentation.primary == .joinRequest(yoho))

        // Once the server arrives the reader is in it, and the page is gone.
        model.guilds[yoho] = Guild(id: yoho, name: "yoho club", ownerID: UserID(rawValue: 9))
        #expect(model.shownJoinRequestGuildID == nil)
    }

    @Test("Each status draws Discord's card for it")
    func pageStates() {
        let model = model()
        model.joinRequestGuilds = [
            JoinRequestGuild(id: yoho, name: "yoho club", splashHash: "abc", features: reviewingFeatures)
        ]
        model.selectedGuildID = yoho

        model.ownJoinRequests[yoho] = OwnJoinRequest(guildID: yoho, status: .submitted)
        #expect(model.joinRequestStatusPresentation?.state == .submitted)
        #expect(model.joinRequestStatusPresentation?.serverName == "yoho club")
        #expect(model.joinRequestStatusPresentation?.splashURL != nil)

        model.ownJoinRequests[yoho] = OwnJoinRequest(guildID: yoho, status: .rejected, rejectionReason: "spam")
        #expect(model.joinRequestStatusPresentation?.state == .rejected(reason: "spam", canReapply: true))

        // Discord's third arm takes STARTED and an approval not yet joined.
        model.ownJoinRequests[yoho] = OwnJoinRequest(guildID: yoho, status: .started)
        #expect(model.joinRequestStatusPresentation?.state == .unfinished)
        model.ownJoinRequests[yoho] = OwnJoinRequest(guildID: yoho, status: .approved)
        #expect(model.joinRequestStatusPresentation?.state == .unfinished)
    }

    @Test("A server that stopped taking applications offers no Reapply")
    func noReapplyWithoutManualApproval() {
        let model = model()
        model.joinRequestGuilds = [JoinRequestGuild(id: yoho, name: "yoho club", features: [])]
        model.selectedGuildID = yoho
        model.ownJoinRequests[yoho] = OwnJoinRequest(guildID: yoho, status: .rejected)
        #expect(model.joinRequestStatusPresentation?.state == .rejected(reason: nil, canReapply: false))
    }

    // MARK: Taking one back

    @Test("Withdrawing leaves the page for home, and asks the right question first")
    func withdrawLeavesThePage() {
        let model = model()
        model.joinRequestGuilds = [JoinRequestGuild(id: yoho, name: "yoho club")]
        model.ownJoinRequests[yoho] = OwnJoinRequest(guildID: yoho, status: .submitted)
        model.ownJoinRequests[forza] = OwnJoinRequest(guildID: forza, status: .started)

        model.askToWithdrawApplication(yoho)
        #expect(model.withdrawApplicationRequest == WithdrawApplicationRequest(
            guildID: yoho, serverName: "yoho club", isDiscard: false
        ))
        model.askToWithdrawApplication(forza)
        #expect(model.withdrawApplicationRequest?.isDiscard == true)

        model.selectGuild(yoho)
        model.withdrawApplication(yoho)
        #expect(model.ownJoinRequests[yoho] == nil)
        #expect(model.selectedGuildID == nil)
        #expect(!model.pendingJoinRequestGuildIDs.contains(yoho))
    }

    // MARK: Filing

    @Test("Only a submitted application counts as waiting on a moderator")
    func pendingIsSubmittedOnly() {
        let model = model()
        model.ownJoinRequests = [
            yoho: OwnJoinRequest(guildID: yoho, status: .submitted),
            forza: OwnJoinRequest(guildID: forza, status: .rejected),
        ]
        #expect(model.pendingJoinRequestGuildIDs == [yoho])
    }

    @Test("An approval already seen is dropped, as Discord's store drops it")
    func settledApprovalIsDropped() {
        let model = model()
        model.ownJoinRequests[yoho] = OwnJoinRequest(guildID: yoho, status: .submitted)
        model.fileOwnJoinRequest(OwnJoinRequest(guildID: yoho, status: .approved, isOutcomeSeen: true))
        #expect(model.ownJoinRequests[yoho] == nil)

        model.fileOwnJoinRequest(OwnJoinRequest(guildID: yoho, status: .approved))
        #expect(model.ownJoinRequests[yoho]?.isUnseenApproval == true)
    }

    @Test("The socket's requests are filed only when they are the reader's own")
    func socketFiltersOtherApplicants() {
        let model = model()
        let request = OwnJoinRequest(guildID: forza, status: .submitted)

        model.sessionController.applyJoinRequestEvent(request, userID: UserID(rawValue: 77))
        #expect(model.ownJoinRequests[forza] == nil)
        // Discord's store drops a request with no applicant on it, too.
        model.sessionController.applyJoinRequestEvent(request, userID: nil)
        #expect(model.ownJoinRequests[forza] == nil)

        model.sessionController.applyJoinRequestEvent(request, userID: readerID)
        #expect(model.ownJoinRequests[forza] == request)

        model.sessionController.removeJoinRequest(forza, userID: UserID(rawValue: 77))
        #expect(model.ownJoinRequests[forza] != nil)
        model.sessionController.removeJoinRequest(forza, userID: readerID)
        #expect(model.ownJoinRequests[forza] == nil)
    }

    // MARK: Marks

    @Test("A tile is marked only where the server reviews and the application is unsettled")
    func tileMarks() {
        let model = model()
        model.guilds[joined]?.features = reviewingFeatures
        model.members[joined] = [
            readerID: Member(userID: readerID, roleIDs: [], joinedAt: .now, isPending: true)
        ]

        // A pending member, waiting on a moderator.
        model.ownJoinRequests[joined] = OwnJoinRequest(guildID: joined, status: .submitted)
        #expect(model.railApplicationMark(for: joined) == .inReview)
        #expect(model.railApplicationMark(for: joined)?.membershipLine == "Membership In Review")

        // In, and approved: marked until the approval is seen.
        model.members[joined]?[readerID]?.isPending = false
        model.ownJoinRequests[joined] = OwnJoinRequest(guildID: joined, status: .approved)
        #expect(model.railApplicationMark(for: joined) == .approved)
        model.ownJoinRequests[joined] = OwnJoinRequest(guildID: joined, status: .rejected, isOutcomeSeen: true)
        #expect(model.railApplicationMark(for: joined) == nil)

        // A server that does not review applications says nothing.
        model.guilds[joined]?.features = []
        model.ownJoinRequests[joined] = OwnJoinRequest(guildID: joined, status: .submitted)
        #expect(model.railApplicationMark(for: joined) == nil)

        // Outside the server, the server list's features decide.
        model.joinRequestGuilds = [JoinRequestGuild(id: yoho, name: "yoho club", features: reviewingFeatures)]
        model.ownJoinRequests[yoho] = OwnJoinRequest(guildID: yoho, status: .started)
        #expect(model.railApplicationMark(for: yoho) == .incomplete)
    }

    @Test("The reader's own server's tile carries its mark")
    func markReachesTheRail() {
        let model = model()
        model.guilds[joined]?.features = reviewingFeatures
        model.folders = [GuildFolder(guildIDs: [joined])]
        model.ownJoinRequests[joined] = OwnJoinRequest(guildID: joined, status: .submitted)

        guard case .guild(let tile) = model.railItems.first else {
            Issue.record("no tile")
            return
        }
        #expect(tile.applicationMark == .inReview)
    }

    // MARK: The approval

    @Test("An unseen approval raises the notice in its server, and the button forgets it")
    func approvalNotice() {
        let model = model()
        model.ownJoinRequests[joined] = OwnJoinRequest(guildID: joined, status: .approved)

        // Not while the reader is somewhere else.
        model.offerApprovedApplicationIfNeeded(joined)
        #expect(model.approvedApplication == nil)

        model.selectedGuildID = joined
        model.offerApprovedApplicationIfNeeded(joined)
        #expect(model.approvedApplication == ApprovedApplicationNotice(guildID: joined, serverName: "Already In"))

        model.acknowledgeApprovedApplication(joined)
        #expect(model.approvedApplication == nil)
        #expect(model.ownJoinRequests[joined] == nil)

        // Seen once, never again.
        model.offerApprovedApplicationIfNeeded(joined)
        #expect(model.approvedApplication == nil)
    }
}
