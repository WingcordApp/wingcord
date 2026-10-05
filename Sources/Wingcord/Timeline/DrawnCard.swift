import AppKit
import CoreGraphics
import Foundation
import WingcordCore

/// A card drawn from parts — AutoMod's alert and notice, Discord's safety
/// notices: grounds, words, glyphs, faces and dots, and the controls laid
/// among them.
///
/// **A list of parts rather than a slot per card.** Four of Discord's cards
/// share every primitive and differ only in arrangement, so the layout writes
/// the arrangement once and the painter, the pointer and VoiceOver each walk
/// one list. Colours are named here and resolved at paint time, so a theme
/// change is a repaint; the words carry theirs, as every laid-out block does.
nonisolated struct DrawnCard: Sendable {
    enum Part: Sendable {
        case ground(CGRect, Ground, Corners, radius: CGFloat)
        case text(TimelineTextBlock, at: CGPoint)
        case symbol(String, CGRect, Tint)
        case avatar(URL?, monogram: String, CGRect)
        /// Discord's tag chip beside a name — `AuthorTagChip`.
        case tag(AuthorTag, CGRect)
        /// Discord's 4-point separator (`--background-mod-subtle`).
        case dot(CGRect)
    }

    /// What a ground is filled with — Discord's surfaces, in this app's room.
    enum Ground: Sendable {
        /// `--background-base-lower`: a card.
        case card
        /// `--background-base-lowest`: the bar joined under an alert.
        case bar
        /// `--background-mod-normal`: a plate inside a card, a notice's footer.
        case plate
        /// `--control-critical-primary-background-default`: a policy notice's
        /// footer.
        case critical
    }

    enum Corners: Sendable {
        case all
        case top
        case bottom
    }

    enum Tint: Sendable {
        case accent
        case primary
        case muted
        case critical
        case positive
        case link
    }

    /// Something to press: Discord's text buttons and links, a face, a card.
    struct Control: Sendable {
        var action: DrawnCardAction
        var rect: CGRect
        /// The words, and the same underlined for the pointer — Discord's
        /// `:hover` — laid out twice rather than once per hover. Nil for a
        /// control drawn by its parts: a face, a whole card.
        var label: TimelineTextBlock?
        var litLabel: TimelineTextBlock?
        var labelOrigin: CGPoint = .zero
        var accessibilityLabel: String
    }

    /// What a moderator did, over the mark that says so — its words are found
    /// when the pointer arrives, because they name the moderator and say how
    /// long ago.
    struct Tip: Sendable {
        var rect: CGRect
        var action: AutoModExecutedAction
    }

    var parts: [Part] = []
    var controls: [Control] = []
    var tips: [Tip] = []
    /// Everything the card covers, for the row's height.
    var rect: CGRect = .zero

    /// The control under a point in row space. **The first that holds it** —
    /// the layout lists a card's own click after the faces and words inside it.
    func control(at point: CGPoint) -> Control? {
        controls.first { $0.rect.contains(point) }
    }
}

/// What a card's control does — handed up by the canvas with the message it
/// is on and where it was pressed.
enum DrawnCardAction: Hashable, Sendable {
    /// A face or a name: their profile.
    case person(UserID)
    /// AutoMod's Actions: the member's own menu, where the moderation is.
    case moderate(UserID)
    /// Discord's Jump to Surrounding: the channel the member wrote in, at the
    /// moment AutoMod acted.
    case jumpToSurrounding(ChannelID)
    /// Delete User's Message — AutoMod's alert action.
    case deleteFlaggedMessage
    /// The alert's card itself: the flagged message, where it still is.
    case openFlaggedMessage(MessageID, in: ChannelID)
    /// A mention raid's Remove Restrictions.
    case removeMentionRestrictions(decisionID: String?)
    /// A mention raid's Configure Settings: AutoMod's settings.
    case configureAutoMod
    /// A safety notice's See Details — Discord's own fallback for the
    /// violation's detail, the Account Standing page.
    case accountStanding
    case openURL(URL)
}

