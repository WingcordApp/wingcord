import SwiftUI

/// One control inside the call's capsule: a disc lit by a fill, with its ▾
/// beside it where the control has a flyout.
///
/// **A region of the capsule's glass, never a body of its own** (`Glass.swift`
/// rule 2): glass stacked inside glass samples the outer body's blur rather
/// than the content behind the window and reads as a flat disc. The states are
/// fills, as the overlay's `VoiceControl` is built.
///
/// **Contiguous hit regions** (HIG, Pointing devices): each part fills its whole
/// slot and draws its fill two points in, so the pointer never falls between
/// two controls while the capsule still reads as separate discs.
struct CallRegionControl: View {
    var kind: CallButton.Kind
    var isActive: Bool
    var glyph: String
    var title: String
    var note: String?
    var flyout: CallFlyout?
    var action: () -> Void

    /// On the control, which is the only place a popover can point at it.
    @State private var isFlyoutOpen = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                Image(symbol: glyph)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: CallCapsuleMetrics.slot, height: CallCapsuleMetrics.slot)
                    .contentShape(.rect)
            }
            .buttonStyle(CallRegionStyle(part: flyout == nil ? .whole : .leading, isActive: isActive, isLeave: kind == .leave))
            .help(note ?? title)
            .accessibilityLabel(Text(title))
            .accessibilityHint(Text(note ?? ""))
            .accessibilityAddTraits(isActive ? .isSelected : [])

            if let flyout {
                Button(action: toggleFlyout) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: CallCapsuleMetrics.chevron, height: CallCapsuleMetrics.slot)
                        .contentShape(.rect)
                }
                .buttonStyle(CallRegionStyle(part: .trailing, isActive: isActive, isLeave: false))
                .help(flyout.title)
                .accessibilityLabel(Text(flyout.title))
                .popover(isPresented: $isFlyoutOpen, arrowEdge: .top) {
                    // Built only while presented: the device lists are read when
                    // the flyout opens, never on the capsule's own passes.
                    switch flyout {
                    case .devices(let devices):
                        CallDeviceFlyout(kind: devices)
                    case .stream:
                        LiveShareFlyout { isFlyoutOpen = false }
                    }
                }
            }
        }
        .foregroundStyle(CallButtonLook.ink(kind, isActive: isActive))
        // **One light pill under both halves of a switched-on control**, so a
        // muted microphone and its ▾ read as one thing that is on.
        .background {
            if isActive {
                Capsule()
                    .fill(CallButtonLook.activeTint)
                    .padding(CallCapsuleMetrics.fillInset)
            }
        }
        .preference(key: CallControlsEngagedKey.self, value: isFlyoutOpen)
    }

    private func toggleFlyout() {
        isFlyoutOpen.toggle()
    }
}

extension CallFlyout {
    /// The ▾'s name, in Discord's words.
    var title: String {
        switch self {
        case .devices(let devices): devices.deviceTitle
        case .stream: "Stream Quality"
        }
    }
}
