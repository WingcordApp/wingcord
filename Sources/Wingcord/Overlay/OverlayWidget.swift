import SwiftUI
import WingcordCore

// MARK: - What each widget draws
//
// Every one of these is a **projection of state the app already holds** rather
// than a second copy of it. The controls are `VoiceControlBar`, unchanged — the
// same cluster the channel pane and the call overlay draw — because a second
// implementation of mute is a second place for mute to be wrong.
//
// The material is `.clear` glass throughout, which is the app's own rule: over
// media or a lit ground you see through the chrome and watch content lens as it
// passes underneath. A game is the most lit ground there is.

struct OverlayWidget: View {
    var kind: OverlayWidgetKind
    @Bindable var controller: OverlayController

    var body: some View {
        switch kind {
        case .quickActions: OverlayQuickActions(controller: controller)
        case .voice: OverlayVoiceWidget()
        case .notifications: OverlayNotificationsWidget(controller: controller)
        case .clips: OverlayClipsWidget(controller: controller)
        }
    }
}

// MARK: - The controls

/// The call's own controls, over the game.
private struct OverlayQuickActions: View {
    @Bindable var controller: OverlayController
    @Environment(AppModel.self) private var model

    var body: some View {
        if let presentation = model.voicePresentation {
            VoiceControlBar(
                presentation: presentation,
                isCompact: true,
                toggleMute: model.toggleVoiceMute,
                toggleDeafen: model.toggleVoiceDeafen,
                toggleCamera: model.toggleCamera,
                toggleScreenShare: model.toggleScreenShare,
                leave: model.leaveVoice
            )
        } else {
            // **Not an empty box.** A widget that vanishes when you leave a call
            // takes its slot with it, and the next call puts the toolbar
            // somewhere the reader has to find again. A resting state keeps the
            // arrangement stable.
            Label("Not in a call", systemImage: "phone.down.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Ink.secondary)
                .padding(.horizontal, Spacing.margin)
                .frame(height: Metrics.control + 8)
                .chromeOverMedia(in: .capsule)
        }
    }
}

// MARK: - Voice

/// Who is in the call, and who is talking.
private struct OverlayVoiceWidget: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    private var nameMode: OverlayNameDisplay { AppSettings.shared.overlayVoiceNames }

    var body: some View {
        if let presentation = model.voicePresentation, !presentation.participants.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                ForEach(visible(presentation.participants)) { participant in
                    OverlayVoiceRow(participant: participant, nameMode: nameMode)
                }
            }
            .padding(Spacing.base)
            // **Hugging, not filled.** A `maxWidth` with a `Spacer` inside made
            // every row the full width, so a call with one silent person drew a
            // 220-point panel containing a 22-point face and nothing else. The
            // cap is on the *name*, where long names actually need one.
            .fixedSize(horizontal: true, vertical: false)
            .chromeOverMedia(in: .rect(cornerRadius: Radius.glass))
            .animation(motion.standard, value: presentation.participants.count)
        }
    }

    /// The roster, capped.
    ///
    /// **A cap rather than a scroller.** The widget sits over somebody's game
    /// and cannot be scrolled while the overlay is asleep; a channel with forty
    /// people in it would otherwise cover the screen. Talkers are kept first so
    /// the cap never hides the person making noise.
    private func visible(_ participants: [VoiceParticipant]) -> [VoiceParticipant] {
        let limit = AppSettings.shared.overlayVoiceLimit
        let ordered = participants.sorted { lhs, rhs in
            if lhs.isSpeaking != rhs.isSpeaking { return lhs.isSpeaking }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
        return Array(ordered.prefix(limit))
    }
}

private struct OverlayVoiceRow: View {
    var participant: VoiceParticipant
    var nameMode: OverlayNameDisplay
    @Environment(\.motion) private var motion

    /// The gap between the avatar and its speaking ring.
    private let ringGap: CGFloat = 2

