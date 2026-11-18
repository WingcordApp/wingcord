import Foundation
import WingcordCore

// MARK: - The activity in a call, and where its frame is drawn

extension AppModel {

    /// The activity running in a call's channel, newest launch first, as the
    /// call's tile draws it. Nil where nothing runs there.
    func callActivity(in channelID: ChannelID) -> CallActivityPresentation? {
        guard let instance = activityInstances.instances(in: channelID).last else {
            // Starting one here that no update has listed yet.
            guard let starting = activityStarting, starting.channelID == channelID else { return nil }
            return CallActivityPresentation(
                applicationID: starting.applicationID, channelID: channelID, name: starting.name,
                iconURL: applicationIconURL(starting.applicationID, side: Metrics.activityHeaderIcon),
                coverURL: activityCoverURL(starting.applicationID),
                hostName: nil, players: [], playerCount: 0, isJoined: false, isStarting: true
            )
        }
        return presentation(of: instance, in: channelID)
    }

    /// Every activity running in a channel, newest launch first: the
    /// launcher's "In This Call" row (decision 5).
    func runningActivities(in channelID: ChannelID) -> [CallActivityPresentation] {
        activityInstances.instances(in: channelID).reversed().map { presentation(of: $0, in: channelID) }
    }

    private func presentation(of instance: ActivityInstance, in channelID: ChannelID) -> CallActivityPresentation {
        let app = activityApp(instance.applicationID)
        let guildID = instance.guildID
        let people = instance.userIDs
        let isJoined = runningActivity.map {
            $0.applicationID == instance.applicationID && $0.instance.location.channelID == channelID
        } ?? false
        return CallActivityPresentation(
            applicationID: instance.applicationID,
            channelID: channelID,
            name: app?.name ?? "Activity",
            iconURL: applicationIconURL(instance.applicationID, side: Metrics.activityHeaderIcon),
            coverURL: activityCoverURL(instance.applicationID),
            hostName: people.first.map { voiceName(of: $0, inGuild: guildID) },
            players: people.prefix(4).map { userID in
                CallActivityPresentation.Face(
                    id: userID,
                    url: avatarURL(forUserID: userID, inGuild: guildID, side: 24),
                    monogram: users[userID]?.monogram ?? "?"
                )
            },
            playerCount: people.count,
            isJoined: isJoined,
            isStarting: activityStarting?.applicationID == instance.applicationID && !isJoined
        )
    }

    /// An app's wide artwork: the shelf's tile, else its page's first picture,
    /// else its store cover.
    func activityCoverURL(_ id: ApplicationID) -> URL? {
        if let tile = activityDirectory.apps[id]?.tileAssetID {
            return CDN.applicationAsset(id: id, assetID: tile, side: 600)
        }
        let app = activityApp(id)
        if let hero = app?.heroImageURL { return hero }
        return app?.coverHash.flatMap { CDN.applicationCover(id: id, hash: $0, width: 600) }
    }

    /// Joins the activity a call's tile offers.
    func joinCallActivity(_ activity: CallActivityPresentation) {
        let app = activityApp(activity.applicationID)
            ?? ActivityApp(
                id: activity.applicationID, name: activity.name,
                config: EmbeddedActivityConfig(supportedPlatforms: ["web"])
            )
        Task { await sessionController.startActivity(app, in: activity.channelID, section: "voice_tile") }
    }

    /// Where the running activity's frame is drawn right now: in its own place
    /// when that is on screen, in its own window when popped out, otherwise in
    /// the picture in picture (Discord's panel modes: panel, popout, PiP).
    ///
    /// **One host at a time**: the web view is one view, and every surface asks
    /// this before drawing it.
    var activityHost: ActivityHost? {
        guard let running = runningActivity else { return nil }
        if isActivityPoppedOut { return .popout }
        let channelID = running.instance.location.channelID
        switch workspacePresentation.primary {
        case .conversation(let shown) where shown == channelID:
            return isCallBandShowing(in: channelID) ? .call : .band
        case .voice(let shown) where shown == channelID, .stage(let shown) where shown == channelID:
            return .call
        case .guildSurface(let guildID, .serverHub)
            where serverHub.spaces[guildID]?.channelID == channelID:
            return .hub
        default:
            return .pictureInPicture
        }
    }

    /// Whether a conversation shows a call band: the reader's call, or one
    /// going without them.
    func isCallBandShowing(in channelID: ChannelID) -> Bool {
        if voicePresentation?.channelID == channelID { return true }
        return !callLobby(for: channelID).isEmpty
    }
}

// MARK: - Pop Out, picture in picture, and back

extension AppModel {

    /// The running activity in its own window (Discord's Pop Out).
    func popOutActivity() {
        guard runningActivity != nil, !isActivityPoppedOut else { return }
        isActivityPoppedOut = true
        ActivityPopoutWindow.shared.show(model: self)
    }

    /// Back from its own window to wherever it belongs now.
    func popInActivity() {
        guard isActivityPoppedOut else {
            returnToActivity()
            return
        }
        isActivityPoppedOut = false
        ActivityPopoutWindow.shared.close()
    }

    /// Goes to the activity's own place (Discord's Return to Activity).
    /// The sidebar's activity row (`ActivityHUDRow`): the activity the reader
    /// is in and where it runs. Nil when there is none.
    var activityHUD: ActivityHUDPresentation? {
        guard let running = runningActivity else { return nil }
        return ActivityHUDPresentation(
            name: running.name,
            iconURL: running.iconURL,
            place: channelIndex[running.instance.location.channelID].map { displayName(of: $0) }
        )
    }

    func returnToActivity() {
        guard let running = runningActivity else { return }
        let channelID = running.instance.location.channelID
        if let guildID = running.instance.location.guildID,
           serverHub.spaces[guildID]?.channelID == channelID {
            selectGuild(guildID)
            openSurface(.serverHub)
        } else if channelIndex[channelID]?.guildID == nil {
            openDirectMessage(channelID)
        } else {
            selectChannel(channelID)
        }
    }
}

// MARK: - Sharing from an activity (decision 7)

extension AppModel {
    /// Sends what the activity's share sheet holds to the conversations picked,
    /// those the reader may still write in.
    func shareFromActivity(_ request: ActivityShareRequest, to targets: [ChannelID], comment: String) {
        let permitted = targets.filter { permissionGate.canSend(in: $0) }
        guard !permitted.isEmpty else { return }
        request.sent()
        sessionController.send(request.message(comment: comment), to: permitted)
        request.close()
        activityShareRequest = nil
    }
}

extension AppModel {
    /// Whether the running activity is in a server channel, where an invite
    /// that opens it can be made.
    var canInviteToRunningActivity: Bool {
        runningActivity?.instance.location.guildID != nil
    }

    /// Makes an invite that opens the running activity and offers it in the
    /// share sheet: copy it, or send it to friends and channels.
    func inviteToRunningActivity() {
        guard let running = runningActivity, running.instance.location.guildID != nil else { return }
        Task {
            do {
                let link = try await sessionController.rest.createActivityInvite(
                    in: running.instance.location.channelID, application: running.applicationID
                )
                activityShareRequest = ActivityShareRequest(
                    kind: .invite, applicationID: running.applicationID, appName: running.name,
                    iconURL: running.iconURL, link: link
                )
            } catch {
                reportActionFailure("Couldn\u{2019}t make an invite for \(running.name).")
            }
        }
    }
}
