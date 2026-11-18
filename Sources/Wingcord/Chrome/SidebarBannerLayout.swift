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
/// ## Under the switcher, not under the chrome (2026-11-18)
///
/// The banner used to run up under the toolbar to the window's top edge, so the
/// arithmetic here was built on the measured chrome inset (52 points on a live
/// macOS 27 window) — and the sidebar toggle, the create menu and the page
/// switcher all sat on the picture (Alex: "the sidebar looks very bad when
/// there's a server banner"). It is the list's first thing now: 16:9 at the
/// column's width, under the switcher, its foot fading into the glass, the
/// server's name written on it. `chromeInset` is still measured and carried for
/// the views that read it; it places nothing here any more.
nonisolated struct SidebarBannerLayout: Equatable {
    /// Whether this server has artwork at all. Most do not — a banner is a boost
    /// perk — and every measurement below collapses to nothing when it is false.
    var hasBanner: Bool
    /// How much room the window's chrome takes above the column. Measured; see
    /// the note above for what makes this the fragile one.
    var chromeInset: CGFloat
    /// How far the list has been scrolled down. Moves the artwork and the pill
    /// up together, one point for one point.
    var travel: CGFloat = 0
    /// How wide the channel column is. Measured, because the split view owns it
    /// and the reader can drag it anywhere between `channelColumnMin` and
    /// `channelColumnMax`. Only the toolbar title needs it.
    var columnWidth: CGFloat = 0
    /// Where the header's title starts — past the rail, or past the traffic
    /// lights on a page with no rail.
    var titleLeading: CGFloat = Self.headerTitleLeading
    /// Whether the header's sidebar toggle has folded into the + menu, which
    /// gives its width back to the name (`ShellLayout.foldsSidebarToggle`).
    var foldsSidebarToggle: Bool = false

    // MARK: The constants

    /// The banner's side inset: the channel rows' own, so the picture lines up
    /// with the list it heads.
    static let sideInset: CGFloat = Spacing.base

    /// The gap between the page switcher and the banner's top.
    ///
    /// **The run the column's rows fade over as they pass under the chrome**
    /// (`SidebarChromeFade.run`): the banner rests just below it, whole, and
    /// fades the way a row does once the list carries it up.
    static let topMargin: CGFloat = SidebarChromeFade.run

    /// The banner's top corners. Its foot has none: it fades into the glass.
    static let cornerRadius: CGFloat = 12

    /// The height a banner takes before the column has been measured.
    static let fallbackHeight: CGFloat = 140

    /// Vertical room the name occupies from the artwork's foot, its breathing
    /// space included — high enough that it reads on picture rather than on
    /// the faded foot. Also the distance the name's fade is spread over.
    static var pillSlot: CGFloat { Metrics.control + Spacing.base + Spacing.snug }

    /// The name's leading edge, from the column's: inside the banner's own
    /// inset by `Spacing.snug`.
    static var pillLeading: CGFloat { sideInset + Spacing.snug }

    // MARK: Derived

    /// The artwork's height: **Discord's 16:9** at the width the column gives
    /// it — the whole banner, uncropped, as Discord's channel list shows it (a
    /// banner is authored at 960x540). Clamped so a very narrow or very wide
    /// column keeps a header rather than a sliver or a poster.
    ///
    /// It used to be 172 plus the chrome it ran under, behind the toolbar and
    /// the page switcher, with the name on a pill at its lip (Alex,
    /// 2026-11-18: "the sidebar looks very bad when there's a server banner").
    var bannerHeight: CGFloat {
        guard columnWidth > 0 else { return Self.fallbackHeight }
        return min(200, max(110, ((columnWidth - Self.sideInset * 2) * 9 / 16).rounded()))
    }

    /// The banner's height at rest.
    var bannerRestingHeight: CGFloat { bannerHeight }

    /// The height the banner view is laid out at.
    var bannerDrawnHeight: CGFloat { bannerRestingHeight }

    /// Where the banner's frame starts, in the column's own space: under the
    /// page switcher, as the list's first thing — no longer up under the
    /// toolbar, where the controls sat on the picture.
    var bannerTop: CGFloat { Self.topMargin }

    /// The artwork's lower lip, in the column's own space.
    var bannerBottom: CGFloat {
        hasBanner ? bannerTop + bannerDrawnHeight - travel : 0
    }

    /// Whether any of the artwork is still below the chrome — Discord's
    /// `bannerVisible`, which is what starts the banner's five seconds of
    /// motion when it comes back into view.
    var isBannerInView: Bool { hasBanner && bannerBottom > 0 }

    /// The name's top edge: in the artwork's lower corner, travelling with it.
    ///
    /// **Unclamped, deliberately.** It used to stop at zero and park there,
    /// which left the server's name in a second row of chrome eight points below
    /// the toolbar's own — two bars saying different things. It now rides the
    /// artwork out of the column and hands the name to the header on the way
    /// out; see `showsToolbarTitle`.
    var pillTop: CGFloat { bannerBottom - Self.pillSlot }

    /// The name's lower edge, `pillSlot` less its own height above the
    /// artwork's foot.
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
        hasBanner ? bannerTop + bannerHeight + Spacing.base : 0
    }

    // MARK: The header's span
    //
    // The name sits in the sidebar panel's header row once the pill has ridden
    // off the banner: after the traffic lights, before the toggle and the
    // create menu at the row's trailing end. The row is the app's own now (see
    // `ShellMetrics`), so an over-wide name truncates instead of being dropped
    // the way a toolbar item was — the cap is about not running under the
    // controls, not about surviving the bar's layout.

    /// Where the name begins, in the channel column's own space: clear of the
    /// traffic lights, which end about where the rail does.
    static let headerTitleLeading: CGFloat = 20

    /// The widest the header's server name may draw before it truncates: what
    /// the trailing controls leave (`ShellMetrics.headerTrailingReserve`), and
    /// the toggle's width as well once it has folded away.
    var toolbarTitleWidth: CGFloat {
        let reserve = ShellMetrics.headerTrailingReserve
            - (foldsSidebarToggle ? ShellMetrics.foldedToggleSaving : 0)
        return max(Metrics.control, columnWidth - titleLeading - reserve)
    }
}
