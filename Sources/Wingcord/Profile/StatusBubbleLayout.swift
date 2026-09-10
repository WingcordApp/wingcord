import CoreGraphics
import Foundation

/// Where the pieces of a custom-status bubble go.
///
/// **A value rather than constants inside the view, for the reason
/// `SidebarBannerLayout` is one.** The banner, the avatar, its decoration and
/// this cluster are one arrangement spread across three files; private copies of
/// the arithmetic is how each stays individually defensible while the result is
/// wrong. It is also the only thing that makes the arrangement testable at all —
/// and every number in it was measured off a reference rather than picked, so
/// there is something to protect.
///
/// The relationships that matter, each of which was wrong in the first attempt:
///
///  - the discs **climb diagonally**, small up and left, large down and right,
///    so the trail has a direction — a vertical column has none;
///  - the large disc **overlaps** the bubble and shares its colour, so the two
///    fuse into one shape rather than sitting near each other;
///  - the large disc's centre is **level with the bubble's**, which puts the
///    trail on the line the eye follows out of the face;
///  - the cluster's width can never exceed the card's, because the card lives in
///    a scroll column and a too-wide child is centred and clipped on both sides.
nonisolated struct StatusBubbleLayout: Equatable, Sendable {
    /// The avatar this hangs off, and how far it drops below the artwork.
    var avatarSide: CGFloat
    var avatarDrop: CGFloat
    /// How far the decoration is drawn outside the avatar's bounds.
    var decorationOverhang: CGFloat
    var cardWidth: CGFloat
    var margin: CGFloat
    /// Between the decoration's edge and the first disc.
    var gap: CGFloat

    // MARK: The measured parts

    // **Discord's own stylesheet, not a screenshot.** Every number below is out
    // of `.outer_ab8609` and its two pseudo-elements, which is where this
    // arrangement actually lives:
    //
    //     .outer:before { width: 20px; height: 20px; left:  10px; top:  -8px }
    //     .outer:after  { width: 10px; height: 10px; left:  -3px; top: -15px }
    //     .inner        { padding: 8px 12px }
    //     .outer        { max-width: 181px; min-width: 42px }
    //     .content      { max-width: 155px; -webkit-line-clamp: 2 }
    //
    // The earlier values here were measured off a picture and every one of them
    // was close and wrong — 9 and 17 against 10 and 20, and a tail beside the
    // bubble where Discord's climbs out of its top-left corner.
    var dotSmall: CGFloat = 10
    var dotLarge: CGFloat = 20
    /// Where each disc's own top-left sits, **relative to the bubble's**.
    ///
    /// Negative is up and to the left. The large one straddles the bubble's top
    /// edge — twelve of its twenty points are inside it — which is what fuses
    /// the two into one shape instead of leaving a disc parked beside a box.
    var largeDotOrigin = CGPoint(x: 10, y: -8)
    var smallDotOrigin = CGPoint(x: -3, y: -15)
    /// How far the bubble's centre sits **below** the avatar's.
    ///
    /// Measured: the cluster leaves the face just under its middle and hangs off
    /// the artwork's lower edge, which is what makes it read as coming out of
    /// somebody rather than floating beside them.
    var dropBelowCentre: CGFloat = 8

    // MARK: The bubble itself

    var emojiSide: CGFloat = 18
    var bubbleHorizontalPadding: CGFloat = 12
    var bubbleVerticalPadding: CGFloat = 8
    /// The widest the words may run before they wrap, and the widest the bubble
    /// may draw. **181 is 155 plus the two paddings plus the border**, exactly,
    /// which is how the two caps in Discord's sheet are known to be one number
    /// stated twice rather than two that happen to agree.
    var contentWidthCap: CGFloat = 155
    var bubbleWidthCap: CGFloat = 181
    /// A bubble holding one emoji still reads as a bubble.
    var minimumBubbleWidth: CGFloat = 42
    /// Lines before it clamps. Hovering shows the rest — see `CustomStatusBubble`.
    var collapsedLineLimit = 2
    /// Between the emoji and the words beside it.
    var contentGap: CGFloat = 6
    /// **A rounded square, not a capsule.** With an emoji and no words — which
    /// is most custom statuses — a capsule stretches into a lozenge around a
    /// single picture. The reference is a squircle that hugs whatever is in it.
    var bubbleCorner: CGFloat = 12

    // MARK: Derived

    /// How far the discs reach above and to the left of the bubble.
    ///
    /// **Reserved as padding rather than left to an overlay**, so the cluster's
    /// own frame contains them: a disc drawn outside its parent's bounds is a
    /// disc that disappears the first time an ancestor clips.
    var topOverhang: CGFloat { max(0, -smallDotOrigin.y) }
    var leadingOverhang: CGFloat { max(0, -smallDotOrigin.x) }

    /// Everything to the left of the cluster: the avatar, its decoration, a gap.
    var leadingInset: CGFloat { margin + avatarSide + decorationOverhang + gap }

    /// The widest the bubble may draw.
    ///
    /// **Discord's cap, or the card's, whichever is smaller.** 181 is the
    /// reference's own number; the card's is what stops a bubble being centred
    /// and clipped on both sides in a narrow column, which is what a too-wide
    /// child gets in a scroll view.
    var maximumBubbleWidth: CGFloat {
        min(bubbleWidthCap, max(40, cardWidth - leadingInset - margin - leadingOverhang))
    }

    /// How far down the cluster is offset from the artwork's lower edge, when it
    /// is placed bottom-leading beside the avatar.
    ///
    /// Positive is down. Derived from the avatar's own drop, so the trail leaves
    /// the face at the same angle on a card and on a full profile — the two have
    /// different drops, and a hand-tuned offset is right on one of them at most.
    var verticalOffset: CGFloat {
        avatarDrop - avatarSide / 2 + dropBelowCentre + topOverhang
    }

    /// How wide the bubble draws, given the width of what is inside it.
    ///
    /// **Computed, not left to `maxWidth`.** `frame(maxWidth:)` *fills* the
    /// space it is offered up to that maximum — it does not hug — so a bubble
    /// holding one emoji stretched the whole width the card could spare. The
    /// same trap the toolbar title documents from the other direction, and the
    /// same answer: measure the content and set the width.
    func bubbleWidth(contentWidth: CGFloat) -> CGFloat {
        min(
            max(minimumBubbleWidth, contentWidth + bubbleHorizontalPadding * 2),
            maximumBubbleWidth
        )
    }

    /// The widest the *content* may run before it wraps.
    var maximumContentWidth: CGFloat {
        min(contentWidthCap, max(20, maximumBubbleWidth - bubbleHorizontalPadding * 2))
    }
}
