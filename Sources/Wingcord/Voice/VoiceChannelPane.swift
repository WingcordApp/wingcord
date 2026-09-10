import AVFoundation
import CoreMedia
import SwiftUI
import WingcordCore

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
    @State private var cameraSession: AVCaptureSession?

    var body: some View {
        Group {
            if let presentation = model.voicePresentation,
               presentation.channelID == channelID {
                connected(presentation)
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
        VoiceTileGrid(
            participants: presentation.participants,
            spotlightUserID: presentation.spotlightUserID,
            effects: effectNames,
            cameraSession: cameraSession,
            selfUserID: model.currentUserID,
            attachVideo: model.attachVideo,
            watch: model.toggleWatchingStream,
            spotlight: model.spotlight
        )
        .padding(Spacing.margin)
        .safeAreaBar(edge: .bottom, spacing: 0) {
            VoiceControlBar(
                presentation: presentation,
                toggleMute: model.toggleVoiceMute,
                toggleDeafen: model.toggleVoiceDeafen,
                toggleCamera: model.toggleCamera,
                toggleScreenShare: model.toggleScreenShare,
                leave: model.leaveVoice
            )
            .padding(.bottom, Spacing.margin)
        }
    }

    private var effectNames: [UserID: String] {
        var names: [UserID: String] = [:]
        for (userID, soundID) in model.soundboardEffects {
            names[userID] = model.soundboardSound(id: soundID)?.name ?? "sound"
        }
        return names
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
                Image(systemName: chips.isEmpty ? "speaker.wave.2" : "person.2.wave.2.fill")
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

            Button {
                model.joinVoice(channelID)
            } label: {
                HStack(spacing: Spacing.base) {
                    Image(systemName: "phone.fill")
                    Text("Join Voice")
                        .font(.system(.body, weight: .semibold))
                }
                .foregroundStyle(InkColor.primary)
                .padding(.horizontal, Spacing.group)
                .frame(height: 40)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .emphasisChrome(Palette.presenceOnline)
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
