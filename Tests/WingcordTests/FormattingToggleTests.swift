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
}
