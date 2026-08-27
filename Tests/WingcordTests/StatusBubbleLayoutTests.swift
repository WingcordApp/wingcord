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

    /// **The relationship the trail rests on.** The large disc has to sit on the
    /// same line as the bubble, or the tail reads as two dots parked above the
    /// thing they belong to — which is exactly how the first version looked.
    @Test("The large disc's centre is level with the bubble's")
    func largeDiscIsOnTheBubblesLine() {
        let value = layout(drop: 34)
        #expect(value.largeDotCenterY == value.centerY)
    }

    /// A vertical column has no direction. The trail has to climb.
    @Test("The discs climb: small above and to the left of large")
    func discsClimbDiagonally() {
        let value = layout(drop: 34)
        #expect(value.dotSmall < value.dotLarge)
        #expect(value.dotStagger > 0)
        // The small disc's own centre sits above the large one's.
        let smallCenter = value.dotSmall / 2
        #expect(smallCenter < value.largeDotCenterY)
    }

    /// Sharing a colour is not enough — they have to touch, or they read as a
    /// disc beside a capsule rather than as one shape.
    @Test("The large disc runs under the bubble")
    func discOverlapsTheBubble() {
        #expect(layout(drop: 34).overlap > 0)
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
        // The widest a bubble can ever draw, plus everything to its left.
        let total = value.leadingInset
            + (value.tailWidth - value.overlap)
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
            let bubbleCenter = value.verticalOffset - value.centerY
            #expect(abs((bubbleCenter - avatarCenter) - value.dropBelowCentre) < 0.001)
        }
    }

    /// **The bug the explicit width exists to prevent.** `frame(maxWidth:)`
    /// *fills* the space it is offered rather than hugging, so a bubble holding
    /// one emoji and no words stretched into a lozenge the width of the card.
    @Test("A bubble holding one emoji hugs it")
    func emojiOnlyBubbleHugs() {
        let value = layout(drop: 34)
        let width = value.bubbleWidth(contentWidth: value.emojiSide)
        #expect(width == value.emojiSide + value.bubbleHorizontalPadding * 2)
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
