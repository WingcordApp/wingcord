import AppKit
import WingcordCore

/// Styles text as it is written — Discord's live markdown (its textbox
/// stylesheet, `358931`).
///
/// **The markers stay, and say what they are.** Discord's box keeps `**` and
/// `||` where they were typed, in its muted syntax colour and semibold; what
/// they enclose takes the style. Underline, strikethrough and spoiler markers
/// are the exception it makes — normal weight, and an underline marker is
/// underlined itself — so a run of them reads as punctuation rather than as
/// shouting.
///
/// Restyled whole on every change. Text in a message box is short, the spans
/// come from one byte scan, and a partial restyle is a second place for the
/// box and the transcript to disagree about where a span ends.
@MainActor
struct MarkdownStyler {
    var font: NSFont
    var color: NSColor
    /// `--textbox-markdown-syntax`: `PRIMARY_360` in a dark room, `PRIMARY_530`
    /// in a light one.
    var syntaxColor: NSColor
    var linkColor: NSColor
    var codeFill: NSColor
    var spoilerFill: NSColor

    /// `--text-feedback-positive`, the colour of a code block's language.
    private static let positive = NSColor(srgbRed: 0x23 / 255, green: 0xA5 / 255, blue: 0x5A / 255, alpha: 1)

    static func current(font: NSFont, ink color: NSColor? = nil) -> MarkdownStyler {
        let ink = ThemeInk.current
        return MarkdownStyler(
            font: font,
            color: color ?? MessageTextStyle.current().primaryColor,
            syntaxColor: ink.isLight
                ? NSColor(srgbRed: 0x41 / 255, green: 0x43 / 255, blue: 0x4A / 255, alpha: 1)
                : NSColor(srgbRed: 0x94 / 255, green: 0x9B / 255, blue: 0xA4 / 255, alpha: 1),
            linkColor: NSColor(cgColor: ink.accent) ?? .linkColor,
            codeFill: NSColor(cgColor: ink.codeFill) ?? .quaternaryLabelColor,
            spoilerFill: NSColor(cgColor: ink.spoilerRevealed) ?? .quaternaryLabelColor
        )
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color]
    }

    func apply(to storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        defer { storage.endEditing() }
        storage.setAttributes(baseAttributes, range: full)
        guard storage.length > 0 else { return }
        let text = storage.string
        let spans = MarkdownEditorSyntax.spans(in: text)
        guard !spans.isEmpty else { return }
        let offsets = Self.utf16Offsets(of: text)
        func range(_ bytes: Range<Int>) -> NSRange {
            let lower = offsets[bytes.lowerBound], upper = offsets[bytes.upperBound]
            return NSRange(location: lower, length: upper - lower)
        }

        // What the markers enclose first, so nested styles add up; the markers
        // over it after.
        for span in spans {
            let content = range(span.content)
            guard content.length > 0 else { continue }
            switch span.kind {
            case .styled(let style):
                if style.contains(.bold) { addTrait(.boldFontMask, in: content, of: storage) }
                if style.contains(.italic) { addTrait(.italicFontMask, in: content, of: storage) }
                if style.contains(.underline) {
                    storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: content)
                }
                if style.contains(.strikethrough) {
                    storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: content)
                }
                if style.contains(.spoiler) {
                    storage.addAttribute(.backgroundColor, value: spoilerFill, range: content)
                }
            case .code:
                storage.addAttributes([.font: code, .backgroundColor: codeFill], range: content)
            case .link:
                storage.addAttribute(.foregroundColor, value: linkColor, range: content)
            case .codeBlock:
                storage.addAttribute(.font, value: code, range: content)
            case .subtext:
                storage.addAttributes([.font: subtext, .foregroundColor: syntaxColor], range: content)
            case .linePrefix:
                break
            }
        }

        for span in spans {
            let open = range(span.open)
            let close = range(span.close)
            switch span.kind {
            case .styled(let style):
                // Discord's `before_u`, `before_s`, `before_spoiler`: plain
                // weight, and an underline marker carries the underline.
                let quiet = style.isSubset(of: [.underline, .strikethrough, .spoiler])
                var marker: [NSAttributedString.Key: Any] = [
                    .foregroundColor: syntaxColor, .font: quiet ? font : semibold,
                ]
                if style.contains(.underline) { marker[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                storage.addAttributes(marker, range: open)
                storage.addAttributes(marker, range: close)
            case .code:
                let marker: [NSAttributedString.Key: Any] = [
                    .foregroundColor: syntaxColor, .font: code, .backgroundColor: codeFill,
                ]
                storage.addAttributes(marker, range: open)
                storage.addAttributes(marker, range: close)
            case .link:
                storage.addAttributes([.foregroundColor: syntaxColor], range: open)
                storage.addAttributes([.foregroundColor: syntaxColor], range: close)
            case .codeBlock(let language):
                storage.addAttributes([.foregroundColor: syntaxColor, .font: code], range: open)
                storage.addAttributes([.foregroundColor: syntaxColor, .font: code], range: close)
                if let language {
                    storage.addAttribute(.foregroundColor, value: Self.positive, range: range(language))
                }
            case .linePrefix:
                storage.addAttributes([.foregroundColor: syntaxColor, .font: semibold], range: open)
            case .subtext:
                // Discord's `before_subtext`: bold, and as small as the line.
                storage.addAttributes([
                    .foregroundColor: syntaxColor,
                    .font: NSFont.systemFont(ofSize: subtext.pointSize, weight: .bold),
                ], range: open)
            }
        }
    }

    // MARK: Faces

    private var semibold: NSFont { NSFont.systemFont(ofSize: font.pointSize, weight: .semibold) }
    /// `--font-code` at 85%.
    private var code: NSFont { NSFont.monospacedSystemFont(ofSize: (font.pointSize * 0.85).rounded(), weight: .regular) }
    /// Discord's subtext is 13 against a 16 body.
    private var subtext: NSFont { NSFont.systemFont(ofSize: (font.pointSize * 13 / 16).rounded()) }

    private func addTrait(_ trait: NSFontTraitMask, in range: NSRange, of storage: NSTextStorage) {
        storage.enumerateAttribute(.font, in: range) { value, run, _ in
            let current = value as? NSFont ?? font
            storage.addAttribute(.font, value: NSFontManager.shared.convert(current, toHaveTrait: trait), range: run)
        }
    }

    /// Where each UTF-8 byte of `text` falls in UTF-16 — the scanner counts in
    /// the first and the text system in the second.
    private static func utf16Offsets(of text: String) -> [Int] {
        var offsets: [Int] = []
        offsets.reserveCapacity(text.utf8.count + 1)
        var utf16 = 0
        for scalar in text.unicodeScalars {
            for _ in 0..<UTF8.width(scalar) { offsets.append(utf16) }
            utf16 += UTF16.width(scalar)
        }
        offsets.append(utf16)
        return offsets
    }
}
