import CoreGraphics
import SwiftUI

// MARK: - The two grounds
//
// The workspace window has exactly two of them, and they are different objects
// with different rules — which is `INVARIANTS.md` §1 restated in code rather
// than a new idea:
//
//  - **The reading surface** is the detail column. It is opaque, because a
//    transcript over a photograph is unreadable. A theme changes what colour it
//    is; a backdrop changes it to a picture with the theme drawn back over it,
//    and the scrim's floor is what keeps §1's promise while doing so.
//  - **The sidebar column** is painted with nothing, because AppKit paints it
//    with behind-window vibrancy and that vibrancy IS the bleed. A theme with a
//    hue veils it — thin enough that the wallpaper still comes through, tinted —
//    and an achromatic theme still paints nothing at all.
//
// THE PICTURE IS ONE PICTURE ACROSS BOTH COLUMNS, which is the whole reason
// this file has any geometry in it. Each column draws the *same* bitmap
// aspect-filled to the *window*, offset by that column's own origin, and clipped
// to itself. Filling each column separately would put two different crops of the
// photograph side by side with a seam down the middle where the split view is.

/// The window's own rect, published by the root and read by every ground.
///
/// **A published value rather than a named coordinate space, and that is a
/// correction.** The first version declared `.coordinateSpace(.named(…))` at the
/// root and had each column ask for `bounds(of:)`. It works in the detail column
/// and returns **nil in the sidebar** — a split view hosts that column
/// separately, and a named space does not cross the boundary. The fallback then
/// gave the sidebar a field of its own height starting at its own top, so the
/// two columns ran two different gradients: measured on a Conifer window, the
/// sidebar read #00210C at the same height the transcript read #011508, and the
/// split was a visible seam again.
///
/// `.global` *is* uniform across those hosting boundaries — it is what
/// `PresentationOrigin` already anchors profile cards with — so both halves of
/// the arithmetic come from it: the root publishes its frame, and each ground
/// reads its own.
extension EnvironmentValues {
    @Entry var windowField: CGRect = .zero
}

private struct WindowFieldModifier: ViewModifier {
    @State private var field: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { field = $0 }
            .environment(\.windowField, field)
    }
}

extension View {
    /// Applied once, at the window root, above anything that draws a ground.
    func backdropSpace() -> some View {
        modifier(WindowFieldModifier())
    }
}

/// A column's place in the window, as one comparable value.
///
/// Both halves come from one geometry read: publishing them separately means two
/// `@State` writes and two layout passes for one resize, and — the part that
/// actually bites — a window that is briefly described by a new size and an old
/// origin, which draws the picture in the wrong place for a frame.
nonisolated struct BackdropFrame: Equatable, Sendable {
    var container: CGSize = .zero
    var rect: CGRect = .zero
}

// MARK: - The modifier

nonisolated enum ThemeGroundRole: Equatable, Sendable {
    /// The detail column. Opaque, always.
    case reading
    /// The rail and the channel list. Painted with nothing unless the theme or a
    /// picture gives it something to paint.
    case sidebar
}

private struct ThemeGroundModifier: ViewModifier {
    var role: ThemeGroundRole
    /// Whether the ground spreads into the safe areas around it.
    ///
    /// True for a column, which owns its whole span. **False inside a bar**,
    /// which is already living in a safe area and would otherwise expand out of
    /// its own row and paint over the column beside it.
    var spreads: Bool

    @State private var theme = ThemeStore.shared
    @State private var renderer = BackdropRenderer.shared

    func body(content: Content) -> some View {
        content.background {
            ThemeGroundLayer(
                role: role,
                colors: theme.colors,
                backdrop: theme.backdrop,
                picture: renderer.image,
                spreads: spreads
            )
        }
    }
}

extension View {
    /// The opaque ground the *detail* column sits on.
    ///
    /// **Never apply this to the sidebar column** — see the note at the top of
    /// this file, and §1. Use `sidebarGround()` there, which knows to paint
    /// nothing.
    func readingSurface() -> some View {
        modifier(ThemeGroundModifier(role: .reading, spreads: true))
    }

    /// The sidebar column's ground: nothing, a veil, or the picture.
    func sidebarGround() -> some View {
        modifier(ThemeGroundModifier(role: .sidebar, spreads: true))
    }

