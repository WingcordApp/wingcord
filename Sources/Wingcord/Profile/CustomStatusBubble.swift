import AppKit
import SwiftUI
import WingcordCore

/// Somebody's custom status, drawn as the thing it is: a **speech bubble coming
/// off their face**.
///
/// It used to be a caption — one grey line among the handle, the pronouns and
/// the nickname, in the same type as all three. That is the wrong category. A
/// handle is a fact about a person and a custom status is *something they said*,
/// and setting the two identically leaves the only sentence on the card that
/// anybody wrote by hand looking like metadata.
///
/// **The geometry below is measured, not chosen.** The first attempt got the
/// vocabulary right and every number wrong: dots too small, stacked in a
/// vertical column, floating clear of the bubble, and the whole cluster parked
/// well above the face it was supposed to be coming from. What makes this read
/// as speech rather than as a label with decoration beside it:
///
///  - the discs **climb diagonally** — small up and left, large down and right —
///    so the trail has a direction, where a vertical column has none;
///  - the large disc **overlaps the bubble** and shares its colour, so the two
///    fuse into one shape rather than sitting near each other;
///  - the large disc's centre is **level with the bubble's**, which is what puts
///    the trail on the line the eye follows out of the avatar;
///  - the bubble is a **capsule**. At this height a 13pt radius reads as a
///    rounded rectangle, and a rectangle is a label.
///
/// **A fixed scrim, not glass, and that is the invariant rather than an
/// exception to it.** This sits over a banner the reader did not choose, which
/// may be a GIF — and `INVARIANTS.md` §4 sends anything over moving artwork to a
/// fixed scrim precisely because a sampled material cannot promise the text on
/// top of it stays readable frame to frame.
struct CustomStatusBubble: View {
    var text: String?
    var emoji: EmojiRef?
    /// How far the avatar beside this hangs below the artwork.
    ///
    /// **The bubble places itself from it.** The banner's height, the avatar's
    /// drop and this cluster are one arrangement, and three private copies of
    /// the arithmetic is how each stays individually defensible while the result
    /// is wrong — `INVARIANTS.md` §2. The two profile surfaces have different
    /// drops, so a hand-tuned offset is right on one of them at most.
    var avatarDrop: CGFloat
    /// The widest the card can spare. The bubble never decides the card's width;
    /// the card decides the bubble's.
    var cardWidth: CGFloat
    /// The avatar this hangs off. **A parameter for the same reason the drop is
    /// one**: the card draws an 80-point face and the full profile's identity
    /// panel a 96-point one, and every number in the layout below is written
    /// against it.
    var avatarSide: CGFloat = Metrics.avatarProfile
    /// The gutter the avatar is inset by, for the same reason.
    var margin: CGFloat = Spacing.margin

    @Environment(\.motion) private var motion
    /// Whether the pointer is on it, which lifts the two-line clamp.
    @State private var isExpanded = false

    /// Where every piece goes. See `StatusBubbleLayout` — the numbers are
    /// measured off a reference, and they live in one value so a test can hold
    /// them to the relationships that make this read as speech.
    private var layout: StatusBubbleLayout {
        StatusBubbleLayout(
            avatarSide: avatarSide,
            avatarDrop: avatarDrop,
            decorationOverhang: ProfileAvatar.decorationOverhang(side: avatarSide),
            cardWidth: cardWidth,
            margin: margin,
            gap: Spacing.base
        )
    }

    /// The plate, which follows the card it sits on — see
    /// `ProfileGround.statusBubbleFill`. Defaulted so a surface that draws a
    /// bubble with no ground behind it does not have to say so, and declared
    /// last because a memberwise initialiser takes its arguments in order.
    var fill: Color = Palette.statusBubble

    var body: some View {
        bubble
            // **Behind the bubble, not beside it.** The large disc straddles its
            // top edge, and a disc drawn *over* it would show its own rim
            // crossing the bubble's face; underneath, only the part that
            // protrudes is ever seen, which is the arc Discord draws.
            .background(alignment: .topLeading) { tail }
            // The overhang is reserved so the discs are inside this view's own
            // frame — a background is not clipped by its parent, but an
            // ancestor that clips would take them.
            .padding(.top, layout.topOverhang)
            .padding(.leading, layout.leadingInset + layout.leadingOverhang)
        // Placed from the avatar's own drop, so the cluster leaves the face at
        // the same angle on both surfaces.
        .offset(y: layout.verticalOffset)
        // **The clamp lifts under the pointer, in place.** Discord expands the
        // bubble itself rather than opening a second surface to read it in, and
        // the flyout this replaces was answering a question by putting the
        // answer somewhere else.
        //
        // Unconditional on purpose: a status that already fits in two lines is
        // unchanged by lifting a limit it never reached, so there is no
        // "is it truncated" to measure and get wrong.
        .onHover { hovering in
            guard isExpanded != hovering else { return }
            isExpanded = hovering
        }
        .animation(motion.hover, value: isExpanded)
        .accessibilityElement(children: .ignore)
        // VoiceOver gets the WHOLE status regardless of what is drawn. A visual
        // truncation is a layout decision, not a decision about what the status
        // says.
        .accessibilityLabel(Text(accessibilityLabel))
    }

