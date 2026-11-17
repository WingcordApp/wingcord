import SwiftUI

/// The call's controls as a row of labelled capsules, for a surface with room
/// for words: the band over a conversation and the channel's own stage.
///
/// Alex's labelled design (reference 10), in the order a reference client's
/// call band uses (reference 22): the camera, the screen, the two switches
/// about being heard, the soundboard, and leave. Camera, microphone and
/// headphones are split buttons whose ▾ opens the device and its level; the
/// screen is one while it is live, and its ▾ opens the stream's choices.
struct CallControlRow: View {
    var presentation: VoicePresentation

    var toggleMute: () -> Void = {}
    var toggleDeafen: () -> Void = {}
    var toggleCamera: () -> Void = {}
    var toggleScreenShare: () -> Void = {}
    var leave: () -> Void = {}

    /// **Local, not a flag on the store**: two surfaces build this row, and a
    /// shared flag would ask both to present at once.
    @State private var isSoundboardOpen = false
    @State private var isActivitiesOpen = false

    var body: some View {
        // Labelled where the words fit, round where they do not: a narrow
        // conversation still gets every control, in the HUD's form.
        ViewThatFits(in: .horizontal) {
            controls(.labeled)
            controls(.round)
        }
        // **Each panel hangs from its own control.** `ViewThatFits` holds both
        // forms and only one may own a presentation, so the panels were on the
        // row — and a popover on the row points at the row's middle, which is
        // Deafen. The drawn form publishes where its controls are (the undrawn
        // one publishes nothing), and the panel is attached to a clear box laid
        // exactly over that control. The contents are still built only while
        // presented, which keeps the catalog read out of this row's body.
        .overlayPreferenceValue(CallPanelAnchors.self) { anchors in
            GeometryReader { proxy in
                if let anchor = anchors[.soundboard] {
                    panelAnchor(proxy[anchor])
                        .popover(isPresented: $isSoundboardOpen, arrowEdge: .top) {
                            SoundboardPickerContainer { isSoundboardOpen = false }
                        }
                        .position(x: proxy[anchor].midX, y: proxy[anchor].midY)
                }
            }
            .allowsHitTesting(false)
        }
        // **The launcher, large and centred over the call** (decision 5): a
        // card in the window's own modal layer, grown out of the Activities
        // control, rather than a popover the size of the composer's.
        .modal(isPresented: $isActivitiesOpen, style: .panel) {
            ActivityLauncher(channelID: presentation.channelID, context: .call)
        }
    }

    private func controls(_ form: CallButton.Form) -> some View {
        // The row's glass drawn together — each control its own capsule or
        // disc of it. **Spacing 0: the controls never merge.** At the row's own
        // gap they did, and a caption changing width ("Mute" → "Unmute")
        // dragged its neighbours' glass along with it.
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: Spacing.base) {
                CallButton(
                    kind: .camera, isActive: presentation.isCameraOn, form: form,
                    flyout: .devices(.camera), action: toggleCamera
                )
                CallButton(
                    kind: .screenShare, isActive: presentation.isScreenSharing, form: form,
                    flyout: presentation.isScreenSharing ? .stream : nil,
                    action: toggleScreenShare
                )
                CallButton(
                    kind: .microphone, isActive: presentation.isMuted, form: form,
                    flyout: .devices(.input), action: toggleMute
                )
                CallButton(
                    kind: .headphones, isActive: presentation.isDeafened, form: form,
                    flyout: .devices(.output), action: toggleDeafen
                )
                if presentation.canLaunchActivities {
                    CallButton(kind: .activities, isActive: isActivitiesOpen, form: form) {
                        isActivitiesOpen.toggle()
                    }
                    .anchorPreference(key: CallPanelAnchors.self, value: .bounds) { [.activities: $0] }
                }
                if presentation.soundboard != .unavailable {
                    CallButton(
                        kind: .soundboard, isActive: isSoundboardOpen, form: form,
                        note: presentation.soundboard == .serverMuted ? "Soundboard disabled when server muted" : nil
                    ) {
                        isSoundboardOpen.toggle()
                    }
                    .disabled(presentation.soundboard == .serverMuted)
                    .anchorPreference(key: CallPanelAnchors.self, value: .bounds) { [.soundboard: $0] }
                }
                CallButton(kind: .leave, isActive: false, form: form, action: leave)
            }
        }
        .fixedSize()
    }
}

extension CallControlRow {
    /// A clear box the size of a control, for its panel to point at.
    fileprivate func panelAnchor(_ frame: CGRect) -> some View {
        Color.clear.frame(width: frame.width, height: frame.height)
    }
}

/// Where the controls that raise a panel are drawn.
private struct CallPanelAnchors: PreferenceKey {
    static let defaultValue: [CallButton.Kind: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [CallButton.Kind: Anchor<CGRect>],
        nextValue: () -> [CallButton.Kind: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { $1 }
    }
}
