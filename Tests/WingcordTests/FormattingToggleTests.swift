import Foundation
import Testing
@testable import Wingcord

/// Discord's formatting toggles on plain text — module `339871`.
struct FormattingToggleTests {

    @Test("Bold goes on around the selection and comes off again")
    func boldRoundTrip() {
        let on = FormattingToggle.toggle(.bold, in: "hello", selection: NSRange(location: 0, length: 5))
        #expect(on == FormattingEdit(text: "**hello**", selection: NSRange(location: 2, length: 5)))
        #expect(FormattingToggle.activeFormats(in: on.text, selection: on.selection) == [.bold])
        let off = FormattingToggle.toggle(.bold, in: on.text, selection: on.selection)
        #expect(off == FormattingEdit(text: "hello", selection: NSRange(location: 0, length: 5)))
    }

    /// `***` is italics and bold together, and either comes off alone.
    @Test("Italics over bold makes the triple, and comes off alone")
    func triple() {
        let italic = FormattingToggle.toggle(.italics, in: "**hello**", selection: NSRange(location: 2, length: 5))
        #expect(italic.text == "***hello***")
        #expect(FormattingToggle.activeFormats(in: italic.text, selection: italic.selection) == [.bold, .italics])
        let plain = FormattingToggle.toggle(.italics, in: italic.text, selection: italic.selection)
        #expect(plain == FormattingEdit(text: "**hello**", selection: NSRange(location: 2, length: 5)))
    }

    /// A single `*` inside `**` is not italics.
    @Test("Part of a longer run is not the shorter marker")
    func runRule() {
        #expect(!FormattingToggle.activeFormats(in: "**hi**", selection: NSRange(location: 2, length: 2))
            .contains(.italics))
    }

    @Test("Spoiler and code use Discord's markers")
    func markers() {
        #expect(FormattingToggle.toggle(.spoiler, in: "x", selection: NSRange(location: 0, length: 1)).text == "||x||")
        #expect(FormattingToggle.toggle(.inlineCode, in: "x", selection: NSRange(location: 0, length: 1)).text == "`x`")
    }

    @Test("Quote prefixes every line, and unquotes when all are")
    func quote() {
        let text = "one\ntwo"
        let quoted = FormattingToggle.toggleQuote(in: text, selection: NSRange(location: 0, length: 7))
        #expect(quoted.text == "> one\n> two")
        #expect(quoted.selection == NSRange(location: 2, length: 9))
        let back = FormattingToggle.toggleQuote(in: quoted.text, selection: quoted.selection)
        #expect(back.text == text)
    }

    // MARK: The Format menu

    @Test("A heading prefixes every line, swaps for another, and comes off when every line has it")
    func headings() {
        let text = "one\ntwo"
        let title = FormattingToggle.toggleLinePrefix("# ", in: text, selection: NSRange(location: 0, length: 7))
        #expect(title.text == "# one\n# two")
        #expect(title.selection == NSRange(location: 2, length: 9))
        // Heading on a Title swaps the prefix rather than stacking a second.
        let heading = FormattingToggle.toggleLinePrefix("## ", in: title.text, selection: title.selection)
        #expect(heading.text == "## one\n## two")
        // The same prefix again takes it off.
        let off = FormattingToggle.toggleLinePrefix("## ", in: heading.text, selection: heading.selection)
        #expect(off.text == text)
        // Subtext is one of the family.
        #expect(FormattingToggle.toggleLinePrefix("-# ", in: "### x", selection: NSRange(location: 4, length: 1)).text == "-# x")
    }

    @Test("A heading on a caret alone prefixes its line and keeps the caret on the word")
    func headingAtCaret() {
        let edit = FormattingToggle.toggleLinePrefix("# ", in: "hello", selection: NSRange(location: 0, length: 0))
        #expect(edit.text == "# hello")
        #expect(edit.selection == NSRange(location: 2, length: 0))
    }

    @Test("A code block fences the selection on lines of its own, and unfences it")
    func codeBlock() {
        let fenced = FormattingToggle.toggleCodeBlock(in: "let x = 1", selection: NSRange(location: 0, length: 9))
        #expect(fenced.text == "```\nlet x = 1\n```")
        #expect(fenced.selection == NSRange(location: 4, length: 9))
        let back = FormattingToggle.toggleCodeBlock(in: fenced.text, selection: fenced.selection)
        #expect(back.text == "let x = 1")
        #expect(back.selection == NSRange(location: 0, length: 9))
    }
}
