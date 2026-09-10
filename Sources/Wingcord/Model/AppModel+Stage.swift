import Foundation
import WingcordCore

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

    /// Everything the stage pane needs, resolved once.
    ///
    /// Nil for anything that is not a stage channel, which is what keeps the
    /// pane from drawing an audience for an ordinary voice room.
    func stagePresentation(of channelID: ChannelID) -> StagePresentation? {
        guard let channel = channelIndex[channelID], channel.kind == .stage else { return nil }
        let guildID = channel.guildID
        let roster = stageRoster(in: channelID)
        let permissions = permissionGate.permissions(in: channelID)
        let selfState = currentUserID.flatMap { voiceStates[$0] }
        let isHere = selfState?.channelID == channelID

        // **One permission answers three different questions**, which is why
        // it is resolved once here rather than asked three times in the view:
        // `MUTE_MEMBERS` is what makes somebody a stage moderator — it is the
        // bit that lets them unsuppress themselves, unsuppress anybody else,
        // and therefore run the queue.
        let isModerator = permissions.contains(.muteMembers)

        return StagePresentation(
            channelID: channelID,
            guildID: guildID,
            channelName: channel.name,
            topic: stageInstances[channelID]?.topic,
            isLive: stageInstances[channelID] != nil,
            speakers: roster.speakers.map { stageMember($0, inGuild: guildID) },
            audience: roster.audience.map { stageMember($0, inGuild: guildID) },
            requests: roster.requests.map { stageMember($0, inGuild: guildID) },
            isConnected: isHere,
            isSpeaker: isHere && selfState?.isSuppressed == false,
            hasRaisedHand: isHere && selfState?.requestToSpeakAt != nil,
            isModerator: isModerator,
            // **Offered only where it can be honoured** — §5.5. Without
            // `REQUEST_TO_SPEAK` the route refuses the hand, and a moderator
            // has no use for one because they can simply step up.
            canRaiseHand: isHere && !isModerator && permissions.contains(.requestToSpeak),
            canStartStage: isModerator
        )
    }

    private func stageMember(_ userID: UserID, inGuild guildID: GuildID?) -> StageMember {
        let user = users[userID]
        return StageMember(
            id: userID,
            name: voiceName(of: userID, inGuild: guildID),
            avatarURL: user.flatMap { avatarURL(for: $0, side: Metrics.avatarProfile) },
            monogram: user?.monogram ?? "?",
            nameColor: voiceNameColor(of: userID, inGuild: guildID),
            isSpeaking: userID == currentUserID ? isSelfSpeaking : speakingUserIDs.contains(userID),
            isMuted: voiceStates[userID]?.isSilenced ?? false,
            isSelf: userID == currentUserID
        )
    }

    // MARK: What the reader can do

    /// Raises a hand, or lowers one.
    ///
    /// **The instant must be now or later** — Discord refuses a timestamp in
    /// the past, and a client that sent the moment the button was pressed
    /// would lose the race with its own request often enough to look
    /// intermittent. Lowering it sends an explicit null; see
    /// `DiscordREST.setSelfStageState` for why that needs a hand-written
    /// encoder.
    func setStageHandRaised(_ isRaised: Bool, inChannel channelID: ChannelID) {
        guard let guildID = channelIndex[channelID]?.guildID else { return }
        applySelfStageRequest(isRaised ? .now : nil)
        sessionController.writeStageHand(isRaised, inGuild: guildID, channelID: channelID)
    }

    /// Steps down to the audience.
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
        if let subject { applyStageSuppress(!isSpeaker, for: subject) }
        sessionController.writeStageSuppress(
            !isSpeaker,
            userID: userID,
            inGuild: guildID,
            channelID: channelID
        )
    }

    func startStage(inChannel channelID: ChannelID, topic: String, notifyEveryone: Bool) {
        guard let guildID = channelIndex[channelID]?.guildID else { return }
        sessionController.writeStartStage(
            channelID: channelID,
            guildID: guildID,
            topic: topic,
            notifyEveryone: notifyEveryone
        )
    }

    func endStage(inChannel channelID: ChannelID) {
        sessionController.writeEndStage(channelID: channelID)
    }

    // MARK: Applying what the wire says

    func applyStage(_ stage: StageInstance) {
        guard stageInstances[stage.channelID] != stage else { return }
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
    /// Hands up, oldest first. Empty for everybody who is not a moderator —
    /// the queue is theirs to run.
    var requests: [StageMember]
    var isConnected: Bool
    var isSpeaker: Bool
    var hasRaisedHand: Bool
    var isModerator: Bool
    var canRaiseHand: Bool
    var canStartStage: Bool
}
