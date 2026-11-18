import SwiftUI

// MARK: - The vocabulary the three server pages are built from
//
// A heading, a card, a row, a glyph and a chip — and nothing else. The same
// argument the settings window's row vocabulary makes: a page that needs a sixth
// shape is a page that has not decided what it is.
//
// TWO RULES DECIDE THE MATERIALS HERE, and both come out of `INVARIANTS.md` §4.
//
//   1. **A card is structure, not glass.** These pages sit on the opaque reading
//      surface, and glass over an opaque fill is rule 3 — the material has
//      nothing to lens and renders as a flat panel. So a card is
//      `.structuralSurface()`, which is a material *behind* content and honours
//      the system's glass-intensity and Reduce Transparency settings for free.
//   2. **Only the floating bar is glass**, because only the floating bar has
//      moving content passing beneath it. That is the whole distinction: glass
//      floats, structure sits.

// MARK: Page

/// The scrolling column every server page is.
///
/// A measure rather than the window's width: at 1500 points a full-bleed page is
/// a line of text nobody can track back to the start of. The column is centred
/// and the page's ground is the reading surface, which the detail column already
/// paints — so this adds none of its own.
struct SurfacePage<Content: View>: View {
    /// How wide the column is. One page has an aside and needs more; the other
    /// two are a single measure of prose.
    var measure: CGFloat = Proportions.surfaceColumnMax
    /// The BUILT view, not the builder. An escaping `@ViewBuilder` stored on a
    /// view keeps a closure per instance and stops SwiftUI seeing the content as
    /// structurally stable across updates.
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            // **Lazy, because one of these pages is unbounded.** A five-hundred
            // channel server's browse list is five hundred rows, and an eager
            // stack builds every one of them before the first is on screen. The
            // children here are whole sections, so laziness bounds the eager
            // work to one category — which is the shape the cards already have.
            LazyVStack(alignment: .leading, spacing: Spacing.group) {
                content
            }
            .surfaceColumn(measure)
            .padding(.top, Spacing.margin)
            .padding(.bottom, Spacing.section)
        }
        .scrollBounceBehavior(.always, axes: .vertical)
    }
}

extension View {
    /// Puts a view on the page's own column.
    ///
    /// **The floating bar uses this too**, which is the whole reason it exists:
    /// a bar whose controls start at the detail column's edge while the page
    /// they belong to starts three hundred points further in reads as two
    /// unrelated surfaces. Same measure, same order of modifiers, so the two
    /// cannot drift.
    func surfaceColumn(
        _ measure: CGFloat = Proportions.surfaceColumnMax,
        alignment: Alignment = .leading
    ) -> some View {
        frame(maxWidth: measure, alignment: alignment)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, Spacing.group)
    }
}

