import CoreGraphics
import SwiftUI
import Testing
@testable import Wingcord
@testable import WingcordCore

/// Where the profile card lands, now that nothing else places it.
///
/// This is what a popover used to do. It is worth pinning at this level for the
/// reason the anchor conversion one space earlier is: the failure mode is not a
/// crash or a blank view but **a card that opens somewhere believable and
/// wrong**, which nobody notices until they open one near a window edge.
@Suite("Profile card placement")
struct ProfileCardPlacementTests {

    private static let container = CGSize(width: 1200, height: 800)
    private static let cardWidth: CGFloat = 320

    /// Dark Roses at the mini card's width: 15 points each side, 56 above,
    /// 50 below.
    private var roses: EdgeInsets {
        ProfileFrame(
            skuID: "1", label: nil,
            innerWidth: 1200, overflowTop: 211, overflowBottom: 186, overflowHorizontal: 56,
            layers: [ProfileFrame.Layer(
                id: "a", url: URL(string: "https://example.invalid/a")!,
                anchor: .top, order: .front
            )]
        ).overhang(cardWidth: Self.cardWidth)
    }

    private func place(
        anchor: CGRect,
        overhang: EdgeInsets = EdgeInsets(),
        container: CGSize = ProfileCardPlacementTests.container
    ) -> ProfileCardPlacement {
        ProfileCardPlacement(
            anchor: anchor, cardWidth: Self.cardWidth,
            overhang: overhang, container: container
        )
    }

    @Test("A roster row opens the card on its leading side, as the popover did")
    func opensLeading() {
        // The member list is at the trailing edge, so this is the case that
        // happens constantly and must not change from what people are used to.
        let row = CGRect(x: 1000, y: 400, width: 180, height: 44)
        let placement = place(anchor: row)
        let expected: CGFloat = 1000 - ProfileCardPlacement.gap - Self.cardWidth
        #expect(placement.cardX == expected)
        #expect(placement.growthAnchor.x == 1)
    }

    @Test("It flips to the trailing side only when there is no room")
    func flipsWhenCornered() {
        let row = CGRect(x: 10, y: 400, width: 180, height: 44)
        let placement = place(anchor: row)
        let expected: CGFloat = 190 + ProfileCardPlacement.gap
        #expect(placement.cardX == expected)
        #expect(placement.growthAnchor.x == 0)
    }

    @Test("The card is centred on the row it belongs to")
    func centresOnTheRow() {
        let row = CGRect(x: 1000, y: 400, width: 180, height: 44)
        // Hoisted: inline arithmetic inside `#expect` is re-typed by the macro
        // and compares wrong. See `docs/HANDOFF.md`.
        let centred: CGFloat = row.midY - 200
        #expect(place(anchor: row).cardY(forHeight: 400) == centred)
    }

    @Test("The ARTWORK is what stays inside the window, not the card")
    func clampsOnTheArtwork() {
        // A frame is what reaches the edge first. Clamping the card alone puts
        // the roses half outside the window, which is the whole reason the
        // overhang travels with the placement rather than being applied after
        // it.
        let overhang = roses
        #expect(overhang.top > 0, "fixture must actually overhang")

        // A row at the very top: the card cannot sit centred on it without the
        // top garland leaving the window.
        let high = CGRect(x: 1000, y: 0, width: 180, height: 44)
        let y = place(anchor: high, overhang: overhang).cardY(forHeight: 400)
        #expect(y >= ProfileCardPlacement.margin + overhang.top)

        // And a row at the very bottom, for the garland below it.
        let low = CGRect(x: 1000, y: 790, width: 180, height: 44)
        let bottom = place(anchor: low, overhang: overhang).cardY(forHeight: 400) + 400
        #expect(bottom <= Self.container.height - ProfileCardPlacement.margin - overhang.bottom)
    }

    @Test("A profile with no frame is placed exactly as before")
    func noFrameCostsNothing() {
        // The overwhelming majority of profiles. A frame must not change where
        // anybody else's card opens.
        let row = CGRect(x: 1000, y: 400, width: 180, height: 44)
        let bare = place(anchor: row)
        let framed = place(anchor: row, overhang: roses)
        #expect(bare.cardX == framed.cardX)
        #expect(bare.cardY(forHeight: 400) == framed.cardY(forHeight: 400))
    }

