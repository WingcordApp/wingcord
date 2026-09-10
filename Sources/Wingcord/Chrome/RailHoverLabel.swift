import SwiftUI
import WingcordCore

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
    /// The server this names, or nil for the rail's other tiles — Direct
    /// Messages, Add a Server, Discover. **Nil is what keeps those three
    /// exactly as they were**: no store read, no rows, the same one-line chip.
    var guildID: GuildID?
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
    /// Who is in voice here. Empty for every tile that is not a server, and for
    /// every server with nobody in one — which is the common case and draws
    /// exactly the chip this has always drawn.
    var presence: RailHoverPresence = RailHoverPresence()

    /// The name's own band. **Unchanged**, so a chip with no rows is the same
    /// object it always was.
    static let height: CGFloat = 32
    /// One row of faces. Derived rather than measured, so the host can centre
    /// the chip on its tile with arithmetic — §2.
    static let rowHeight: CGFloat = 28

    static func height(rows: Int) -> CGFloat {
        height + CGFloat(rows) * rowHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            name
            if !presence.voice.isEmpty {
                row(
                    symbol: "speaker.wave.2.fill",
                    faces: presence.voice,
                    overflow: presence.voiceOverflow,
                    label: "in voice"
                )
            }
            if !presence.live.isEmpty {
                // The share glyph, not a second speaker: this row answers
                // "is there something to watch", which is a different question
                // from "who is here".
                row(
                    symbol: "rectangle.inset.filled.on.rectangle",
                    faces: presence.live,
                    overflow: presence.liveOverflow,
                    label: "streaming"
                )
            }
        }
        .padding(.bottom, presence.isEmpty ? 0 : Spacing.base)
        // Boxy rather than a capsule: the rail's own tiles are rounded
        // squares, and a lozenge beside them reads as a different family.
        //
        // `.clear`, because what passes behind it is the channel list —
        // content, not a reading surface. §4: `.regular` would frost the
        // names underneath into a grey slab.
        .glassEffect(.clear.tint(Palette.flyoutTint), in: .rect(cornerRadius: Radius.chip))
        .fixedSize()
    }

    /// The name, in the band it has always had.
    private var name: some View {
        Text(label)
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(Ink.primary)
            .lineLimit(1)
            .padding(.horizontal, Spacing.snug)
            .frame(height: Self.height, alignment: .leading)
    }

    /// One row: what it is about, then the faces.
    ///
    /// **Overlapped, and the leading face is on top.** A row of separate circles
    /// is a list; a stack that overlaps reads as a group, which is what a room
    /// full of people is — and it is how the count at the end stays close enough
    /// to belong to them.
    private func row(
        symbol: String,
        faces: [RailHoverPresence.Face],
        overflow: Int,
        label: String
    ) -> some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Ink.secondary)
                .frame(width: 16)

            HStack(spacing: -Self.faceOverlap) {
                ForEach(faces) { face in
                    AvatarView(
                        url: face.avatarURL,
                        monogram: face.monogram,
                        side: Self.faceSide
                    )
                    // The ring is the chip's own ground showing through, which
                    // is what separates one face from the one under it without
                    // drawing a border on anybody.
                    .overlay {
                        Circle().strokeBorder(Palette.canvas, lineWidth: 1.5)
                    }
                }
                if overflow > 0 {
                    Text("+\(overflow)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Ink.secondary)
                        .padding(.leading, Self.faceOverlap + Spacing.tight)
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, Spacing.snug)
        .frame(height: Self.rowHeight, alignment: .leading)
        // One node per row: "in voice, six people" rather than six unlabelled
        // pictures.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(faces.count + overflow) \(label)"))
    }

    private static let faceSide: CGFloat = 20
    /// How far each face sits under the one before it.
    private static let faceOverlap: CGFloat = 6
}

extension View {
    /// Publishes this tile's bounds as the rail's hover anchor while `isHovered`.
    ///
    /// **The modifier is unconditional and the value is what varies** — §2's
    /// rule about guarding the modifier rather than the closure. An
    /// `anchorPreference` applied inside an `if` changes the view's structural
    /// identity on every hover, which is a rebuild where a preference write
    /// would have done.
    func railHoverLabel(
        _ label: String, guildID: GuildID? = nil, isHovered: Bool
    ) -> some View {
        anchorPreference(key: RailHoverKey.self, value: .bounds) { anchor in
            isHovered
                ? RailHoverAnchor(label: label, guildID: guildID, anchor: anchor)
                : nil
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
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(RailHoverKey.self) { item in
            GeometryReader { proxy in
                if let item {
                    let rect = proxy[item.anchor]
                    // **Read for the hovered server and no other**, and only
                    // while something is hovered: the read is inside this
                    // branch, so a rail nobody is pointing at registers no
                    // dependency on the voice table at all. One pass over it per
                    // hover is far cheaper than a face list on ninety-seven
                    // tiles in a memo that rebuilds on every message.
                    let presence = item.guildID.map(model.railHoverPresence(for:))
                        ?? RailHoverPresence()
                    RailHoverChip(label: item.label, presence: presence)
                        .offset(
                            x: rect.maxX + Spacing.base,
                            y: rect.midY - RailHoverChip.height(rows: presence.rowCount) / 2
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
        lhs.label == rhs.label && lhs.guildID == rhs.guildID && lhs.anchor == rhs.anchor
    }
}
