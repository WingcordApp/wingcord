import AppKit
import QuartzCore

/// The blur where a drawn canvas passes under the window's chrome.
///
/// # Why this is AppKit, and why it lives inside the scroll view
///
/// SwiftUI's `Material` and `.glassEffect` blur the SwiftUI **display list**.
/// The transcript is an `NSView` canvas hosted inside that list, so a material
/// laid over it samples nothing, resolves to its own flat tint, and paints the
/// grey slab this app shipped for two sessions. Five mechanisms were measured
/// against the live window before this one was kept:
///
///  1. `.ultraThinMaterial` over the strip — a slab. Sees no AppKit content.
///  2. The system toolbar's own backdrop, with `titlebarAppearsTransparent` and
///     `toolbarBackgroundVisibility` both left alone — **draws nothing at all**
///     in this window, with or without `.fullSizeContentView`, and
///     `scrollEdgeEffectStyle` in either style adds nothing to it. The AppKit
///     scroll-edge API is settable only on titlebar and split-item accessory
///     controllers; `NSScrollView` has no property for it, checked in the SDK 27
///     headers.
///  3. `CALayer.backgroundFilters` with a `CIGaussianBlur` — inert, at every
///     radius from 3 to 22, both at the window's content view and inside the
///     scroll view.
///  4. `CALayer.filters` over the effect view, to correct its tint — renders the
///     band **solid black**. It is not a colour correction of the material; it
///     replaces it.
///  5. `NSVisualEffectView` with `.withinWindow` blending — a flat opaque grey
///     when it is a child of the SwiftUI hierarchy or of the window's content
///     view, and **a real blur of the canvas when it is a subview of the scroll
///     view itself.**
///
/// That last line is the finding the rest of this file is built on:
/// within-window blending composites against the layers of its own hosting
/// subtree, and SwiftUI hands each representable a subtree of its own. So the
/// treatment belongs to the scrolling surface, not to the window — a surface
/// that passes under the chrome treats its own edge.
///
/// `CanvasGroundView` follows from the same sentence: a within-window backdrop
/// can see the rows and **cannot see the ground they are drawn on**, so the
/// ground is drawn a second time below the clip view, inside the tree this can
/// reach. Everything here assumes it is there.
///
/// # The strip is a STRAIGHT blur, and it is two layers
///
/// The version this replaces feathered out over 28 points below the toolbar and
/// read as a shadow ruled across the top of the window. That was wrong twice
/// over. A ramp is not what macOS does — the system's own scroll edge is a
/// uniform band that ends on a hard line at the chrome's foot — and the ramp was
/// the *visible* half of a darkening that came from somewhere else entirely.
///
/// **Every material in the SDK is a grey.** Measured over a reader's
/// photograph: a ground reading `41, 80, 98` came back `52, 64, 74` under the
/// material — lifted in red and *dropped* in green and blue, and about a
/// seventh darker in luminance. That is a strip which stops following the theme
/// at exactly the moment the theme is worth looking at, and it is the shadow.
/// Feathering it only spread the shadow over a longer distance.
///
/// So the material is half of the strip. Over it sits a second
/// `CanvasGroundView` — the same arithmetic, over the same values, at the same
/// place in the window's one field — at `tintOpacity`. Two things follow:
///
///  - The strip takes the **theme's** colour rather than the material's, and
///    follows a theme change, a backdrop change and the roster's own lift for
///    free, because it is a real ground and not a colour copied out of one.
///  - It lands a hair **above** the surface it crosses rather than below it.
///    That is deliberate and it is the whole point: an error in the lighter
///    direction reads as chrome, and an error in the darker direction reads as
///    the shadow this file exists to delete. The reference this was measured
///    against puts its band slightly light for the same reason.
///
/// What is left of the content underneath is a soft ghost moving under a band
/// the colour of the page — which is what a scroll edge is.
///
/// # The step in front of the page is the MATERIAL's, not a white lift
///
/// The version this replaces drew 16% of white into the tint's ground, and that
/// was the whole of the band's appearance rather than a hair on top of it. On a
/// ground whose red and green are 13 out of 255 — the reader's own theme — 16%
/// of white nearly **triples** them, and the measured band came back
/// `37, 37, 62` over a page of `13, 13, 42`: 2.6 times the page in luminance,
/// and *less* saturated than the page it sits on (blue minus red 29 → 25). That
/// is a chrome row which stops following the theme at the moment the theme is
/// worth looking at — the same fault as the material's own grey, arriving by
/// the other door.
///
/// The material is not what was wrong. Ranked over that ground, the fourteen
/// `NSVisualEffectView` materials fall into three groups: `.sheet`,
/// `.windowBackground`, `.contentBackground` and `.underPageBackground` are
/// **opaque slabs** under `.withinWindow` — nothing behind them survives at
/// all; `.titlebar`, `.sidebar`, `.toolTip`, `.popover` and
/// `.underWindowBackground` render a near-neutral grey that throws the hue
/// away; and only `.fullScreenUI` (`29, 29, 55`) and `.hudWindow`
/// (`27, 27, 54`) both keep the blue and carry a radius wide enough to smear a
/// row into a ghost. `.headerView`, the semantically obvious choice, is in the
/// second group — `33, 33, 37`, a grey with the theme taken out of it.
///
/// So the lift is gone and the tint is exactly its column's own ground. The
/// step in front of the page is the material's veil, which is a *proportion* of
/// what is under it and therefore follows the theme by construction. Measured
/// on the same three grounds:
///
///  - the reader's theme, `13, 13, 42` → `23, 23, 50`, **1.65×** the page;
///  - True Black, `10, 10, 12` → `22, 22, 24`, 2.2× — still an unmistakable
///    row, so nothing disappears on the house theme;
///  - a ground the weight of the reference's own, `31, 22, 58` → `37, 30, 62`,
///    **1.27×** against the reference's measured 1.31×.
///
/// The ghost is untouched by the change: content passing under the chrome
/// contributes 36% of its light either way, because 0.34 and 0.38 leave
/// essentially the same share of the material showing.
///
/// # It is gated, and that is the other half
///
/// A treatment over a surface with nothing beneath it is a slab, whatever it is
/// made of. So the strip is not drawn at all until content is actually passing
/// under the chrome, and it cross-fades in when that becomes true:
///
///  - The transcript's strip triggers on `.contentBehind` alone.
///  - The roster's also waits for the pointer to be in its column
///    (`.contentBehindAndPointer`). A list of names is glanced at, not read, and
///    a treatment that appears under the pointer is one the reader asked for.
///
/// Nothing here runs per frame: `contentDidScroll` is a comparison against two
/// thresholds and returns without touching a view unless the answer *changed*.
/// The strip is resized on a resize and on a chrome height change, and the
/// compositor does every frame in between.
final class ScrollEdgeBlur: NSVisualEffectView {
    /// What has to be true before the strip is drawn.
    enum Trigger: Equatable {
        /// Content passing beneath it is enough. The transcript's.
        case contentBehind
        /// Content passing beneath it, **and** the pointer somewhere in this
        /// column. The roster's.
        case contentBehindAndPointer
    }

