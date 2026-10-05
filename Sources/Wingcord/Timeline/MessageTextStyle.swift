import AppKit
import Foundation
import SwiftUI
import WingcordCore

/// Every font, colour and paragraph style the transcript draws with, resolved
/// once.
///
/// **Resolved once, and that is a performance decision.** `NSFont` lookup goes
/// through the font manager and a paragraph style is an object allocation;
/// building either inside a row's layout means doing it per message per width
/// change. This is one value built when the appearance or the text size changes
/// and read by every row after that.
///
/// It is also the reason the transcript honours the user's text-size setting
/// without a single call site knowing about it: every size below is derived from
/// a system text style rather than written as a number.
/// `@unchecked Sendable`: every stored property is an `NSFont` or an `NSColor`,
/// both of which are immutable once created and documented as safe to read from
/// any thread. The value is built on the main actor — font resolution reads the
/// current appearance — and then only ever read, by the layout engine and the
/// painter.
nonisolated struct MessageTextStyle: @unchecked Sendable {
    var bodyFont: NSFont
    var boldFont: NSFont
    var italicFont: NSFont
    var boldItalicFont: NSFont
    /// Inline code: Discord's `code.inline` is 85% of the text around it.
    var codeFont: NSFont
    /// A fenced block: `.markup code` is `.875rem` against a 1rem body.
    var codeBlockFont: NSFont
    /// A mention chip's face — `--font-weight-medium`, not bold.
    var mentionFont: NSFont
    var authorFont: NSFont
    var metadataFont: NSFont

    var primaryColor: NSColor
    var secondaryColor: NSColor
    var tertiaryColor: NSColor
    var linkColor: NSColor
    /// Whether every link carries a rule as well as its colour. See `link`.
    var underlinesLinks: Bool = false
    /// A mention's ink. Its plate, and every other plate a text run sits on,
    /// is resolved at paint time from `ThemeInk` — see `TextRunPlates`.
    var mentionColor: NSColor
    /// A refused send's words — Discord's `--text-feedback-critical`, `#FFA19C`
    /// in a dark room and `#BA2633` in a light one.
    var criticalColor = Self.criticalInk(isLight: false)

    /// The em-space the inline emoji box is measured against, so an emoji tracks
    /// the text size rather than being pinned at 20pt forever.
    var emojiWidth: CGFloat
    var emojiAscent: CGFloat
    var emojiDescent: CGFloat

    /// The box an inline SF Symbol reserves in a line.
    ///
    /// Derived from the body rather than fixed, so a symbol set in prose tracks
    /// the reader's text size exactly as the words around it do. Slightly under
    /// the cap height: a glyph matched to the ascender sits visibly larger than
    /// the letters beside it.
    var symbolSide: CGFloat { bodyFont.pointSize * 0.92 }

    var lineSpacing: CGFloat
    var paragraphSpacing: CGFloat

    /// Built from the current appearance.
    ///
    /// `@MainActor` because `NSFont.preferredFont` and dynamic system colours
    /// resolve against the current appearance, which is main-actor state. The
    /// resulting value is `Sendable` and is handed to the layout task.
    @MainActor
    static func current(scale: Double = AppSettings.shared.textScale) -> MessageTextStyle {
        // The app's own scale on top of the SYSTEM text size, never instead of
        // it. `preferredFont` already carries the accessibility setting; scaling
        // its point size preserves that and adds the app's, so a reader who has
        // raised the system size and then lowered the app's gets both.
        let systemBody = NSFont.preferredFont(forTextStyle: .body)
        let body = NSFont.systemFont(ofSize: systemBody.pointSize * scale)
        let manager = NSFontManager.shared
        let bold = manager.convert(body, toHaveTrait: .boldFontMask)
        let italic = manager.convert(body, toHaveTrait: .italicFontMask)
        let boldItalic = manager.convert(bold, toHaveTrait: .italicFontMask)
        // Discord's own ratios (`code.inline` 85%, `.markup code` .875rem),
        // taken against this body rather than Discord's 16 px one.
        let code = NSFont.monospacedSystemFont(ofSize: body.pointSize * 0.85, weight: .regular)
        let codeBlock = NSFont.monospacedSystemFont(ofSize: body.pointSize * 0.875, weight: .regular)

        return MessageTextStyle(
            bodyFont: body,
            boldFont: bold,
            italicFont: italic,
            boldItalicFont: boldItalic,
            codeFont: code,
            codeBlockFont: codeBlock,
            mentionFont: NSFont.systemFont(ofSize: body.pointSize, weight: .medium),
            authorFont: manager.convert(body, toHaveTrait: .boldFontMask),
            metadataFont: NSFont.systemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize * scale
            ),
            primaryColor: tinted(.labelColor),
            secondaryColor: tinted(.secondaryLabelColor),
            tertiaryColor: tinted(.tertiaryLabelColor),
            linkColor: .linkColor,
            underlinesLinks: AppSettings.shared.underlinesLinks,
            mentionColor: NSColor(Palette.accent),
            criticalColor: criticalInk(isLight: ThemeStore.shared.colors.appearance == .light),
            emojiWidth: body.pointSize * 1.28,
            emojiAscent: body.ascender * 1.05,
            emojiDescent: abs(body.descender),
            lineSpacing: 2,
            paragraphSpacing: 4
        )
    }

    /// A label colour with the theme's text tint mixed in, or the label colour
    /// itself when the theme carries none.
    ///
    /// **Discord's mix on the system's hierarchy.** Discord runs every text
    /// token through `color-mix(in oklab, <text> 100%, <tint> 38%)`; here the
    /// three label colours go through the same mix with their own alphas kept,
    /// so the hierarchy is still macOS's and only the hue moves. Resolved
    /// against the app's appearance — pinned by the theme — because a mixed
    /// colour is a plain one and cannot follow an appearance change by itself;
    /// the theme change that would move it rebuilds this style anyway.
    @MainActor
    private static func tinted(_ label: NSColor) -> NSColor {
        let colors = ThemeStore.shared.colors
        guard let tint = colors.textTint else { return label }
        var resolved = label
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = label.usingColorSpace(.sRGB) ?? label
        }
        let rgb = UInt32((resolved.redComponent * 255).rounded()) << 16
            | UInt32((resolved.greenComponent * 255).rounded()) << 8
            | UInt32((resolved.blueComponent * 255).rounded())
        let mixed = Oklch(packedRGB: rgb)
            .mixed(with: Oklch(packedRGB: tint), weight: colors.textTintWeight)
            .clippedRGB()
        return NSColor(
            srgbRed: CGFloat((mixed >> 16) & 0xFF) / 255,
            green: CGFloat((mixed >> 8) & 0xFF) / 255,
            blue: CGFloat(mixed & 0xFF) / 255,
            alpha: resolved.alphaComponent
        )
    }

    /// How much larger a message made only of emoji is drawn.
    ///
    /// Discord's jumbo is 48px against a 22px inline emoji, which is a shade
    /// over 2.2x — but that pair is measured on Discord's own 16px body, and
    /// this app's body is the system's. Expressed as a multiple of the body font
    /// rather than as a point size, so a reader who has raised their text size
    /// gets a proportionally larger jumbo instead of the same 48 points.
    static let jumboScale: CGFloat = 2.6

    /// The same style with the emoji drawn large.
    ///
    /// **Both kinds have to grow together.** A Unicode emoji is text and takes
    /// its size from the font; a custom one is a picture in a box the run
    /// delegate reserves. Scaling only the font leaves `:blobcat:` at twenty
    /// points beside a forty-point emoji in the same message, which is worse
    /// than leaving both small.
    ///
    /// Derived rather than measured, so this can be built off the main actor
    /// alongside the layout that asks for it.
    var jumbo: MessageTextStyle {
        var style = self
        let font = NSFont.systemFont(ofSize: bodyFont.pointSize * Self.jumboScale)
        style.bodyFont = font
        style.emojiWidth = font.pointSize * 1.28
        style.emojiAscent = font.ascender * 1.05
        style.emojiDescent = abs(font.descender)
        // A row of jumbo emoji that wraps needs room between the lines, and the
        // body's two points was tuned for text a third the height.
        style.lineSpacing = lineSpacing * Self.jumboScale
        return style
    }

    /// The same style at `factor` of its size — Discord's `text-sm` inside an
    /// embed, 14 px against its 16 px body. The metadata face is already the
    /// small one and stays as it is.
    func scaled(_ factor: CGFloat) -> MessageTextStyle {
        var style = self
        func resized(_ font: NSFont) -> NSFont {
            NSFont(descriptor: font.fontDescriptor, size: font.pointSize * factor) ?? font
        }
        style.bodyFont = resized(bodyFont)
        style.boldFont = resized(boldFont)
        style.italicFont = resized(italicFont)
        style.boldItalicFont = resized(boldItalicFont)
        style.codeFont = resized(codeFont)
        style.codeBlockFont = resized(codeBlockFont)
        style.mentionFont = resized(mentionFont)
        style.authorFont = resized(authorFont)
        style.emojiWidth = emojiWidth * factor
        style.emojiAscent = emojiAscent * factor
        style.emojiDescent = emojiDescent * factor
        return style
    }

    /// The same style for a message Discord refused.
    ///
    /// **Discord's `.isFailed`**: the critical ink on the words, their links and
    /// their code — and on nothing it does not name, so a mention keeps its own.
    var failed: MessageTextStyle {
        var style = self
        style.primaryColor = criticalColor
        style.secondaryColor = criticalColor
        style.linkColor = criticalColor
        return style
    }

    /// The same style for words on the reader's own bubble, which is the
    /// accent deepened until white reads on it (`ThemeInk.ownBubble`).
    ///
    /// **White, and the hierarchy kept by alpha** — a quote's softer ink, a
    /// mention's, the time's. **Links take a rule**, because on the accent
    /// their colour is the one thing that can no longer say what they are.
    var onAccentBubble: MessageTextStyle {
        var style = self
        style.primaryColor = Self.bubbleInk
        style.secondaryColor = Self.bubbleSecondaryInk
        style.tertiaryColor = Self.bubbleTertiaryInk
        style.linkColor = Self.bubbleInk
        style.mentionColor = Self.bubbleInk
        style.underlinesLinks = true
        return style
    }

    // Built once: a derived colour is an allocation, and every row of the
    // reader's own messages would otherwise make three.
    private static let bubbleInk = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    private static let bubbleSecondaryInk = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.82)
    private static let bubbleTertiaryInk = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.64)

    static func criticalInk(isLight: Bool) -> NSColor {
        isLight
            ? NSColor(srgbRed: 0xBA / 255, green: 0x26 / 255, blue: 0x33 / 255, alpha: 1)
            : NSColor(srgbRed: 0xFF / 255, green: 0xA1 / 255, blue: 0x9C / 255, alpha: 1)
    }

    // MARK: Attribute sets

    var body: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: primaryColor, .paragraphStyle: bodyParagraph]
    }

    var subtext: [NSAttributedString.Key: Any] {
        [.font: metadataFont, .foregroundColor: tertiaryColor, .paragraphStyle: bodyParagraph]
    }

    /// Inline code's glyphs. Its plate and hairline are painted from the run's
    /// measured rectangles — CoreText's `.backgroundColor` is a flat box per
    /// glyph run, with no corner and no border.
    var inlineCode: [NSAttributedString.Key: Any] {
        [.font: codeFont, .foregroundColor: primaryColor, .paragraphStyle: bodyParagraph]
    }

    var codeBlock: [NSAttributedString.Key: Any] {
        [.font: codeBlockFont, .foregroundColor: primaryColor, .paragraphStyle: codeParagraph]
    }

    /// A quote's own text: Discord draws a blockquote in `--text-subtle`. Runs
    /// with a colour of their own — a link, a mention — keep it.
    var quoteBody: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: secondaryColor, .paragraphStyle: bodyParagraph]
    }

    var listMarker: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: secondaryColor, .paragraphStyle: bodyParagraph]
    }

    func heading(level: Int) -> [NSAttributedString.Key: Any] {
        let scale: CGFloat = switch level {
        case 1: 1.42
        case 2: 1.24
        default: 1.10
        }
        let font = NSFont.systemFont(ofSize: bodyFont.pointSize * scale, weight: .bold)
        return [.font: font, .foregroundColor: primaryColor, .paragraphStyle: bodyParagraph]
    }

    func link(base: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var attributes = base
        attributes[.foregroundColor] = linkColor
        // **A rule, not a colour, for anyone who cannot rely on the colour.**
        // A link is distinguished from body text by hue alone by default, which
        // is the first distinction a colour-blind reader loses — so the
        // accessibility pane offers the underline and this is the one place it
        // lands. Off by default because Discord's is.
        if underlinesLinks { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return attributes
    }

    /// A mention's glyphs: the chip's medium face, in the role's colour or the
    /// mention ink. The plate is painted — see `TextRunPlates`.
    func mention(
        base: [NSAttributedString.Key: Any],
        tint: UInt32? = nil
    ) -> [NSAttributedString.Key: Any] {
        var attributes = base
        attributes[.font] = mentionFont
        attributes[.foregroundColor] = tint.map { NSColor(Color(hex: $0)) } ?? mentionColor
        return attributes
    }

    /// Applies an inline style to an attribute set.
    ///
    /// Bold and italic combine into one font rather than stacking traits, because
    /// CoreText picks a real bold-italic face where one exists and synthesises a
    /// slant only where it does not — and a synthesised slant on top of a real
    /// bold face is visibly different from the face beside it.
    func apply(_ style: InlineStyle, to attributes: inout [NSAttributedString.Key: Any]) {
        let bold = style.contains(.bold)
        let italic = style.contains(.italic)
        if bold, italic {
            attributes[.font] = boldItalicFont
        } else if bold {
            attributes[.font] = boldFont
        } else if italic {
            attributes[.font] = italicFont
        }
        if style.contains(.underline) {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if style.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        // **A spoiler's text keeps its ink.** The concealed state is an opaque
        // plate painted OVER the measured range, so revealing one is a repaint
        // and the words are there to show — drawn clear, a revealed spoiler
        // uncovered nothing at all.
    }

    /// A list item's lines: Discord's `list-style-position: outside`, the
    /// marker hanging in the list's `indent` and every wrapped line starting
    /// where the first line's words do — under the words, not the marker.
    func listParagraph(marker width: CGFloat, indent: CGFloat) -> NSParagraphStyle {
        let style = (bodyParagraph.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.firstLineHeadIndent = max(0, indent - width)
        style.headIndent = style.firstLineHeadIndent + width
        return style
    }

    private var bodyParagraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = paragraphSpacing
        // Word wrapping, and a `.byWordWrapping` line-break mode: `.byTruncating`
        // anywhere in a transcript silently eats the end of a long message.
        style.lineBreakMode = .byWordWrapping
        return style
    }

    /// A fenced block's lines, inset by the box's `.5em` padding on both sides.
    /// The space above and below the box is added to its first and last line —
    /// see `MessageTextBuilder` — because every line of a block is a paragraph
    /// to CoreText.
    private var codeParagraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 1
        style.firstLineHeadIndent = codeBlockPadding
        style.headIndent = codeBlockPadding
        style.tailIndent = -codeBlockPadding
        style.lineBreakMode = .byCharWrapping
        return style
    }

    /// Discord's `pre code` padding, `.5em` of the block's own face.
    var codeBlockPadding: CGFloat { (codeBlockFont.pointSize * 0.5).rounded() }

    /// Above a fenced block: `pre`'s `margin-top: 6px`, and the box's own top
    /// padding, which is drawn inside that space.
    var codeBlockLeading: CGFloat { 6 + codeBlockPadding }

    /// A quote's lines: the 4-point rule and the 12 points of air after it
    /// (`padding-inline: 12px 8px`), so the text wraps inside the rule rather
    /// than under it.
    var quoteParagraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.firstLineHeadIndent = Self.quoteIndent
        style.headIndent = Self.quoteIndent
        style.lineBreakMode = .byWordWrapping
        return style
    }

    /// The rule's width, and the text's inset from the block's leading edge.
    static let quoteRuleWidth: CGFloat = 4
    static let quoteIndent: CGFloat = quoteRuleWidth + 12
    /// `.blockquoteContainer`'s `margin-block: 4px`.
    static let quoteMargin: CGFloat = 4

    /// A chip's side padding: `padding: 0 2px` on a mention and a timestamp,
    /// `0 .2em` on inline code. Reserved in the line by a zero-glyph run
    /// delegate either side, so the plate never covers a neighbour.
    static let chipPadding: CGFloat = 2
    var codePadding: CGFloat { (codeFont.pointSize * 0.2).rounded() }

    /// A paragraph style with a different space above and below — the first
    /// and last line of a quote or a fenced block, which is how a box or a
    /// rule gets its margin when every line is a CoreText paragraph.
    func paragraph(
        _ base: NSParagraphStyle,
        before: CGFloat? = nil,
        after: CGFloat? = nil
    ) -> NSParagraphStyle {
        let style = (base.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        if let before { style.paragraphSpacingBefore = before }
        if let after { style.paragraphSpacing = after }
        return style
    }
}
