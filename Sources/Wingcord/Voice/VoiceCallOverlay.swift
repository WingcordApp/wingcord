import AVFoundation
import CoreMedia
import SwiftUI
import WingcordCore
import WingcordVoice

// MARK: - A call inside a conversation
//
// A band across the top of a direct message, holding the same tiles the
// channel stage does — and resizable, because a call in a conversation is
// something people want *smaller* while they type and bigger while they watch.
//
// **The tiles take the whole band** (Alex, 2026-11-17): the controls float over
// their foot as one capsule of glass, FaceTime's arrangement, and show while
// the pointer is over the call (`FloatingCallControls`). The band's ground is a
// thick material, so the transcript scrolling under it is frosted rather than
// read through (`CallBandGround`), and the handle at its foot shows on hover.
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
    /// The conversation's height, for the drag's ceiling.
    @State private var room: CGFloat = 0
    /// Hide Members: the strip under a focused game or stream, put away.
    @State private var hidesMembers = false
    /// Live drag offset, applied on top of `height` and 1:1 with the pointer.
    @State private var drag: CGFloat = 0
    @State private var isFullHeight = false
    @State private var isGrabberHovering = false
    /// Whether the pointer is over the band, which is when its handle shows.
    @State private var isPointerInBand = false

    @Environment(\.motion) private var motion

    static let minimumHeight: CGFloat = 168
    static let maximumHeight: CGFloat = 460
    static let restingHeight: CGFloat = 244
    /// How much of the conversation a game may take by drag, and how much it
    /// opens to. **A game is not sized like a call** (Alex, 2026-11-18: "i
    /// cant resize the activity card", Wordle cut off): the 460 cap was made
    /// for a row of faces, and a game's page needs the room its own layout
    /// asks for — so while one is played the band reaches most of the
    /// conversation, a few messages and the composer still in sight.
    static let playingShare: CGFloat = 0.85
    static let playingOpenShare: CGFloat = 0.7

    /// How tall the band may be dragged in a conversation `room` tall.
    private func bandCeiling(for room: CGFloat) -> CGFloat {
        if isPlaying { return max(Self.minimumHeight, room * Self.playingShare) }
        return min(Self.maximumHeight, max(Self.minimumHeight, room * 0.62))
    }
    /// The strip at the band's foot that holds the handle, under the tiles.
    static let grabberStrip: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let ceiling = bandCeiling(for: proxy.size.height)
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
                .onChange(of: proxy.size.height, initial: true) { _, value in
                    room = value
                }
                // A game opens the band to most of the conversation, and the
                // grabber takes it anywhere up to its ceiling; leaving the game
                // brings the band back inside a call's.
                .onChange(of: isPlaying) { _, playing in
                    withAnimation(motion.reposition) {
                        height = playing
                            ? max(height, proxy.size.height * Self.playingOpenShare)
                            : min(height, bandCeiling(for: proxy.size.height))
                    }
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

    /// Whether the reader is playing the call's activity: the capsule then
    /// sits under the game, always shown, instead of over its foot.
    private var isPlaying: Bool { activity?.isJoined == true }

    /// A game or a person's stream has the stage, so the people under it are
    /// a strip that Hide Members can put away.
    private var isFocused: Bool { isPlaying || presentation.spotlightUserID != nil }

    private var band: some View {
        tiles
            .padding(.horizontal, Spacing.snug)
            .padding(.top, Spacing.snug)
            .padding(.bottom, tilesFoot)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .floatingCallControls(
                isPinned: isPlaying,
                lift: Self.grabberStrip + CallCapsuleMetrics.lift
            ) {
                controls
            }
            // **Up under the toolbar** (Alex, 2026-11-17: "the toolbar and the
            // voice bar creating a weird space"): stopped at the toolbar's
            // edge, the transcript showed through between the two.
            .background { CallBandGround().ignoresSafeArea(.container, edges: .top) }
            .overlay(alignment: .bottom) { grabber }
            .onHover { hovering in
                guard isPointerInBand != hovering else { return }
                isPointerInBand = hovering
            }
            .animation(motion.reposition, value: isFullHeight)
            .animation(motion.reposition, value: isPlaying)
            .animation(motion.reposition, value: hidesMembers)
    }

    /// Below the tiles: the handle's strip, and — while a game is played —
    /// the capsule's own room, so it never covers the game's foot.
    private var tilesFoot: CGFloat {
        guard isPlaying else { return Self.grabberStrip }
        return Self.grabberStrip + CallCapsuleMetrics.lift + CallCapsuleMetrics.height + Spacing.base
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
            joinActivity: joinActivity,
            hidesStrip: hidesMembers && isFocused
        )
    }

    private var controls: some View {
        CallControlCapsule(
            presentation: presentation,
            toggleMute: toggleMute,
            toggleDeafen: toggleDeafen,
            toggleCamera: toggleCamera,
            toggleScreenShare: toggleScreenShare,
            leave: leave
        ) {
            // **Discord's Hide Members** (Alex, 2026-11-18): with a game or a
            // stream on the stage, the people under it can be put away so the
            // band is all stage.
            if isFocused {
                CallCapsuleAccessory(
                    title: hidesMembers ? "Show Members" : "Hide Members",
                    systemImage: hidesMembers ? "person.2" : "person.2.slash"
                ) {
                    hidesMembers.toggle()
                }
            }
            CallFullScreenButton()
            CallExpandControl(isExpanded: $isFullHeight)
        }
    }

    /// The handle at the foot of the band.
    ///
    /// **Shown only while the pointer is over the call** (Alex, 2026-11-17),
    /// brighter over the handle itself; the strip keeps its resize cursor and
    /// its drag whether the pill is drawn or not, so the edge is still there
    /// for a pointer that goes straight for it.
    private var grabber: some View {
        Capsule()
            .fill(isGrabberHovering ? Palette.edgeStrong : Palette.edge)
            .frame(width: 44, height: 4)
            .opacity(isPointerInBand || isGrabberHovering || drag != 0 ? 1 : 0)
            .frame(maxWidth: .infinity)
            .frame(height: Self.grabberStrip)
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
            .animation(motion.standard, value: isPointerInBand)
            .accessibilityLabel(Text("Resize the call"))
            .accessibilityValue(Text("\(Int(height)) points tall"))
            .accessibilityAdjustableAction { direction in
                // Full Keyboard Access and VoiceOver get the same range the
                // pointer does. A drag handle with no adjustable action is a
                // control that only exists for a mouse.
                let step: CGFloat = direction == .increment ? 32 : -32
                height = min(bandCeiling(for: room), max(Self.minimumHeight, height + step))
            }
    }

    /// **Measured in the window, never in the handle's own space** (Alex,
    /// 2026-11-18: "it flickers when i resize it"). The handle sits at the
    /// band's foot and moves with every point the band grows, so a local
    /// translation is measured from a frame that is itself moving: the pointer
    /// goes down ten, the band follows ten, the handle's space says nothing
    /// moved, and the height oscillates frame to frame. The sidebar's handle
    /// has always been global for the same reason.
    private var resize: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                guard !isFullHeight else { return }
                drag = value.translation.height
            }
            .onEnded { value in
                guard !isFullHeight else { return }
                let target = min(
                    bandCeiling(for: room),
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