    /// How much of the theme's own ground is drawn back over the material.
    ///
    /// **This one number is the whole appearance of the strip**, and it is the
    /// one to move if it is ever wrong again. It is a pull back toward the page:
    /// at 0 the band is the material's veil undiluted, and every step up trades
    /// a little of the ghost for a band nearer the colour of the page.
    ///
    /// The strip is still deliberately a **step in front of the page**, the way
    /// the reference draws it and the way `ThemeColors.sidebarRecess` and
    /// `WorkspacePane.rosterLift` already separate the other two surfaces in
    /// this window — but the step is the material's, and this only decides how
    /// far back it is pulled. See the note on the type for the three grounds it
    /// was solved over.
    ///
    /// 0.38 rather than the 0.34 it replaces because the two leave the same
    /// ghost — 36% of the light of whatever passes under the chrome — and 0.38
    /// lands a tenth nearer the page.
    private static let tintOpacity: CGFloat = 0.38

    /// Points of content under the chrome before the strip appears, and before
    /// it leaves again.
    ///
    /// Two numbers rather than one: a single threshold sitting exactly under a
    /// resting scroll position flickers the strip on every stray wheel event.
    private static let engageAbove: CGFloat = 2
    private static let disengageBelow: CGFloat = 0.5

    var trigger: Trigger = .contentBehind {
        didSet { if trigger != oldValue { syncVisibility() } }
    }

