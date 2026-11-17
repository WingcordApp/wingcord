import AVFoundation
import CoreMedia
import SwiftUI
import WingcordCore
import WingcordVoice

// MARK: - A server's voice channel
//
// The detail column when a voice channel is open. Two states and one view: the
// room seen from outside, and the room you are in.
//
// **Opening a voice channel does not join it.** That is a decision rather than
// an omission — a click in a list is navigation everywhere else in this app, and
// a click that puts your microphone into a room full of people is not something
// to do by accident. The row selects; the button joins.
struct VoiceChannelPane: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    /// The camera's session, fetched once the camera is actually on. An
    /// `AVCaptureSession` cannot be observed, so it is pulled rather than
    /// published — and only while there is one.
    @State private var cameraSession: CaptureSessionHandle?

    var body: some View {
        Group {
            if let presentation = model.voicePresentation,
               presentation.channelID == channelID {
                // Full screen draws the call's tiles itself, and one person's
                // video can be attached to one view at a time.
                if !model.isCallFullScreen { connected(presentation) }
            } else {
                lobby
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(motion.reposition, value: model.connectedVoiceChannelID)
        .task(id: model.isCameraOn) {
            cameraSession = model.isCameraOn ? await model.cameraSession() : nil
        }
    }

    // MARK: In the room

    private func connected(_ presentation: VoicePresentation) -> some View {
        let activity = model.callActivity(in: presentation.channelID)
        let isPlaying = activity?.isJoined == true
        return VStack(spacing: Spacing.snug) {
            VoiceTileGrid(
                participants: presentation.participants,
                spotlightUserID: presentation.spotlightUserID,
                effects: model.soundboardEffectNames,
                cameraSession: cameraSession,
                selfUserID: model.currentUserID,
                attachVideo: model.attachVideo,
                watch: model.toggleWatchingStream,
                spotlight: model.spotlight,
                activity: activity,
                joinActivity: model.joinCallActivity
            )
            // A game being played keeps its foot: the capsule sits under it.
            .padding(.bottom, isPlaying ? CallCapsuleMetrics.height + CallCapsuleMetrics.lift + Spacing.base : 0)
            // **The controls float over the tiles' foot** (Alex, 2026-11-17),
            // FaceTime's capsule, so the tiles get the stage's whole height.
            .floatingCallControls(isPinned: isPlaying) {
                CallControlCapsule(
                    presentation: presentation,
                    toggleMute: model.toggleVoiceMute,
                    toggleDeafen: model.toggleVoiceDeafen,
                    toggleCamera: model.toggleCamera,
                    toggleScreenShare: model.toggleScreenShare,
                    leave: model.leaveVoice
                ) {
                    CallFullScreenButton()
                }
            }
            if showsActivitySuggestion(presentation) {
                ActivitySuggestionCard(channelID: presentation.channelID)
                    .id(presentation.channelID)
            }
        }
        .padding(Spacing.margin)
    }

    /// Discord's condition for its activity suggestion: a server's call with
    /// two or more people in it, not the AFK channel, nothing already running
    /// here, and Use Activities — "Don't show again" and × are the card's own.
    private func showsActivitySuggestion(_ presentation: VoicePresentation) -> Bool {
        guard presentation.canLaunchActivities, presentation.participants.count >= 2,
              let guildID = model.channelIndex[presentation.channelID]?.guildID,
              model.guilds[guildID]?.afkChannelID != presentation.channelID
        else { return false }
        // Nothing to suggest where an activity already runs: its tile is there.
        return model.runningActivity?.instance.location.channelID != presentation.channelID
            && model.activityInstances.instances(in: presentation.channelID).isEmpty
    }

    // MARK: Looking in

    /// Who is already in there, and the one button that matters.
    ///
    /// The faces are drawn at rest rather than as live tiles: nothing is
    /// arriving — this client is not in the channel and receives no media for it
    /// — so a grid of black rectangles promising video would be four inert
    /// controls, which §5.5 is about.
    private var lobby: some View {
        let chips = model.voiceChips(in: channelID, guildID: model.channelIndex[channelID]?.guildID)
        return VStack(spacing: Spacing.group) {
            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(Palette.selectionFill)
                    .frame(width: 96, height: 96)
                Image(symbol: chips.isEmpty ? "speaker.wave.2" : "person.2.wave.2.fill")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(Ink.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }

            VStack(spacing: Spacing.base) {
                Text(model.channelIndex[channelID]?.name ?? "Voice")
                    .font(.system(.title2, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                Text(subtitle(count: chips.count))
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.tertiary)
            }

            if !chips.isEmpty {
                waitingFaces(chips)
            }

            Button("Join Voice", systemImage: "phone.fill") {
                model.joinVoice(channelID)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .tint(Palette.presenceOnline)
            .controlSize(.extraLarge)
            .keyboardShortcut(.return, modifiers: [])

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(motion.standard, value: chips.count)
    }

    private func waitingFaces(_ chips: [VoiceMemberChip]) -> some View {
        HStack(spacing: -Spacing.base) {
            ForEach(chips.prefix(8)) { chip in
                AvatarView(url: chip.avatarURL, monogram: "?", side: 40)
                    // A hole punched in the neighbour rather than a ring drawn
                    // on top: a stroke on a stack of faces reads as eight
                    // outlined circles, a cut-out reads as depth.
                    .overlay {
                        Circle().strokeBorder(Palette.canvas, lineWidth: 3)
                    }
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
            if chips.count > 8 {
                Text("+\(chips.count - 8)")
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 40, height: 40)
                    .background { Circle().fill(Palette.surfaceRaised) }
                    .overlay { Circle().strokeBorder(Palette.canvas, lineWidth: 3) }
            }
        }
    }

    private func subtitle(count: Int) -> String {
        switch count {
        case 0: "No one is here yet."
        case 1: "One person is in this channel."
        default: "\(count) people are in this channel."
        }
    }
}
