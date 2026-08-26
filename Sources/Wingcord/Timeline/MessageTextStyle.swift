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
    var codeFont: NSFont
    var authorFont: NSFont
    var metadataFont: NSFont

    var primaryColor: NSColor
    var secondaryColor: NSColor
    var tertiaryColor: NSColor
    var linkColor: NSColor
    var mentionColor: NSColor
    var mentionBackground: NSColor
    var selfMentionBackground: NSColor
    var codeBackground: NSColor
    var quoteRuleColor: NSColor
    var spoilerCover: NSColor

    /// The em-space the inline emoji box is measured against, so an emoji tracks
    /// the text size rather than being pinned at 20pt forever.
    var emojiWidth: CGFloat
    var emojiAscent: CGFloat
    var emojiDescent: CGFloat

    var lineSpacing: CGFloat
    var paragraphSpacing: CGFloat

    /// Built from the current appearance.
    ///
    /// `@MainActor` because `NSFont.preferredFont` and dynamic system colours
    /// resolve against the current appearance, which is main-actor state. The
    /// resulting value is `Sendable` and is handed to the layout task.
    @MainActor
    static func current() -> MessageTextStyle {
        let body = NSFont.preferredFont(forTextStyle: .body)
        let manager = NSFontManager.shared
        let bold = manager.convert(body, toHaveTrait: .boldFontMask)
        let italic = manager.convert(body, toHaveTrait: .italicFontMask)
        let boldItalic = manager.convert(bold, toHaveTrait: .italicFontMask)
        let code = NSFont.monospacedSystemFont(
            ofSize: body.pointSize * 0.94,
            weight: .regular
        )

        return MessageTextStyle(
            bodyFont: body,
            boldFont: bold,
            italicFont: italic,
            boldItalicFont: boldItalic,
            codeFont: code,
            authorFont: manager.convert(body, toHaveTrait: .boldFontMask),
            metadataFont: NSFont.preferredFont(forTextStyle: .caption1),
            primaryColor: .labelColor,
            secondaryColor: .secondaryLabelColor,
            tertiaryColor: .tertiaryLabelColor,
            linkColor: .linkColor,
            mentionColor: NSColor(Palette.accent),
            mentionBackground: NSColor(Palette.accent).withAlphaComponent(0.16),
            selfMentionBackground: NSColor(Palette.accent).withAlphaComponent(0.28),
            codeBackground: NSColor(Palette.surfaceRaised),
            quoteRuleColor: NSColor(Palette.selectionFill),
            spoilerCover: NSColor(Palette.surfaceRaised),
            emojiWidth: body.pointSize * 1.28,
            emojiAscent: body.ascender * 1.05,
            emojiDescent: abs(body.descender),
            lineSpacing: 2,
            paragraphSpacing: 4
        )
    }

    // MARK: Attribute sets

    var body: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: primaryColor, .paragraphStyle: bodyParagraph]
    }

    var subtext: [NSAttributedString.Key: Any] {
        [.font: metadataFont, .foregroundColor: tertiaryColor, .paragraphStyle: bodyParagraph]
    }

    var inlineCode: [NSAttributedString.Key: Any] {
        [
            .font: codeFont,
            .foregroundColor: primaryColor,
            .backgroundColor: codeBackground,
            .paragraphStyle: bodyParagraph,
        ]
    }

    var codeBlock: [NSAttributedString.Key: Any] {
        [
            .font: codeFont,
            .foregroundColor: primaryColor,
            .paragraphStyle: codeParagraph,
        ]
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
        return attributes
    }

    func mention(
        base: [NSAttributedString.Key: Any],
        isSelf: Bool,
        tint: UInt32? = nil
    ) -> [NSAttributedString.Key: Any] {
        var attributes = base
        attributes[.font] = boldFont
        attributes[.foregroundColor] = tint.map { NSColor(Color(hex: $0)) } ?? mentionColor
        attributes[.backgroundColor] = isSelf ? selfMentionBackground : mentionBackground
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
        if style.contains(.spoiler) {
            // The concealed state is painted by the row painter over the
            // measured range; the text still lays out normally underneath, so
            // revealing one costs a repaint and never a relayout.
            attributes[.foregroundColor] = NSColor.clear
        }
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

    private var codeParagraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 1
        style.firstLineHeadIndent = 8
        style.headIndent = 8
        style.lineBreakMode = .byCharWrapping
        return style
    }

    var quoteParagraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.firstLineHeadIndent = 14
        style.headIndent = 14
        style.lineBreakMode = .byWordWrapping
        return style
    }

    /// Formats a `<t:…>` timestamp in the reader's own locale and time zone.
    ///
    /// Minute uses `.twoDigits`: the default-digits form renders minute zero as
    /// a bare `0`, so every time on the hour comes out as `22:0`.
    func format(_ date: Date, style: TimestampStyle) -> String {
        switch style {
        case .shortTime:
            date.formatted(.dateTime.hour().minute(.twoDigits))
        case .longTime:
            date.formatted(.dateTime.hour().minute(.twoDigits).second())
        case .shortDate:
            date.formatted(.dateTime.day().month().year())
        case .longDate:
            date.formatted(.dateTime.day().month(.wide).year())
        case .shortDateTime:
            date.formatted(.dateTime.day().month().year().hour().minute(.twoDigits))
        case .longDateTime:
            date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()
                .hour().minute(.twoDigits))
        case .relative:
            date.formatted(.relative(presentation: .named))
        }
    }
}
