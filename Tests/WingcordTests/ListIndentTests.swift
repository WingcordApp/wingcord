import AppKit
import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// A list as Discord sets it (`.markup ul`, `ol`): the marker hangs in the
/// list's indent, and a wrapped line starts under the words, not the marker.
@MainActor
@Suite("List indents")
struct ListIndentTests {
    private let style = MessageTextStyle.current()

    private func paragraph(_ source: String, at index: Int = 2) throws -> NSParagraphStyle {
        let text = MessageTextBuilder.build(document: MarkdownParser().parse(source), context: MentionContext(), style: style)
        return try #require(text.attributed.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)
    }

    private func width(_ marker: String) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: marker, attributes: style.listMarker))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    @Test("A bullet hangs in 1em; wrapped lines start where the words do")
    func bullets() throws {
        let item = try paragraph("- A long item that wraps")
        #expect(abs(item.headIndent - style.bodyFont.pointSize) < 0.01)
        #expect(abs(item.firstLineHeadIndent + width("• ") - item.headIndent) < 0.01)
    }

    @Test("A number's indent is room for the widest number")
    func numbers() throws {
        let item = try paragraph("9. Nine\n10. Ten", at: 3)
        let em = style.bodyFont.pointSize
        // `.4em + .6em` a digit, two digits — or the marker itself where wider.
        #expect(item.headIndent >= em * (0.4 + 0.6 * 2) - 0.01)
        #expect(abs(item.firstLineHeadIndent + width("9. ") - item.headIndent) < 0.01)
    }
}
