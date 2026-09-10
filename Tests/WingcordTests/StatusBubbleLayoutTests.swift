import CoreGraphics
import Foundation
import Testing
@testable import Wingcord

/// The custom status bubble's arrangement.
///
/// Every number in `StatusBubbleLayout` was **measured off a reference**, and
/// the first attempt got the vocabulary right and the geometry wrong in four
/// separate ways. These pin the relationships that make the cluster read as
/// speech coming out of a face rather than as a label with decoration beside it.
@Suite("Status bubble layout")
struct StatusBubbleLayoutTests {

    /// The card, and the full profile, which have different avatar drops.
    private func layout(drop: CGFloat, cardWidth: CGFloat = 320) -> StatusBubbleLayout {
        StatusBubbleLayout(
            avatarSide: 80,
            avatarDrop: drop,
            decorationOverhang: 8,
            cardWidth: cardWidth,
            margin: 16,
            gap: 8
        )
    }

    /// **Sharing a colour is not enough — they have to fuse.** The large disc
    /// straddles the bubble's top edge, twelve of its twenty points inside it,
    /// which is what makes the two read as one shape rather than a disc parked
    /// against a box. Discord's own `top: -8px` on a 20px circle.
    @Test("The large disc straddles the bubble's top edge")
    func largeDiscStraddlesTheBubble() {
        let value = layout(drop: 34)
        #expect(value.largeDotOrigin.y < 0, "it has to break the edge")
        #expect(value.largeDotOrigin.y + value.dotLarge > 0, "and stay attached to it")
    }

    /// A vertical column has no direction. The trail has to climb — up and to
    /// the left, toward the face it is coming out of.
    @Test("The discs climb away from the bubble, small furthest")
    func discsClimbDiagonally() {
        let value = layout(drop: 34)
        #expect(value.dotSmall < value.dotLarge)
        #expect(value.smallDotOrigin.y < value.largeDotOrigin.y, "further up")
        #expect(value.smallDotOrigin.x < value.largeDotOrigin.x, "and further left")
    }

    /// **The two caps in Discord's sheet are one number stated twice.** A bubble
    /// is its content plus two paddings plus the border on each side, and 181
    /// is exactly 155 + 24 + 2 — which is how the pair is known to be measured
    /// rather than picked.
    @Test("The bubble's cap is its content's cap plus its own chrome")
    func capsAgree() {
        let value = layout(drop: 34)
        #expect(
            value.bubbleWidthCap
                == value.contentWidthCap + value.bubbleHorizontalPadding * 2 + 2
        )
    }

    /// The discs hang past the bubble on two sides, and the cluster reserves
    /// room for them: a background is not clipped by its own parent, but any
    /// ancestor that clips would take them.
    @Test("The overhangs cover everything the discs reach")
    func overhangsCoverTheDiscs() {
        let value = layout(drop: 34)
        #expect(value.topOverhang >= -value.smallDotOrigin.y)
        #expect(value.leadingOverhang >= -value.smallDotOrigin.x)
    }

    /// A bubble holding one emoji is still a bubble, not a circle — Discord's
    /// own `min-width: 42px`.
    @Test("A tiny status still draws a bubble")
    func minimumWidthHolds() {
        let value = layout(drop: 34)
        #expect(value.bubbleWidth(contentWidth: 4) == value.minimumBubbleWidth)
    }

    /// **The bug this whole value exists to prevent.** The card lives in a
    /// `ScrollView` column, and a vertical scroll view answers a too-wide child
    /// by centring it and clipping BOTH sides — which is what sliced the first
    /// letter off the name, off `ABOUT ME` and off the avatar.
    @Test(
        "The cluster can never be wider than the card",
        arguments: [CGFloat(272), 320, 360, 200]
    )
    func clusterFitsTheCard(_ cardWidth: CGFloat) {
        let value = layout(drop: 34, cardWidth: cardWidth)
        // The widest a bubble can ever draw, plus everything to its left —
        // the avatar and its gap, and the room the discs hang into.
        let total = value.leadingInset
            + value.leadingOverhang
            + value.bubbleWidth(contentWidth: .greatestFiniteMagnitude)
        #expect(total <= cardWidth)
    }

    /// The two profile surfaces have different drops, so a hand-tuned offset is
    /// right on one of them at most. Both must put the bubble the same distance
    /// below the face's centre.
    @Test("The bubble leaves the face at the same angle on both surfaces")
    func placementIsDerivedFromTheDrop() {
        for drop in [CGFloat(34), 40] {
            let value = layout(drop: drop)
            // Measured down from the artwork's lower edge: the avatar's centre,
            // and the cluster's.
            let avatarCenter = drop - value.avatarSide / 2
            // The bubble's own top, which is the cluster's top plus the room
            // reserved above it for the discs.
            let bubbleTop = value.verticalOffset - value.topOverhang
            #expect(abs((bubbleTop - avatarCenter) - value.dropBelowCentre) < 0.001)
        }
    }

    /// **The bug the explicit width exists to prevent.** `frame(maxWidth:)`
    /// *fills* the space it is offered rather than hugging, so a bubble holding
    /// one emoji and no words stretched into a lozenge the width of the card.
    @Test("A bubble holding one emoji hugs it")
    func emojiOnlyBubbleHugs() {
        let value = layout(drop: 34)
        // Wide enough to clear the minimum, so this measures the hug rather
        // than the floor.
        let content = value.minimumBubbleWidth
        let width = value.bubbleWidth(contentWidth: content)
        #expect(width == content + value.bubbleHorizontalPadding * 2)
        #expect(width < value.maximumBubbleWidth)
    }

    /// And a sentence longer than the card can spare is capped rather than
    /// pushing the cluster off the edge.
    @Test("A long status is capped at what the card can spare")
    func longStatusIsCapped() {
        let value = layout(drop: 34)
        #expect(value.bubbleWidth(contentWidth: 10_000) == value.maximumBubbleWidth)
    }

    /// A status with an emoji and no words is a real state, and so is one with
    /// words and no emoji. Both have to produce a bubble worth drawing.
    @Test(
        "Every content width yields a bubble at least as wide as its padding",
        arguments: [CGFloat(0), 18, 60, 400]
    )
    func bubbleAlwaysHasBody(_ content: CGFloat) {
        let value = layout(drop: 34)
        #expect(value.bubbleWidth(contentWidth: content) >= value.bubbleHorizontalPadding * 2)
    }

    /// A narrow column must still leave a bubble worth drawing rather than a
    /// negative width, which lays out as a crash and not as a small chip.
    @Test("A very narrow card still yields a usable bubble")
    func narrowCardIsClamped() {
        #expect(layout(drop: 34, cardWidth: 120).maximumBubbleWidth >= 40)
    }
}
