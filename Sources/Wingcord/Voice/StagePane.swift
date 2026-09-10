import SwiftUI
import WingcordCore

/// A stage channel, seen from inside and from outside.
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
/// a dense grid of faces at half that, and — for a moderator only — the raised
/// hands in the order they went up.
///
/// # The three states of a stage channel
///
/// **Dark** — nobody has started a stage. The channel exists, people may be
/// standing in it, and there is nothing to listen to. A moderator gets the one
/// control that changes that.
///
/// **Live, from outside** — a stage is running and the reader is not in it.
/// The topic, who is speaking, and a way in.
///
/// **Live, from inside** — everything above, plus the reader's own place in it
/// and the controls that change it.
struct StagePane: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    /// The topic being typed for a stage about to start. Held here rather than
    /// in the store: it is a draft on one surface and it dies with the view.
    @State private var draftTopic = ""
    @State private var isNamingStage = false

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
    }

    // MARK: The room

    @ViewBuilder
    private func content(_ stage: StagePresentation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.group) {
                header(stage)

                if stage.isLive || !stage.speakers.isEmpty {
                    section("Speakers", count: stage.speakers.count) {
                        SpeakerRow(
                            members: stage.speakers,
                            canMove: stage.isModerator,
                            moveToAudience: { userID in
                                model.setStageSpeaker(
                                    userID, isSpeaker: false, inChannel: channelID
                                )
                            }
                        )
                    }
                }

                // **The queue is a moderator's surface and nobody else's.** An
                // audience member seeing eleven raised hands learns only that
                // they are eleventh, which is a fact this client would be
                // inventing — Discord shows the count to the room and the list
                // to the people who can act on it.
                if stage.isModerator, !stage.requests.isEmpty {
                    section("Requests to speak", count: stage.requests.count) {
                        RequestList(
                            members: stage.requests,
                            invite: { userID in
                                model.setStageSpeaker(
                                    userID, isSpeaker: true, inChannel: channelID
                                )
                            }
                        )
                    }
                }

                if !stage.audience.isEmpty {
                    section("Audience", count: stage.audience.count) {
                        AudienceGrid(members: stage.audience)
                    }
                }

                if !stage.isLive { dark(stage) }
            }
            .padding(Spacing.margin)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .softScrollEdgeTopOnly()
        .safeAreaBar(edge: .bottom, spacing: 0) {
            StageControlBar(
                stage: stage,
                raiseHand: { model.setStageHandRaised(!stage.hasRaisedHand, inChannel: channelID) },
                stepDown: { model.leaveStageAsSpeaker(inChannel: channelID) },
                stepUp: { model.setStageSpeaker(nil, isSpeaker: true, inChannel: channelID) },
                join: { model.joinVoice(channelID) },
                leave: { model.leaveVoice() },
                endStage: { model.endStage(inChannel: channelID) },
                toggleMute: { model.toggleVoiceMute() },
                isMuted: model.isSelfMuted
            )
            .padding(.bottom, Spacing.margin)
        }
        .animation(motion.standard, value: stage.speakers)
        .animation(motion.standard, value: stage.audience)
        .animation(motion.standard, value: stage.requests)
    }

    // MARK: Parts

    private func header(_ stage: StagePresentation) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(spacing: Spacing.base) {
                Image(systemName: "person.wave.2.fill")
                    .font(.system(.body))
                    .foregroundStyle(
                        stage.isLive
                            ? AnyShapeStyle(Palette.presenceOnline)
                            : AnyShapeStyle(Ink.tertiary)
                    )
                Text(stage.topic?.isEmpty == false ? stage.topic! : stage.channelName)
                    .font(.system(.title2, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(2)
            }

            // The two counts Discord puts in its own header, in the same
            // order: who can be heard, then who is listening.
            HStack(spacing: Spacing.snug) {
                Label(
                    "\(stage.speakers.count) speaking",
                    systemImage: "mic.fill"
                )
                Label(
                    "\(stage.audience.count) in audience",
                    systemImage: "person.2.fill"
                )
                if !stage.isLive {
                    Text("The stage has not started.")
                        .foregroundStyle(Ink.quaternary)
                }
            }
            .font(.system(.caption))
            .foregroundStyle(Ink.tertiary)
        }
    }

    @ViewBuilder
    private func section(
        _ title: String,
        count: Int,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            Text("\(title.uppercased()) — \(count)")
                .font(.system(.caption2, weight: .bold))
                .foregroundStyle(Ink.quaternary)
                .tracking(0.6)
            content()
        }
    }

    /// A stage channel with the lights off.
    @ViewBuilder
    private func dark(_ stage: StagePresentation) -> some View {
        if stage.canStartStage {
            VStack(alignment: .leading, spacing: Spacing.snug) {
                if isNamingStage {
                    // **A topic is required and this is why it is a field.**
                    // Discord refuses a stage without one, so a bare Start
                    // button would be a control that fails on press.
                    TextField("What is this stage about?", text: $draftTopic)
                        .textFieldStyle(.plain)
                        .font(.system(.body))
                        .foregroundStyle(Ink.primary)
                        .padding(.horizontal, Spacing.snug)
                        .frame(height: 34)
                        .background {
                            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                                .fill(Palette.hoverFill)
                        }
                        .onSubmit(start)

                    HStack(spacing: Spacing.base) {
                        Button("Start Stage", action: start)
                            .buttonStyle(.glass)
                            .disabled(draftTopic.trimmed.isEmpty)
                        Button("Cancel") { isNamingStage = false }
                            .buttonStyle(.plain)
                            .foregroundStyle(Ink.tertiary)
                    }
                } else {
                    Button {
                        isNamingStage = true
                    } label: {
                        Label("Start a Stage", systemImage: "play.circle")
                            .font(.system(.subheadline, weight: .semibold))
                            .padding(.horizontal, Spacing.snug)
                            .frame(height: 34)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .emphasisChrome(Palette.presenceOnline)
                }
            }
            .animation(motion.panel, value: isNamingStage)
        } else {
            Text("Nobody has started a stage here yet.")
                .font(.system(.subheadline))
                .foregroundStyle(Ink.tertiary)
        }
    }

    private func start() {
        let topic = draftTopic.trimmed
        guard !topic.isEmpty else { return }
        // **Not `@everyone`, unless somebody asks for it.** The notification
        // reaches people who are not in the room, and a client that sent it by
        // default would be pinging a server on the reader's behalf.
        model.startStage(inChannel: channelID, topic: topic, notifyEveryone: false)
        isNamingStage = false
        draftTopic = ""
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
