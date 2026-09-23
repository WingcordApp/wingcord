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
    /// Whether every link carries a rule as well as its colour. See `link`.
    var underlinesLinks: Bool = false
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
            metadataFont: NSFont.systemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize * scale
            ),
            primaryColor: tinted(.labelColor),
            secondaryColor: tinted(.secondaryLabelColor),
            tertiaryColor: tinted(.tertiaryLabelColor),
            linkColor: .linkColor,
            underlinesLinks: AppSettings.shared.underlinesLinks,
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
        guard let tint = ThemeStore.shared.colors.textTint else { return label }
        var resolved = label
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = label.usingColorSpace(.sRGB) ?? label
        }
        let rgb = UInt32((resolved.redComponent * 255).rounded()) << 16
            | UInt32((resolved.greenComponent * 255).rounded()) << 8
            | UInt32((resolved.blueComponent * 255).rounded())
        let mixed = Oklch(packedRGB: rgb)
            .mixed(with: Oklch(packedRGB: tint), weight: DiscordTheme.textTintWeight)
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
        // **A rule, not a colour, for anyone who cannot rely on the colour.**
        // A link is distinguished from body text by hue alone by default, which
        // is the first distinction a colour-blind reader loses — so the
        // accessibility pane offers the underline and this is the one place it
        // lands. Off by default because Discord's is.
        if underlinesLinks { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
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
