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

    var dotSmall: CGFloat = 9
    var dotLarge: CGFloat = 17
    var dotGap: CGFloat = 2
    /// How far right the large disc sits from the small one — the diagonal.
    var dotStagger: CGFloat = 6
    /// How far the large disc runs under the bubble.
    var overlap: CGFloat = 3
    /// How far the bubble's centre sits **below** the avatar's.
    ///
    /// Measured: the cluster leaves the face just under its middle and hangs off
    /// the artwork's lower edge, which is what makes it read as coming out of
    /// somebody rather than floating beside them.
    var dropBelowCentre: CGFloat = 8

    // MARK: The bubble itself

    var emojiSide: CGFloat = 18
    var bubbleHorizontalPadding: CGFloat = 11
    var bubbleVerticalPadding: CGFloat = 8
    /// Between the emoji and the words beside it.
    var contentGap: CGFloat = 6
    /// **A rounded square, not a capsule.** With an emoji and no words — which
    /// is most custom statuses — a capsule stretches into a lozenge around a
    /// single picture. The reference is a squircle that hugs whatever is in it.
    var bubbleCorner: CGFloat = 12

    // MARK: Derived

    /// The gap under the tail column.
    ///
    /// **Arithmetic, not taste**: it is exactly what puts the LARGE disc's
    /// centre on the cluster's own centre, and therefore on the bubble's.
    var tailBottomPadding: CGFloat { dotSmall + dotGap }

    var tailHeight: CGFloat { dotSmall + dotGap + dotLarge + tailBottomPadding }

    var tailWidth: CGFloat { dotStagger + dotLarge }

    /// Everything to the left of the tail: the avatar, its decoration, a gap.
    var leadingInset: CGFloat { margin + avatarSide + decorationOverhang + gap }

    /// The widest the bubble may draw.
    var maximumBubbleWidth: CGFloat {
        max(40, cardWidth - leadingInset - margin - (tailWidth - overlap))
    }

    /// How far down the cluster is offset from the artwork's lower edge, when it
    /// is placed bottom-leading beside the avatar.
    ///
    /// Positive is down. Derived from the avatar's own drop, so the trail leaves
    /// the face at the same angle on a card and on a full profile — the two have
    /// different drops, and a hand-tuned offset is right on one of them at most.
    var verticalOffset: CGFloat {
        avatarDrop - avatarSide / 2 + dropBelowCentre + tailHeight / 2
    }

    /// How wide the bubble draws, given the width of what is inside it.
    ///
    /// **Computed, not left to `maxWidth`.** `frame(maxWidth:)` *fills* the
    /// space it is offered up to that maximum — it does not hug — so a bubble
    /// holding one emoji stretched the whole width the card could spare. The
    /// same trap the toolbar title documents from the other direction, and the
    /// same answer: measure the content and set the width.
    func bubbleWidth(contentWidth: CGFloat) -> CGFloat {
        min(contentWidth + bubbleHorizontalPadding * 2, maximumBubbleWidth)
    }

    /// The widest the *content* may run before it has to truncate.
    var maximumContentWidth: CGFloat {
        max(20, maximumBubbleWidth - bubbleHorizontalPadding * 2)
    }

    /// The large disc's centre, measured down from the cluster's top.
    var largeDotCenterY: CGFloat { dotSmall + dotGap + dotLarge / 2 }

    /// The cluster's own centre, measured down from its top.
    var centerY: CGFloat { tailHeight / 2 }
}