/// Lays a card's parts out, one line at a time.
nonisolated struct DrawnCardWriter {
    let style: MessageTextStyle
    var card = DrawnCard()

    /// Discord's `text-xs/medium` and `text-xs/normal`, at this app's
    /// metadata size.
    var smallMedium: NSFont { NSFont.systemFont(ofSize: style.metadataFont.pointSize, weight: .medium) }
    var small: NSFont { style.metadataFont }
    /// `text-md/semibold`.
    var semibold: NSFont { NSFont.systemFont(ofSize: style.bodyFont.pointSize, weight: .semibold) }

    init(style: MessageTextStyle) {
        self.style = style
    }

    /// One run of words in one face, laid out at `width` — hugging, so a
    /// label is as wide as its words.
    func block(
        _ string: String,
        font: NSFont,
        color: NSColor,
        width: CGFloat,
        underlined: Bool = false,
        hugs: Bool = true
    ) -> TimelineTextBlock {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if underlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return TimelineTextBlock(
            text: .plain(NSAttributedString(string: string, attributes: attributes)),
            width: max(1, width),
            style: style,
            hugsText: hugs
        )
    }

    mutating func text(_ block: TimelineTextBlock, at origin: CGPoint) {
        card.parts.append(.text(block, at: origin))
    }

    /// A ground under what was written since `index` — grounds are drawn
    /// first, so it goes in before them.
    mutating func ground(
        _ rect: CGRect,
        _ ground: DrawnCard.Ground,
        _ corners: DrawnCard.Corners,
        under index: Int,
        radius: CGFloat = DrawnCardMetrics.corner
    ) {
        card.parts.insert(.ground(rect, ground, corners, radius: radius), at: index)
    }

    /// One of Discord's text buttons or links: the words, lit under the
    /// pointer, and the control over them.
    @discardableResult
    mutating func button(
        _ title: String,
        action: DrawnCardAction,
        at origin: CGPoint,
        font: NSFont,
        color: NSColor,
        width: CGFloat = 10_000
    ) -> CGRect {
        let label = block(title, font: font, color: color, width: width)
        let lit = block(title, font: font, color: color, width: width, underlined: true)
        let rect = CGRect(origin: origin, size: label.size)
        card.controls.append(DrawnCard.Control(
            action: action,
            rect: rect,
            label: label,
            litLabel: lit,
            labelOrigin: origin,
            accessibilityLabel: title
        ))
        return rect
    }

    /// Pieces of a line set one after another with a dot between each pair,
    /// wrapping to the next line where the next piece would run past
    /// `maxX` — Discord's rows of footer words and actions.
    ///
    /// - Returns: where the last line ends.
    mutating func dotted(
        _ pieces: [TimelineTextBlock],
        from start: CGPoint,
        maxX: CGFloat,
        gap: CGFloat,
        lineGap: CGFloat = 2
    ) -> CGFloat {
        var x = start.x
        var y = start.y
        var lineHeight: CGFloat = 0
        for (index, piece) in pieces.enumerated() {
            let lead = index == 0 ? 0 : gap * 2 + DrawnCardMetrics.dot
            if index > 0, x + lead + piece.size.width > maxX {
                x = start.x
                y += lineHeight + lineGap
                lineHeight = 0
            } else if index > 0 {
                card.parts.append(.dot(CGRect(
                    x: x + gap,
                    y: y + (piece.size.height - DrawnCardMetrics.dot) / 2,
                    width: DrawnCardMetrics.dot,
                    height: DrawnCardMetrics.dot
                )))
                x += lead
            }
            text(piece, at: CGPoint(x: x, y: y))
            x += piece.size.width
            lineHeight = max(lineHeight, piece.size.height)
        }
        return y + lineHeight
    }
}

/// Discord's measures for these cards, from its stylesheets.
nonisolated enum DrawnCardMetrics {
    /// `.embedCard { padding: 12px }`, and the notices' and safety cards' own.
    static let padding: CGFloat = 12
    static let corner: CGFloat = 8
    /// `.dot { width: 4px; height: 4px }`.
    static let dot: CGFloat = 4
    /// Discord's `xs` icon.
    static let icon: CGFloat = 16
    /// The safety cards' header glyph.
    static let safetyIcon: CGFloat = 14
    /// `.footerAction { padding: 8px }`.
    static let actionPadding: CGFloat = 8
}