    /// **Every row the same height, whatever it carries.** A name capsule is
    /// taller than a bare face and a muted person carries two glyphs; left to
    /// themselves the rows jitter as people speak, which on a roster somebody
    /// glances at is the most distracting thing it could do.
    private var rowHeight: CGFloat {
        AppSettings.shared.overlayAvatarSize.points + ringGap * 2 + 4
    }

    private var showsName: Bool {
        switch nameMode {
        case .always: true
        case .never: false
        case .whileSpeaking: participant.isSpeaking
        }
    }

    var body: some View {
        HStack(spacing: Spacing.base) {
            AvatarView(
                url: participant.avatarURL,
                monogram: participant.monogram,
                side: AppSettings.shared.overlayAvatarSize.points
            )
            // The speaking ring, on the avatar rather than beside it: it is a
            // property of the person, and a separate dot is a second thing to
            // read.
            //
            // **Outside the avatar, with a gap.** Drawn on the avatar's own
            // edge it disappears against a green avatar, which is exactly what
            // happened — the first person to speak in the demo has a green
            // face and the ring was measured as absent. The gap puts the
            // panel's dark ground between the two, so the ring reads whatever
            // the picture underneath it is.
            .padding(ringGap)
            .overlay {
                Circle()
                    .strokeBorder(Palette.presenceOnline, lineWidth: 2)
                    .opacity(participant.isSpeaking ? 1 : 0)
                    .animation(motion.hover, value: participant.isSpeaking)
            }

            if showsName {
                // The name in its own capsule beside the face, which is the
                // shape Discord's own widget has and the one that reads over a
                // moving picture: a name printed straight onto the game
                // disappears whenever something light passes behind it.
                Text(participant.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 140, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, Spacing.base)
                    .padding(.vertical, 3)
                    .background(Palette.surface.opacity(0.55), in: .capsule)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
            }

            if participant.isSelfMuted || participant.isServerMuted {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.destructive)
            }
            if participant.isDeafened {
                Image(systemName: "headphones.slash")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.destructive)
            }
        }
        .frame(height: rowHeight)
        .animation(motion.hover, value: showsName)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            participant.displayName + (participant.isSpeaking ? ", speaking" : "")
        )
    }
}

// MARK: - Notifications

/// Messages that arrived while a game was in front.
private struct OverlayNotificationsWidget: View {
    @Bindable var controller: OverlayController
    @Environment(\.motion) private var motion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            ForEach(controller.notices) { notice in
                OverlayToast(notice: notice) { controller.dismiss(notice) }
                    // Spatial symmetry: it arrives from the left and leaves to
                    // the left, because that is the edge it belongs to.
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        )
                    )
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
        .animation(motion.panel, value: controller.notices)
    }
}

private struct OverlayToast: View {
    var notice: OverlayNotice
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            AvatarView(url: notice.avatarURL, monogram: notice.monogram, side: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(notice.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(notice.body)
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(2)
                // **The keybind, on the toast.** It is how anybody finds out
                // the overlay is there at all — Discord puts the same line on
                // theirs, and a toast that only reports a message teaches
                // nothing. Absent when there is no binding to name, rather than
                // printing "unbound" at somebody mid-game.
                if let keys = AppSettings.shared.hotkey(for: .toggleOverlay)?.displayString {
                    Text("Press \(keys) to reply")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Ink.tertiary)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Ink.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(Spacing.snug)
        .chromeOverMedia(in: .rect(cornerRadius: Radius.bubble))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Clips

/// What the clip key did, and what it will do.
private struct OverlayClipsWidget: View {
    @Bindable var controller: OverlayController
    @Environment(\.motion) private var motion

    var body: some View {
        if let state = controller.clipFeedback {
            HStack(spacing: Spacing.base) {
                Image(systemName: state.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(state.isFailure ? Palette.destructive : Palette.presenceOnline)
                Text(state.message)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
            }
            .padding(.horizontal, Spacing.snug)
            .padding(.vertical, Spacing.base)
            .frame(maxWidth: 280, alignment: .leading)
            .chromeOverMedia(in: .capsule)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
            .animation(motion.standard, value: state)
            .accessibilityElement(children: .combine)
        }
    }
}
