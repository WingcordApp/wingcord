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
///  - the bubble's top is **level with the face's middle**, which puts the trail
///    on the line the eye follows out of the face;
///  - the cluster's width can never exceed the card's, because the card lives in
///    a scroll column and a too-wide child is centred and clipped on both sides.
nonisolated struct StatusBubbleLayout: Equatable, Sendable {
    /// Which of the two arrangements it hangs in.
    enum Surface: Sendable {
        case card
        case fullProfile
    }

    /// The avatar this hangs off, and how far it drops below the artwork.
    var avatarSide: CGFloat
    var avatarDrop: CGFloat
    var cardWidth: CGFloat
    var margin: CGFloat
    var surface: Surface = .card

    // MARK: Where it sits against the face
    //
    // **Discord's stylesheet, where this is stated outright** — the avatar and
    // the bubble's container are both absolutely placed:
    //
    //     .custom-user-profile-theme.user-profile-popout .avatar { left: 14px; top: 59px }   /* 80 across */
    //     .user-profile-popout .container { left: 105px; top: calc(banner-height - 7px) }    /* banner 105 */
    //
    //     .user-profile-modal .avatar     { left: 24px;  top: -68px }                         /* 120 across */
    //     .user-profile-modal .container  { left: 161px; top: -10px }
    //
    // Both were first measured off pictures and both came out wrong: 12.5 "below
    // the centre", then 5.5 (Alex's screenshots 28 and 29, misread — the bubble's
    // top is at y 136 and the face's centre at 137.5). Alex's "once and for all".

    /// From the face's edge to the bubble's leading edge.
    var gapFromFace: CGFloat {
        switch surface {
        case .card: 11
        case .fullProfile: 17
        }
    }

    /// How far the bubble's **top** sits below the avatar's centre. Negative is
    /// above it. **Its top, because that is what Discord fixes**: a longer status
    /// grows the bubble downward, over the name.
    var topBelowCentre: CGFloat {
        switch surface {
        case .card: -1
        case .fullProfile: -2
        }
    }

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

    // MARK: The bubble itself

    /// `.statusEmoji`: 16 beside words, 32 with none.
    var emojiSide: CGFloat = 16
    var loneEmojiSide: CGFloat = 32
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
    /// Between the emoji and the words beside it: `margin-inline-end: 4px`.
    var contentGap: CGFloat = 4
    /// **A rounded square, not a capsule.** With an emoji and no words — which
    /// is most custom statuses — a capsule stretches into a lozenge around a
    /// single picture. `.outer`'s `--radius-lg`, 16 pixels.
    var bubbleCorner: CGFloat = 16

    // MARK: Derived

    /// How far the discs reach above and to the left of the bubble.
    ///
    /// **Reserved as padding rather than left to an overlay**, so the cluster's
    /// own frame contains them: a disc drawn outside its parent's bounds is a
    /// disc that disappears the first time an ancestor clips.
    var topOverhang: CGFloat { max(0, -smallDotOrigin.y) }
    var leadingOverhang: CGFloat { max(0, -smallDotOrigin.x) }

    /// Everything to the left of the bubble: the avatar and the gap.
    var leadingInset: CGFloat { margin + avatarSide + gapFromFace }

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
    /// Positive is down. **Derived from how the view hangs it**: the cluster is
    /// `topOverhang + collapsedHeight` tall, its bottom on the artwork's lower
    /// edge plus this offset, and the bubble at its top below the overhang —
    /// so the bubble's top is `offset − collapsedHeight` below that edge, and
    /// the face's centre is `avatarDrop − avatarSide / 2` below it. Setting
    /// the difference to `topBelowCentre` gives this. From the avatar's own
    /// drop, so the trail leaves the face at the same angle on a card and on a
    /// full profile — the two have different drops.
    func verticalOffset(collapsedHeight: CGFloat) -> CGFloat {
        avatarDrop - avatarSide / 2 + topBelowCentre + collapsedHeight
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

    /// How tall the bubble is while its words are clamped.
    ///
    /// **The bubble's LAYOUT height, which is not its drawn height once it
    /// expands.** Hovering lifts the two-line clamp, and the cluster is placed
    /// bottom-leading against the banner — so growing it pushed the whole bubble
    /// *upward*, off the artwork and away from the face it comes out of.
    /// Discord's grows downward, over the name. Pinning the layout height to the
    /// collapsed one and aligning the content to its top is what makes the extra
    /// lines spill down instead of shoving everything up.
    ///
    /// - Parameter lineHeight: the drawn height of one line of the bubble's own
    ///   face. Passed in because this type has no text stack — the view measures
    ///   it with the same CoreText the transcript uses.
    func collapsedHeight(lineHeight: CGFloat, hasEmoji: Bool, hasText: Bool) -> CGFloat {
        var content: CGFloat = 0
        if hasEmoji { content = emojiSide }
        if hasText {
            content = max(content, lineHeight * CGFloat(collapsedLineLimit))
        }
        return max(content, emojiSide) + bubbleVerticalPadding * 2
    }

    /// The widest the *content* may run before it wraps.
    var maximumContentWidth: CGFloat {
        min(contentWidthCap, max(20, maximumBubbleWidth - bubbleHorizontalPadding * 2))
    }
}
