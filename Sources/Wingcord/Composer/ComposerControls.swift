import SwiftUI

/// The mark one composer control wears.
///
/// **Its own view, because two surfaces draw it.** The composer draws the live
/// control and the settings editor draws an inert copy the reader drags around;
/// a mark written out twice is a mark that drifts, and the editor's whole
/// argument is that it shows the real thing.
///
/// **Filled glyphs, and white.** These used to be a `.body` outline in
/// `Ink.secondary` at 26 points, which over the composer's glass read as four
/// grey smudges. A material's own veil eats a thin stroke — that is what
/// vibrancy does to hairlines — so the marks that survive on glass are the solid
/// ones, and the hierarchy is carried by the *control*'s size rather than by the
/// ink's weight.
struct ComposerControlMark: View {
    var control: ComposerControl

    var body: some View {
        switch control {
        case .gif:
            // **The word in a box, drawn rather than imported.** Every symbol
            // for this idea is a rectangle with something in it, and the system
            // ships none — so the mark is three letters inside a rounded rect,
            // at the size the neighbouring glyphs read at. The bare word at 10
            // points, which is what this was, is a label somebody left in the
            // corner rather than a control.
            Text("GIF")
                .font(.system(size: 10, weight: .heavy))
                .frame(width: 26, height: 18)
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(lineWidth: 1.5)
                }
        case .sticker:
            // A sticker peeling off its sheet. Deliberately not a second face:
            // the emoji control beside it is already the face, and two faces is
            // two controls nobody can tell apart.
            Image(systemName: "rectangle.fill.on.rectangle.angled.fill")
                .font(.system(size: 18, weight: .medium))
        case .emoji:
            // The inverse variant: a filled disc with the features knocked out,
            // so the glass shows through the eyes. The outline face this
            // replaces disappeared into the material at any size.
            Image(systemName: "face.smiling.inverse")
                .font(.system(size: 19, weight: .medium))
        case .apps:
            // Four rounded pips — the mark an app grid has anywhere it appears,
            // and the "familiarity" principle spent on the one idea that earns
            // it. Smaller than the faces beside it because a 2x2 field of solid
            // dots carries far more ink per point than a glyph does.
            Image(systemName: "circle.grid.2x2.fill")
                .font(.system(size: 15, weight: .semibold))
        }
    }
}

/// One control at the composer's trailing end.
///
/// **A nil action is an inert label, not a disabled button.** The settings
/// editor draws these to be dragged, and `.disabled` would dim the very thing it
/// is showing — a preview of the wrong thing. It also keeps the reorderable item
/// one stable view: a `ForEach` whose element changes type between a `Button`
/// and a `Text` loses the identity the drag is tracking.
struct ComposerControlButton<Mark: View>: View {
    var label: String
    var isActive: Bool = false
    var shape: ChromeShape
    var action: (() -> Void)?
    @ViewBuilder var mark: Mark

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) { body(of: mark) }
                    .buttonStyle(.plain)
            } else {
                body(of: mark)
            }
        }
        .onHover { hovering in
            guard isHovering != hovering, action != nil else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .animation(motion.standard, value: isActive)
        .help(label)
        .accessibilityLabel(Text(label))
    }

    private func body(of mark: Mark) -> some View {
        mark
            .foregroundStyle(isActive ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(InkColor.solid))
            .frame(width: Metrics.composerControl, height: Metrics.composerControl)
            // A region inside the bar's own material, never a body on top of
            // it — `INVARIANTS.md` §4 rule 2. The fill is the whole of the
            // hover and pressed state.
            .background(ComposerControlShape(shape).fill(fill))
            .contentShape(ComposerControlShape(shape))
    }

    private var fill: Color {
        if isActive { return Palette.accent.opacity(0.18) }
        return isHovering ? ComposerControlFill.hover : .clear
    }
}

/// The silhouette a control cut into the composer takes.
///
/// It follows the bar rather than being chosen: a circle inside a rounded
/// rectangle reads as a badge stuck on a panel, and a rounded rectangle inside a
/// capsule reads as a tile that missed its grid.
///
/// `nonisolated`, because a `Shape` conformance is — `INVARIANTS.md` §4.87 —
/// and both constants it reads already are.
nonisolated struct ComposerControlShape: Shape {
    var shape: ChromeShape

    init(_ shape: ChromeShape) { self.shape = shape }

    func path(in rect: CGRect) -> Path {
        shape.enclosesFlankingControls
            ? Path(roundedRect: rect, cornerRadius: Radius.row, style: .continuous)
            : Path(ellipseIn: rect)
    }
}

