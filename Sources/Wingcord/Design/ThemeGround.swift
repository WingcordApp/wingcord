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
//  - **The sidebar column** is painted with nothing under the house theme,
//    because AppKit paints it with behind-window vibrancy and that vibrancy IS
//    the bleed. Choosing any other theme, or a picture, paints it with the same
//    field as the page beside it. See `ThemeGround.paintsFrame`.
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

/// Where a CSS `linear-gradient(<angle>deg, …)` begins and ends in a box.
///
/// CSS measures the angle **clockwise from "to top"** — 90° runs left to right,
/// 180° top to foot — and makes the gradient line exactly long enough that the
/// perpendiculars through its two ends touch the box's far corners:
/// `|w·sin θ| + |h·cos θ|`, centred on the box. A line that merely spanned the
/// box would be right at 180° and would move every stop at any other angle,
/// which is every one of Discord's themes but two.
nonisolated enum GradientAxis {
    static func endpoints(angle degrees: Double, in box: CGRect) -> (start: CGPoint, end: CGPoint) {
        let radians = degrees * .pi / 180
        // Clockwise from "up", in a space whose y runs down the screen.
        let dx = sin(radians)
        let dy = -cos(radians)
        let half = (abs(box.width * dx) + abs(box.height * dy)) / 2
        return (
            CGPoint(x: box.midX - dx * half, y: box.midY - dy * half),
            CGPoint(x: box.midX + dx * half, y: box.midY + dy * half)
        )
    }
}

// MARK: - What a ground is made of

/// A theme's ground, resolved once per theme change for the views that draw it:
/// the gradient each column cuts its piece of the window out of, what is laid
/// over it, and the light in its corner.
///
/// **Beside `ThemeColors`, never inside it.** That value is copied through a
/// lock for every drawn row and is kept to plain integers for it; this one holds
/// SwiftUI gradients and is read only on the main actor, by the ground and the
/// gallery.
struct ThemeGround: Equatable {
    /// The line both gradients run along, in CSS degrees. See `GradientAxis`.
    var angle: Double
    /// The page — the reading column.
    var page: Gradient
    /// The frame — the sidebar column. The same line as the page, so the two
    /// columns are one field; it may carry more of the colour. See
    /// `ThemeSeed.frame(at:)`.
    var frame: Gradient
    /// A flat veil over the page's gradient and over the frame's: Discord's —
    /// black in a dark room, white in a light one. Zero for a house theme, whose
    /// gradients are already the ground.
    var pageVeil: Double
    var frameVeil: Double
    /// Whether the sidebar column is painted at all.
    ///
    /// **The one place this system knowingly breaks `INVARIANTS.md` §1**, and
    /// the exception is worth stating precisely. §1 says the sidebar column is
    /// painted with nothing, because AppKit paints it with behind-window
    /// vibrancy and that vibrancy *is* the bleed — the wallpaper and the
    /// menu-bar accent coming through the rail and the channel list.
    ///
    /// **So the house theme paints nothing, and every other theme paints it
    /// opaque.** That is a rule about *consent* rather than colour: the bleed is
    /// what Wingcord looks like until somebody says otherwise, and choosing a
    /// theme is saying otherwise. A thin veil that tried to keep the bleed *and*
    /// carry the colour was measured and failed both ways — invisible over
    /// vibrancy at a third, and at ninety-four percent the column's colour
    /// became a function of the wallpaper, lighter than the page by a different
    /// amount at every height because the desktop is.
    var paintsFrame: Bool
    /// The light in the window's bottom-trailing corner: its fall-off from the
    /// corner outward, or nil for a ground with no light of its own.
    var glow: Gradient?
    /// The brightest ground a coloured name can land on: the page at its
    /// lightest, which the roster shares — the roster is where a name meets the
    /// corner light. What `AppModel.roleColor` checks against.
    var inkCeiling: UInt32
    /// Whether this ground is a dark room or a light one — for a picture of it
    /// drawn inside a window of the other kind, like a gallery tile.
    var appearance: ThemeAppearance = .dark

    /// The house palette's ground: one flat colour, an unpainted sidebar, no
    /// light. Stated, like the palette it belongs to.
    static let trueBlack: ThemeGround = {
        let canvas = ThemeColors.trueBlack.canvas
        let flat = Gradient(colors: [Color(hex: canvas), Color(hex: canvas)])
        return ThemeGround(
            angle: 180, page: flat, frame: flat,
            pageVeil: 0, frameVeil: 0, paintsFrame: false, glow: nil,
            inkCeiling: canvas
        )
    }()

