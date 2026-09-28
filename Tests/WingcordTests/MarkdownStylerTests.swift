import AppKit
import Testing
@testable import Wingcord

/// Discord's live markdown in the box: the markers stay, muted and semibold,
/// and what they enclose takes the style.
@MainActor
struct MarkdownStylerTests {

    private let styler = MarkdownStyler.current(font: NSFont.systemFont(ofSize: 13))

    private func styled(_ text: String) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        styler.apply(to: storage)
        return storage
    }

    @Test("Bold content is bold, and its markers are syntax")
    func bold() {
        let storage = styled("a **b** c")
        let marker = storage.attributes(at: 2, effectiveRange: nil)
        #expect(marker[.foregroundColor] as? NSColor == styler.syntaxColor)
        let content = storage.attribute(.font, at: 4, effectiveRange: nil) as? NSFont
        #expect(content.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)
        let plain = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(plain == styler.color)
    }

    /// Discord's `before_u`: an underline marker is plain weight and underlined.
    @Test("An underline marker is quiet and underlined")
    func underlineMarker() {
        let storage = styled("__u__")
        let marker = storage.attributes(at: 0, effectiveRange: nil)
        #expect(marker[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue)
        let font = marker[.font] as? NSFont
        #expect(font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == false)
    }

    @Test("Text after an emoji keeps its place — offsets are UTF-16")
    func astral() {
        let storage = styled("😀 **x**")
        // The emoji is two UTF-16 units and four UTF-8 bytes; the bold `x` is
        // at 5 in the text system's units.
        let font = storage.attribute(.font, at: 5, effectiveRange: nil) as? NSFont
        #expect(font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)
    }
}
