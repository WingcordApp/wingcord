import Foundation
import WingcordCore
import WingcordNet

// MARK: - Stages
//
// A stage channel is a voice channel where **almost nobody may speak**, and
// that one difference reshapes the surface: two groups instead of one, a queue
// of raised hands, and a set of acts whose permissions differ from each other.
//
// The two facts everything here rests on, and both are Discord's:
//
//   - **`suppress` makes somebody the audience**, and it is not a mute. It is
//     lifted by a moderator, or by the person themselves if they hold
//     `MUTE_MEMBERS`, and never by muting.
//   - **A live stage is separate from the channel it runs in.** The channel is
//     always there; the stage is created with a topic and deleted when it ends,
//     and a channel with people in it and no stage is a room with the lights
//     off. See `StageInstance`.

extension AppModel {

    /// The live stage in a channel, or nil when nothing is running.
    func stage(in channelID: ChannelID) -> StageInstance? { stageInstances[channelID] }

    /// Who is where, in one channel.
    ///
    /// The split itself is `StageRoster.resolve`, which is pure and tested;
    /// this is the store lookup that feeds it.
    func stageRoster(in channelID: ChannelID) -> StageRoster {
        StageRoster.resolve(voiceStates(in: channelID))
    }

    /// The stage microphone's age gate for this reader: READY's regional
    /// features with the account's own age status.
    var stageAgeGate: StageAgeGate {
        StageAgeGate(features: ageGatedFeatures, ageVerificationStatus: entitlements.ageVerificationStatus)
    }

    /// Everything the stage pane needs, resolved once.
    ///
    /// Nil for anything that is not a stage channel, which is what keeps the
    /// pane from drawing an audience for an ordinary voice room.
    func stagePresentation(of channelID: ChannelID) -> StagePresentation? {
        guard let channel = channelIndex[channelID], channel.kind == .stage else { return nil }
        let guildID = channel.guildID
        let guild = guildID.flatMap { guilds[$0] }
        let roster = stageRoster(in: channelID)
        let permissions = permissionGate.permissions(in: channelID)
        let selfState = currentUserID.flatMap { voiceStates[$0] }
        let isHere = selfState?.channelID == channelID
        let live = stageInstances[channelID]
        let gate = stageAgeGate
        let canRequest = permissions.contains(.requestToSpeak)

        // Discord's stage moderator: Manage Channels, Mute Members and Move
        // Members, all three (its `STAGE_CHANNEL_MODERATOR_PERMISSIONS`).
        let isModerator = permissions.contains(Self.stageModerator)
        let speakers = roster.speakers.map { stageMember($0, inGuild: guildID) }
        let audience = roster.audience.map { stageMember($0, inGuild: guildID) }
        let present = roster.speakers + roster.audience
        let hasUnmutedSpeaker = hasUnmutedStageSpeaker(in: channelID)

        return StagePresentation(
            channelID: channelID,
            guildID: guildID,
            channelName: channel.name,
            topic: live?.topic,
            isLive: live != nil,
            speakers: speakers,
            audience: audience,
            requests: roster.requests.map { stageMember($0, inGuild: guildID, channel: channel, roster: roster) },
            isConnected: isHere,
            isSpeaker: isHere && selfState?.isSuppressed == false && selfState?.requestToSpeakAt == nil,
            hasRaisedHand: isHere && selfState?.requestToSpeakAt != nil,
            isModerator: isModerator,
            canMuteMembers: permissions.contains(.muteMembers),
            canRequestToSpeak: canRequest,
            withholdsSpeaking: canRequest && gate.withholdsSpeaking,
            isTeen: gate.isTeen,
            canConnect: permissions.contains(.connect),
            canInvite: guild != nil
                && (permissions.contains(.createInvite) || live?.inviteCode != nil),
            canCreateEvent: permissions.contains(.manageEvents) || permissions.contains(.createEvents),
            showsStartScreen: isModerator && live == nil && stageStartScreenDismissedIn != channelID,
            isInvitedToSpeak: isHere && selfState.map { !$0.isSuppressed && $0.requestToSpeakAt != nil } ?? false,
            allowsEveryoneToRequest: everyoneMayRequest(in: channel),
            imminentEvents: guildID.map { imminentStageEvents(in: channelID, guildID: $0) } ?? [],
            blockedCount: present.count { blockedUserIDs.contains($0) },
            ignoredCount: present.count { ignoredUserIDs.contains($0) },
            isVideoFull: StageVideoCapacity.isMaxedOut(
                hasVideo: voiceStates(in: channelID).contains { $0.isCameraOn || (!$0.isSuppressed && $0.isStreaming) },
                isDismissed: dismissedStageCapacityNotices.contains(channelID),
                canModerate: isModerator,
                isCommunity: guild?.features.contains("COMMUNITY") ?? false,
                premiumTier: guild?.premiumTier ?? 0,
                maxUsers: guild?.maxStageVideoUsers ?? 0,
                count: present.count
            ),
            music: isHere ? stageMusicButton(isLive: live != nil, hasUnmutedSpeaker: hasUnmutedSpeaker) : nil,
            waitingLine: StageCopy.waitingLine(present.map { voiceName(of: $0, inGuild: guildID) }),
            speakingLine: StageCopy.speakingLine(speakers.map(\.name))
        )
    }

