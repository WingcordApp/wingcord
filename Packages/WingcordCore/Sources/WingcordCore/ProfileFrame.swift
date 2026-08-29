import CoreGraphics
import Foundation

/// A profile frame: the artwork that wraps a profile card and hangs over its
/// edges.
///
/// **Not a profile effect, and the distinction is load-bearing.** Discord's
/// collectible types are `0` avatar decoration, `1` profile effect, `2`
/// nameplate, `3` profile frame — and one account can wear several at once.
/// Captured from a live profile: torriel wears effect `1462116613775167569`
/// ("Nevermore (White)", grey birds and feathers) *and* frame
/// `1515124557290410204` ("Dark Roses (Blue)"). A client that models only the
/// effect can never draw the roses, however it positions what it has.
///
/// The two are different in every way that matters to drawing:
///
/// | | effect | frame |
/// |---|---|---|
/// | shape | one canvas over the card | pieces anchored to card edges |
/// | extent | inside the card | deliberately outside it |
/// | motion | a timeline of animated strips | stills |
/// | sizing | authored size per layer | one scale for the whole composition |
///
/// So a frame costs two still decodes and no clock at all, which makes it
/// markedly cheaper than the effect that already ships.
public struct ProfileFrame: Hashable, Sendable {
    public var skuID: String
    /// What the frame looks like, in Discord's words. The accessibility label,
    /// and the only description a reader who cannot see it will ever get.
    public var label: String?
    /// The card width the composition was authored against.
    public var innerWidth: CGFloat
    /// How far the artwork runs past the card, in authored units.
    public var overflowTop: CGFloat
    public var overflowBottom: CGFloat
    /// Applied to **both** sides. The name is Discord's and it is singular
    /// because the value is one number used twice, not two that happen to match.
    public var overflowHorizontal: CGFloat

    /// Drawn behind the card, in payload order.
    public var backLayers: [Layer]
    /// Drawn over the card, in payload order.
    public var frontLayers: [Layer]

    /// **Partitioned once, at the boundary, rather than filtered in a body.**
    /// A view that filters per evaluation allocates an array every time SwiftUI
    /// asks it for a body, for an answer that cannot change while the frame is
    /// on screen.
    public init(
        skuID: String,
        label: String?,
        innerWidth: CGFloat,
        overflowTop: CGFloat,
        overflowBottom: CGFloat,
        overflowHorizontal: CGFloat,
        layers: [Layer]
    ) {
        self.skuID = skuID
        self.label = label
        self.innerWidth = innerWidth
        self.overflowTop = overflowTop
        self.overflowBottom = overflowBottom
        self.overflowHorizontal = overflowHorizontal
        backLayers = layers.filter { $0.order == .back }
        frontLayers = layers.filter { $0.order == .front }
    }

    /// One piece of the composition.
    public struct Layer: Hashable, Sendable, Identifiable {
        public var id: String
        public var url: URL
        /// Which edge of the card this piece hangs from.
        public var anchor: Anchor
        /// Whether it sits over the card or behind it.
        public var order: Order

        public init(id: String, url: URL, anchor: Anchor, order: Order) {
            self.id = id
            self.url = url
            self.anchor = anchor
            self.order = order
        }
    }

    /// **Strings, not integers.** The unofficial documentation types these as
    /// enums with integer cases; the live payload sends `"top"`, `"bottom"`,
    /// `"front"` and `"staple"` as strings. The capture wins, and both fall
    /// back rather than failing the decode — an unrecognised anchor should cost
    /// one misplaced picture, never the whole frame.
    public enum Anchor: String, Hashable, Sendable {
        case top
        case bottom
    }

    public enum Order: String, Hashable, Sendable {
        case back
        case front
    }

    public var isEmpty: Bool { backLayers.isEmpty && frontLayers.isEmpty }

    /// Where this composition lands on a card `cardWidth` points wide.
    public func layout(cardWidth: CGFloat) -> ProfileFrameLayout {
        ProfileFrameLayout(frame: self, cardWidth: cardWidth)
    }

}

/// Where a frame's artwork sits around the card it wraps.
///
/// **One value, because the numbers have to agree.** The room the surface
/// reserves, the width each layer draws at and the edge each one hangs from are
/// one arrangement; three private copies of the arithmetic is how each stays
/// individually defensible while the result is wrong — the same reason
/// `SidebarBannerLayout` exists.
///
/// **Nothing here is measured.** The layer artwork is authored in the *same*
/// coordinate space as `innerWidth` and the overflows — verified against Dark
/// Roses, whose payload says `inner_width: 1200` and `overflow_horizontal: 56`
/// and whose two layer PNGs are both exactly 1312 pixels wide. So there is one
/// scale factor for the whole composition, it comes from a width the card
/// already knows, and no `GeometryReader` and no intrinsic-size read into
/// `@State` is involved anywhere.
///
/// **The overhang is only drawable because the card is not in a presentation.**
/// A popover and a sheet are each an `NSWindow`, and a window cannot draw
/// outside itself; both also paint their own backdrop behind the whole of their
/// content, which `.presentationBackground(.clear)` does not suppress — see
/// `INVARIANTS.md`. The profile card is an overlay at the window root for
/// exactly this reason.
public struct ProfileFrameLayout: Equatable, Sendable {
    /// Authored units to points.
    public let scale: CGFloat
    /// How far the artwork runs past each side of the card, in points.
    public let leading: CGFloat
    public let top: CGFloat
    public let bottom: CGFloat
    /// What every layer draws at: the card plus both horizontal overflows.
    public let layerWidth: CGFloat

    public init(frame: ProfileFrame, cardWidth: CGFloat) {
        // A card of no width has no scale, and dividing by an authored width of
        // zero would put every layer at infinity. Both collapse to a frame that
        // occupies nothing rather than to a crash.
        let width = max(cardWidth, 0)
        scale = width / max(frame.innerWidth, 1)
        leading = (frame.overflowHorizontal * scale).rounded()
        top = (frame.overflowTop * scale).rounded()
        bottom = (frame.overflowBottom * scale).rounded()
        layerWidth = width + leading * 2
    }
}