    /// Two discs climbing out of the bubble's top-left corner, toward the face.
    ///
    /// **Placed from the bubble's own corner**, which is how the stylesheet
    /// states them — both are absolutely positioned against it. Their offsets
    /// are negative upward, so this reads the same way the CSS does.
    private var tail: some View {
        ZStack(alignment: .topLeading) {
            disc(layout.dotLarge)
                .offset(x: layout.largeDotOrigin.x, y: layout.largeDotOrigin.y)
            disc(layout.dotSmall)
                .offset(x: layout.smallDotOrigin.x, y: layout.smallDotOrigin.y)
        }
    }

    /// **The same fill as the bubble, or the tail stops belonging to it.** The
    /// two discs are the speech tail; drawn in a different colour they read as
    /// two dots that happen to be nearby.
    private func disc(_ side: CGFloat) -> some View {
        Circle()
            .fill(fill)
            .frame(width: side, height: side)
    }

    private var bubble: some View {
        HStack(spacing: layout.contentGap) {
            if let emoji {
                ExpressionGlyph(emoji: emoji, side: layout.emojiSide)
            }
            if let text, !text.isEmpty {
                Text(text)
                    .font(.system(.subheadline))
                    // Fixed white rather than the hierarchy: this composites
                    // against a scrim over artwork nobody chose, and vibrancy
                    // there resolves against the picture instead of the panel.
                    .foregroundStyle(.white)
                    // **Two lines, then it clamps** — Discord's own
                    // `-webkit-line-clamp: 2` — and hovering lifts the clamp
                    // rather than opening a second surface to read it in. The
                    // bubble is positioned by an offset, so growing it moves
                    // nothing else on the card.
                    .lineLimit(isExpanded ? nil : layout.collapsedLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.horizontal, layout.bubbleHorizontalPadding)
        .padding(.vertical, layout.bubbleVerticalPadding)
        // **An explicit width, hugging its content.** `frame(maxWidth:)` fills
        // the space it is offered rather than hugging, which is what stretched a
        // bubble holding one emoji into a lozenge the width of the card.
        .frame(width: layout.bubbleWidth(contentWidth: contentWidth), alignment: .leading)
        .background(
            fill,
            in: .rect(cornerRadius: layout.bubbleCorner, style: .continuous)
        )
    }

    /// How wide what is inside the bubble actually is.
    ///
    /// Measured through CoreText, which is the same stack the transcript sizes
    /// every name and timestamp with — `NSAttributedString.size()` builds a text
    /// container and a layout manager to answer the same question.
    private var contentWidth: CGFloat {
        var width: CGFloat = 0
        if emoji != nil { width += layout.emojiSide }
        if let text, !text.isEmpty {
            if width > 0 { width += layout.contentGap }
            width += TimelineLayoutEngine.measure(text, font: Self.textFont)
        }
        return width
    }

    /// The face the status is drawn in, resolved once for measurement.
    private static var textFont: NSFont { .preferredFont(forTextStyle: .subheadline) }


    private var accessibilityLabel: String {
        let spoken = [emoji.map { UnicodeEmoji.shortcode(for: $0.name) ?? $0.name }, text]
            .compactMap { $0 }
            .joined(separator: " ")
        return "Status: \(spoken)"
    }
}

/// One emoji at a fixed size, whichever kind it is.
///
/// A Unicode emoji is **text** and costs a glyph; a custom one is a picture at a
/// known size out of the shared cache. Both appear wherever a status, a chip or
/// a trait carries one, and writing the branch at each of those call sites is
/// how one of them ends up drawing `:blobcat:` as a word.
struct ExpressionGlyph: View {
    var emoji: EmojiRef
    var side: CGFloat

    var body: some View {
        if let id = emoji.id {
            RemoteImage(
                url: CDN.emoji(id: id, animated: emoji.isAnimated, side: side),
                side: side
            ) {
                Color.clear
            }
            .frame(width: side, height: side)
        } else {
            Text(emoji.name)
                .font(.system(size: side * 0.86))
                .frame(width: side, height: side)
        }
    }
}
