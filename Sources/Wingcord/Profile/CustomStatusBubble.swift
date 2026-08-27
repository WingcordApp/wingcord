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

    /// Where every piece goes. See `StatusBubbleLayout` — the numbers are
    /// measured off a reference, and they live in one value so a test can hold
    /// them to the relationships that make this read as speech.
    private var layout: StatusBubbleLayout {
        StatusBubbleLayout(
            avatarSide: Metrics.avatarProfile,
            avatarDrop: avatarDrop,
            decorationOverhang: ProfileAvatar.decorationOverhang,
            cardWidth: cardWidth,
            margin: Spacing.margin,
            gap: Spacing.base
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: -layout.overlap) {
            tail
            bubble
        }
        .padding(.leading, layout.leadingInset)
        // Placed from the avatar's own drop, so the cluster leaves the face at
        // the same angle on both surfaces.
        .offset(y: layout.verticalOffset)
        // The whole sentence on hover, and **only when there is more of it to
        // see**. A status is one line here because a second line pushes the name
        // it belongs to off its own banner; the rest is a question the reader
        // can ask by pointing at it.
        .modifier(TruncatedStatusFlyout(text: isTruncated ? text : nil))
        .accessibilityElement(children: .ignore)
        // VoiceOver gets the WHOLE status regardless of what is drawn. A visual
        // truncation is a layout decision, not a decision about what the status
        // says.
        .accessibilityLabel(Text(accessibilityLabel))
    }

    /// Two discs climbing from the face toward the bubble.
    private var tail: some View {
        VStack(alignment: .leading, spacing: layout.dotGap) {
            disc(layout.dotSmall)
            disc(layout.dotLarge).padding(.leading, layout.dotStagger)
        }
        .padding(.bottom, layout.tailBottomPadding)
    }

    private func disc(_ side: CGFloat) -> some View {
        Circle()
            .fill(Palette.statusBubble)
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
                    // One line, cut at the edge. See the flyout above.
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, layout.bubbleHorizontalPadding)
        .padding(.vertical, layout.bubbleVerticalPadding)
        // **An explicit width, hugging its content.** `frame(maxWidth:)` fills
        // the space it is offered rather than hugging, which is what stretched a
        // bubble holding one emoji into a lozenge the width of the card.
        .frame(width: layout.bubbleWidth(contentWidth: contentWidth), alignment: .leading)
        .background(
            Palette.statusBubble,
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

    /// Whether the sentence is longer than the one line it gets.
    ///
    /// **Measured, and the flyout is conditional on it.** A status that already
    /// fits has nothing to reveal, and a popover that opens to repeat what is
    /// visibly on screen is noise the reader learns to move away from. One
    /// `CTLine` measurement per bubble, not per frame — the bubble is built when
    /// a card opens.
    private var isTruncated: Bool {
        guard let text, !text.isEmpty else { return false }
        return contentWidth > layout.maximumContentWidth
    }

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

/// Reveals a status that did not fit, and installs nothing when it did.
///
/// **The modifier is guarded, not the closure.** `.onHover` compiles to an
/// AppKit tracking area and a `.popover` to a presentation node; writing both
/// unconditionally and returning early inside still pays for them on every
/// bubble in the app, including the great majority whose status fits on its
/// line — see `INVARIANTS.md` §2.
private struct TruncatedStatusFlyout: ViewModifier {
    var text: String?

    /// What the revealed sentence wraps at. Wide enough for a paragraph, narrow
    /// enough that a long status is a block rather than a ribbon.
    private static let width: CGFloat = 260

    func body(content: Content) -> some View {
        if let text {
            content.hoverFlyout(text, edge: .top, wrapsAt: Self.width)
        } else {
            content
        }
    }
}
