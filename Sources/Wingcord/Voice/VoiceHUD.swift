import SwiftUI
import WingcordCore

// MARK: - The call, wherever you are in the app
//
// A card at the sidebar's foot, above the now bar. It answers "I joined a voice
// channel and then went to read something else": the call has to stay
// reachable from every screen, and the sidebar's foot is on every screen.
//
// **Alex's design, exactly** (references 09, 09b and 10): the connection's
// glyph, "Voice Connected", where the call is and how long it has run, then
// five controls spread evenly across the card — camera, screen, microphone,
// headphones, leave. Who is in the call lives on the call's own surface; at
// the sidebar's width a row of faces only crowds the controls.
//
// **`.regular` glass, the now bar's own** (Alex, 2026-10-22). It was clear
// glass once, and channel names read straight through it; then an opaque
// card. The frosted variant is what the now bar settled on for the same
// problem — rows still move behind it, and their words never collide with
// the card's.
struct VoiceHUD: View {
    var presentation: VoicePresentation
    /// Discord's silent-mic warning, under the controls.
    var isMicSilent = false
    /// The call is running without echo cancellation although the reader
    /// asked for it (#14): speakers would feed everybody's voice back to them.
    var isEchoCancellationOff = false

    var toggleMute: () -> Void = {}
    var toggleDeafen: () -> Void = {}
    var toggleCamera: () -> Void = {}
    var toggleScreenShare: () -> Void = {}
    var openChannel: () -> Void = {}
    var leave: () -> Void = {}
    /// The activity the reader is in, which heads the card (`ActivityHUDRow`).
    var activity: ActivityHUDPresentation? = nil
    var openActivity: () -> Void = {}
    var leaveActivity: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            if let activity {
                ActivityHUDRow(activity: activity, open: openActivity, leave: leaveActivity)
                Rectangle()
                    .fill(Palette.edge)
                    .frame(height: 1)
                    .accessibilityHidden(true)
            }
            Button(action: openChannel) {
                VoiceHUDHeader(presentation: presentation)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)

            // One container for the five, so their glass is drawn together
            // over the card's own — and never merged (see `CallControlRow`).
            GlassEffectContainer(spacing: 0) {
                HStack(spacing: 0) {
                    CallButton(kind: .camera, isActive: presentation.isCameraOn, action: toggleCamera)
                        .frame(maxWidth: .infinity)
                    CallButton(kind: .screenShare, isActive: presentation.isScreenSharing, action: toggleScreenShare)
                        .frame(maxWidth: .infinity)
                    CallButton(kind: .microphone, isActive: presentation.isMuted, action: toggleMute)
                        .frame(maxWidth: .infinity)
                    CallButton(kind: .headphones, isActive: presentation.isDeafened, action: toggleDeafen)
                        .frame(maxWidth: .infinity)
                    CallButton(kind: .leave, isActive: false, action: leave)
                        .frame(maxWidth: .infinity)
                }
            }

            if isMicSilent {
                Label {
                    Text("Discord isn\u{2019}t detecting any input from your mic.")
                } icon: {
                    Image(systemName: "mic.badge.xmark")
                }
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
            }

            // **Said, rather than discovered through an echo.** The engine
            // falls back to a call without the canceller where Apple's voice
            // processor will not come up on a Mac, because a call beats no
            // call — and the people on it hear themselves through the
            // speakers. Headphones are the cure that needs nothing from us.
            if isEchoCancellationOff {
                Label {
                    Text("Echo cancellation is off on this Mac. Use headphones so others don\u{2019}t hear themselves.")
                } icon: {
                    Image(systemName: "headphones")
                }
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
            }
        }
        .padding(Spacing.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.glass))
        .padding(.horizontal, Spacing.base)
    }
}

/// The connection, where the call is, and how long it has run.
private struct VoiceHUDHeader: View {
    var presentation: VoicePresentation

    @Environment(\.motion) private var motion
    /// Discord's connection panel, from the grade (decision 11).
    @State private var showsConnection = false

    var body: some View {
        HStack(spacing: Spacing.snug) {
            Image(symbol: glyph)
                .font(.system(.title2, weight: .semibold))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 1) {
                Button { showsConnection.toggle() } label: {
                    Text(presentation.quality.label)
                        .font(.system(.title3, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .buttonStyle(.plain)
                .help("Connection details")
                .popover(isPresented: $showsConnection, arrowEdge: .top) {
                    CallConnectionPanel(quality: presentation.quality)
                }
                Text(place)
                    .font(.body)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                if let since = presentation.connectedSince {
                    // Its own view, ticking on its own: a timer text here
                    // updated the sidebar's whole graph every second.
                    CallTimerLabel(since: since)
                        .fixedSize()
                }
            }
            Spacer(minLength: 0)
        }
        .animation(motion.standard, value: presentation.quality.grade)
        .accessibilityElement(children: .combine)
    }

    private var place: String {
        presentation.guildName.map { "\(presentation.channelName) / \($0)" } ?? presentation.channelName
    }

    private var glyph: String {
        switch presentation.quality.grade {
        case .connecting, .good: "wifi"
        case .fair, .poor: "wifi.exclamationmark"
        }
    }

    private var tint: Color {
        switch presentation.quality.grade {
        case .connecting: InkColor.secondary
        case .good: Palette.presenceOnline
        case .fair: Palette.presenceIdle
        case .poor: Palette.destructive
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
        let activity = model.activityHUD
        let leaveActivity = { Task { await model.sessionController.leaveActivity() } }
        Group {
            if let presentation = model.voicePresentation {
                VoiceHUD(
                    presentation: presentation,
                    // Unmuted and silent, and the reader still wants to hear
                    // about it — Discord's own setting, on by default.
                    isMicSilent: model.isMicSilent && !presentation.isMuted
                        && AppSettings.shared.showsSilentMicWarning,
                    isEchoCancellationOff: model.isEchoCancellationOff,
                    toggleMute: model.toggleVoiceMute,
                    toggleDeafen: model.toggleVoiceDeafen,
                    toggleCamera: model.toggleCamera,
                    toggleScreenShare: model.toggleScreenShare,
                    openChannel: { model.selectChannel(presentation.channelID) },
                    leave: model.leaveVoice,
                    activity: activity,
                    openActivity: model.returnToActivity,
                    leaveActivity: { _ = leaveActivity() }
                )
                // It arrives from the edge it lives on, the sidebar's foot, and
                // leaves the same way.
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let activity {
                // An activity with no call around it: the row on its own card.
                ActivityHUDCard(
                    activity: activity,
                    open: model.returnToActivity,
                    leave: { _ = leaveActivity() }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(motion.panel, value: model.connectedVoiceChannelID)
        .animation(motion.panel, value: activity)
    }
}