    /// The chrome's own row. The strip is exactly this tall.
    var chromeHeight: CGFloat = 0 {
        didSet {
            guard abs(chromeHeight - oldValue) > 0.5 else { return }
            tint.chromeInset = max(0, chromeHeight)
            fit()
        }
    }

    /// Asks the owner to redraw the ground below this strip.
    ///
    /// **A within-window backdrop is captured from its group, and the group is
    /// only refreshed when something inside it redraws — marking the effect view
    /// itself dirty does nothing.** So the strip cannot fix its own stale
    /// sample; it has to ask the surface underneath to paint again.
    ///
    /// The failure this exists for: on the pass where the strip is first sized,
    /// the ground below it has not painted yet, so the strip captures black. In
    /// the transcript that corrected itself within a frame or two, because rows
    /// arriving and a pointer moving over them redraw the canvas constantly. The
    /// roster's canvas is **static**, so its strip stayed a black slab for the
    /// life of the window. Now that the strip also comes back from hidden, the
    /// same request is made every time it does.
    var needsGroundRedraw: (() -> Void)?

    /// The theme half of the strip. See the note on this type.
    private let tint = CanvasGroundView(frame: .zero)

    private var hasContentBehind = false
    private var isPointerInside = false
    /// What the last cross-fade was asked for, so a completion handler from a
    /// fade that has already been superseded cannot hide a visible strip.
    private var isShown = false
    private var fadeGeneration = 0

    init(role: ThemeGroundRole, lift: Double) {
        super.init(frame: .zero)
        // **Chosen for radius AND for what it does to the hue**, which is the
        // ranking in the note on this type: of the fourteen materials in the
        // SDK, only this and `.hudWindow` both keep the theme's blue and smear
        // a row far enough to read as a ghost rather than as dimming.
        // `.headerView`, the semantically obvious choice, is a near-neutral
        // grey — it measures `33, 33, 37` over a ground of `13, 13, 42`.
        material = .fullScreenUI
        blendingMode = .withinWindow
        // **`.active`, not the default.** Left to follow the window's active
        // state, an inactive window renders the material's flat inactive fill —
        // which is precisely the slab this replaces, arriving whenever somebody
        // clicks another app.
        state = .active
        isEmphasized = false

        // Starts away. Nothing is under the chrome at the moment a window opens,
        // and a strip that shows itself for the first frame is the fault this
        // gate exists to remove.
        alphaValue = 0
        isHidden = true

        tint.role = role
        // The column's own lift and nothing added. What separates this row from
        // the page is the material's veil; see the note on `tintOpacity`.
        tint.lift = lift
        tint.alphaValue = Self.tintOpacity
        // **Sized in `fit`, not by an autoresizing mask** — a mask resizes a
        // subview *proportionally*, so one added at zero stays at zero however
        // large the strip becomes. The same trap the strip itself is documented
        // for, one level down.
        addSubview(tint)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Never takes a click. Everything level with this strip is a real toolbar
    /// item, drawn by AppKit above it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: The gate

    /// How much content is passing under the chrome, in points.
    ///
    /// Called from the owner's viewport observer, which already runs on every
    /// bounds change. See `CanvasChrome.overlap(in:)` for the arithmetic.
    func contentDidScroll(overlap: CGFloat) {
        let engaged = hasContentBehind
            ? overlap > Self.disengageBelow
            : overlap > Self.engageAbove
        guard engaged != hasContentBehind else { return }
        hasContentBehind = engaged
        syncVisibility()
    }

    /// Whether the pointer is anywhere in the column this strip belongs to.
    func pointerDidChange(inside: Bool) {
        guard inside != isPointerInside else { return }
        isPointerInside = inside
        guard trigger == .contentBehindAndPointer else { return }
        syncVisibility()
    }

    private var shouldShow: Bool {
        guard chromeHeight > 1, (superview?.bounds.width ?? 0) > 1, hasContentBehind else {
            return false
        }
        return trigger == .contentBehind || isPointerInside
    }

    private func syncVisibility() {
        let show = shouldShow
        guard show != isShown else { return }
        isShown = show

        fadeGeneration &+= 1
        let generation = fadeGeneration
        if show {
            isHidden = false
            refreshBackdrop()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = show ? 1 : 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.fadeGeneration, !self.isShown else { return }
                // Hidden rather than left at zero alpha: a within-window
                // backdrop is re-sampled whenever its group redraws, and the
                // transcript's group redraws on every scrolled frame. A strip
                // nobody can see must not be paying for that.
                self.isHidden = true
            }
        }
    }

