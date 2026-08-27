import CoreGraphics

/// Where the banner, the server-name pill and the first channel row sit, from
/// the four numbers that decide all three.
///
/// **One value, because the three layers are one arrangement.** The banner is a
/// layer *behind* the list, the pill is a layer *in front* of it, and the list
/// has to reserve the room the banner occupies — so a change to any one of them
/// is wrong unless the other two move with it. Three separate pieces of
/// arithmetic in three separate views is what produced a pill floating in a band
/// of empty column between the artwork and the rows, with each of the three
/// individually defensible.
///
/// ## The one measured input
///
/// `chromeInset` is the only thing here that has to be asked for rather than
/// derived, and every failure this type exists to prevent came from it being
/// wrong rather than from the arithmetic below. Measured on a live macOS 27
/// window, all four in the same frame:
///
/// - the toolbar strip is **52.00** points tall;
/// - a `GeometryProxy` that **ignores** the safe area reports **0.00** for it,
///   and one that respects it reports **52.00** — so the reader that looks like
///   the right one to use is the one that cannot answer;
/// - `.ignoresSafeArea(.container, edges: .top)` lifts a fixed-height view to
///   the window's own top edge, so the banner's frame reports `y = -52.00`;
/// - with a drawn height of `chromeInset + bannerHeight`, the two cancel and the
///   artwork's lower lip lands at exactly `bannerHeight` in the column's space.
///
/// With a zero inset in hand the banner was built a toolbar's height short, its
/// lower lip landed 52 points above where the pill and the list both assumed it
/// was, and the pill — placed correctly against an edge that was not there —
/// floated in the gap underneath the artwork.
nonisolated struct SidebarBannerLayout: Equatable {
    /// Whether this server has artwork at all. Most do not — a banner is a boost
    /// perk — and every measurement below collapses to nothing when it is false.
    var hasBanner: Bool
    /// How much room the window's chrome takes above the column. Measured; see
    /// the note above for what makes this the fragile one.
    var chromeInset: CGFloat
    /// How far the list has been pulled past its top. Grows the artwork downward
    /// from a fixed top, and carries the pill with it.
    var stretch: CGFloat = 0
    /// How far the list has been scrolled down. Moves the artwork and the pill
    /// up together, one point for one point.
    var travel: CGFloat = 0
    /// How wide the channel column is. Measured, because the split view owns it
    /// and the reader can drag it anywhere between `channelColumnMin` and
    /// `channelColumnMax`. Only the toolbar title needs it.
    var columnWidth: CGFloat = 0

    // MARK: The two constants

    /// The artwork's height **below the chrome**.
    ///
    /// A guild banner is authored at 960x540 — a 16:9 strip. Aspect-filled into
    /// a 220pt-wide column at 116pt tall it was cropped to roughly a third of
    /// its height, which is why every server's banner read as an unrecognisable
    /// detail. At 172 the column shows about half, and the pill has colour under
    /// its whole body rather than straddling the seam.
    static let bannerHeight: CGFloat = 172

    /// Vertical room the pill occupies, its own breathing space included. It is
    /// also the distance the pill's fade is spread over.
    static var pillSlot: CGFloat { Metrics.control + Spacing.base }

    /// The pill's leading edge, inset from the **banner's** edge rather than the
    /// column's.
    ///
    /// The artwork is already padded in by `Spacing.base`, so a pill padded by
    /// the same amount would sit hard against its edge — and that edge carries a
    /// `Radius.card` corner, which curves away underneath exactly where the
    /// pill's own corner is. One step further in puts it inside the curve, which
    /// is the relationship iOS draws.
    static var pillLeading: CGFloat { Spacing.base + Spacing.snug }

    // MARK: Derived

    /// The banner's height with no pull applied — the size the zoom is measured
    /// against, and the height the artwork is fetched for.
    ///
    /// The artwork runs **under the toolbar**, up to the window's own top edge,
    /// so the sidebar toggle floats over the picture rather than over a bare
    /// strip above it. That overhang is this term.
    var bannerRestingHeight: CGFloat { chromeInset + Self.bannerHeight }

    /// The height the banner view is laid out at, pull included.
    var bannerDrawnHeight: CGFloat { bannerRestingHeight + stretch }

    /// Where the banner's frame starts, in the column's own space: above it, by
    /// exactly the chrome it runs under.
    ///
    /// This is the placement `.ignoresSafeArea(.container, edges: .top)`
    /// performs, written down rather than assumed — measured on a live window as
    /// `y = -52.00` against a 52.00 inset.
    var bannerTop: CGFloat { -chromeInset }

    /// The artwork's lower lip, in the column's own space.
    ///
    /// **Derived from the drawn frame rather than restated**, so the overhang
    /// cannot be added to the height and forgotten here — which is the shape the
    /// defect took: a banner drawn one height and a pill placed against another.
    /// The two terms cancel at rest and this comes out as `bannerHeight`.
    var bannerBottom: CGFloat {
        hasBanner ? bannerTop + bannerDrawnHeight - travel : 0
    }

    /// The pill's top edge: on the banner's lower lip, travelling with it.
    ///
    /// **Unclamped, deliberately.** It used to stop at zero and park there,
    /// which left the server's name in a second row of chrome eight points below
    /// the toolbar's own — two bars saying different things. It now rides the
    /// artwork out of the column and hands the name to a real toolbar item on
    /// the way out; see `showsToolbarTitle`.
    var pillTop: CGFloat { bannerBottom - Self.pillSlot }

    /// The pill's lower edge. `Spacing.base` above the artwork's, which is what
    /// "sitting in the corner" means.
    var pillBottom: CGFloat { pillTop + Metrics.control }

    /// How solid the floating pill is as it runs out of banner to sit on.
    ///
    /// It has to reach zero **before** it reaches the chrome. Nothing clips the
    /// column at the safe area — the banner draws up to the window's top edge
    /// through that same hole — so a pill that kept its opacity would slide up
    /// and cross the sidebar toggle. One slot's worth of travel is the whole
    /// fade, and it finishes exactly as the pill arrives at the column's top.
    var pillOpacity: Double {
        min(1, max(0, pillTop / Self.pillSlot))
    }

    /// Whether the server's name belongs to the toolbar rather than the banner.
    ///
    /// **A real `ToolbarItem`, not a capsule parked under the chrome**, and that
    /// is forced rather than preferred: measured on a live window, the top 32
    /// points belong to `NSTitlebarView` — a sibling *above* the hosting view,
    /// which takes the mouse before SwiftUI ever sees it. A pill drawn level
    /// with the sidebar toggle would be visible, unclickable, and would drag the
    /// window when pressed. A toolbar item is level with the toggle by
    /// construction and reachable by definition.
    ///
    /// A server with no banner has nothing to float a pill on, so its name lives
    /// up there from the start rather than waiting for a scroll that never
    /// comes.
    var showsToolbarTitle: Bool { !hasBanner || pillTop <= 0 }

    /// Empty room at the head of the list, standing in for the banner.
    ///
    /// The banner is not in the list — it is a layer behind it — so the content
    /// has to reserve the space it occupies or the first rows are drawn
    /// underneath the artwork.
    ///
    /// **The whole banner, not the banner minus the pill.** The pill FLOATS over
    /// both; it takes no space in either. Subtracting its slot here left the
    /// first row starting a pill's height too high, which is exactly the amount
    /// by which "Channels & Roles" appeared behind the artwork.
    ///
    /// One term, not two: this used to be the banner minus a slot that the
    /// scroll view reserved straight back as top safe area, a pair that had to
    /// cancel exactly and had to be re-derived whenever either moved. Nothing
    /// parks under the chrome any more, so nothing needs reserving there.
    var listReserve: CGFloat {
        hasBanner ? Self.bannerHeight + Spacing.base : 0
    }

    // MARK: The toolbar's span
    //
    // Measured on a live window with a 368pt sidebar (68pt rail + 300pt column):
    // the traffic lights end at x=79 and the bar's first usable point is x=92,
    // while the split view's own toggle owns x=324..360 — the last 44 points of
    // the sidebar. Everything between is what a title may occupy: 232 points
    // there, and less on a narrower column.

    /// Where the sidebar's span of the toolbar begins — past the traffic lights.
    private static let barLeadingDeadZone: CGFloat = 92
    /// What the split view's own sidebar toggle reserves at the trailing end.
    private static let barToggleReserve: CGFloat = 44
    /// Everything a title needs beyond its label: the platter's own padding and
    /// disclosure chevron, plus the clearance the bar insists on keeping before
    /// the toggle.
    ///
    /// Both halves measured by sweeping the cap on a live window. The platter is
    /// **label + 24.5** at every width tried. The clearance is the part that
    /// bites: a platter ending 23 points short of the toggle is kept, and one
    /// ending 9 points short is **dropped** — the item vanishes and the toggle
    /// slides to the leading edge to fill the hole. 56 leaves about 28 points of
    /// slack at every sidebar width, which is the margin an accessibility text
    /// size can move the label by.
    private static let barTitleOverhead: CGFloat = 56

    /// The widest the toolbar's server name may draw before it has to truncate.
    ///
    /// **A cap, not a hope.** An item wider than the span is not squeezed to fit
    /// — it is DROPPED, and the toggle slides into its place at the leading
    /// edge. Measured with a 35-character name: three platters where four
    /// belonged, and the toggle at x=96 instead of x=324. That is the whole of
    /// "on scroll the name disappears", and it is invisible on any server whose
    /// name happens to be short.
    ///
    /// A truncated name is still a name. A dropped one is nothing, and it takes
    /// the toolbar's layout with it.
    var toolbarTitleWidth: CGFloat {
        let span = Proportions.railWidth + columnWidth
            - Self.barLeadingDeadZone
            - Self.barToggleReserve
        return max(Metrics.control, span - Self.barTitleOverhead)
    }
}
