import AVFoundation
import CoreMedia
import SwiftUI
import WingcordCore
import WingcordVoice

// MARK: - A call inside a conversation
//
// A band across the top of a direct message, holding the same tiles and the
// same controls the channel stage does — and resizable, because a call in a
// conversation is something people want *smaller* while they type and bigger
// while they watch.
//
// **Opaque, edge to edge.** It was a clear-glass card floating over the
// transcript, so messages read through the call. The band is the call's own
// surface, the transcript is pushed down by its height rather than covered by
// it, and a hairline closes it off — reference 22, and Alex: "the call overlay
// could be a blur, like on [another client]".
struct VoiceCallOverlay: View {
    var presentation: VoicePresentation
    var effects: [UserID: String]
    var cameraSession: CaptureSessionHandle?
    var selfUserID: UserID?
    var attachVideo: (UserID, (@Sendable (CMSampleBuffer) -> Void)?) -> Void
    /// Opens or closes somebody's screen share.
    var watch: (UserID) -> Void
    var spotlight: (UserID?) -> Void

    var toggleMute: () -> Void = {}
    var toggleDeafen: () -> Void = {}
    var toggleCamera: () -> Void = {}
    var toggleScreenShare: () -> Void = {}
    var leave: () -> Void = {}
    /// Reports the outside height, so the transcript can inset itself by it.
    var heightChanged: (CGFloat) -> Void = { _ in }
    /// The activity running in this call (decision 3).
    var activity: CallActivityPresentation? = nil
    var joinActivity: (CallActivityPresentation) -> Void = { _ in }

    /// The panel's height, at rest.
    ///
    /// **Bounded on purpose, and not by much.** The user asked for resizable and
    /// not *very* resizable, which is the right instinct: past about half the
    /// window a call in a conversation has stopped being a panel and should be
    /// the channel stage instead, and below the floor the tiles are smaller than
    /// the faces in them.
    @State private var height: CGFloat = VoiceCallOverlay.restingHeight
    /// Live drag offset, applied on top of `height` and 1:1 with the pointer.
    @State private var drag: CGFloat = 0
    @State private var isFullHeight = false
    @State private var isGrabberHovering = false

    @Environment(\.motion) private var motion

    static let minimumHeight: CGFloat = 168
    static let maximumHeight: CGFloat = 460
    static let restingHeight: CGFloat = 244

    var body: some View {
        GeometryReader { proxy in
            let ceiling = min(Self.maximumHeight, max(Self.minimumHeight, proxy.size.height * 0.62))
            let resolved = resolvedHeight(ceiling: ceiling)

            band
                .frame(height: isFullHeight ? proxy.size.height : resolved)
                .frame(maxWidth: .infinity, alignment: .top)
                .onChange(of: isFullHeight ? proxy.size.height : resolved, initial: true) { _, value in
                    heightChanged(value)
                }
                // **An activity the reader joins opens the band to the room a
                // game needs, to start with**: the grabber still resizes it
                // (Alex, 2026-11-17: "i cant resize the voice header when an
                // activity is open"; it was pinned to the ceiling).
                .onChange(of: activity?.isJoined == true) { _, joined in
                    guard joined else { return }
                    withAnimation(motion.reposition) { height = ceiling }
                }
        }
        // The band arrives from the edge it lives on and leaves the same way —
        // spatial symmetry, §3.
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func resolvedHeight(ceiling: CGFloat) -> CGFloat {
        // Rubber-banded outside the bounds and 1:1 inside them. A hard stop at
        // the limit reads as frozen; continuous resistance reads as responsive
        // with nothing more to give.
        Motion.clampWithResistance(
            height + drag,
            to: Self.minimumHeight...ceiling,
            limit: ceiling
        )
    }

    // MARK: The band

    private var band: some View {
        VStack(spacing: 0) {
            tiles
            controls
            grabber
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // **Transparent** (Alex, 2026-11-17): the conversation's own backdrop
        // runs behind the call; the tiles and controls carry their own ground.
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: Spacing.tight) {
                CallFullScreenButton()
                expandButton
            }
            .padding(Spacing.snug)
        }
        .animation(motion.reposition, value: isFullHeight)
    }

    private var tiles: some View {
        VoiceTileGrid(
            participants: presentation.participants,
            spotlightUserID: presentation.spotlightUserID,
            effects: effects,
            cameraSession: cameraSession,
            selfUserID: selfUserID,
            attachVideo: attachVideo,
            watch: watch,
            spotlight: spotlight,
            activity: activity,
            joinActivity: joinActivity
        )
        .padding(.horizontal, Spacing.snug)
        .padding(.top, Spacing.snug)
        .frame(maxHeight: .infinity)
    }

    private var controls: some View {
        CallControlRow(
            presentation: presentation,
            toggleMute: toggleMute,
            toggleDeafen: toggleDeafen,
            toggleCamera: toggleCamera,
            toggleScreenShare: toggleScreenShare,
            leave: leave
        )
        .padding(.horizontal, Spacing.snug)
        .padding(.top, Spacing.snug)
    }

