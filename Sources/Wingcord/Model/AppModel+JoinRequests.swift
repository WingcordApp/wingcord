import Foundation
import WingcordCore

// MARK: - The reader's own applications
//
// Discord's applicant side of Apply to Join: the Pending Applications folder at
// the head of the rail (`rc`), a tile and a menu for each application (`rl`,
// `97187`), and the status page a tile opens (`995198`). How each application
// stands is `OwnJoinRequest`, off READY and the socket; the servers are drawn
// from `JoinRequestGuild`.

extension AppModel {

    // MARK: The folder

    /// The servers in the folder: an application out, and not a server the
    /// reader is in — Discord's `928568`. In the order the server list
    /// answered, so the tiles do not shuffle each time a request is filed.
    var pendingApplicationGuildIDs: [GuildID] {
        // Nearly every account, on every rail evaluation.
        guard !ownJoinRequests.isEmpty else { return [] }
        let order = Dictionary(
            joinRequestGuilds.enumerated().map { ($1.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return ownJoinRequests.keys
            .filter { guilds[$0] == nil }
            .sorted { (order[$0] ?? .max, $0.rawValue) < (order[$1] ?? .max, $1.rawValue) }
    }

    /// The folder as the rail draws it, or nil while there is nothing in it —
    /// Discord draws no folder at all then.
    var pendingApplicationsRail: PendingApplicationsRail? {
        let guildIDs = pendingApplicationGuildIDs
        guard !guildIDs.isEmpty else { return nil }
        let known = Dictionary(
            joinRequestGuilds.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let tiles = guildIDs.compactMap { guildID -> RailGuild? in
            guard let guild = known[guildID] else { return nil }
            return RailGuild(
                id: guildID,
                name: guild.name,
                iconURL: guild.iconHash.flatMap {
                    CDN.guildIcon(guildID: guildID, hash: $0, side: Metrics.guildTile)
                },
                monogram: guild.monogram,
                mentionCount: 0,
                hasUnread: false,
                isMuted: false,
                isConnectedToVoice: false,
                // Only a denial is marked in the folder (`rl`): everything in
                // it is an application, so the rest would say nothing.
                applicationMark: ownJoinRequests[guildID]?.status == .rejected ? .denied : nil
            )
        }
        return PendingApplicationsRail(
            guilds: tiles,
            isOpen: isPendingApplicationsOpen,
            showsCoachmark: showsApplicationCoachmark
        )
    }

    /// Opens or closes the folder. **Discord asks for the servers here**
    /// (`USER_JOIN_REQUEST_GUILDS_FETCH` on the first open), so a folder
    /// nobody opens costs no request.
    func togglePendingApplications() {
        isPendingApplicationsOpen.toggle()
        // However the folder is touched, the coachmark has been read.
        showsApplicationCoachmark = false
        if isPendingApplicationsOpen { sessionController.loadJoinRequestGuildsIfNeeded() }
    }

    func dismissApplicationCoachmark() {
        showsApplicationCoachmark = false
    }

    /// Raises the coachmark once the application's sheet has gone.
    ///
    /// **Discord waits too** — 200 ms after its form (`408213`'s
    /// `setTimeout`), so the coachmark lands on a window with no modal over
    /// it. Here the form is a sheet that closes after the submit answers, and
    /// a popover asked for while a sheet is still attached is a presentation
    /// fighting another; the sheet's own dismissal is the moment.
    func raiseQueuedApplicationCoachmark() {
        guard isApplicationCoachmarkQueued else { return }
        isApplicationCoachmarkQueued = false
        showsApplicationCoachmark = true
    }

    // MARK: Marks

    /// How the reader's application to a server stands, where Discord says so
    /// on the server's tile — `ir`: a server that reviews applications, and an
    /// application that is not settled. Not settled is the reader not being a
    /// full member there yet, or an outcome they have not seen.
    func railApplicationMark(for guildID: GuildID) -> RailApplicationMark? {
        guard let request = ownJoinRequests[guildID] else { return nil }
        let features = guilds[guildID]?.features
            ?? joinRequestGuilds.first { $0.id == guildID }?.features
            ?? []
        guard features.contains("MEMBER_VERIFICATION_MANUAL_APPROVAL") else { return nil }
        let member = currentUserID.flatMap { members[guildID]?[$0] }
        let isFullMember = guilds[guildID] != nil && member.map { !$0.isPending } == true
        let isOutcomeUnseen = (request.status == .approved || request.status == .rejected)
            && !request.isOutcomeSeen
        guard !isFullMember || isOutcomeUnseen else { return nil }
        return RailApplicationMark(request.status)
    }

    /// The marks on the reader's own servers' tiles, for the rail's memo.
    ///
    /// **One pass over the applications, not one per tile**: an account has a
    /// handful of these and ninety-seven tiles, and with none out this reads
    /// nothing at all.
    var railApplicationMarks: [GuildID: RailApplicationMark] {
        var marks: [GuildID: RailApplicationMark] = [:]
        for guildID in ownJoinRequests.keys where guilds[guildID] != nil {
            marks[guildID] = railApplicationMark(for: guildID)
        }
        return marks
    }

    // MARK: The status page

    /// The application the detail column is showing: a server picked out of
    /// the folder, which the reader is not in. Discord's
    /// `/member-verification/{guildId}`.
    var shownJoinRequestGuildID: GuildID? {
        guard let guildID = selectedGuildID,
              guilds[guildID] == nil,
              ownJoinRequests[guildID] != nil
        else { return nil }
        return guildID
    }

    var isJoinRequestShown: Bool { shownJoinRequestGuildID != nil }

    var joinRequestStatusPresentation: JoinRequestStatusPresentation? {
        guard let guildID = shownJoinRequestGuildID,
              let request = ownJoinRequests[guildID]
        else { return nil }
        let guild = joinRequestGuilds.first { $0.id == guildID }
        let state: JoinRequestStatusPresentation.State = switch request.status {
        case .submitted:
            .submitted
        case .rejected:
            .rejected(
                reason: request.rejectionReason,
                canReapply: guild?.acceptsApplications ?? false
            )
        // Discord's switch has three arms, and an approval for a server not
        // yet joined falls into the third with STARTED.
        case .started, .approved, .unknown:
            .unfinished
        }
        return JoinRequestStatusPresentation(
            guildID: guildID,
            serverName: guild?.name,
            splashURL: guild?.splashHash.flatMap {
                CDN.guildSplash(guildID: guildID, hash: $0, width: 1200)
            },
            state: state,
            isReapplying: reapplyingGuildIDs.contains(guildID)
        )
    }

    // MARK: Acting on one

    func openJoinRequestMenu(_ guildID: GuildID, anchor: CGRect) {
        joinRequestMenu = JoinRequestMenuRequest(guildID: guildID, anchor: anchor)
    }

    /// Discord's "Are you sure?" — the question an application never sent asks
    /// differently, because nothing is being taken back.
    ///
    /// - Parameter isDiscard: the menu decides by the status; the page by
    ///   which of its three cards is up, as Discord's does.
    func askToWithdrawApplication(_ guildID: GuildID, isDiscard: Bool? = nil) {
        withdrawApplicationRequest = WithdrawApplicationRequest(
            guildID: guildID,
            serverName: joinRequestGuilds.first { $0.id == guildID }?.name,
            isDiscard: isDiscard ?? (ownJoinRequests[guildID]?.status == .started)
        )
    }

    /// Takes an application back — `DELETE /guilds/{id}/requests/@me`.
    ///
    /// **And leaves its page**, as Discord's does (`pX(BVt.ME)`): the page was
    /// about an application that no longer exists, and the column would
    /// otherwise be showing a server the reader is not in and has not applied
    /// to.
    func withdrawApplication(_ guildID: GuildID) {
        let previous = ownJoinRequests.removeValue(forKey: guildID)
        if selectedGuildID == guildID { selectGuild(nil) }
        sessionController.writeWithdrawJoinRequest(guildID, restoring: previous)
    }

    /// Opens a denied application again — Discord's Reapply.
    ///
    /// - Parameter opensForm: the status page's button opens the form once the
    ///   application is open again; the menu's goes to the page instead, which
    ///   is what each of Discord's does.
    func reapply(toGuild guildID: GuildID, opensForm: Bool) {
        guard reapplyingGuildIDs.insert(guildID).inserted else { return }
        sessionController.writeResetJoinRequest(guildID, opensForm: opensForm)
    }

    // MARK: An approval

    /// Raises Discord's "You are now a member of" for a server the reader is
    /// in and looking at, whose application was approved and never
    /// acknowledged. Discord draws it from the server's own chat, so it is
    /// asked when the server opens and when an approval lands on it.
    func offerApprovedApplicationIfNeeded(_ guildID: GuildID) {
        guard approvedApplication == nil,
              selectedGuildID == guildID,
              let guild = guilds[guildID],
              ownJoinRequests[guildID]?.isUnseenApproval == true
        else { return }
        approvedApplication = ApprovedApplicationNotice(guildID: guildID, serverName: guild.name)
    }

    /// The notice's "Let's Go!", and its close — both acknowledge, as
    /// Discord's do (`onAccept` and `onCloseRequest` are the same function).
    func acknowledgeApprovedApplication(_ guildID: GuildID) {
        approvedApplication = nil
        let request = ownJoinRequests.removeValue(forKey: guildID)
        guard let requestID = request?.requestID else { return }
        sessionController.writeAcknowledgeJoinRequest(guildID, requestID: requestID)
    }

    // MARK: Filing what arrives

    /// One of the reader's own requests, from a write's answer or the socket —
    /// Discord's `212455`, which drops an approval already seen rather than
    /// keeping it.
    func fileOwnJoinRequest(_ request: OwnJoinRequest) {
        if request.isSettled {
            ownJoinRequests[request.guildID] = nil
        } else {
            ownJoinRequests[request.guildID] = request
        }
    }

    /// Replaces the server list with what the route answered.
    func applyJoinRequestGuilds(_ guilds: [JoinRequestGuild]) {
        guard joinRequestGuilds != guilds else { return }
        joinRequestGuilds = guilds
    }
}
