import SwiftUI

/// The name of the rail tile under the pointer, drawn beside it.
///
/// **An anchored overlay, not a popover, and that difference is the whole
/// feature.** A popover on macOS is a real window: it costs a window server
/// round trip to open, it draws the system's own material rather than this
/// app's, it cannot be moved from one tile to another — each hover is a fresh
/// window — and it needs a dwell before opening or a sweep down the rail
/// spawns and destroys a dozen of them. That dwell is the delay a rail must not
/// have: the label is the *only* thing that names a wordless 44-point picture,
/// so it has to be there the moment the pointer is.
///
/// So the hovered tile publishes its bounds through an anchor preference and one
/// host draws one chip for whichever tile is hovered. The chip is a single view
/// with a single identity, so moving from server to server **animates** — it
/// slides and its width morphs to the new name rather than cutting. Nothing
/// opens and nothing closes.
///
/// The host has to sit outside the rail's `ScrollView`, which clips, and wide
/// enough to hold the chip beside the 68-point column — the sidebar's own
/// `HStack` is exactly that view.
struct RailHoverAnchor: Equatable {
    var label: String
    var anchor: Anchor<CGRect>
}

private struct RailHoverKey: PreferenceKey {
    static let defaultValue: RailHoverAnchor? = nil

    /// First writer wins. At most one tile is hovered, so this is only
    /// "ignore the nil every other tile publishes".
    static func reduce(value: inout RailHoverAnchor?, nextValue: () -> RailHoverAnchor?) {
        value = value ?? nextValue()
    }
}

/// The chip itself.
///
/// Fixed height so the host can centre it on a tile with arithmetic rather than
/// a measurement round trip — a `GeometryReader` here would cost a second layout
/// pass and would visibly settle into place on the first hover. §2: derive the
/// geometry you already have the inputs for.
private struct RailHoverChip: View {
    var label: String

    static let height: CGFloat = 32

    var body: some View {
        Text(label)
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(Ink.primary)
            .lineLimit(1)
            .padding(.horizontal, Spacing.snug)
            .frame(height: Self.height)
            // Boxy rather than a capsule: the rail's own tiles are rounded
            // squares, and a lozenge beside them reads as a different family.
            //
            // `.clear`, because what passes behind it is the channel list —
            // content, not a reading surface. §4: `.regular` would frost the
            // names underneath into a grey slab.
            .glassEffect(.clear.tint(Palette.flyoutTint), in: .rect(cornerRadius: Radius.chip))
            .fixedSize()
    }
}

extension View {
    /// Publishes this tile's bounds as the rail's hover anchor while `isHovered`.
    ///
    /// **The modifier is unconditional and the value is what varies** — §2's
    /// rule about guarding the modifier rather than the closure. An
    /// `anchorPreference` applied inside an `if` changes the view's structural
    /// identity on every hover, which is a rebuild where a preference write
    /// would have done.
    func railHoverLabel(_ label: String, isHovered: Bool) -> some View {
        anchorPreference(key: RailHoverKey.self, value: .bounds) { anchor in
            isHovered ? RailHoverAnchor(label: label, anchor: anchor) : nil
        }
    }

    /// Draws the hovered rail tile's name. Apply to an ancestor wide enough to
    /// hold the chip beside the rail — the sidebar's rail + channel-list stack.
    func railHoverLabelHost() -> some View {
        modifier(RailHoverLabelHost())
    }
}

/// The host, as a modifier so it can read the resolved motion from the
/// environment rather than reaching for a global — §3: Reduce Motion is resolved
/// once at the root and read from `\.motion`, never honoured by hand.
private struct RailHoverLabelHost: ViewModifier {
    @Environment(\.motion) private var motion

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(RailHoverKey.self) { item in
            GeometryReader { proxy in
                if let item {
                    let rect = proxy[item.anchor]
                    RailHoverChip(label: item.label)
                        .offset(
                            x: rect.maxX + Spacing.base,
                            y: rect.midY - RailHoverChip.height / 2
                        )
                        // Enter and exit along the same path — it grows out of
                        // the tile it names.
                        .transition(.materialize(from: .leading))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // It is an answer about the thing under the pointer, so it must
            // never become the thing under the pointer.
            .allowsHitTesting(false)
            // One animation on the whole overlay, keyed on the item: moving from
            // one tile to the next is one chip travelling, so the offset and the
            // width morph together instead of a dissolve between two labels.
            .animation(motion.hover, value: item)
        }
    }
}

extension RailHoverAnchor {
    /// `Anchor` is `Equatable`, so the chip only re-lays-out when the tile under
    /// the pointer actually changes — a scroll that moves the rail moves the
    /// anchor, which is precisely when the chip should follow.
    static func == (lhs: RailHoverAnchor, rhs: RailHoverAnchor) -> Bool {
        lhs.label == rhs.label && lhs.anchor == rhs.anchor
    }
}
