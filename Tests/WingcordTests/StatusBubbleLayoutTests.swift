import CoreGraphics
import Foundation
import Testing
@testable import Wingcord

/// The custom status bubble's arrangement.
///
/// Every number in `StatusBubbleLayout` is **out of Discord's stylesheet**, and
/// the attempts measured off pictures got the vocabulary right and the geometry
/// wrong. These pin the relationships that make the cluster read as speech coming
/// out of a face rather than as a label with decoration beside it.
@Suite("Status bubble layout")
struct StatusBubbleLayoutTests {

    /// The card, and the full profile, which have different avatar drops.
    private func layout(drop: CGFloat, cardWidth: CGFloat = 320) -> StatusBubbleLayout {
        StatusBubbleLayout(
            avatarSide: 80,
            avatarDrop: drop,
            cardWidth: cardWidth,
            margin: 16
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
            for collapsedHeight in [CGFloat(50), 44] {
                let value = layout(drop: drop)
                // Measured down from the artwork's lower edge: the avatar's centre.
                let avatarCenter = drop - value.avatarSide / 2
                // **As the view hangs it**: bottom-leading, the cluster's frame
                // `topOverhang + collapsedHeight` tall, the bubble at its top
                // under the overhang. The old test placed it by its top, which
                // the view never did — and the bubble sat a line and a half
                // higher than this said (Alex's screenshots 28, 29).
                let clusterBottom = value.verticalOffset(collapsedHeight: collapsedHeight)
                let bubbleTop = clusterBottom - (value.topOverhang + collapsedHeight) + value.topOverhang
                #expect(abs((bubbleTop - avatarCenter) - value.topBelowCentre) < 0.001)
                // Level with the face's middle, a point above it, as Discord's.
                #expect(bubbleTop == avatarCenter - 1)
            }
        }
    }

    /// `.user-profile-popout .container { left: 105px; top: calc(banner - 7px) }`
    /// inside a themed card's 2 pixels of padding, against `.avatar { left: 14px;
    /// top: 59px }`. Alex's screenshot 29 agrees to the pixel: the face's right
    /// edge at 238.5, the bubble's left at 260; its centre at 137.5, the
    /// bubble's top at 136.
    @Test("On the card it sits where Discord's stylesheet says")
    func cardFromTheStylesheet() {
        // The card's avatar: 80 across, 16 in, dropping 34 below the artwork.
        let value = layout(drop: 34)
        #expect(value.gapFromFace == 11)
        #expect(value.leadingInset == CGFloat(105 + 2))
        let top = value.verticalOffset(collapsedHeight: 50) - 50
        #expect(top == -7, "7 above the banner's foot, whatever the status holds")
    }

    /// `.user-profile-modal`: `.avatar { left: 24px; top: -68px }`, 120 across;
    /// `.container { left: 161px; top: -10px }`.
    @Test("On the full profile it sits where Discord's stylesheet says")
    func fullProfileFromTheStylesheet() {
        var value = layout(drop: 56)
        value.avatarSide = 118
        value.surface = .fullProfile
        #expect(value.gapFromFace == CGFloat(161 - (24 + 120)))
        #expect(value.topBelowCentre == CGFloat(-10 - (-68 + 60)))
    }

    @Test("The emoji is Discord's 16 beside words, with 4 after it, in a 16-point corner")
    func bubbleFromTheStylesheet() {
        let value = layout(drop: 34)
        #expect(value.emojiSide == 16)
        #expect(value.loneEmojiSide == 32)
        #expect(value.contentGap == 4)
        #expect(value.bubbleCorner == 16)
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
