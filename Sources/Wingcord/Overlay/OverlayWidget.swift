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
        case .friends: OverlaySidebarWidget(controller: controller)
        case .chat: OverlayChatWidget(controller: controller)
        case .streams: OverlayStreamsWidget(controller: controller)
        case .videoTiles: OverlayVideoTilesWidget(controller: controller)
        case .quickActions: OverlayQuickActions(controller: controller)
        case .voice: OverlayVoiceWidget(controller: controller)
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
            VStack(spacing: Spacing.base) {
                VoiceControlBar(
                    presentation: presentation,
                    isCompact: true,
                    // **The two things the captures settled and this client did
                    // not do.** Over a game the material is `.clear` — a game is
                    // the most lit ground there is — and the three device
                    // controls carry a chevron, because over a game there is no
                    // settings window to send anybody to.
                    isOverMedia: true,
                    showsDeviceMenus: true,
                    toggleMute: model.toggleVoiceMute,
                    toggleDeafen: model.toggleVoiceDeafen,
                    toggleCamera: model.toggleCamera,
                    toggleScreenShare: model.toggleScreenShare,
                    leave: model.leaveVoice
                )
                // **The status line, which the reference has and this bar did
                // not.** Controls that do not say what they are controlling are
                // four glyphs over somebody's game; `Voice Connected · server ·
                // channel` is the sentence that makes them mean something — and
                // `VoiceQualityLine` was already written for the HUD, so this is
                // a second caller rather than a second answer.
                VoiceQualityLine(
                    quality: presentation.quality,
                    channelName: presentation.channelName,
                    guildName: presentation.guildName
                )
                .padding(.horizontal, Spacing.snug)
                .padding(.vertical, Spacing.tight + 1)
                .fixedSize(horizontal: true, vertical: false)
                .chromeOverMedia(in: .capsule)
            }
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
    @Bindable var controller: OverlayController
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    private var nameMode: OverlayNameDisplay { AppSettings.shared.overlayVoiceNames }

    var body: some View {
        if let presentation = model.voicePresentation, !presentation.participants.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                ForEach(visible(presentation.participants)) { participant in
                    OverlayVoiceRow(
                        participant: participant,
                        nameMode: nameMode,
                        controller: controller
                    )
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

/// One person in the call.
///
/// **The marks live INSIDE the name capsule, after the name**, which is the
/// arrangement the reference was photographed in and is the better one on its
/// own terms: a row is then one object per person rather than a face, a capsule
/// and two loose glyphs that drift apart as the capsule's width changes with the
/// name in it.
///
/// One mark the reference has is deliberately absent — **the music note**. It
/// would need the person's *activity*, which is not on `VoiceParticipant`, and
/// putting it there means keying the call's memo on presence: the sidebar's own
/// note explains what that costs, and `voicePresenceRevision` exists precisely
/// because a roster rebuilt five times a second on a busy account is not worth a
/// glyph. The flyout beside the row says what somebody is doing instead.
private struct OverlayVoiceRow: View {
    var participant: VoiceParticipant
    var nameMode: OverlayNameDisplay
    @Bindable var controller: OverlayController

    @Environment(\.motion) private var motion
    /// This row's box on the surface, for the card that hangs beside it.
    @State private var frame: CGRect = .zero

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

    /// Whether the capsule is drawn at all. A row with nothing to put in it is a
    /// bare face, which is what "Never" means.
    private var showsCapsule: Bool { showsName || participant.hasMarks }

    /// **Two branches rather than a conditional closure**, and it is §2's rule
    /// about guarding the *modifier*: `.onHover` compiles to an AppKit tracking
    /// area, and AppKit re-derives an `.inVisibleRect` tracking area's geometry
    /// on every frame of every scroll. Only a row with a share behind it has a
    /// card to open, so only such a row gets one. The identity change when
    /// somebody starts sharing costs one row rebuild, once.
    var body: some View {
        if participant.canWatch {
            row.onHover(perform: hover)
        } else {
            row
        }
    }

    private var row: some View {
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

            if showsCapsule { capsule }
        }
        .frame(height: rowHeight)
        .animation(motion.hover, value: showsCapsule)
        // **Derived from the layout that already happened**, not measured into
        // a reader that costs a pass — §2. Written only when it moves.
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(OverlaySpace.name))
        } action: { frame = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            participant.displayName + (participant.isSpeaking ? ", speaking" : "")
        )
    }

    /// The name and its marks, in one capsule beside the face.
    ///
    /// The shape the reference has and the one that reads over a moving picture:
    /// a name printed straight onto the game disappears whenever something light
    /// passes behind it.
    private var capsule: some View {
        HStack(spacing: Spacing.tight) {
            if showsName {
                Text(participant.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 140, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if participant.isCameraOn {
                Image(systemName: "video.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
            }
            if participant.isStreaming { LiveChip() }
            if participant.isSilenced {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.destructive)
            }
            if participant.isDeafened {
                Image(systemName: "headphones.slash")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.destructive)
            }
        }
        .padding(.horizontal, Spacing.base)
        .padding(.vertical, 3)
        .background(Palette.surface.opacity(0.55), in: .capsule)
        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
    }

    private func hover(_ hovering: Bool) {
        if hovering {
            controller.hoverStream(participant.id, anchor: frame)
        } else {
            controller.endStreamHover(participant.id)
        }
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
                OverlayToast(notice: notice, controller: controller)
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

/// One toast, and the reply field inside it.
///
/// **The toast expands rather than a second surface opening.** The reference
/// does the same and it is right for a reason worth stating: somebody mid-game
/// has just read four words in a corner of the screen, and answering them must
/// not move their eyes anywhere else.
///
/// **The pause is the act of typing, not a button to press first.** The
/// reference draws an explicit pause control; here opening the field *is* the
/// hold — `OverlayController.holdsNotice` — and the control reports the state
/// rather than setting it. A reader who has begun typing has already said
/// everything a pause button would have asked them to say, and a toast that
/// vanished mid-sentence would be the feature failing at the one moment it
/// matters.
private struct OverlayToast: View {
    var notice: OverlayNotice
    @Bindable var controller: OverlayController

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @FocusState private var isFocused: Bool

    private var isReplying: Bool { controller.holdsNotice(notice.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
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
                    // **Two facts, and the first one has to be true.** The line
                    // used to read "Click here or press ⌃⌘` to reply" while a
                    // sleeping overlay ignored every click — so the half of the
                    // sentence somebody would actually try was the half that did
                    // nothing. Clicking now replies without waking the surface;
                    // the keybind is a *different* act and is named as one,
                    // because it is still how anybody finds out the overlay is
                    // there at all.
                    //
                    // Absent while the field is open, where it would be
                    // instructions for something already done.
                    if !isReplying, let keys = AppSettings.shared.hotkey(for: .toggleOverlay)?
                        .displayString
                    {
                        Text("Click to reply · \(keys) for the overlay")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Ink.tertiary)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
                if isReplying { pauseMark }
                Button { controller.dismiss(notice) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Ink.tertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            if isReplying { field }
        }
        .padding(Spacing.snug)
        .chromeOverMedia(in: .rect(cornerRadius: Radius.bubble))
        // The whole toast is the way in, which is what its own hint promises.
        // A `.contentShape` because a toast is an avatar and two labels, and the
        // space between them would otherwise swallow the click — §2.
        .contentShape(.rect(cornerRadius: Radius.bubble))
        .onTapGesture {
            guard !isReplying else { return }
            controller.beginReply(to: notice)
            isFocused = true
        }
        .animation(motion.standard, value: isReplying)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(notice.title): \(notice.body)")
    }

    /// What the reference draws as a pause button, reporting rather than setting.
    ///
    /// It is a control all the same — pressing it closes the field, which is the
    /// one thing a reader looking at a paused toast might want — and it says so.
    private var pauseMark: some View {
        Button {
            controller.cancelReply()
            controller.releaseNoticeHold(notice.id)
        } label: {
            Image(systemName: "pause.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Ink.secondary)
                .frame(width: 18, height: 18)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help("Held while you are replying — click to let it dismiss")
        .accessibilityLabel("Stop replying")
    }

    private var field: some View {
        HStack(spacing: Spacing.base) {
            TextField("Reply to \(notice.title)", text: $controller.replyDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1 ... 4)
                .focused($isFocused)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .emphasisChrome(Palette.accent, in: .circle)
            .disabled(controller.replyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, Spacing.base)
        .padding(.vertical, Spacing.tight)
        .background(Palette.surfaceRaised.opacity(0.7), in: .rect(cornerRadius: Radius.chip))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func send() {
        let text = controller.replyDraft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // **Not cleared here.** A reply that goes dismisses its toast, which
        // closes the field with it — synchronously, so a second Return on a
        // slow round trip finds nothing to post twice. One held back for
        // slowmode keeps its text for the next Return.
        model.replyFromOverlay(text, to: notice)
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
                Image(symbol: state.symbolName)
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