/// A page's own heading, for the two pages that are not about the server itself.
///
/// The toolbar pill already names the destination; this says what it is *for*,
/// which the pill has no room to.
struct SurfaceHeading: View {
    var title: String
    var detail: String
    /// A quiet count beside the title — the number of channels, the number of
    /// servers. Nil where there is nothing to count.
    var badge: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.base) {
                Text(title)
                    .font(.system(.title3, weight: .bold))
                    .foregroundStyle(Ink.primary)
                if let badge {
                    Text(badge)
                        .font(Typeface.badge)
                        .foregroundStyle(Ink.tertiary)
                        .padding(.horizontal, Spacing.base)
                        .padding(.vertical, 3)
                        .background(Palette.hoverFill, in: .capsule)
                        .contentTransition(.numericText())
                }
            }
            Text(detail)
                .font(.system(.callout))
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A titled group. The heading's air is asymmetric — more above than below —
/// which a stack with one spacing value cannot express, so each group carries
/// its own.
struct SurfaceSection<Content: View>: View {
    var title: String
    /// The line under the heading, where the group needs one.
    var detail: String?
    /// A qualifier on the heading — "Required". **On the title's own line**,
    /// because it qualifies the question rather than the group: parked at the
    /// far edge of the section it reads as a label for whatever happens to be
    /// beside it, which is the first option.
    var note: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.base) {
                Text(title)
                    // 13 semibold. `.headline` is 13 **bold** on macOS 27 — see
                    // `HANDOFF.md` — and a page of bold headings reads as
                    // shouting.
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                if let note {
                    Text(note)
                        .font(Typeface.sectionHeader)
                        .foregroundStyle(Palette.accent)
                }
                Spacer(minLength: 0)
            }
            if let detail {
                Text(detail)
                    .font(.system(.caption))
                    .foregroundStyle(Ink.tertiary)
                    .padding(.top, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
                .padding(.top, Spacing.base)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The card's shape, shared by its clip, its material and its edge — three
/// places that must agree, and a literal at each is three places to disagree.
///
/// A free constant rather than a `static let` on the type: `SurfaceCard` is
/// generic over its content, and a generic type cannot hold a stored static.
private let surfaceCardShape = RoundedRectangle(
    cornerRadius: Radius.card,
    style: .continuous
)

/// A group of rows on one lifted surface.
///
/// The card clips its own content, so a row's hover fill runs edge to edge and
/// the first and last take the card's corners. Insetting each row instead leaves
/// a hover highlight floating inside a box, which reads as two containers.
struct SurfaceCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(surfaceCardShape)
            .structuralSurface(in: surfaceCardShape)
            // **A hairline, because a material over an opaque near-black ground
            // has almost nothing to lens.** On the sidebar's vibrant column the
            // material alone defines an edge; over `Palette.canvas` it resolves
            // to a value four steps from the ground, and a card with no edge
            // reads as a slightly lighter region of the page rather than as an
            // object on it.
            .overlay { surfaceCardShape.strokeBorder(Ink.quaternary, lineWidth: 1) }
    }
}

/// The hairline between two rows of a card, inset to clear the gutter.
struct SurfaceDivider: View {
    /// Cleared to the text's own leading edge, so the line separates rows rather
    /// than being drawn across a box.
    var leading: CGFloat = Spacing.margin + SurfaceGlyphView.side + Spacing.snug

    /// One device pixel, from the environment rather than from `NSScreen.main`:
    /// the environment value is the scale of the display this view is actually
    /// on, and reading it costs no trip through AppKit per divider per render.
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(Ink.quaternary)
            .frame(height: 1 / max(displayScale, 1))
            .padding(.leading, leading)
            .accessibilityHidden(true)
    }
}

// MARK: Glyph

/// The picture in a row's gutter: a server's own emoji, a Unicode glyph, or the
/// app's fallback symbol.
///
/// One view with an internal `switch` rather than a branch at the call site —
/// the three are different view types, and branching in the row's builder gives
/// the row three identities.
struct SurfaceGlyphView: View {
    var glyph: SurfaceGlyph
    var isEmphasised = false

    static let side: CGFloat = 26

    var body: some View {
        Group {
            switch glyph {
            case .emoji(let url):
                RemoteImage(url: url, side: Metrics.inlineEmojiSide) { Color.clear }
                    .frame(width: Metrics.inlineEmojiSide, height: Metrics.inlineEmojiSide)
            case .character(let character):
                Text(character)
                    .font(.system(.title3))
            case .symbol(let name):
                Image(symbol: name)
                    .font(.system(.callout))
                    .foregroundStyle(isEmphasised ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Ink.tertiary))
            }
        }
        .frame(width: Self.side, height: Self.side)
        .accessibilityHidden(true)
    }
}

// MARK: Rows

