import SwiftUI
import WingcordVoice

// MARK: - The call's controls
//
// One vocabulary for every surface that holds the call: the HUD at the
// sidebar's foot draws them round, and the call band draws them as labelled
// capsules. A control means the same thing wherever it is.
//
// **At rest a control is a quiet disc with a plain glyph. Switched on, it turns
// light and its glyph takes the state's colour**: green for a camera that is
// on, indigo for a screen being shared, orange for a muted microphone, red for
// deafened. Leave is red at all times. That is Alex's design (references 09 and
// 10 in `docs/references/2026-10-05`), and it shows at a glance which of the
// switches are thrown.
//
// **Every control is Liquid Glass** (Alex, 2026-10-22): `.regular` and
// interactive at rest, the same material as the bar or card it sits on; tinted
// light when switched on, so the state's colour still reads; Leave is red
// glass, as the capture bar's Record is.

/// One of the call's controls.
struct CallButton: View {
    enum Kind: Hashable, CaseIterable {
        case camera
        case screenShare
        case microphone
        case headphones
        case activities
        case soundboard
        case leave
    }

    enum Form {
        /// A disc, for the HUD.
        case round
        /// A capsule with the control's name in it, for the call band.
        case labeled
    }

    var kind: Kind
    var isActive: Bool
    var form: Form = .round
    /// What the control's ▾ opens. Labelled form only: the capsule becomes a
    /// split button, and the ▾ opens a flyout — the device and its level, or
    /// a live stream's own choices.
    var flyout: CallFlyout?
    /// Discord's reason the control is off, said in its tooltip instead of
    /// what it would do.
    var note: String?
    var action: () -> Void

    var body: some View {
        Group {
            if form == .labeled, let flyout {
                CallSplitButton(
                    kind: kind, isActive: isActive, caption: caption,
                    glyph: glyph, flyout: flyout, action: action
                )
            } else {
                Button(action: action) {
                    switch form {
                    case .round:
                        Image(symbol: glyph)
                            .font(.system(.title3, weight: .semibold))
                    case .labeled:
                        Label {
                            Text(caption)
                        } icon: {
                            Image(symbol: glyph)
                        }
                        .font(.system(.body, weight: .semibold))
                    }
                }
                .buttonStyle(CallButtonStyle(kind: kind, isActive: isActive, form: form))
            }
        }
        .help(note ?? title)
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(note ?? ""))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    /// What the control does next, in Discord's words.
    private var title: String {
        switch kind {
        case .camera: isActive ? "Turn Off Camera" : "Turn On Camera"
        case .screenShare: isActive ? "Stop Streaming" : "Share Screen"
        case .microphone: isActive ? "Unmute" : "Mute"
        case .headphones: isActive ? "Undeafen" : "Deafen"
        case .activities: "Activities"
        case .soundboard: "Soundboard"
        case .leave: "Disconnect"
        }
    }

    /// The name in the capsule, in Discord's words.
    private var caption: String {
        switch kind {
        case .camera: "Camera"
        case .screenShare: isActive ? "Stop Streaming" : "Share Screen"
        case .microphone: isActive ? "Unmute" : "Mute"
        case .headphones: isActive ? "Undeafen" : "Deafen"
        case .activities: "Activities"
        case .soundboard: "Soundboard"
        case .leave: "Leave"
        }
    }

    private var glyph: String {
        switch kind {
        case .camera: "video.fill"
        case .screenShare: "rectangle.inset.filled.and.person.filled"
        case .microphone: isActive ? "mic.slash.fill" : "mic.fill"
        case .headphones: isActive ? "headphones.slash" : "headphones"
        case .activities: "gamecontroller.fill"
        case .soundboard: "music.note.list"
        case .leave: "phone.down.fill"
        }
    }
}

// MARK: - How a control looks in each state

private enum CallButtonLook {
    /// The colour a switched-on control's glyph takes.
    static func stateColor(_ kind: CallButton.Kind) -> Color {
        switch kind {
        case .camera: Palette.presenceOnline
        case .screenShare: .indigo
        case .microphone: .orange
        case .headphones, .leave: Palette.destructive
        case .soundboard, .activities: Palette.accent
        }
    }

    static func ink(_ kind: CallButton.Kind, isActive: Bool) -> Color {
        if kind == .leave { return .white }
        return isActive ? stateColor(kind) : InkColor.primary
    }