    private func refreshBackdrop() {
        // Deferred by a turn: an invalidation raised inside the current display
        // pass is sampled before that pass has committed, which is the bug
        // rather than the fix.
        DispatchQueue.main.async { [weak self] in
            guard let self, !isHidden else { return }
            needsGroundRedraw?()
        }
    }

    // MARK: Size and shape

    /// Takes the scroll view's width, and has to be **driven** rather than
    /// autoresized.
    ///
    /// Two ways of doing that were tried and neither works. An
    /// `autoresizingMask` resizes a width *proportionally*, so a strip added
    /// before the scroll view has any size stays at zero however wide the window
    /// becomes. Overriding `resize(withOldSuperviewSize:)` never fires either:
    /// `NSScrollView` tiles its clip view, its scrollers and its floating
    /// subviews itself and does not walk an ordinary one.
    ///
    /// The visible failure was not a missing strip — it was a strip stuck at the
    /// width it had when the *member list was still showing*, leaving the rest
    /// of the transcript untreated with a hard vertical seam down the middle of
    /// the window's chrome. So the owner calls this from the same viewport
    /// observer that already watches the clip view's frame.
    func fit() {
        guard chromeHeight > 1, let width = superview?.bounds.width, width > 1 else {
            syncVisibility()
            return
        }
        // **Exactly the chrome's row, and it ends on a hard line.** The system's
        // own scroll edge is a uniform band with a crisp foot; the ramp that
        // used to hang 28 points below this is what made the treatment read as
        // something cast by the toolbar rather than as the toolbar's own row.
        let size = NSSize(width: width, height: chromeHeight)
        if size != frame.size {
            setFrameSize(size)
            tint.frame = CGRect(origin: .zero, size: size)
            refreshBackdrop()
        }
        syncVisibility()
    }

}

// MARK: - AppKit's own scroll edge

extension NSScrollView {
    /// Hides the scroll-edge machinery AppKit installs by itself.
    ///
    /// **The black band across the roster's chrome was this, not anything the
    /// app drew.** Dumping the window's view tree found it: as soon as a scroll
    /// view is given a top content inset, AppKit inserts a `BackdropView` and an
    /// `NSScrollPocket` across that inset, *above* anything the app added and
    /// below the clip view. Over this window they render as a flat dark slab —
    /// invisible in the transcript, where rows are dense enough to cover the
    /// strip at every scroll position, and unmissable in the roster, where the
    /// space above the first section is empty.
    ///
    /// There is no public property for it. `NSScrollEdgeEffectStyle` is settable
    /// only on `NSTitlebarAccessoryViewController` and
    /// `NSSplitViewItemAccessoryViewController` — checked in the SDK 27 headers
    /// — and `NSScrollView` exposes nothing at all. So the views are found by
    /// class name and hidden, which is **defensive on purpose**: a name that
    /// stops matching means the system stopped installing them, and this
    /// quietly does nothing.
    ///
    /// Cheap enough to call from a viewport observer: a scroll view has a
    /// handful of direct subviews, and AppKit reinstates these on some layout
    /// passes, so it has to be asked more than once.
    func hidesSystemScrollEdge() {
        for view in subviews where !view.isHidden {
            switch String(describing: type(of: view)) {
            case "NSScrollPocket", "BackdropView": view.isHidden = true
            default: continue
            }
        }
    }
}
