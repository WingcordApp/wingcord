import CoreGraphics
import Testing
@testable import Wingcord

/// The arrangement the sidebar's banner, its name pill and its channel list
/// share.
///
/// **`overhangCancels` and `pillSitsInTheCorner` are the two that matter**, and
/// they were confirmed to fail against the version this replaced before being
/// trusted: with the chrome overhang missing from the drawn height, the artwork
/// stops 52 points short and the pill — placed correctly against an edge that is
/// not there — lands in the empty band underneath it. That is the defect the
/// screenshots showed, expressed as a number.
///
/// The chrome inset itself cannot be tested here. It is measured from a live
/// window, and the whole of its history is that the reader which looks correct
/// reports zero; see `SidebarBannerLayout`'s note and `ChannelSidebar`'s
/// `chromeInsetProbe`.
@Suite("Sidebar banner layout")
struct SidebarBannerLayoutTests {

    /// What a live macOS 27 window reports for the toolbar strip.
    private let chrome: CGFloat = 52

    private func layout(
        hasBanner: Bool = true,
        travel: CGFloat = 0
    ) -> SidebarBannerLayout {
        SidebarBannerLayout(
            hasBanner: hasBanner,
            chromeInset: chrome,
            travel: travel
        )
    }

    @Test("The overhang is added to the height and taken straight back off the top")
    func overhangCancels() {
        let banner = layout()
        let drawnBottom = banner.bannerTop + banner.bannerDrawnHeight
        #expect(banner.bannerTop == -chrome)
        #expect(banner.bannerDrawnHeight == chrome + SidebarBannerLayout.bannerHeight)
        #expect(drawnBottom == SidebarBannerLayout.bannerHeight)
        #expect(banner.bannerBottom == SidebarBannerLayout.bannerHeight)
    }

    @Test("The pill sits ON the artwork, one base unit above its lower lip")
    func pillSitsInTheCorner() {
        let banner = layout()
        let bottomInset = banner.bannerBottom - banner.pillBottom
        #expect(bottomInset == Spacing.base)
        #expect(banner.pillTop > 0)
        #expect(banner.pillBottom < banner.bannerBottom)
    }

    @Test("The pill is inset from the artwork's leading edge, not the column's")
    func pillClearsTheRoundedCorner() {
        let insetFromArtwork = SidebarBannerLayout.pillLeading - Spacing.base
        #expect(insetFromArtwork == Spacing.snug)
    }

    @Test("The first channel row clears the artwork by the same base unit")
    func firstRowClearsArtwork() {
        let banner = layout()
        let gap = banner.listReserve - banner.bannerBottom
        #expect(gap == Spacing.base)
    }

    @Test("Scrolling moves artwork and pill together, one point for one")
    func travelMovesBothTogether() {
        let rest = layout()
        let scrolled = layout(travel: 40)
        let artworkMoved = rest.bannerBottom - scrolled.bannerBottom
        let pillMoved = rest.pillTop - scrolled.pillTop
        #expect(artworkMoved == 40)
        #expect(pillMoved == 40)
    }

    /// The banner used to grow and zoom on overscroll. It does not any more —
    /// see the note in `SidebarBannerLayout` — and this pins the height as a
    /// constant so a future pull cannot quietly reintroduce it.
    @Test("The drawn height is the resting height, whatever the list does")
    func heightIsFixed() {
        let rest = layout()
        let scrolled = layout(travel: 400)
        #expect(rest.bannerDrawnHeight == rest.bannerRestingHeight)
        #expect(scrolled.bannerDrawnHeight == rest.bannerRestingHeight)
        #expect(scrolled.bannerTop == rest.bannerTop)
    }

    @Test("At rest the pill is solid and the toolbar carries nothing")
    func restingState() {
        let banner = layout()
        #expect(banner.pillOpacity == 1)
        #expect(banner.showsToolbarTitle == false)
    }

    @Test("The pill has gone by the time it reaches the chrome")
    func pillFadesBeforeTheStrip() {
        let travelToTop = SidebarBannerLayout.bannerHeight - SidebarBannerLayout.pillSlot
        let atTop = layout(travel: travelToTop)
        #expect(atTop.pillTop == 0)
        #expect(atTop.pillOpacity == 0)

        let past = layout(travel: travelToTop + 200)
        #expect(past.pillTop < 0)
        #expect(past.pillOpacity == 0)
    }

    @Test("Nothing can drive the opacity above one")
    func opacityIsClamped() {
        #expect(layout().pillOpacity == 1)
        #expect(layout(travel: -400).pillOpacity == 1)
    }

    /// The invariant the hand-off exists to keep: the server's name is on screen
    /// at every single point of the scroll, in exactly one of its two homes.
    ///
    /// A gap here is a frame with no server name anywhere, and an overlap is the
    /// same name in two places — both of which a threshold picked by eye
    /// produces and neither of which shows up in a screenshot of the ends.
    @Test("The toolbar takes the name exactly as the pill loses it")
    func handoffLeavesNoGap() {
        let end = SidebarBannerLayout.bannerHeight + 40
        var travel: CGFloat = 0
        var gaps = 0
        while travel <= end {
            let banner = layout(travel: travel)
            if banner.pillOpacity <= 0 && !banner.showsToolbarTitle { gaps += 1 }
            travel += 0.5
        }
        #expect(gaps == 0)
    }

    /// The bar does not squeeze an over-wide item — it DROPS it, and the split
    /// view's toggle slides into the hole. So the cap is not a nicety: past it,
    /// the server's name is simply gone, which is invisible on any server whose
    /// name happens to be short.
    @Test("The toolbar title is capped to what the sidebar's span can hold")
    func toolbarTitleFitsTheSpan() {
        // Measured on a live window: the bar's usable span over a 368pt sidebar
        // is x=92..324, the platter is its label plus 24.5, and a platter
        // ending fewer than ~20 points before the toggle is dropped.
        let columns: [CGFloat] = [
            Proportions.channelColumnMin,
            Proportions.channelColumnIdeal,
            Proportions.channelColumnMax,
        ]
        for column in columns {
            var banner = layout()
            banner.columnWidth = column
            let platter = banner.toolbarTitleWidth + 24.5
            let toggleStart = Proportions.railWidth + column - 44
            let clearance = toggleStart - (92 + platter)
            #expect(clearance >= 20)
        }
    }

    @Test("A narrow sidebar still leaves a title worth drawing")
    func toolbarTitleNeverCollapses() {
        var banner = layout()
        banner.columnWidth = 0
        #expect(banner.toolbarTitleWidth >= Metrics.control)
    }

    @Test("A server with no banner reserves nothing and keeps its name in the bar")
    func bannerlessServer() {
        let plain = layout(hasBanner: false)
        #expect(plain.bannerBottom == 0)
        #expect(plain.listReserve == 0)
        #expect(plain.pillOpacity == 0)
        #expect(plain.showsToolbarTitle)
    }
}
