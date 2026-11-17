import SwiftUI
import WingcordVoice

// MARK: - The call's controls
//
// One vocabulary for every surface that holds the call: the HUD at the
// sidebar's foot draws them as glass discs, and the call's floating capsule
// draws them as regions of its one body of glass. A control means the same
// thing wherever it is — see `CallButtonLook` for the states.

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
        /// A disc of its own glass, for the HUD.
        case round
        /// A region inside the call's capsule: a fill, never a second body of
        /// glass (`Glass.swift` rule 2). With a flyout it grows a ▾.
        case region
    }

    var kind: Kind
    var isActive: Bool
    var form: Form = .round
    /// What the control's ▾ opens — the device and its level, or a live
    /// stream's own choices. Region form only.
    var flyout: CallFlyout?
    /// Discord's reason the control is off, said in its tooltip instead of
    /// what it would do.
    var note: String?
    var action: () -> Void

    var body: some View {
        switch form {
        case .round:
            Button(action: action) {
                Image(symbol: glyph)
                    .font(.system(.title3, weight: .semibold))
            }
            .buttonStyle(CallButtonStyle(kind: kind, isActive: isActive))
            .help(note ?? title)
            .accessibilityLabel(Text(title))
            .accessibilityHint(Text(note ?? ""))
            .accessibilityAddTraits(isActive ? .isSelected : [])
        case .region:
            CallRegionControl(
                kind: kind,
                isActive: isActive,
                glyph: glyph,
                title: title,
                note: note,
                flyout: flyout,
                action: action
            )
        }
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

// MARK: - The HUD's disc

private struct CallButtonStyle: ButtonStyle {
    var kind: CallButton.Kind
    var isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        // **No animation of its own, and no press shrink.** The interactive
        // glass answers the press itself; a scale on top of it fought it, and
        // an animated swap of the glass's tint made every mute and deafen land
        // late (Alex, 2026-10-22: "they lag"). The state changes at once.
        configuration.label
            .foregroundStyle(CallButtonLook.ink(kind, isActive: isActive))
            .frame(width: Metrics.callControl, height: Metrics.callControl)
            // Layout first, glass last.
            .glassEffect(CallButtonLook.glass(kind, isActive: isActive), in: .circle)
            .contentShape(.circle)
    }
}
