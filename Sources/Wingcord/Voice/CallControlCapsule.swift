import SwiftUI

/// The call's controls as one floating capsule of Liquid Glass, FaceTime's
/// arrangement: it floats over the foot of the tiles, so they keep the whole
/// height (Alex, 2026-11-17).
///
/// **One body of glass, the controls regions of it** — the functional layer
/// over content, regular glass because it carries symbols over pictures whose
/// brightness nothing controls (HIG, Materials). In Discord's order: the camera,
/// the screen, the two switches about being heard, Activities, the soundboard
/// and Leave; then, after a hairline, the window's own controls — Full Screen,
/// and the band's Fill — at the capsule's end.
struct CallControlCapsule<Accessories: View>: View {
    var presentation: VoicePresentation
    var toggleMute: () -> Void = {}
    var toggleDeafen: () -> Void = {}
    var toggleCamera: () -> Void = {}
    var toggleScreenShare: () -> Void = {}
    var leave: () -> Void = {}
    /// Full Screen and the band's Fill, at the capsule's end.
    @ViewBuilder var accessories: Accessories

    /// **Local, not a flag on the store**: three surfaces build this capsule,
    /// and a shared flag would ask them all to present at once.
    @State private var isSoundboardOpen = false
    @State private var isActivitiesOpen = false
    /// The Activities control's first answer: the mini shelf.
    @State private var isShelfOpen = false

    var body: some View {
        HStack(spacing: 0) {
            CallButton(
                kind: .camera, isActive: presentation.isCameraOn, form: .region,
                flyout: .devices(.camera), action: toggleCamera
            )
            CallButton(
                kind: .screenShare, isActive: presentation.isScreenSharing, form: .region,
                flyout: presentation.isScreenSharing ? .stream : nil, action: toggleScreenShare
            )
            CallButton(
                kind: .microphone, isActive: presentation.isMuted, form: .region,
                flyout: .devices(.input), action: toggleMute
            )
            CallButton(
                kind: .headphones, isActive: presentation.isDeafened, form: .region,
                flyout: .devices(.output), action: toggleDeafen
            )
            if presentation.canLaunchActivities {
                CallButton(kind: .activities, isActive: isActivitiesOpen || isShelfOpen, form: .region, action: toggleActivities)
                    // **The mini shelf first, the launcher from See All** —
                    // Discord's order (Alex, 2026-11-18: "add back the
                    // suggested activities flyout"). On the control, which is
                    // the only place a popover can point at it from.
                    .popover(isPresented: $isShelfOpen, arrowEdge: .top) {
                        SuggestedActivitiesFlyout(channelID: presentation.channelID) {
                            isShelfOpen = false
                            // On the next turn: the popover is still closing.
                            Task { @MainActor in isActivitiesOpen = true }
                        }
                    }
            }
            if presentation.soundboard != .unavailable {
                CallButton(
                    kind: .soundboard, isActive: isSoundboardOpen, form: .region,
                    note: presentation.soundboard == .serverMuted ? "Soundboard disabled when server muted" : nil,
                    action: toggleSoundboard
                )
                .disabled(presentation.soundboard == .serverMuted)
                // On the control, which is the only place a popover can point
                // at the button that opened it. Its contents are built only
                // while presented, which keeps the catalog read out of this
                // capsule's body.
                .popover(isPresented: $isSoundboardOpen, arrowEdge: .top) {
                    SoundboardPickerContainer { isSoundboardOpen = false }
                }
            }
            CallButton(kind: .leave, isActive: false, form: .region, action: leave)
            if Accessories.self != EmptyView.self {
                // **A different kind of control, set apart** (HIG, Toolbars:
                // group by function): these change the window, not the call.
                Capsule()
                    .fill(InkColor.primary.opacity(0.2))
                    .frame(width: 1, height: CallCapsuleMetrics.disc / 2)
                    .padding(.horizontal, CallCapsuleMetrics.padding)
                    .accessibilityHidden(true)
                accessories
            }
        }
        .padding(CallCapsuleMetrics.padding)
        .fixedSize()
        // Layout first, glass last.
        .floatingChrome(in: .capsule)
        // **The launcher, large and centred over the call** (decision 5): a
        // card in the window's own modal layer, grown out of the Activities
        // control, rather than a popover the size of the composer's.
        .modal(isPresented: $isActivitiesOpen, style: .panel) {
            ActivityLauncher(channelID: presentation.channelID, context: .call)
        }
        .transformPreference(CallControlsEngagedKey.self) { engaged in
            engaged = engaged || isSoundboardOpen || isActivitiesOpen || isShelfOpen
        }
    }

    private func toggleActivities() {
        isShelfOpen.toggle()
    }

    private func toggleSoundboard() {
        isSoundboardOpen.toggle()
    }
}

extension CallControlCapsule where Accessories == EmptyView {
    /// A capsule with nothing at its end.
    init(
        presentation: VoicePresentation,
        toggleMute: @escaping () -> Void = {},
        toggleDeafen: @escaping () -> Void = {},
        toggleCamera: @escaping () -> Void = {},
        toggleScreenShare: @escaping () -> Void = {},
        leave: @escaping () -> Void = {}
    ) {
        self.presentation = presentation
        self.toggleMute = toggleMute
        self.toggleDeafen = toggleDeafen
        self.toggleCamera = toggleCamera
        self.toggleScreenShare = toggleScreenShare
        self.leave = leave
        self.accessories = EmptyView()
    }
}