/// A row that goes somewhere: a channel a guide points at, a channel in the
/// browse list.
///
/// **A row that cannot go anywhere is not a button.** A guide can name a channel
/// the reader may not see, and a chevron on that row is the inert control §5.5
/// forbids — so `destination` being nil takes the press, the hover and the
/// chevron away together, and the row says why instead.
struct SurfaceNavigationRow: View {
    var glyph: SurfaceGlyph
    var title: String
    var detail: String?
    /// The channel this leads to, named. Nil when it leads nowhere.
    var destination: String?
    var destinationSymbolName: String = "number"
    /// The quiet line at the trailing edge — a relative time, a count.
    var trailing: String?
    var isEmphasised = false
    /// Whether this row's destination is already open beside the page.
    ///
    /// **The chevron turns**, which is the disclosure vocabulary the sidebar's
    /// categories already use — a row whose target is on screen is a row that
    /// has been opened, and a second press closes it.
    var isOpen = false
    var action: (() -> Void)?

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(alignment: .top, spacing: Spacing.snug) {
                SurfaceGlyphView(glyph: glyph, isEmphasised: isEmphasised)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.body, weight: .medium))
                        .foregroundStyle(action == nil ? AnyShapeStyle(Ink.tertiary) : AnyShapeStyle(Ink.primary))
                        .lineLimit(1)

                    if let detail {
                        Text(detail)
                            .font(.system(.caption))
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let destination {
                        HStack(spacing: 3) {
                            Image(symbol: destinationSymbolName)
                                .font(.system(.caption2))
                            Text(destination)
                                .font(.system(.caption))
                                .lineLimit(1)
                        }
                        .foregroundStyle(Ink.tertiary)
                        .padding(.top, 1)
                    } else if action == nil {
                        Text("You do not have access to this channel.")
                            .font(.system(.caption))
                            .foregroundStyle(Ink.quaternary)
                            .padding(.top, 1)
                    }
                }

                Spacer(minLength: Spacing.base)

                if let trailing {
                    Text(trailing)
                        .font(.system(.caption))
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                        .padding(.top, 3)
                }

                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(.caption2, weight: .semibold))
                        .foregroundStyle(isOpen ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Ink.quaternary))
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                        .padding(.top, 5)
                }
            }
            .padding(.horizontal, Spacing.margin)
            .padding(.vertical, Spacing.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .background(Palette.hoverFill.opacity(isOpen || isHovering ? 1 : 0))
        // Guard the modifier, not the closure: `.onHover` compiles to an AppKit
        // tracking area, and installing one on a row that can never highlight is
        // geometry AppKit re-derives on every frame of every scroll for nothing.
        .modifier(HoverHighlight(isEnabled: action != nil, isHovering: $isHovering))
        .animation(motion.fadeQuick, value: isHovering)
        .animation(motion.standard, value: isOpen)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isOpen ? [.isButton, .isSelected] : .isButton)
        .modifier(OpensHint(destination: action == nil ? nil : destination))
    }
}

/// The hint, only where there is one. An empty hint is a pause a screen reader
/// still takes.
private struct OpensHint: ViewModifier {
    var destination: String?

    func body(content: Content) -> some View {
        if let destination {
            content.accessibilityHint(Text("Opens \(destination)"))
        } else {
            content
        }
    }
}

/// Installs a tracking area only where a highlight can actually happen.
private struct HoverHighlight: ViewModifier {
    var isEnabled: Bool
    @Binding var isHovering: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.onHover { hovering in
                guard isHovering != hovering else { return }
                isHovering = hovering
            }
        } else {
            content
        }
    }
}

/// The roles somebody holds, wrapped onto as many rows as they need.
///
/// **`FlowLayout` rather than a `GeometryReader`**: a layout sees the proposal
/// and places its subviews in one pass, where a reader needs a second pass and a
/// state write to publish the width it measured — and a state write during
/// layout is a relayout. It is the profile card's own layout, reused; only the
/// chip's material differs, because the ground here is the page's material
/// rather than a person's own colour and clear glass over it has nothing to
/// lens.
struct SurfaceRoleFlow: View {
    var roles: [ProfileRole]

