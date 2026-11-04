import AppKit
import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// macOS's Look Up in the selection's menu (Alex, 2026-10-26: "Look Up in the
/// text selection's right-click menu").
@MainActor
@Suite("Look Up")
struct LookUpTests {
    @Test("The row names the words, as a text view's menu does, cut short past a few")
    func rowNamesTheWords() {
        #expect(MessageMenu.excerpt("serendipity") == "serendipity")
        #expect(MessageMenu.excerpt("  two\nlines ") == "two lines")
        let long = MessageMenu.excerpt("the quick brown fox jumps over the lazy dog")
        #expect(long == "the quick brown fox jump…")
        #expect(long.count == 25)
    }

    @Test("Offered on a selection, not a permission, in the dictionary's glyph")
    func vocabulary() {
        #expect(MessageActionKind.lookUp.requirement == nil)
        #expect(MessageActionKind.lookUp.title == "Look Up")
        #expect(NSImage(systemSymbolName: MessageActionKind.lookUp.symbolName, accessibilityDescription: nil) != nil)
        #expect(!MessageActionKind.lookUp.opensSurface)
    }

    @Test("The panel is drawn from the selected word's place on its baseline")
    func baselineOfTheWord() throws {
        let style = MessageTextStyle.current()
        let text = MessageText.plain(NSAttributedString(string: "hello world", attributes: style.body))
        let block = TimelineTextBlock(text: text, width: 400, style: style)
        let start = try #require(block.baselineOrigin(at: 0))
        let world = try #require(block.baselineOrigin(at: 6))
        #expect(world.x > start.x + 20)
        #expect(start.y == block.firstBaseline)
        #expect(world.y == start.y)
        #expect(block.baselineOrigin(at: 40) == nil)
    }
}
