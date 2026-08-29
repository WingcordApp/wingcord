import Foundation
import Testing
@testable import WingcordCore

/// Where a profile frame's artwork lands.
///
/// **These numbers were checked against Discord's own rendering before they
/// were written down**, which is the only reason to trust a layout nobody can
/// see in a unit test. A screenshot of the real client was measured: the card
/// came out 604 device pixels wide at 2x, its artwork reached 29 pixels past the
/// left edge and 105 above the top. Predicted from the payload at that width,
/// this layout answers 14 and 53 points — 28 and 106 pixels. Both within a pixel
/// of what was on screen, which is what promoted the model from plausible to
/// correct.
struct ProfileFrameLayoutTests {

    /// Dark Roses (Blue), as `GET /collectibles-products/{sku}` sends it.
    private func darkRoses() -> ProfileFrame {
        ProfileFrame(
            skuID: "1515124557290410204",
            label: "Blue roses…",
            innerWidth: 1200,
            overflowTop: 211,
            overflowBottom: 186,
            overflowHorizontal: 56,
            layers: [
                ProfileFrame.Layer(
                    id: "top",
                    url: URL(string: "https://example.invalid/top")!,
                    anchor: .top,
                    order: .front
                ),
                ProfileFrame.Layer(
                    id: "bottom",
                    url: URL(string: "https://example.invalid/bottom")!,
                    anchor: .bottom,
                    order: .front
                ),
            ]
        )
    }

    @Test("The reference card's overhangs, to the pixel that was measured")
    func matchesTheMeasuredReference() {
        // 604 device pixels at 2x.
        let layout = darkRoses().layout(cardWidth: 302)
        #expect(layout.leading == 14)
        #expect(layout.top == 53)
        #expect(abs(layout.leading * 2 - 29) <= 1)
        #expect(abs(layout.top * 2 - 105) <= 1)
    }

    @Test("A layer is the card plus BOTH horizontal overflows")
    func layerSpansTheWholeComposition() {
        // The relationship the whole design rests on: this width is the layer
        // PNG's own, so one scale factor places the artwork and nothing has to
        // be measured. Dark Roses' layers are 1312 pixels wide.
        let layout = darkRoses().layout(cardWidth: 1200)
        #expect(layout.scale == 1)
        #expect(layout.layerWidth == 1312)
        #expect(layout.top == 211)
        #expect(layout.bottom == 186)
    }

    @Test("Both of the app's card widths scale the same composition")
    func scalesWithTheCard() {
        let frame = darkRoses()
        let mini = frame.layout(cardWidth: 320)
        let full = frame.layout(cardWidth: 360)
        #expect(mini.layerWidth == 320 + mini.leading * 2)
        #expect(full.layerWidth == 360 + full.leading * 2)
        // The full profile's column is wider, so the frame is larger there —
        // which is what Discord does, and is how the frame was identified as
        // scaling to the identity column rather than to the window: the ratio of
        // rose sizes between the two reference screenshots is the ratio of the
        // two column widths, not of the two window widths.
        #expect(full.scale > mini.scale)
        #expect(full.top > mini.top)
    }

    @Test("A card with no width collapses rather than dividing by nothing")
    func degeneratesSafely() {
        let layout = darkRoses().layout(cardWidth: 0)
        #expect(layout.scale == 0)
        #expect(layout.layerWidth == 0)
        #expect(layout.top == 0)
    }

    @Test("An authored width of zero cannot put a layer at infinity")
    func zeroInnerWidthIsSurvivable() {
        let broken = ProfileFrame(
            skuID: "x", label: nil,
            innerWidth: 0, overflowTop: 10, overflowBottom: 10, overflowHorizontal: 10,
            layers: []
        )
        let layout = broken.layout(cardWidth: 320)
        #expect(layout.scale.isFinite)
        #expect(layout.top.isFinite)
    }

    @Test("Layers are partitioned by paint order once, not filtered per draw")
    func partitionsByOrder() {
        let frame = ProfileFrame(
            skuID: "x", label: nil,
            innerWidth: 1200, overflowTop: 0, overflowBottom: 0, overflowHorizontal: 0,
            layers: [
                ProfileFrame.Layer(
                    id: "a", url: URL(string: "https://example.invalid/a")!,
                    anchor: .top, order: .back
                ),
                ProfileFrame.Layer(
                    id: "b", url: URL(string: "https://example.invalid/b")!,
                    anchor: .bottom, order: .front
                ),
            ]
        )
        #expect(frame.backLayers.map(\.id) == ["a"])
        #expect(frame.frontLayers.map(\.id) == ["b"])
        #expect(!frame.isEmpty)
    }
}