    var body: some View {
        FlowLayout(spacing: Spacing.tight) {
            ForEach(roles) { role in
                HStack(spacing: 5) {
                    Circle()
                        // A role with no colour set draws the neutral dot rather
                        // than none: the dot is what aligns the names, and a
                        // list where some rows have one is a ragged list.
                        .fill(role.colorValue.map { Color(hex: $0) } ?? Palette.presenceOffline)
                        .frame(width: 7, height: 7)
                    Text(role.name)
                        .font(.system(.caption))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, Spacing.base)
                .padding(.vertical, 4)
                .background(Palette.hoverFill, in: .capsule)
            }
        }
    }
}

// MARK: States

/// What a page shows while its route is out.
///
/// A sentence and a spinner rather than a skeleton: these pages are one round
/// trip and a shimmering ghost of a layout nobody has seen yet is a promise
/// about a shape the answer may not have.
struct SurfaceLoadingState: View {
    var message: String

    var body: some View {
        HStack(spacing: Spacing.snug) {
            ProgressView().controlSize(.small)
            Text(message)
                .font(.system(.callout))
                .foregroundStyle(Ink.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, Spacing.section)
    }
}

/// What a page shows when the answer came back empty.
struct SurfaceEmptyState: View {
    var symbol: String
    var title: String
    var detail: String

    var body: some View {
        VStack(spacing: Spacing.base) {
            Image(symbol: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Ink.quaternary)
            Text(title)
                .font(.system(.headline))
                .foregroundStyle(Ink.secondary)
            Text(detail)
                .font(.system(.caption))
                .foregroundStyle(Ink.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.section)
    }
}

// MARK: Actions

/// The one filled control these pages and their cards have — the system's
/// prominent Liquid Glass capsule, in the accent unless a page tints it
/// (Alex, 2026-10-14: glass capsules for buttons, never a solid slab).
struct SurfaceFilledButton: View {
    var title: String
    var systemImage: String?
    var tint: Color = Palette.accent
    var action: () -> Void

    /// **It hugs its label**, with a floor. A primary action stretched across a
    /// 680-point column is a banner rather than a button: it out-weighs the card
    /// it sits in and there is nothing for the eye to aim at. The minimum is
    /// what keeps a two-letter label from being a dot.
    private static let minimumLabelWidth: CGFloat = 112

    var body: some View {
        Button(action: action) {
            SurfaceButtonLabel(title: title, systemImage: systemImage)
                .frame(minWidth: Self.minimumLabelWidth)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .tint(tint)
        .controlSize(.large)
    }
}

/// A quiet secondary action beside it — plain Liquid Glass.
struct SurfaceQuietButton: View {
    var title: String
    var systemImage: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            SurfaceButtonLabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
    }
}

/// The words, and the glyph before them where there is one.
private struct SurfaceButtonLabel: View {
    var title: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: Spacing.base) {
            if let systemImage {
                Image(symbol: systemImage)
            }
            Text(title)
        }
        .font(.system(.body, weight: .semibold))
        .padding(.horizontal, Spacing.tight)
    }
}

/// A server page arriving: each section rises a few points into place on a
/// soft spring, a beat after the one above it — once, when the page opens.
/// Under Reduce Motion it fades, without the travel. The Server Guide's first
/// (Alex, 2026-11-18: "I like the animation of how the server guide appears"),
/// and Channels & Roles' since.
///
/// **The stagger is capped** at the eighth section: a long page's lower
/// sections are off screen when it opens, and the ones a reader scrolls to
/// must not wait their turn behind a queue they never saw.
struct SurfaceEntrance: ViewModifier {
    var index: Int
    var isShown: Bool

    @Environment(\.motion) private var motion

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .offset(y: isShown || motion.reduceMotion ? 0 : 12)
            .animation(
                motion.reduceMotion
                    ? .easeOut(duration: 0.2)
                    : .spring(response: 0.46, dampingFraction: 0.86).delay(Double(min(index, 8)) * 0.05),
                value: isShown
            )
    }
}
