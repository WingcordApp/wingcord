import SwiftUI
import WingcordCore

// MARK: - The call, wherever you are in the app
//
// A floating glass panel above the now bar. It is the answer to "I joined a
// voice channel and then went to read something else": the call has to stay
// reachable from every screen, and the sidebar's foot is the one place that is
// on every screen.
//
// **`.clear` here, and `.regular` would be wrong.** This sits on the sidebar
// column, which AppKit paints with behind-window vibrancy — the wallpaper and
// the menu-bar accent come through it. A frosted panel over that throws the
// bleed away and leaves a grey slab down the side of the window; clear glass
// lenses it, which is the whole reason this app uses the material.
struct VoiceHUD: View {
    var presentation: VoicePresentation
    var speakingUserIDs: Set<UserID>

    var toggleMute: () -> Void = {}
    var toggleDeafen: () -> Void = {}
    var toggleCamera: () -> Void = {}
    var toggleScreenShare: () -> Void = {}
    var openChannel: () -> Void = {}
    var leave: () -> Void = {}

    @Environment(\.motion) private var motion
    @State private var isExpanded = true
    /// Local, for the reason `VoiceControlBar`'s is — see the note there.
    @State private var isSoundboardOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            header

            if isExpanded {
                faces
                controls
            }
        }
        .padding(Spacing.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(
            .clear.tint(Palette.flyoutTint),
            in: .rect(cornerRadius: Radius.glass)
        )
        .padding(.horizontal, Spacing.base)
        .animation(motion.panel, value: isExpanded)
        .animation(motion.standard, value: presentation.participants.count)
    }

    // MARK: The line that says where you are

    private var header: some View {
        HStack(spacing: Spacing.base) {
            Button(action: openChannel) {
                VoiceQualityLine(
                    quality: presentation.quality,
                    channelName: presentation.channelName,
                    guildName: presentation.guildName
                )
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Open the call")

            Button { isExpanded.toggle() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(.caption2, weight: .bold))
                    .foregroundStyle(Ink.tertiary)
                    // Rotates rather than swapping glyphs: the same mark
                    // pointing a different way says "this opens and closes",
                    // where two glyphs say "this is two controls".
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    .frame(width: 18, height: 18)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(isExpanded ? "Collapse the call" : "Expand the call"))
        }
    }

    // MARK: Who is in it

    /// A row of faces rather than tiles. At the sidebar's width a tile is
    /// smaller than the face inside it, so the tile is dropped and the face
    /// keeps the speaking ring — which is the part that carries the information.
    private var faces: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Spacing.base) {
                ForEach(presentation.participants) { participant in
                    face(participant)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.never)
        // A call of four fits without scrolling, and a scroll view that
        // rubber-bands over content that already fits reads as broken.
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: 40)
    }

    private func face(_ participant: VoiceParticipant) -> some View {
        AvatarView(
            url: participant.avatarURL,
            monogram: participant.monogram,
            side: 32
        )
        .overlay {
            Circle()
                .strokeBorder(
                    participant.isSpeaking ? Palette.presenceOnline : .clear,
                    lineWidth: 2
                )
                .padding(-2.5)
        }
        .overlay(alignment: .bottomTrailing) {
            if participant.isDeafened || participant.isSilenced {
                Image(systemName: participant.isDeafened ? "headphones.slash" : "mic.slash.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(InkColor.primary)
                    .frame(width: 14, height: 14)
                    .background { Circle().fill(Palette.destructive) }
                    .offset(x: 2, y: 2)
            }
        }
        .opacity(participant.isSpeaking ? 1 : 0.72)
        .animation(motion.standard, value: participant.isSpeaking)
        .transition(.scale(scale: 0.7).combined(with: .opacity))
        .help(participant.displayName)
        .accessibilityLabel(Text(participant.displayName))
    }

    // MARK: The controls

    /// The same six as the stage, at the compact size, with the hang-up
    /// carrying the tint. One vocabulary in both places — a control that means
    /// something different in the HUD than on the stage is a control nobody
    /// trusts.
    private var controls: some View {
        HStack(spacing: Spacing.tight) {
            VoiceControl(
                systemImage: presentation.isMuted ? "mic.slash.fill" : "mic.fill",
                label: presentation.isMuted ? "Unmute" : "Mute",
                isActive: presentation.isMuted,
                accent: Palette.destructive,
                isCompact: true,
                action: toggleMute
            )
            VoiceControl(
                systemImage: presentation.isDeafened ? "headphones.slash" : "headphones",
                label: presentation.isDeafened ? "Undeafen" : "Deafen",
                isActive: presentation.isDeafened,
                accent: Palette.destructive,
                isCompact: true,
                action: toggleDeafen
            )
            VoiceControl(
                systemImage: presentation.isCameraOn ? "video.fill" : "video.slash.fill",
                label: presentation.isCameraOn ? "Turn Off Camera" : "Turn On Camera",
                isActive: presentation.isCameraOn,
                accent: Palette.accent,
                isCompact: true,
                action: toggleCamera
            )
            VoiceControl(
                systemImage: "rectangle.inset.filled.on.rectangle",
                label: presentation.isScreenSharing ? "Stop Sharing" : "Share Screen",
                isActive: presentation.isScreenSharing,
                accent: Palette.presenceOnline,
                isCompact: true,
                action: toggleScreenShare
            )
            VoiceControl(
                systemImage: "music.note.list",
                label: "Soundboard",
                isActive: isSoundboardOpen,
                accent: Palette.accent,
                isCompact: true,
                action: { isSoundboardOpen.toggle() }
            )
            .popover(isPresented: $isSoundboardOpen, arrowEdge: .top) {
                SoundboardPickerContainer { isSoundboardOpen = false }
            }

            Spacer(minLength: Spacing.tight)

            Button(action: leave) {
                Image(systemName: "phone.down.fill")
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(InkColor.primary)
                    .frame(width: Metrics.compactControl, height: Metrics.compactControl)
                    .background { Circle().fill(Palette.destructive) }
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help("Leave the call")
            .accessibilityLabel(Text("Leave the call"))
        }
    }
}

/// Reads the store and hands the HUD its call.
///
/// One container per surface — §2 — so a message arriving cannot invalidate the
/// call panel, and a packet arriving cannot invalidate the channel list.
struct VoiceHUDContainer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    var body: some View {
        Group {
            if let presentation = model.voicePresentation {
                VoiceHUD(
                    presentation: presentation,
                    speakingUserIDs: model.speakingUserIDs,
                    toggleMute: model.toggleVoiceMute,
                    toggleDeafen: model.toggleVoiceDeafen,
                    toggleCamera: model.toggleCamera,
                    toggleScreenShare: model.toggleScreenShare,
                    openChannel: { model.selectChannel(presentation.channelID) },
                    leave: model.leaveVoice
                )
                // Glass materialises rather than fading, and it arrives from the
                // edge it lives on — the sidebar's foot. Spatial symmetry: it
                // leaves the same way.
                .transition(
                    .move(edge: .bottom).combined(with: .materialize(from: .bottom))
                )
            }
        }
        .animation(motion.panel, value: model.connectedVoiceChannelID)
    }
}