    /// The handle at the foot of the band.
    ///
    /// A pill rather than a hit area with nothing in it: an edge that can be
    /// dragged has to say so, and a cursor change alone is a discovery nobody
    /// makes. It brightens on hover, which is the macOS class of motion —
    /// `hover`, fast enough that running the pointer past it leaves no trail.
    private var grabber: some View {
        Capsule()
            .fill(isGrabberHovering ? Palette.edgeStrong : Palette.edge)
            .frame(width: 44, height: 4)
            .padding(.bottom, Spacing.base)
            .padding(.top, Spacing.tight)
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
            .onHover { hovering in
                guard isGrabberHovering != hovering else { return }
                isGrabberHovering = hovering
                // The resize cursor is the other half of saying so, and it has
                // to be pushed and popped rather than set — a cursor set on
                // hover-in and never restored leaks into the whole window.
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(resize)
            .animation(motion.hover, value: isGrabberHovering)
            .accessibilityLabel(Text("Resize the call"))
            .accessibilityValue(Text("\(Int(height)) points tall"))
            .accessibilityAdjustableAction { direction in
                // Full Keyboard Access and VoiceOver get the same range the
                // pointer does. A drag handle with no adjustable action is a
                // control that only exists for a mouse.
                let step: CGFloat = direction == .increment ? 32 : -32
                height = min(Self.maximumHeight, max(Self.minimumHeight, height + step))
            }
    }

    private var resize: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard !isFullHeight else { return }
                drag = value.translation.height
            }
            .onEnded { value in
                guard !isFullHeight else { return }
                let target = min(
                    Self.maximumHeight,
                    max(Self.minimumHeight, height + value.translation.height)
                )
                let settled = height + drag
                height = settled
                drag = 0
                // **Velocity handoff.** The spring starts at the pointer's exact
                // release speed, so there is no seam between the drag and the
                // settle — `momentum` without it puts back the join the whole
                // vocabulary exists to remove.
                withAnimation(
                    motion.handoff(
                        velocity: value.velocity.height,
                        over: target - settled
                    )
                ) {
                    height = target
                }
            }
    }

    /// Fills the pane, and comes back.
    private var expandButton: some View {
        Button {
            isFullHeight.toggle()
        } label: {
            // Vertical, because the band grows down the conversation; the
            // diagonal arrows are full screen's, as they are across macOS.
            Image(symbol: isFullHeight
                ? "rectangle.compress.vertical"
                : "rectangle.expand.vertical")
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .frame(width: Metrics.compactControl, height: Metrics.compactControl)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .background { Circle().fill(Palette.selectionFill) }
        .help(isFullHeight ? "Shrink the call" : "Fill the conversation")
        .accessibilityLabel(Text(isFullHeight ? "Shrink the call" : "Fill the conversation"))
    }
}

/// Reads the store and shows the panel only for the conversation it belongs to.
///
/// **Guarded on the channel, not just on there being a call.** A reader in a
/// server's voice channel who then opens a direct message must not find the
/// server's call floating over that conversation — the panel belongs to the
/// conversation whose call it is.
struct VoiceCallOverlayContainer: View {
    var channelID: ChannelID
    var heightChanged: (CGFloat) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var cameraSession: CaptureSessionHandle?

    var body: some View {
        // **Read once per evaluation.** This is a walk of every voice state the
        // client knows about, and this container is in the conversation pane's
        // body — asking for it again to feed an animation's value would double
        // that for a number that is already in hand.
        let waiting = model.callLobby(for: channelID)
        let lobby = waiting.isEmpty ? nil : waiting

        // **Whether this container is showing anything at all**, which is the
        // only thing the transcript's inset may follow.
        let isShowing = lobby != nil || model.voicePresentation.map {
            $0.isDirect && $0.channelID == channelID && !model.isCallFullScreen
        } ?? false

        return content(lobby: lobby)
            .animation(motion.reposition, value: model.connectedVoiceChannelID)
            .animation(motion.reposition, value: waiting.map(\.id))
        .onChange(of: isShowing) { _, showing in
            // **A panel that has left reports no height of its own**, so the
            // inset it reserved has to be given back here or the transcript
            // stays pushed down for the rest of the session.
            //
            // This used to watch `connectedVoiceChannelID` alone, which misses
            // the exit that actually happens: hang up while the other person is
            // still in the call and the **lobby** takes over — correctly, with
            // a height of its own — and then *they* leave. The channel id has
            // not changed since the first step, so nothing fires, the lobby
            // goes, and a band of empty canvas the size of the panel is left
            // behind with nothing in it. Measured, and it persists until the
            // window is rebuilt.
            //
            // Following "is anything on screen" covers both exits, because it
            // is the question the inset was always asking.
            guard !showing else { return }
            heightChanged(0)
        }
        .task(id: model.isCameraOn) {
            cameraSession = model.isCameraOn ? await model.cameraSession() : nil
        }
    }

    @ViewBuilder
    private func content(lobby: [VoiceParticipant]?) -> some View {
        Group {
            // Full screen draws the call's tiles itself, and one person's video
            // can be attached to one view at a time.
            if let presentation = model.voicePresentation,
               presentation.isDirect,
               presentation.channelID == channelID {
                if !model.isCallFullScreen {
                    VoiceCallOverlay(
                        presentation: presentation,
                        effects: model.soundboardEffectNames,
                        cameraSession: cameraSession,
                        selfUserID: model.currentUserID,
                        attachVideo: model.attachVideo,
                        watch: model.toggleWatchingStream,
                        spotlight: model.spotlight,
                        toggleMute: model.toggleVoiceMute,
                        toggleDeafen: model.toggleVoiceDeafen,
                        toggleCamera: model.toggleCamera,
                        toggleScreenShare: model.toggleScreenShare,
                        leave: model.leaveVoice,
                        heightChanged: heightChanged,
                        activity: model.callActivity(in: channelID),
                        joinActivity: model.joinCallActivity
                    )
                }
            } else if let lobby {
                VoiceCallLobby(
                    participants: lobby,
                    activity: model.callActivity(in: channelID),
                    joinActivity: model.joinCallActivity
                ) { model.joinCall(in: channelID) }
                    .frame(height: VoiceCallLobby.height)
                    .frame(maxWidth: .infinity, alignment: .top)
                    // The band arrives from the edge it lives on and leaves the
                    // same way — §3.
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onAppear { heightChanged(VoiceCallLobby.height) }
            }
        }
    }
}