    /// The ground behind a **floating bar's own row**.
    ///
    /// `safeAreaBar` paints a background of its own under whatever it is handed,
    /// and there is no supported way to ask it not to. Over the house palette it
    /// is invisible — the bar's fill and the window's ground are the same
    /// near-black — and under any theme it is a flat slab across the foot of the
    /// column, with a hard edge exactly one bar tall. With a picture behind the
    /// app it cuts the photograph off mid-window.
    ///
    /// So the bar is handed the same ground the column has, positioned in the
    /// same window space, which puts the theme back on top of the system's fill
    /// and continues the picture through it without a seam. The one bar that
    /// does *not* need this is the composer's, because the transcript already
    /// runs underneath it and covers the fill.
    func barGround(_ role: ThemeGroundRole) -> some View {
        modifier(ThemeGroundModifier(role: role, spreads: false))
    }
}

// MARK: - What is actually drawn

private struct ThemeGroundLayer: View {
    var role: ThemeGroundRole
    var colors: ThemeColors
    var backdrop: Backdrop?
    var picture: CGImage?
    var spreads: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.windowField) private var windowField
    @State private var mine: CGRect = .zero

    /// This column's place in the window. Falls back to filling itself when
    /// there is no root above — the settings window's own preview is the case.
    private var frame: BackdropFrame {
        guard windowField.width > 1, windowField.height > 1 else {
            return BackdropFrame(container: mine.size, rect: CGRect(origin: .zero, size: mine.size))
        }
        return BackdropFrame(
            container: windowField.size,
            rect: mine.offsetBy(dx: -windowField.minX, dy: -windowField.minY)
        )
    }

    var body: some View {
        painted
            // `onGeometryChange` rather than a `GeometryReader`: it reads the
            // value the layout already computed and fires only when it moves,
            // where a reader is an extra layout container and an extra pass on
            // every resize.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { mine = $0 }
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var painted: some View {
        // **The clip lives inside `field`, and it has to.** Written here as
        // `field.clipped().ignoresSafeArea()` the clip is established against
        // the *un-expanded* bounds and the escape then has nothing to fill: the
        // ground stopped at the sidebar's bottom safe area, leaving the rail's
        // last sixty points showing the window's own fill — a grey rectangle in
        // the corner of every themed window, and one that survived three
        // plausible explanations before a red probe behind the ground showed it
        // red.
        let layers = field
        if spreads {
            // **A ground fills its column edge to edge. Every safe area in it
            // belongs to something else.**
            //
            // A `.background` is laid out inside the modified view's safe area,
            // and this window has one at each end of the sidebar: the titlebar
            // claims the top and the now bar's `safeAreaBar` claims the bottom.
            // Respecting them left the ground as a band down the middle of the
            // column with the *window's* own colour above and below it — which
            // is invisible under the house theme, where the two happen to match,
            // and unmissable under any other. With a picture behind the app it
            // was a hard black edge cut straight across the identity capsule.
            //
            // Only the ground ignores these. Nothing that is *read* does, which
            // is the distinction §1's rule about the titlebar is drawing: the
            // strip is unclickable and belongs to AppKit, so a control there is
            // a bug — a colour there is the whole point.
            layers.ignoresSafeArea()
        } else {
            layers
        }
    }

    /// The theme's ground and, over it, the reader's picture — **both laid out
    /// in the WINDOW rather than in this column.**
    ///
    /// This is the whole correction, and it is what the first version got
    /// wrong. The gradient used to be drawn per column: the detail column got a
    /// wash from its own top to its own foot, and the sidebar got one flat fill.
    /// Two columns lit independently is not a theme, it is two themes — the
    /// window read as a dark stripe beside a coloured page, with a hard seam
    /// down the split view where the two disagreed.
    ///
    /// So there is ONE field, sized to the window and offset by this column's
    /// origin in it, exactly the way the photograph already was. The sidebar and
    /// the transcript then take the same colour at the same height, because it
    /// is the same gradient — the split has nothing to be a seam *of*.
    @ViewBuilder
    private var field: some View {
        if role == .sidebar, colors.railVeilOpacity <= 0, backdrop == nil {
            // Nothing at all. Painting the column is what throws the bleed away,
            // and the house theme has no reason to.
            //
            // **A picture is a reason.** The guard used to be on the theme
            // alone, so choosing True Black with a photograph behind the app
            // left the whole sidebar column unpainted — the desktop coming
            // through the rail beside a transcript with the reader's own
            // picture on it. The bleed is what Wingcord looks like until
            // somebody says otherwise, and setting a background says otherwise
            // just as plainly as choosing a hue does.
            Color.clear
        } else {
            ZStack {
                groundGradient
                picturePlate
            }
            .overlay {
                // A column of contents is a step behind the page beside it — the
                // same relationship every client with a theme draws, and the
                // only difference left between the two columns now that they
                // share one field.
                if role == .sidebar {
                    Color.black.opacity(ThemeColors.sidebarRecess)
                }
            }
            .clipped()
            .opacity(sidebarOpacity)
        }
    }

    /// How solidly the sidebar column is painted.
    ///
    /// A picture makes it opaque whatever the theme says: the photograph *is*
    /// the ground there, and letting the desktop through a hole in it would put
    /// two different backgrounds in one column.
    private var sidebarOpacity: Double {
        guard role == .sidebar else { return 1 }
        return backdrop == nil ? colors.railVeilOpacity : 1
    }

    /// The window's gradient, expressed in **this column's** unit space.
    ///
    /// **Not a window-sized child offset into place**, which is what the picture
    /// below still is and what this used to be. A ground ignores its safe areas,
    /// so a column reaches past the root view that publishes the window's rect —
    /// under the titlebar at the top, past the now bar's inset at the foot — and
    /// a child sized to that rect simply runs out before the layer does. What it
    /// left was the rail's last sixty points unpainted: a grey rectangle in the
    /// corner of every themed window, which survived three plausible
    /// explanations before a red probe behind the ground came back red.
    ///
    /// A `LinearGradient` extends its end colours past its own start and end
    /// points, so putting those points where the window's top and foot fall in
    /// this column fills the layer however far it reaches — and puts the same
    /// colour at the same height in every column, which is the whole point.
    private var groundGradient: LinearGradient {
        let height = max(frame.rect.height, 1)
        return LinearGradient(
            colors: [Color(hex: colors.canvas), Color(hex: colors.canvasLit)],
            startPoint: UnitPoint(x: 0.5, y: -frame.rect.minY / height),
            endPoint: UnitPoint(x: 0.5, y: (frame.container.height - frame.rect.minY) / height)
        )
    }

    /// The reader's picture, aspect-filled to the window and offset to this
    /// column's place in it.
    ///
    /// **The rectangle it fills is the window UNION this column**, and that
    /// union is the whole of what makes this reliable. A picture sized to the
    /// window alone leaves anything outside the window's rect unpainted, and
    /// this window has several such places: a ground ignores its safe areas, so
    /// a column reaches under the titlebar and past the now bar's inset — and a
    /// column whose own frame is reported in a space the root does not share
    /// reaches somewhere else entirely. Every one of those showed up the same
    /// way, as a hard-edged region of flat colour where the photograph should
    /// have been: a quarter of the window in one build, the member list in the
    /// next.
    ///
    /// Taking the union means the picture covers the layer *by construction*,
    /// whatever the geometry turns out to be, and the only cost is that a column
    /// which overhangs the window crops a few points differently from one that
    /// does not. That is invisible; a missing photograph is not.
    @ViewBuilder
    private var picturePlate: some View {
        if let backdrop, let picture {
            let cover = CGRect(origin: .zero, size: frame.container)
                .union(frame.rect)
                .insetBy(dx: -Self.pictureBleed, dy: -Self.pictureBleed)
            Color.clear
                .overlay(alignment: .topLeading) {
                    Image(decorative: picture, scale: 1, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: cover.width, height: cover.height)
                        .offset(
                            x: cover.minX - frame.rect.minX,
                            y: cover.minY - frame.rect.minY
                        )
                }
                .overlay { groundGradient.opacity(scrim(backdrop)) }
                // Not a spring: there is no position to overshoot in a picture
                // arriving, and this happens once per launch and once per change.
                .animation(.easeOut(duration: 0.22), value: backdrop.fileName)
                .transition(.opacity)
        }
    }

    /// A few points of slack around the union, so a half-point rounding
    /// disagreement between two columns cannot leave a hairline of ground
    /// showing down the split.
    private static let pictureBleed: CGFloat = 4

    /// How far the theme's ground is drawn back over the picture.
    ///
    /// **One value for the whole window, and the two-value version it replaces
    /// was the bug.** The sidebar used to take a much lighter scrim than the
    /// reading surface, on the reasoning that nothing in a table of contents is
    /// read for minutes at a time and a picture is worth seeing there. What that
    /// produced was one photograph shown at two exposures with the split view
    /// between them — bright sky down the sidebar, dim green across the
    /// transcript — which reads as two pictures rather than as one window.
    ///
    /// The columns are told apart by `ThemeColors.sidebarRecess`, which is six
    /// percent and belongs to the ground rather than to the picture.
    ///
    /// **Reduce Transparency raises the floor rather than removing the
    /// picture.** The setting is about surfaces you have to read *through*, and
    /// a backdrop is not one — but the transcript on top of it is, so the scrim
    /// stops being a preference at that point and becomes the thing keeping the
    /// prose legible.
    private func scrim(_ backdrop: Backdrop) -> Double {
        reduceTransparency ? max(0.88, backdrop.scrim) : backdrop.scrim
    }
}