    /// Discord's stage moderator permissions.
    static let stageModerator: Permissions = [.manageChannels, .muteMembers, .moveMembers]

    /// A stage chat's "requested to speak." lines whose hand is still up, for
    /// a reader who may answer them — Discord's renderer for the line: Mute
    /// Members, the author still asking (suppressed, hand up — not already
    /// invited), and this line the request's own, its moment the hand's to
    /// the millisecond. Empty for every other channel, before anything else
    /// is read, so no other transcript observes the voice states.
    func openStageRequests(in channelID: ChannelID) -> Set<MessageID> {
        guard channelIndex[channelID]?.kind == .stage,
              permissionGate.permissions(in: channelID).contains(.muteMembers),
              let box = messages(in: channelID)
        else { return [] }
        var open: Set<MessageID> = []
        for message in box.messages where message.kind == .stageRaiseHand {
            guard let state = voiceStates[message.authorID],
                  state.channelID == channelID, state.isSuppressed,
                  let raised = state.requestToSpeakAt,
                  Self.milliseconds(raised) == Self.milliseconds(message.id.timestamp)
            else { continue }
            open.insert(message.id)
        }
        return open
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// The channel's events about to start — Discord's `RO` (module 508654):
    /// not live, starting within fifteen minutes or already due — and none
    /// while one is on in it (`Qs`).
    func imminentStageEvents(in channelID: ChannelID, guildID: GuildID, now: Date = .now) -> [ScheduledEvent] {
        let events = (scheduledEvents[guildID] ?? []).filter { $0.location.channelID == channelID }
        guard !events.contains(where: { $0.status == .active }) else { return [] }
        return events
            .filter { $0.status == .scheduled && $0.startsAt <= now.addingTimeInterval(15 * 60) }
            .sorted(by: Self.eventOrder)
    }

    /// Who the reader has blocked or ignored among the people in a stage —
    /// Discord's "Blocked Accounts Present" list (module 918192, `ld`), each
    /// with where they stand.
    func stageFlaggedPeople(in channelID: ChannelID) -> [StageFlaggedPerson] {
        let guildID = channelIndex[channelID]?.guildID
        let roster = stageRoster(in: channelID)
        let speakers = Set(roster.speakers)
        return (roster.speakers + roster.audience).compactMap { userID in
            let isBlocked = blockedUserIDs.contains(userID)
            guard isBlocked || ignoredUserIDs.contains(userID) else { return nil }
            let place = if speakers.contains(userID) {
                "Speaker"
            } else if let channel = channelIndex[channelID], let guildID,
                      isStageModerator(userID, inGuild: guildID, channel: channel) {
                "Stage Moderator"
            } else {
                "Audience"
            }
            return StageFlaggedPerson(
                id: userID,
                name: voiceName(of: userID, inGuild: guildID),
                avatarURL: avatarURL(forUserID: userID, inGuild: guildID, side: 32),
                monogram: users[userID]?.monogram ?? "?",
                isBlocked: isBlocked,
                place: place
            )
        }
    }

    private func stageMember(
        _ userID: UserID,
        inGuild guildID: GuildID?,
        channel: Channel? = nil,
        roster: StageRoster? = nil
    ) -> StageMember {
        let user = users[userID]
        var member = StageMember(
            id: userID,
            name: voiceName(of: userID, inGuild: guildID),
            avatarURL: avatarURL(forUserID: userID, inGuild: guildID, side: Metrics.avatarProfile),
            monogram: user?.monogram ?? "?",
            nameColor: voiceNameColor(of: userID, inGuild: guildID),
            isSpeaking: userID == currentUserID ? isSelfSpeaking : speakingUserIDs.contains(userID),
            isMuted: voiceStates[userID]?.isSilenced ?? false,
            isSelf: userID == currentUserID
        )
        if let guildID, let channel {
            member.isModerator = isStageModerator(userID, inGuild: guildID, channel: channel)
            if let roster {
                let record = members[guildID]?[userID]
                let guildRoles = roles[guildID] ?? [:]
                let top = record.flatMap { RoleResolver.topRole(of: $0.roleIDs, in: guildRoles) { _ in true } }
                member.requestLabel = StageRequesterLabel.label(
                    for: userID,
                    joinedAt: record?.joinedAt,
                    roleCount: record?.roleIDs.count ?? 0,
                    roleName: top?.name
                )
                member.isInvited = roster.invited.contains(userID)
            }
        }
        return member
    }

    /// Whether someone holds Discord's stage moderator permissions here — the
    /// "Stage Moderator" mark beside a speaker.
    private func isStageModerator(_ userID: UserID, inGuild guildID: GuildID, channel: Channel) -> Bool {
        guard let guild = guilds[guildID] else { return false }
        return PermissionResolver.permissions(
            forMember: members[guildID]?[userID]?.roleIDs ?? [],
            userID: userID,
            guildID: guildID,
            guildOwnerID: guild.ownerID,
            roles: roles[guildID] ?? [:],
            channel: channel
        ).contains(Self.stageModerator)
    }

    /// Discord's "Allow requests from @everyone": whether `@everyone` may ask
    /// to speak here — its role's own grant, then the channel's overwrite.
    private func everyoneMayRequest(in channel: Channel) -> Bool {
        guard let guildID = channel.guildID else { return false }
        var granted = roles[guildID]?[RoleID(rawValue: guildID.rawValue)]?.permissions.contains(.requestToSpeak) ?? false
        if let overwrite = channel.overwrites.first(where: { $0.subject == .role && $0.id == guildID.rawValue }) {
            if overwrite.deny.contains(.requestToSpeak) { granted = false }
            if overwrite.allow.contains(.requestToSpeak) { granted = true }
        }
        return granted
    }

    /// Whether the last moderator speaking is about to leave a live stage —
    /// Discord's `106044`: the reader moderates and is on it, and no other
    /// moderator is in the room, or none is on the stage. Disconnecting then
    /// asks "Do you want to also end the Stage?".
    func isLastStageModerator(in channelID: ChannelID) -> Bool {
        guard stageInstances[channelID] != nil,
              let channel = channelIndex[channelID], let guildID = channel.guildID,
              let reader = currentUserID,
              permissionGate.permissions(in: channelID).contains(Self.stageModerator),
              voiceStates[reader].map({ !$0.isSuppressed && $0.requestToSpeakAt == nil }) == true
        else { return false }
        let roster = stageRoster(in: channelID)
        let others: ([UserID]) -> Bool = { people in
            people.contains { $0 != reader && self.isStageModerator($0, inGuild: guildID, channel: channel) }
        }
        return !others(roster.speakers + roster.audience) || !others(roster.speakers)
    }

    // MARK: The waiting music

    /// Somebody — the reader included — is on the stage with a microphone
    /// open: Discord's `!suppress && !isVoiceMuted()`.
    private func hasUnmutedStageSpeaker(in channelID: ChannelID) -> Bool {
        voiceStates(in: channelID).contains { state in
            let isMuted = state.userID == currentUserID ? isSelfMuted : state.isSelfMuted
            return !state.isSuppressed && !isMuted && !state.isServerMuted
        }
    }

    /// What the waiting music does now — Discord's `I()` over this client's
    /// state. Read by the call's player, which follows it wherever the reader
    /// is looking.
    var stageMusicPlayback: StageMusic.Playback {
        guard let channelID = connectedVoiceChannelID, channelIndex[channelID]?.kind == .stage else {
            return .stopped
        }
        return StageMusic.playback(
            isInStageChannel: true,
            isDeafened: isSelfDeafened,
            isRequested: stageMusicRequested,
            isLive: stageInstances[channelID] != nil,
            isMuted: AppSettings.shared.mutesStageMusic,
            hasUnmutedSpeaker: hasUnmutedStageSpeaker(in: channelID)
        )
    }

    /// The tray's music button — Discord's `n9`, in its two forms.
    private func stageMusicButton(isLive: Bool, hasUnmutedSpeaker: Bool) -> StageMusicButton {
        if StageMusic.isWaiting(isConnected: true, isLive: isLive, hasUnmutedSpeaker: hasUnmutedSpeaker) {
            let isMuted = AppSettings.shared.mutesStageMusic
            return StageMusicButton(title: isMuted ? "Unmute Music" : "Mute Music", isOn: !isMuted)
        }
        return StageMusicButton(title: stageMusicRequested ? "Mute Music" : "Unmute Music", isOn: stageMusicRequested)
    }

    /// Discord's music button: the persistent mute while the room waits, the
    /// one-off Unmute Music otherwise (`STAGE_MUSIC_MUTE` / `STAGE_MUSIC_PLAY`).
    func toggleStageMusic() {
        guard let channelID = connectedVoiceChannelID else { return }
        let isWaiting = StageMusic.isWaiting(
            isConnected: true,
            isLive: stageInstances[channelID] != nil,
            hasUnmutedSpeaker: hasUnmutedStageSpeaker(in: channelID)
        )
        if isWaiting {
            AppSettings.shared.mutesStageMusic.toggle()
            stageMusicRequested = false
        } else {
            stageMusicRequested.toggle()
        }
    }

    // MARK: What the reader can do

    /// Raises a hand, or lowers it.
    ///
    /// **The instant must be now or later** — Discord refuses a timestamp in
    /// the past, and a client that sent the moment the button was pressed
    /// would lose the race with its own request often enough to look
    /// intermittent. Lowering it sends an explicit null; see
    /// `DiscordREST.setSelfStageState` for why that needs a hand-written
    /// encoder. A hand a moderator has answered is the invitation, declined —
    /// Discord's own click there (`nW`).
    func setStageHandRaised(_ isRaised: Bool, inChannel channelID: ChannelID) {
        guard let guildID = channelIndex[channelID]?.guildID else { return }
        if !isRaised, let userID = currentUserID,
           voiceStates[userID].map({ !$0.isSuppressed && $0.requestToSpeakAt != nil }) == true {
            answerStageInvite(accept: false, inChannel: channelID)
            return
        }
        applySelfStageRequest(isRaised ? .now : nil)
        sessionController.writeStageHand(isRaised, inGuild: guildID, channelID: channelID)
    }

    /// Discord's Leave the Stage: down to the audience.
    ///
    /// Always allowed: nobody needs permission to stop talking. Stepping *up*
    /// is `setStageSpeaker`, and it is a moderator's act.
    func leaveStageAsSpeaker(inChannel channelID: ChannelID) {
        guard let guildID = channelIndex[channelID]?.guildID,
              let userID = currentUserID else { return }
        applyStageSuppress(true, for: userID)
        sessionController.writeStageSuppress(
            true, userID: nil, inGuild: guildID, channelID: channelID
        )
    }

    /// Invites somebody to speak, or moves them back to the audience.
    ///
    /// **Also the reader's own way up**, with `nil` for the id — the route for
    /// oneself is a different one and holds the same permission, so the
    /// distinction lives in the controller rather than at every call site.
    func setStageSpeaker(_ userID: UserID?, isSpeaker: Bool, inChannel channelID: ChannelID) {
        guard let guildID = channelIndex[channelID]?.guildID else { return }
        let subject = userID ?? currentUserID
        if let subject {
            applyStageSuppress(!isSpeaker, for: subject)
            if userID == nil {
                // One's own move takes the hand down, as Discord's does.
                voiceStates[subject]?.requestToSpeakAt = nil
            } else if isSpeaker, voiceStates[subject]?.requestToSpeakAt == nil {
                // Discord stamps an invitation itself; drawn as "Invite Sent"
                // on the click rather than a round trip later.
                voiceStates[subject]?.requestToSpeakAt = .now
            }
        }
        sessionController.writeStageSuppress(
            !isSpeaker,
            userID: userID,
            inGuild: guildID,
            channelID: channelID
        )
    }

    /// Discord's Dismiss on a raised hand: back to the audience, the hand down.
    func dismissStageRequest(_ userID: UserID, inChannel channelID: ChannelID) {
        setStageSpeaker(userID, isSpeaker: false, inChannel: channelID)
    }

    /// Discord's "Allow requests from @everyone": `REQUEST_TO_SPEAK` allowed or
    /// denied in the channel's `@everyone` overwrite, every other bit of it
    /// kept — its `updatePermissionOverwrite`.
    func setEveryoneMayRequestToSpeak(_ allowed: Bool, inChannel channelID: ChannelID) {
        guard let channel = channelIndex[channelID], let guildID = channel.guildID else { return }
        let current = channel.overwrites.first { $0.subject == .role && $0.id == guildID.rawValue }
        var allow = current?.allow ?? []
        var deny = current?.deny ?? []
        if allowed {
            allow.insert(.requestToSpeak)
            deny.remove(.requestToSpeak)
        } else {
            allow.remove(.requestToSpeak)
            deny.insert(.requestToSpeak)
        }
        sessionController.writeChannelOverwrite(
            in: channelID, subjectID: guildID.rawValue, isRole: true, allow: allow, deny: deny
        )
    }

    /// Answers a moderator's invitation — Discord's `L(channel, suppress)`:
    /// the hand comes down either way, and accepting lifts the suppression.
    func answerStageInvite(accept: Bool, inChannel channelID: ChannelID) {
        guard let guildID = channelIndex[channelID]?.guildID, let userID = currentUserID else { return }
        voiceStates[userID]?.isSuppressed = !accept
        voiceStates[userID]?.requestToSpeakAt = nil
        voiceRevision &+= 1
        sessionController.writeStageInviteAnswer(accept, inGuild: guildID, channelID: channelID)
    }

    /// Discord's Continue without starting: the start screen put away, and
    /// the reader into the room if they are not in it — not onto the stage.
    func continueStageWithoutStarting(inChannel channelID: ChannelID) {
        stageStartScreenDismissedIn = channelID
        if connectedVoiceChannelID != channelID { joinVoice(channelID) }
    }

    /// Starts a stage — Discord's Start Stage, or its Start Event for a stage
    /// event, whose name is the topic. The reader goes into the room first if
    /// they are not in it, as Discord's does. Nil once it is live; Discord's
    /// refusal otherwise, for the dialog to show.
    func startStage(
        inChannel channelID: ChannelID,
        topic: String,
        notifyEveryone: Bool,
        event: ScheduledEvent? = nil
    ) async -> String? {
        guard let guildID = channelIndex[channelID]?.guildID else { return nil }
        if connectedVoiceChannelID != channelID { joinVoice(channelID) }
        do {
            try await sessionController.startStage(
                channelID: channelID,
                guildID: guildID,
                topic: topic,
                notifyEveryone: notifyEveryone,
                scheduledEventID: event?.id
            )
            return nil
        } catch {
            return Self.stageRefusal(error)
        }
    }

    /// Discord's Edit Stage: the topic of a stage already live.
    func setStageTopic(_ topic: String, inChannel channelID: ChannelID) async -> String? {
        guard let live = stageInstances[channelID] else { return nil }
        do {
            try await sessionController.setStageTopic(topic, privacyLevel: live.privacyLevel, channelID: channelID)
            return nil
        } catch {
            return Self.stageRefusal(error)
        }
    }

    private static func stageRefusal(_ error: any Error) -> String {
        if case DiscordREST.Failure.api(_, _, let message?) = error { return message }
        return "Something went wrong, try again later"
    }

    func endStage(inChannel channelID: ChannelID) {
        sessionController.writeEndStage(channelID: channelID)
    }

    /// Discord's Dismiss on "This Video Stage is maxed out.".
    func dismissStageCapacityNotice(in channelID: ChannelID) {
        dismissedStageCapacityNotices.insert(channelID)
    }

    // MARK: Applying what the wire says

    func applyStage(_ stage: StageInstance) {
        guard stageInstances[stage.channelID] != stage else { return }
        // Going live puts the start screen away for whoever is in the room,
        // and it stays away until they leave (Discord's `vI`).
        if connectedVoiceChannelID == stage.channelID { stageStartScreenDismissedIn = stage.channelID }
        stageInstances[stage.channelID] = stage
        voiceRevision &+= 1
    }

    func applyStageEnded(_ channelID: ChannelID) {
        guard stageInstances.removeValue(forKey: channelID) != nil else { return }
        voiceRevision &+= 1
    }

    /// Writes a suppression locally, so the tile moves on the click rather
    /// than a round trip later.
    ///
    /// **Suppressing also takes the hand down**, because that is what the
    /// route does — see `DiscordREST.setStageSpeaker`. Leaving it up locally
    /// would put somebody in the moderator's queue who is already back in the
    /// audience by their own choice.
    func applyStageSuppress(_ isSuppressed: Bool, for userID: UserID) {
        guard voiceStates[userID] != nil else { return }
        voiceStates[userID]?.isSuppressed = isSuppressed
        if isSuppressed { voiceStates[userID]?.requestToSpeakAt = nil }
        voiceRevision &+= 1
    }

    func applySelfStageRequest(_ at: Date?) {
        guard let userID = currentUserID, voiceStates[userID] != nil else { return }
        voiceStates[userID]?.requestToSpeakAt = at
        voiceRevision &+= 1
    }
}

/// One face on a stage.
///
/// **Not `VoiceParticipant`.** A stage tile has no video, no screen share and
/// nothing to watch — a stage is audio, and the audience is drawn as a grid of
/// faces at a third the size. Carrying the call's tile here would be carrying
/// six fields that are always false and inviting a view to read one.
struct StageMember: Hashable, Sendable, Identifiable {
    var id: UserID
    var name: String
    var avatarURL: URL?
    var monogram: String
    var nameColor: UInt32?
    var isSpeaking: Bool
    var isMuted: Bool
    var isSelf: Bool
    /// Discord's "Stage Moderator" mark.
    var isModerator = false
    /// What Discord writes under a raised hand — `StageRequesterLabel`.
    var requestLabel: String?
    /// Invited and not yet answered — "Invite Sent".
    var isInvited = false
}

/// Somebody blocked or ignored in a stage — a row of Discord's "Blocked
/// Accounts Present".
struct StageFlaggedPerson: Hashable, Sendable, Identifiable {
    var id: UserID
    var name: String
    var avatarURL: URL?
    var monogram: String
    /// Blocked, rather than ignored.
    var isBlocked: Bool
    /// "Speaker", "Stage Moderator" or "Audience".
    var place: String
}

/// The tray's music button: Discord's words, and whether it is lit.
struct StageMusicButton: Hashable, Sendable {
    var title: String
    var isOn: Bool
}

/// Everything the stage pane draws, as one plain value.
struct StagePresentation: Hashable, Sendable {
    var channelID: ChannelID
    var guildID: GuildID?
    var channelName: String
    /// What the host called this stage. Nil when nothing is running.
    var topic: String?
    /// Whether a stage is actually live, as opposed to a stage channel with
    /// people standing in it.
    var isLive: Bool
    var speakers: [StageMember]
    var audience: [StageMember]
    /// Hands up, oldest first. Drawn only for a moderator — the queue is
    /// theirs to run.
    var requests: [StageMember]
    var isConnected: Bool
    /// On the stage — Discord's `ON_STAGE`: unsuppressed, no hand up.
    var isSpeaker: Bool
    var hasRaisedHand: Bool
    /// Discord's stage moderator: End Stage, Start the Stage, the start
    /// screen, the topic.
    var isModerator: Bool
    /// Mute Members — the full tray, and Speak on Stage for oneself.
    var canMuteMembers: Bool
    var canRequestToSpeak: Bool
    /// Discord's age gate holds the microphone back — "Speaker abilities are
    /// only for confirmed adults".
    var withholdsSpeaking: Bool
    /// A teen where the gate applies: Start the Stage is not offered.
    var isTeen: Bool
    /// Join Stage, or Discord's disabled Channel Locked.
    var canConnect: Bool
    /// Discord's Invite beside Join Stage.
    var canInvite: Bool
    /// Discord's Create Event card on the start screen.
    var canCreateEvent: Bool
    /// Discord's start screen (module 571909).
    var showsStartScreen: Bool
    /// A moderator has invited the reader up, and the answer is theirs.
    var isInvitedToSpeak: Bool
    /// Discord's "Allow requests from @everyone".
    var allowsEveryoneToRequest: Bool
    /// The channel's events about to start.
    var imminentEvents: [ScheduledEvent]
    /// People the reader blocked, and people they ignored, in the room.
    var blockedCount: Int
    var ignoredCount: Int
    /// Discord's "This Video Stage is maxed out.", for a moderator.
    var isVideoFull: Bool
    /// The tray's music button, while the reader is in the room.
    var music: StageMusicButton?
    /// "… is currently waiting", over everybody in the room.
    var waitingLine: String?
    /// "… is currently speaking", under the join card's title.
    var speakingLine: String
}
