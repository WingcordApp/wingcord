import SwiftUI
import WingcordCore

/// A stage channel, in Discord's three arrangements under one header (module
/// 883396, `iA`): **the start screen** for a moderator while nothing is live,
/// **the room** for somebody in it, and **the join card** for everybody else.
///
/// # Why this is not the voice pane with a filter on it
///
/// A voice channel is one group of equals. A stage is **two groups and a
/// queue**, and the difference is not cosmetic: the audience is not a set of
/// muted speakers, it is a set of people whose microphone is not on the stage
/// at all. Drawing them as dimmer voice tiles would say the wrong thing about
/// what a click does — muting a speaker is reversible by them, and moving them
/// to the audience is not.
///
/// So: speakers at full size with their rings and their badges, the audience as
/// a dense grid of faces at half that, and — for whoever may answer them — the
/// raised hands in the order they went up.
struct StagePane: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    /// Discord's Show Requests — closed until asked for, as its own is.
    @State private var showsRequests = false
    @State private var sheet: StageSheet?
    @State private var confirmation: StageConfirmation?
    @State private var isConfirming = false

    var body: some View {
        Group {
            if let stage = model.stagePresentation(of: channelID) {
                content(stage)
            } else {
                // Not a stage channel. Nothing to draw and nothing to say —
                // the workspace only routes here for `.stage`.
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // **Asked on open, not only awaited.** READY carries the stages that
        // were live when this client connected, and the gateway carries every
        // one that starts while it is watching — but a resume can miss the
        // event between, and a stage channel opened cold is exactly when the
        // answer matters.
        .task(id: channelID) {
            model.sessionController.loadStage(inChannel: channelID)
        }
        // Discord's "Welcome to Stages!", the first time any stage is opened.
        .onAppear {
            guard !AppSettings.shared.hasSeenStageWelcome else { return }
            AppSettings.shared.hasSeenStageWelcome = true
            sheet = .welcome
        }
        .modal(item: $sheet) { sheet in
            switch sheet {
            case .start:
                StartStageSheet(channelID: channelID)
            case .startEvent(let event):
                StageEventStartSheet(event: event, channelID: channelID)
            case .welcome:
                StageWelcomeSheet()
            case .blockedPresent:
                StageBlockedSheet(channelID: channelID) { model.joinVoice(channelID) }
            }
        }
        .modal(isPresented: $isConfirming, style: .alert) {
            if let asked = confirmation {
                ModalAlert(
                    hero: .symbol("person.wave.2.fill"),
                    title: asked.title,
                    message: Text(asked.message),
                    actions: {
                        switch asked {
                        case .endStage:
                            [
                                .cancel(),
                                .act("End Stage", symbol: "stop.circle", irreversible: true) { endAndLeave() },
                            ]
                        case .alsoEnd:
                            // Three, so they stack — the act first.
                            [
                                .cancel(),
                                .secondary("No, just disconnect quietly", symbol: "phone.down") { model.leaveVoice() },
                                .act("Disconnect and End", symbol: "stop.circle", irreversible: true) { endAndLeave() },
                            ]
                        }
                    }()
                )
            }
        }
    }

    // MARK: The arrangements

    private func content(_ stage: StagePresentation) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                StageHeader(
                    stage: stage,
                    showsRequestsButton: stage.canMuteMembers && !showsRequests
                ) { showsRequests = true }
                Divider()
                if stage.isVideoFull {
                    StageCapacityNotice { model.dismissStageCapacityNotice(in: channelID) }
                        .padding(.top, Spacing.snug)
                }
                Group {
                    if stage.showsStartScreen {
                        StageStartScreen(
                            stage: stage,
                            waitingFaces: Array((stage.speakers + stage.audience).prefix(3))
                        ) { startAct($0, stage) }
                    } else if stage.isConnected {
                        room(stage)
                    } else {
                        StageJoinCard(stage: stage) { join(stage) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                if stage.isConnected {
                    StageControlBar(stage: stage, isMuted: model.isSelfMuted) { trayAct($0, stage) }
                        .padding(.bottom, Spacing.margin)
                }
            }
            // **The queue is theirs who may answer it.** An audience member
            // seeing eleven raised hands learns only that they are eleventh.
            if showsRequests, stage.canMuteMembers {
                Divider()
                StageRequestsSidebar(
                    requests: stage.requests,
                    canEditPermissions: canEditPermissions,
                    allowsEveryone: stage.allowsEveryoneToRequest,
                    setAllowsEveryone: { model.setEveryoneMayRequestToSpeak($0, inChannel: channelID) },
                    invite: { model.setStageSpeaker($0, isSpeaker: true, inChannel: channelID) },
                    dismiss: { model.dismissStageRequest($0, inChannel: channelID) },
                    close: { showsRequests = false }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(motion.panel, value: showsRequests)
    }

    private func room(_ stage: StagePresentation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.group) {
                if stage.isInvitedToSpeak { invitation }

                // Discord's `n4` over a room still waiting: what is about to
                // start and, for a moderator, the highlighted Start the Stage.
                if !stage.isLive, !stage.imminentEvents.isEmpty || (stage.isModerator && !stage.isTeen) {
                    VStack(spacing: Spacing.snug) {
                        StageEventCards(events: stage.imminentEvents) { startAct($0, stage) }
                        if stage.isModerator, !stage.isTeen {
                            StageOptionCard(
                                title: "Start the Stage",
                                detail: "Pick a topic to start the conversation.",
                                symbol: "person.wave.2.fill",
                                tint: Palette.presenceOnline,
                                isHighlighted: true
                            ) { sheet = .start }
                        }
                    }
                    .frame(maxWidth: 440)
                    .frame(maxWidth: .infinity)
                }

                if stage.isLive || !stage.speakers.isEmpty {
                    section("Speakers", count: stage.speakers.count) {
                        SpeakerRow(
                            members: stage.speakers,
                            canMove: stage.canMuteMembers,
                            moveToAudience: { userID in
                                model.setStageSpeaker(userID, isSpeaker: false, inChannel: channelID)
                            }
                        )
                    }
                }

                if !stage.audience.isEmpty {
                    section("Audience", count: stage.audience.count) {
                        AudienceGrid(members: stage.audience)
                    }
                }
            }
            .padding(Spacing.margin)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .animation(motion.standard, value: stage.speakers)
        .animation(motion.standard, value: stage.audience)
    }

    /// Discord's notice to someone a moderator has invited up.
    private var invitation: some View {
        HStack(spacing: Spacing.snug) {
            Image(systemName: "mic.fill")
                .foregroundStyle(Palette.accent)
            Text("You have been invited to speak.")
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(Ink.primary)
            Spacer(minLength: Spacing.base)
            Button("Accept") { model.answerStageInvite(accept: true, inChannel: channelID) }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .tint(Palette.accent)
            Button("Decline") { model.answerStageInvite(accept: false, inChannel: channelID) }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
        }
        .padding(Spacing.snug)
        .background(Palette.surfaceRaised, in: .rect(cornerRadius: Radius.card, style: .continuous))
    }

    @ViewBuilder
    private func section(
        _ title: String,
        count: Int,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            Text("\(title.uppercased()) \u{2014} \(count)")
                .font(.system(.caption2, weight: .bold))
                .foregroundStyle(Ink.quaternary)
                .tracking(0.6)
            content()
        }
    }

    // MARK: Acts

    /// Discord's gate on the toggle in Requests to Speak: Manage Channels or
    /// Manage Roles.
    private var canEditPermissions: Bool {
        let permissions = model.permissionGate.permissions(in: channelID)
        return permissions.contains(.manageChannels) || permissions.contains(.manageRoles)
    }

    /// Discord's `cy`: somebody who does not moderate, joining a room with
    /// people they blocked or ignored in it, is told first (`j6`).
    private func join(_ stage: StagePresentation) {
        if !stage.isModerator, stage.blockedCount + stage.ignoredCount > 0 {
            sheet = .blockedPresent
        } else {
            model.joinVoice(channelID)
        }
    }

    private func startAct(_ act: StageStartAct, _ stage: StagePresentation) {
        switch act {
        case .startStage:
            sheet = .start
        case .createEvent:
            if let guildID = stage.guildID { model.openEventEditor(inGuild: guildID) }
        case .continueWithoutStarting:
            model.continueStageWithoutStarting(inChannel: channelID)
        case .event(let event):
            if model.canManage(event) {
                sheet = .startEvent(event)
            } else {
                model.openEvents(inGuild: event.guildID, event: event.id)
            }
        }
    }

    private func trayAct(_ act: StageAct, _ stage: StagePresentation) {
        switch act {
        case .toggleMute: model.toggleVoiceMute()
        case .music: model.toggleStageMusic()
        case .hand: model.setStageHandRaised(!stage.hasRaisedHand, inChannel: channelID)
        case .speakOnStage: model.setStageSpeaker(nil, isSpeaker: true, inChannel: channelID)
        case .leaveStage: model.leaveStageAsSpeaker(inChannel: channelID)
        case .changeTopic, .startStage: sheet = .start
        case .voiceSettings: SettingsWindow.open(.voiceVideo)
        case .disconnect:
            // Discord's `106044`: the last moderator speaking is asked whether
            // the stage ends with them.
            if model.isLastStageModerator(in: channelID) {
                ask(.alsoEnd)
            } else {
                model.leaveVoice()
            }
        case .endStage:
            ask(.endStage)
        }
    }

    private func ask(_ asked: StageConfirmation) {
        confirmation = asked
        isConfirming = true
    }

    private func endAndLeave() {
        model.endStage(inChannel: channelID)
        model.leaveVoice()
    }
}

/// Discord's two questions on the way out of a live stage.
enum StageConfirmation {
    /// End Stage for Everyone (module 25997).
    case endStage
    /// The last moderator speaking disconnects (module 118101).
    case alsoEnd

    var title: String {
        switch self {
        case .endStage: "Are you sure you want to end the Stage for everyone?"
        case .alsoEnd: "Do you want to also end the Stage?"
        }
    }

    var message: String {
        switch self {
        case .endStage: "The Stage will end immediately."
        case .alsoEnd: "A Stage with no speakers will automatically end after a few minutes."
        }
    }
}