    @Test("A window too small for the card still puts it somewhere legal")
    func survivesATinyWindow() {
        // The clamps cross over. Answering with the leading margin is arbitrary
        // but bounded; answering with a negative or NaN origin is a card drawn
        // off screen or not at all.
        let tiny = CGSize(width: 200, height: 120)
        let placement = place(
            anchor: CGRect(x: 10, y: 10, width: 40, height: 40),
            overhang: roses,
            container: tiny
        )
        #expect(placement.cardX.isFinite)
        #expect(placement.cardY(forHeight: 400).isFinite)
        #expect(placement.cardX >= ProfileCardPlacement.margin)
    }

    @Test("The card grows from the half of the window the row is in")
    func growsFromTheTrigger() {
        // Spatial symmetry: it materialises out of the thing that summoned it.
        let high = CGRect(x: 1000, y: 100, width: 180, height: 44)
        let low = CGRect(x: 1000, y: 700, width: 180, height: 44)
        #expect(place(anchor: high).growthAnchor.y == 0)
        #expect(place(anchor: low).growthAnchor.y == 1)
    }
}

/// The now bar's own card, which stands on its trigger rather than flanking it.
///
/// **The bar is pinned to the window's foot.** Placed `.beside`, the card was
/// centred on the bar and then clamped to the window — which put its bottom edge
/// level with the bar's and laid the card straight over the control that opened
/// it. There is no "beside" for a bar at the foot of a window; there is only
/// above.
@Suite("Profile card above its trigger")
@MainActor
struct ProfileCardAbovePlacementTests {

    private static let cardWidth: CGFloat = 320
    private static let container = CGSize(width: 1512, height: 900)
    /// The identity capsule, at the foot of the sidebar column.
    private static let bar = CGRect(x: 76, y: 838, width: 190, height: 46)

    private func place(
        _ anchor: CGRect = ProfileCardAbovePlacementTests.bar,
        overhang: EdgeInsets = EdgeInsets(),
        container: CGSize = ProfileCardAbovePlacementTests.container
    ) -> ProfileCardPlacement {
        ProfileCardPlacement(
            anchor: anchor, cardWidth: Self.cardWidth,
            overhang: overhang, container: container, side: .above
        )
    }

    @Test("Its leading edge is the trigger's, not a gap away from it")
    func alignsToTheTriggerLeadingEdge() {
        #expect(place().cardX == Self.bar.minX)
    }

    /// The whole defect, as arithmetic: the card's foot must clear the bar's
    /// head whatever the card's height turns out to be.
    @Test("Its foot clears the trigger's head at every height")
    func neverOverlapsTheTrigger() {
        for height in [200.0, 480.0, 720.0] as [CGFloat] {
            let y = place().cardY(forHeight: height)
            #expect(y + height <= Self.bar.minY)
        }
    }

    @Test("A card taller than the room above it is clamped, not pushed off")
    func tallCardStaysInTheWindow() {
        let y = place().cardY(forHeight: 2000)
        #expect(y >= ProfileCardPlacement.margin)
    }

    @Test("It grows out of the trigger's own corner")
    func growsFromTheCorner() {
        #expect(place().growthAnchor.x == 0)
        #expect(place().growthAnchor.y == 1)
    }

    /// A row keeps flanking. This is the case that happens constantly and the
    /// one the new mode must not have touched.
    @Test("Beside is unchanged")
    func besideIsUnchanged() {
        let row = CGRect(x: 1000, y: 400, width: 180, height: 44)
        let beside = ProfileCardPlacement(
            anchor: row, cardWidth: Self.cardWidth,
            overhang: EdgeInsets(), container: Self.container
        )
        #expect(beside.cardX == 1000 - ProfileCardPlacement.gap - Self.cardWidth)
        #expect(beside.cardY(forHeight: 400) == row.midY - 200)
    }
}