/// The `+` at the composer's leading end.
///
/// A glass body of its own beside a pill, a region cut into a boxy bar. It keeps
/// `.interactive()` in the first case only: the displacement scales with the
/// surface, so on a 38-point circle it reads as the control responding, and on a
/// region inside a larger plate there is no separate body to displace.
struct ComposerAttachButton: View {
    var shape: ChromeShape
    var action: (() -> Void)?

    var body: some View {
        if shape.enclosesFlankingControls {
            ComposerControlButton(label: "Add attachment", shape: shape, action: action) {
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .regular))
            }
        } else {
            ComposerCircleBody(action: action) {
                Image(systemName: "plus")
                    .font(Typeface.controlGlyph)
                    .foregroundStyle(InkColor.solid)
            }
            .help("Add attachment")
            .accessibilityLabel(Text("Add attachment"))
        }
    }
}

/// The send control.
///
/// **Always drawn, tinted only once there is something to send.** It used to
/// appear on the first keystroke and vanish on the last backspace, which moved
/// the field's trailing edge under the caret while somebody was typing — and in
/// the pill arrangement, where it is a body outside the plate, it would have
/// moved the plate itself. Colour still carries the meaning: the accent is the
/// one tinted thing in the bar and it arrives exactly when Return will do
/// something.
struct ComposerSendButton: View {
    var shape: ChromeShape
    var isArmed: Bool
    var action: () -> Void

    @Environment(\.motion) private var motion

    var body: some View {
        Group {
            if shape.enclosesFlankingControls {
                Button(action: action) { enclosedBody }
                    .buttonStyle(.plain)
            } else {
                ComposerCircleBody(tint: isArmed ? Palette.accent.opacity(0.7) : nil, action: action) {
                    arrow
                }
            }
        }
        .disabled(!isArmed)
        // A `Return` shortcut on a disabled button is inert, which is what keeps
        // this from swallowing the key the text field needs while there is
        // nothing to send.
        .keyboardShortcut(.return, modifiers: [])
        .animation(motion.glassMorph, value: isArmed)
        .accessibilityLabel(Text("Send"))
    }

    private var enclosedBody: some View {
        arrow
            .frame(width: Metrics.composerControl, height: Metrics.composerControl)
            .background {
                Circle().fill(isArmed ? Palette.accent.opacity(0.85) : ComposerControlFill.resting)
            }
            .contentShape(.circle)
    }

    private var arrow: some View {
        Image(systemName: "arrow.up")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(isArmed ? AnyShapeStyle(.white) : AnyShapeStyle(Ink.tertiary))
    }
}

/// A circular glass control beside the composer's plate.
///
/// One type for `+` and for send, because they are the same object at the two
/// ends of the bar and two copies is two places for the diameter to drift.
/// The composer's relative fills — light on a dark room's glass, shade on a
/// light one's. Here rather than on the generic views that use them, which
/// cannot hold a stored constant.
private nonisolated enum ComposerControlFill {
    /// A control under the pointer.
    static let hover = Color.relative(dark: 0.14, light: 0.10)
    /// A round control at rest.
    static let resting = Color.relative(dark: 0.10, light: 0.07)
}

private struct ComposerCircleBody<Mark: View>: View {
    var tint: Color?
    var action: (() -> Void)?
    @ViewBuilder var mark: Mark

    var body: some View {
        Group {
            if let action {
                Button(action: action) { shell }
                    .buttonStyle(.plain)
            } else {
                shell
            }
        }
        // Layout first, glass last — and the tint goes IN the material rather
        // than behind it, which is what keeps it lensing (§4 rule 3).
        .glassEffect(.regular.tint(tint).interactive(), in: .circle)
        .specularEdge(in: Circle())
    }

    private var shell: some View {
        mark
            .frame(
                width: Metrics.composerControlHeight,
                height: Metrics.composerControlHeight
            )
            .contentShape(.circle)
    }
}