    /// The house's light room, stated like its colours — see
    /// `ThemeColors.porcelain`. The same diagonal as every house theme, lit at
    /// the foot; the frame a step deeper than the page, because in a light room
    /// "carries more of the colour" means a warmer, more toned column beside a
    /// brighter page. No corner light: at the lit end of a light ground there is
    /// no brighter to go.
    static let porcelain = ThemeGround(
        angle: ThemeSeed.fieldAngle,
        page: Gradient(colors: [Color(hex: 0xEF_EE_EA), Color(hex: 0xF7_F6_F3)]),
        frame: Gradient(colors: [Color(hex: 0xE6_E4_DF), Color(hex: 0xED_EB_E6)]),
        pageVeil: 0,
        frameVeil: 0,
        paintsFrame: true,
        glow: nil,
        inkCeiling: 0xF7_F6_F3,
        appearance: .light
    )

    /// A house theme, or the reader's own: the walk from head to foot sampled
    /// finely enough that the straight lines SwiftUI draws between samples stay
    /// on it.
    init(_ seed: ThemeSeed) {
        angle = seed.angle
        page = Self.sampled(seed, seed.field(at:))
        frame = Self.sampled(seed, seed.frame(at:))
        pageVeil = 0
        frameVeil = 0
        paintsFrame = true
        let light = Color(hex: seed.glow.packedRGB())
        let strength = seed.glowStrength
        glow = Gradient(stops: Self.glowFalloff.map {
            Gradient.Stop(color: light.opacity(strength * $0.share), location: $0.location)
        })
        inkCeiling = seed.inkCeiling
    }

    /// One of Discord's: its own gradient, its angle and its veils — thinned by
    /// vividness exactly as Discord's own theme editor thins them. No light of
    /// its own: Discord's themes have none, and one here would be ours.
    init(_ theme: DiscordTheme, vividness: Double = 0) {
        angle = theme.angle
        page = theme.gradient
        frame = theme.gradient
        pageVeil = theme.readingVeil(vividness: vividness)
        frameVeil = theme.sidebarVeil(vividness: vividness)
        paintsFrame = true
        glow = nil
        appearance = theme.base
        // The page's brightest stop through the page's own veil — black over a
        // dark theme, white over a light one.
        let veil = pageVeil
        let veilColor: UInt32 = theme.base == .light ? 0xFF_FF_FF : 0
        let brightest = theme.stops.map(\.color).max { InkContrast.luminance($0) < InkContrast.luminance($1) } ?? 0
        inkCeiling = InkContrast.composite(veilColor, over: brightest, opacity: veil)
    }

    /// A server's theme: its two colours spread evenly along its angle, under
    /// its own veils — Discord's `custom-client-theme` arrangement, which is
    /// the reader's Discord-theme arrangement with the veils set by the
    /// server's mix. No light of its own, and the reader's vividness does not
    /// reach it: it is the server's, stated.
    init(server theme: ServerTheme) {
        let gradient = Gradient(colors: theme.stops.map { Color(hex: $0) })
        angle = theme.angle
        page = gradient
        frame = gradient
        pageVeil = theme.pageVeil
        frameVeil = theme.frameVeil
        paintsFrame = true
        glow = nil
        appearance = theme.room
        let veilColor: UInt32 = theme.room == .light ? 0xFF_FF_FF : 0
        let brightest = theme.stops.max { InkContrast.luminance($0) < InkContrast.luminance($1) } ?? 0
        inkCeiling = InkContrast.composite(veilColor, over: brightest, opacity: pageVeil)
    }

    private init(
        angle: Double, page: Gradient, frame: Gradient,
        pageVeil: Double, frameVeil: Double, paintsFrame: Bool, glow: Gradient?,
        inkCeiling: UInt32, appearance: ThemeAppearance = .dark
    ) {
        self.appearance = appearance
        self.angle = angle
        self.page = page
        self.frame = frame
        self.pageVeil = pageVeil
        self.frameVeil = frameVeil
        self.paintsFrame = paintsFrame
        self.glow = glow
        self.inkCeiling = inkCeiling
    }

    private static func sampled(_ seed: ThemeSeed, _ point: (Double) -> Oklch) -> Gradient {
        let count = (seed.anchors.count - 1) * samplesPerLeg + 1
        return Gradient(stops: (0..<count).map { index in
            let t = Double(index) / Double(count - 1)
            return Gradient.Stop(color: Color(hex: point(t).packedRGB()), location: t)
        })
    }

    func gradient(for role: ThemeGroundRole) -> Gradient { role == .reading ? page : frame }
    func veil(for role: ThemeGroundRole) -> Double { role == .reading ? pageVeil : frameVeil }