    /// The control's glass. Interactive throughout, so the pointer and a press
    /// are answered by the material itself rather than by a fill that changes.
    static func glass(_ kind: CallButton.Kind, isActive: Bool) -> Glass {
        if kind == .leave { return .regular.tint(Palette.destructive).interactive() }
        if isActive { return .regular.tint(activeTint).interactive() }
        return .regular.interactive()
    }

    /// A switched-on control: near-white glass in a dark room, white in a
    /// light one, so the state's colour reads on it either way.
    static let activeTint = Color.adaptive(dark: NSColor(white: 0.92, alpha: 1), light: .white)
}

// MARK: - The plain control

private struct CallButtonStyle: ButtonStyle {
    var kind: CallButton.Kind
    var isActive: Bool
    var form: CallButton.Form

    func makeBody(configuration: Configuration) -> some View {
        CallButtonBody(
            label: configuration.label,
            kind: kind,
            isActive: isActive,
            form: form
        )
    }
}

private struct CallButtonBody<Content: View>: View {
    var label: Content
    var kind: CallButton.Kind
    var isActive: Bool
    var form: CallButton.Form


    var body: some View {
        let shape = form == .round ? AnyShape(Circle()) : AnyShape(Capsule())
        // **No animation of its own, and no press shrink.** The interactive
        // glass answers the press itself; a scale on top of it fought it, and
        // an animated swap of the glass's tint made every mute and deafen land
        // late (Alex, 2026-10-22: "they lag"). The state changes at once.
        label
            .foregroundStyle(CallButtonLook.ink(kind, isActive: isActive))
            .modifier(CallButtonFrame(form: form))
            // Layout first, glass last.
            .glassEffect(CallButtonLook.glass(kind, isActive: isActive), in: shape)
            .contentShape(shape)
    }
}

/// The disc's diameter, or the capsule's height and inset.
private struct CallButtonFrame: ViewModifier {
    var form: CallButton.Form

    func body(content: Content) -> some View {
        switch form {
        case .round:
            content.frame(width: Metrics.callControl, height: Metrics.callControl)
        case .labeled:
            content
                .padding(.horizontal, Spacing.snug)
                .frame(height: Metrics.callControlLabeled)
        }
    }
}

// MARK: - The split control

/// A labelled control with a ▾ beside it: the capsule acts, the ▾ opens its
/// flyout. The HIG's split button, in the call's own shape.
private struct CallSplitButton: View {
    var kind: CallButton.Kind
    var isActive: Bool
    var caption: String
    var glyph: String
    var flyout: CallFlyout
    var action: () -> Void

    /// On the button, which is the only place a popover can point at the
    /// control that opened it.
    @State private var isFlyoutOpen = false

    var body: some View {
        let ink = CallButtonLook.ink(kind, isActive: isActive)
        HStack(spacing: 0) {
            Button(action: action) {
                Label {
                    Text(caption)
                } icon: {
                    Image(symbol: glyph)
                }
                .font(.system(.body, weight: .semibold))
                .padding(.leading, Spacing.snug)
                .padding(.trailing, Spacing.base)
                .frame(height: Metrics.callControlLabeled)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(ink.opacity(0.25))
                .frame(width: 1, height: Metrics.callControlLabeled / 2)

            Button { isFlyoutOpen.toggle() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(.caption, weight: .bold))
                    .frame(width: Metrics.callControlLabeled - Spacing.tight, height: Metrics.callControlLabeled)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel(Text(flyoutTitle))
            .popover(isPresented: $isFlyoutOpen, arrowEdge: .top) {
                // Built only while presented: the device lists are read when
                // the flyout opens, never on the band's own passes.
                switch flyout {
                case .devices(let devices):
                    CallDeviceFlyout(kind: devices)
                case .stream:
                    LiveShareFlyout { isFlyoutOpen = false }
                }
            }
        }
        .foregroundStyle(ink)
        // One capsule of glass under both halves — the split is drawn by the
        // hairline, not by two plates. Not animated: see `CallButtonBody`.
        .glassEffect(CallButtonLook.glass(kind, isActive: isActive), in: .capsule)
    }

    /// The ▾'s name for VoiceOver, in Discord's words.
    private var flyoutTitle: String {
        switch flyout {
        case .devices(let devices): devices.deviceTitle
        case .stream: "Stream Quality"
        }
    }
}
