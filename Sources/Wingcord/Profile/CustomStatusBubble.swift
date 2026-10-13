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
    /// The greyed prompt an **empty** bubble carries, on the reader's own card.
    ///
    /// **Nil everywhere else, and that is the whole difference between the two
    /// cases.** Somebody else's empty status is not drawn at all — there is
    /// nothing to say and nothing to press. The reader's own is a control, so it
    /// is always there and says what it is for.
    var placeholder: String?
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
    /// The ink on that plate — see `ProfileGround.statusBubbleInk`. Defaulted
    /// for the surfaces that draw a bubble with no themed ground behind it.
    var ink: Color = InkColor.primary
    /// Answering it. **Nil on the reader's own bubble and on a surface with no
    /// route** — you do not react to yourself, and a control that cannot send
    /// is the inert one §5.5 forbids.
    var answer: CustomStatusAnswering?
    /// Whether the words can be selected and copied. Somebody else's status
    /// can; the reader's own is the button that edits it, and a selectable
    /// label inside a button takes the click the button exists for.
    var isSelectable = false

    var body: some View {
        bubble
            // **Above the bubble's own trailing corner, on hover.** Discord
            // floats a small pill there rather than putting the controls inside
            // the bubble: what is inside is what somebody said, and a button in
            // it would read as part of the sentence.
            //
            // **Attached to the bubble, not to the cluster.** It was on the
            // outer view — which carries the tail's overhang at its top and the
            // avatar's whole width as leading padding — so "top-trailing" was a
            // corner thirty points above the bubble and to the right of it, and
            // the pill floated off on its own. The only frame this can be placed
            // from is the one it is about.
            .overlay(alignment: .topTrailing) {
                if let answer, isExpanded {
                    StatusAnswerControls(
                        answer: answer,
                        // **Never wider than the bubble it belongs to.** A
                        // status of one emoji draws a 42-point bubble, and a
                        // fixed 64-point pill on it hung off both ends and
                        // covered the thing it was about. The controls shrink
                        // to fit instead — down to a floor, because a button
                        // smaller than a fingertip is a button nobody can hit.
                        side: Self.controlSide(
                            forBubbleWidth: layout.bubbleWidth(contentWidth: contentWidth)
                        )
                    )
                        // Sat on the bubble's top edge, tucked in from its right
                        // end — the pill's foot overlaps the bubble so the two
                        // read as one object rather than as a toolbar hovering
                        // nearby.
                        .alignmentGuide(.top) { $0[.bottom] - Self.controlsOverlap }
                        .alignmentGuide(.trailing) { $0[.trailing] + Spacing.base }
                        .transition(.opacity)
                }
            }
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
        // **One height for every status, and the content aligned to its top.**
        //
        // Two bugs, one cause. The cluster is placed bottom-leading against the
        // banner, so its *layout* height decides where the bubble rests — and
        // that height was the content's. A one-line status, a two-line one, an
        // emoji on its own and the empty prompt are four different heights, so
        // the bubble sat in four different places; and hovering, which lifts the
        // two-line clamp, moved it again — upward, off the artwork and away from
        // the face it comes out of, where Discord's grows down over the name.
        //
        // Fixing it is one frame. The box is always as tall as two clamped lines
        // need, so its bottom never moves and the resting position is the same
        // whatever the status says; the content sits at its top, so anything
        // taller spills below rather than shoving the whole cluster up.
        .frame(height: layout.topOverhang + collapsedHeight, alignment: .top)
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
            if let placeholder, text?.isEmpty != false, emoji == nil {
                // The plus is the affordance: an empty bubble with grey words in
                // it reads as a status somebody wrote, where a plus reads as a
                // place to put one.
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: layout.emojiSide * 0.9))
                    .foregroundStyle(ink.opacity(0.55))
                Text(placeholder)
                    .font(.system(.subheadline))
                    .italic()
                    .foregroundStyle(ink.opacity(0.55))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            } else if let text, !text.isEmpty {
                SelectableIf(isSelectable) {
                Text(text)
                    .font(.system(.subheadline))
                    // The plate's own ink. **Not the hierarchy**, which would
                    // resolve against the card rather than against this panel,
                    // and not a fixed white, which was legible on half the
                    // themes — see `ProfileGround.statusBubbleInk`.
                    .foregroundStyle(ink)
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
        // The empty state is the plus and the prompt, and it has to be measured
        // the same way — a bubble sized for a status it does not have would sit
        // at zero width with its own prompt spilling out of it.
        if let placeholder, text?.isEmpty != false, emoji == nil {
            return layout.emojiSide
                + layout.contentGap
                + TimelineLayoutEngine.measure(placeholder, font: Self.textFont)
        }
        var width: CGFloat = 0
        if emoji != nil { width += layout.emojiSide }
        if let text, !text.isEmpty {
            if width > 0 { width += layout.contentGap }
            width += TimelineLayoutEngine.measure(text, font: Self.textFont)
        }
        return width
    }

    /// The height the cluster reserves, whatever it is holding.
    ///
    /// **Two clamped lines, always** — not the height of *this* status. That is
    /// the whole point: a box sized to its content is a bubble that moves every
    /// time the content changes, which is what put an emoji-only status and a
    /// two-line one in two different places on the same card.
    private var collapsedHeight: CGFloat {
        layout.collapsedHeight(lineHeight: Self.lineHeight, hasEmoji: true, hasText: true)
    }

    /// One line of the bubble's face, drawn.
    ///
    /// **Ascent plus descent plus leading**, which is what a text stack advances
    /// a baseline by — a height taken from the point size alone is short by the
    /// descender on every face.
    private static var lineHeight: CGFloat {
        let font = textFont
        return (font.ascender - font.descender + font.leading).rounded(.up)
    }

    /// How far the hover pill's foot sits inside the bubble's top edge.
    ///
    /// `nonisolated` because an alignment guide's closure is `Sendable` — a
    /// main-actor constant cannot be read from one.
    nonisolated static let controlsOverlap: CGFloat = 6

    /// How big each control may be, given the bubble it sits on.
    ///
    /// Two buttons and three points of padding have to fit inside the bubble's
    /// own width with a little to spare, and no smaller than 18 points — below
    /// that a target stops being reliably hittable and the glyph inside it stops
    /// being legible, which is worse than a pill that slightly overhangs.
    nonisolated static func controlSide(forBubbleWidth width: CGFloat) -> CGFloat {
        let available = width - Spacing.base * 2 - 6
        return min(26, max(18, (available / 2).rounded(.down)))
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

// MARK: - Answering somebody's status

/// What the bubble's hover controls do.
///
/// **Both halves are one act with two spellings.** Reacting and replying are
/// the same `POST` to the same conversation — see
/// `SessionController.answerStatus`, where the only difference is the word in
/// the header, chosen from whether the reader sent an emoji or a sentence. So
/// this is one closure, not two.
struct CustomStatusAnswering {
    /// The person whose status it is, for the sheet's own copy.
    var name: String
    /// Sends it. An emoji on its own reads as a reaction; anything else as a
    /// reply.
    var send: (String) -> Void
}

/// The smiley and the arrow above a status bubble.
private struct StatusAnswerControls: View {
    var answer: CustomStatusAnswering
    /// How big each button draws — see `CustomStatusBubble.controlSide`.
    var side: CGFloat

    @Environment(\.motion) private var motion
    @State private var isPickingEmoji = false
    @State private var isReplying = false

    var body: some View {
        HStack(spacing: 2) {
            control("face.smiling", label: "React to this status") {
                isPickingEmoji = true
            }
            .popover(isPresented: $isPickingEmoji, arrowEdge: .bottom) {
                ExpressionPicker(
                    mode: .emoji,
                    onPick: { item in
                        isPickingEmoji = false
                        guard case .insert(let text) = item.pick else { return }
                        answer.send(text)
                    },
                    onPickGIF: { _ in }
                )
                .presentationBackground(.clear)
            }

            control("arrowshape.turn.up.left", label: "Reply to this status") {
                isReplying = true
            }
            .popover(isPresented: $isReplying, arrowEdge: .bottom) {
                StatusReplyField(name: answer.name) { text in
                    isReplying = false
                    answer.send(text)
                }
                .presentationBackground(.clear)
            }
        }
        .padding(3)
        // In-window glass, not a popover's: this sits inside the card and
        // samples what is under it — §4.9's other half.
        .glassEffect(.clear.tint(Palette.flyoutTint), in: .capsule)
    }

    private func control(
        _ symbol: String,
        label: String,
        act: @escaping () -> Void
    ) -> some View {
        Button(action: act) {
            Image(symbol: symbol)
                // Scaled with the button, so a shrunken control holds a
                // proportionate glyph rather than the same one in a smaller box.
                .font(.system(size: side * 0.42, weight: .medium))
                .foregroundStyle(InkColor.primary)
                .frame(width: side, height: side)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

/// The field a reply is typed into.
///
/// Discord's own copy — "Reply to {name}'s status" — because the field is the
/// only thing that says what it will do.
private struct StatusReplyField: View {
    var name: String
    var send: (String) -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Reply to \(name)'s status", text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(.subheadline))
            .foregroundStyle(InkColor.primary)
            .lineLimit(1...4)
            .focused($isFocused)
            .onSubmit(commit)
            .padding(.horizontal, Spacing.snug)
            .padding(.vertical, Spacing.base)
            .frame(width: 260, alignment: .leading)
            .task { isFocused = true }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        send(trimmed)
    }
}

/// Selection on a label that only sometimes takes it. A wrapper rather than a
/// ternary, because `.enabled` and `.disabled` are different types.
private struct SelectableIf<Content: View>: View {
    var isSelectable: Bool
    @ViewBuilder var content: Content

    init(_ isSelectable: Bool, @ViewBuilder content: () -> Content) {
        self.isSelectable = isSelectable
        self.content = content()
    }

    var body: some View {
        if isSelectable {
            content.textSelection(.enabled)
        } else {
            content
        }
    }
}