    /// Four steps per leg of the walk: a sixty-to-eighty degree leg in steps of
    /// fifteen to twenty, which a straight line through RGB between neighbours
    /// cannot visibly bend off. A two-stop theme is five samples; a five-stop
    /// one, seventeen.
    static let samplesPerLeg = 4

    /// How far it reaches, as a share of the window's diagonal.
    static let glowReach = 0.55

    /// The light's fall-off, eased rather than linear: a two-stop radial fades
    /// in a straight line and reads as a cone with an edge, where light thins
    /// quickly near its source and lingers at the far end.
    private static let glowFalloff: [(location: Double, share: Double)] = [
        (0, 1), (0.22, 0.62), (0.5, 0.30), (0.78, 0.10), (1, 0),
    ]
}

extension View {
    /// Restates the **app's** colour scheme — the theme's room — on a surface
    /// that escapes a themed card into a window of its own: a flyout, a
    /// popover. A presentation inherits the card's environment on the way out,
    /// so without this a flyout raised from a light profile in a dark room
    /// comes up with the card's dark ink on the app's dark material.
    ///
    /// **Not `.dark`**, which is what these surfaces used to say: that was the
    /// same statement for as long as every theme was dark.
    func appColorScheme() -> some View {
        modifier(AppColorSchemeModifier())
    }
}

private struct AppColorSchemeModifier: ViewModifier {
    @State private var theme = ThemeStore.shared

    func body(content: Content) -> some View {
        content.environment(\.colorScheme, theme.colors.appearance == .light ? .light : .dark)
    }
}

extension ThemePreset {
    /// This preset's ground, resolved once for the life of the process.
    ///
    /// The gallery draws all ten and re-evaluates on every event of a Plumage
    /// drag, because the reader's own tile is in it; resolving the ten on each
    /// of those would be a hundred gamut fits per event for pictures that
    /// cannot change. The table is built from `allCases`, so it cannot miss.
    var ground: ThemeGround { Self.grounds[self]! }

    /// At the reader's vividness: the cached ground at zero, derived otherwise.
    /// True Black is the same at every setting, for the reason `colors` gives.
    func ground(vividness: Double) -> ThemeGround {
        guard vividness > 0, !isStated else { return ground }
        return ThemeGround(seed.at(vividness: vividness))
    }

    private static let grounds: [ThemePreset: ThemeGround] = Dictionary(
        uniqueKeysWithValues: allCases.map { preset in
            // The two stated palettes have stated grounds.
            let ground: ThemeGround = switch preset {
            case .trueBlack: .trueBlack
            case .porcelain: .porcelain
            default: ThemeGround(preset.seed)
            }
            return (preset, ground)
        }
    )
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
                ground: theme.ground,
                identity: theme.groundIdentity,
                backdrop: theme.shownBackdrop,
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

    /// The sidebar column's ground: nothing, the theme's frame, or the picture.
    func sidebarGround() -> some View {
        modifier(ThemeGroundModifier(role: .sidebar, spreads: true))
    }

}

// MARK: - What is actually drawn

private struct ThemeGroundLayer: View {
    var role: ThemeGroundRole
    var ground: ThemeGround
    /// Read only to tell a *choice* of theme — or going into or out of a
    /// themed server — from an edit to one. See `outgoing`.
    var identity: ThemeStore.GroundIdentity
    var backdrop: Backdrop?
    var picture: CGImage?
    var spreads: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.windowField) private var windowField
    @Environment(\.motion) private var motion
    @State private var mine: CGRect = .zero

    /// The ground a newly chosen theme is replacing, held over the new one
    /// while it fades out.
    ///
    /// **Over, not under, and fading out rather than in.** The new ground is
    /// opaque from its first frame and the old one thins away on top of it, so
    /// every frame of the change is the two grounds mixed and none of it is the
    /// window behind them — two opaque layers cross-fading symmetrically dip
    /// through a quarter of whatever is underneath at the midpoint.
    ///
    /// **A choice, never an edit.** Dragging the picker changes the ground on
    /// every event without changing the choice, and a fade per event would stack
    /// a dozen translucent windows under the pointer. Stepping into a server
    /// with a theme of its own is a choice in this sense — the server's.
    @State private var outgoing: ThemeGround?

    /// What the change is keyed on: the ground that was on screen, and whether
    /// the choice moved with it.
    private struct Shown: Equatable {
        var identity: ThemeStore.GroundIdentity
        var ground: ThemeGround
    }

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
        ZStack {
            painted(ground)
            if let outgoing {
                painted(outgoing)
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
            }
        }
        // `onGeometryChange` rather than a `GeometryReader`: it reads the
        // value the layout already computed and fires only when it moves,
        // where a reader is an extra layout container and an extra pass on
        // every resize.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { mine = $0 }
        .onChange(of: Shown(identity: identity, ground: ground)) { old, new in
            guard old.identity != new.identity else { return }
            outgoing = old.ground
        }
        // **Removed on the next turn, not in the same one.** Put in and taken
        // out in one update, the layer is never drawn at all and there is
        // nothing to fade from; the task runs once the old ground is on screen
        // over the new one.
        .task(id: outgoing) {
            if outgoing != nil { outgoing = nil }
        }
        // A fade has no travel for Reduce Motion to take away, which is why
        // this is `fade` and not a spring.
        .animation(motion.fade, value: outgoing == nil)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func painted(_ ground: ThemeGround) -> some View {
        // **The clip lives inside `field`, and it has to.** Written here as
        // `field.clipped().ignoresSafeArea()` the clip is established against
        // the *un-expanded* bounds and the escape then has nothing to fill: the
        // ground stopped at the sidebar's bottom safe area, leaving the rail's
        // last sixty points showing the window's own fill — a grey rectangle in
        // the corner of every themed window, and one that survived three
        // plausible explanations before a red probe behind the ground showed it
        // red.
        let layers = field(ground)
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
    /// the transcript then take their colour from the same line at the same
    /// place — the frame only carries more of it — so the split has nothing to
    /// be a seam *of*.
    @ViewBuilder
    private func field(_ ground: ThemeGround) -> some View {
        if role == .sidebar, !ground.paintsFrame, backdrop == nil {
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
                tinted(ground)
                picturePlate(ground)
            }
            .clipped()
        }
    }

    /// The theme's own ground in this column, before any picture: its gradient,
    /// the veil over it, and the light in the corner.
    @ViewBuilder
    private func tinted(_ ground: ThemeGround) -> some View {
        let veil = ground.veil(for: role)
        groundGradient(ground)
            .overlay {
                if veil > 0 {
                    (ground.appearance == .light ? Color.white : Color.black).opacity(veil)
                }
            }
            .overlay {
                // **Not under Increase Contrast.** The light is brightest in the
                // corner where the newest messages are, and a reader who asked
                // for more contrast asked for exactly the ground under them to
                // stay put.
                if let glow = ground.glow, contrast != .increased {
                    glowLayer(glow)
                }
            }
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
    /// points, so putting those points where the gradient's line begins and ends
    /// *in the window* fills the layer however far it reaches — and puts the
    /// same colour at the same place in every column, which is the whole point.
    /// The line is laid out in the window the way CSS lays it out in a box, so a
    /// Discord theme's stops land where Discord's do; see `GradientAxis`.
    private func groundGradient(_ ground: ThemeGround) -> LinearGradient {
        let (start, end) = GradientAxis.endpoints(
            angle: ground.angle,
            in: CGRect(origin: .zero, size: frame.container)
        )
        return LinearGradient(
            gradient: ground.gradient(for: role),
            startPoint: unit(start),
            endPoint: unit(end)
        )
    }

    /// The corner light, centred on the **window's** bottom-trailing corner and
    /// sized to the window, so every column draws its own part of one light.
    private func glowLayer(_ glow: Gradient) -> RadialGradient {
        let window = frame.container
        return RadialGradient(
            gradient: glow,
            center: unit(CGPoint(x: window.width, y: window.height)),
            startRadius: 0,
            endRadius: max(1, ThemeGround.glowReach * hypot(window.width, window.height))
        )
    }

    /// A point in the window, in this column's unit space.
    private func unit(_ point: CGPoint) -> UnitPoint {
        let column = frame.rect
        return UnitPoint(
            x: (point.x - column.minX) / max(column.width, 1),
            y: (point.y - column.minY) / max(column.height, 1)
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
    private func picturePlate(_ ground: ThemeGround) -> some View {
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
                .overlay {
                    tinted(ground)
                        // Flattened before it is faded. Faded as two layers, the
                        // veil and the gradient under it thin separately and the
                        // picture shows through each at a different strength —
                        // the veil is part of the theme's colour, not a second
                        // coat of it.
                        .compositingGroup()
                        .opacity(scrim(backdrop))
                }
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
    /// The columns are told apart by the theme's frame, which carries more of
    /// the colour than the page and belongs to the ground rather than to the
    /// picture — one photograph, one exposure.
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
