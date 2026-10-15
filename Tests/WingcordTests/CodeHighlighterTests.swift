import AppKit
import Foundation
import Testing
@testable import Wingcord

/// highlight.js as Discord runs it: the guards against Discord's own wrapper
/// (`752238`) and the tokens against the same bundle run in Node, so the
/// JavaScriptCore path is checked against the engine it embeds.
@Suite("Code highlighter")
struct CodeHighlighterTests {
    typealias Token = CodeHighlighter.Token

    nonisolated static let guardVectors: [(String, String, Bool)] = [
        ("let x = 1", "swift", true),
        ("a" + String(repeating: "/", count: 15), "swift", false),
        ("a" + String(repeating: "/", count: 14), "swift", true),
        (String(repeating: "x", count: 1000), "swift", true),
        (String(repeating: "x", count: 1001), "swift", false),
        ("//////////\n//////////\n//////////\n/", "swift", false),
        ("//////////\n//////////\n//////////", "swift", true),
        ("a/b/c/d/e/f/g/h/i/j/k\nl/m/n/o/p/q/r/s/t/u/v/w/x/y/z/a/b/c/d/e/f/g", "c", true),
        ("// one / two / three / four / five / six / seven / eight\n// a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q/r/s/t/u/v/w", "c", false),
        ("  // c1 / / / / / / / / / / / / / / /\nplain line\n// / / / / / / / / / / / / / / / / / / / / / / / / / / / / / /", "c", false),
        (String(repeating: "<script></script>", count: 11), "xml", false),
        (String(repeating: "<script></script>", count: 10), "xml", true),
        (String(repeating: "< script >", count: 11), "xml", false),
        (String(repeating: "html`x`", count: 11), "javascript", false),
        (String(repeating: "html\\`x`", count: 11), "typescript", false),
        (String(repeating: "<script/>", count: 11), "xml", false),
        (String(repeating: "<script></script>", count: 11), "swift", true),
        (String(repeating: "<script>\\>", count: 12), "handlebars", false),
        ("", "swift", true),
    ]

    @Test("Discord's guards refuse what its wrapper refuses", arguments: guardVectors)
    func guards(code: String, canonical: String, admits: Bool) {
        #expect(CodeHighlighter.admits(code, canonicalLanguage: canonical) == admits)
    }

    static let tokenVectors: [(String, String, [Token]?)] = [
        ("swift", "let answer = 42 // the answer\nfunc greet(name: String) -> String { \"Hi \\(name)\" }", [Token(location: 0, length: 3, scopes: ["keyword"]), Token(location: 11, length: 1, scopes: ["operator"]), Token(location: 13, length: 2, scopes: ["number"]), Token(location: 16, length: 13, scopes: ["comment"]), Token(location: 30, length: 4, scopes: ["keyword"]), Token(location: 35, length: 5, scopes: ["title.function"]), Token(location: 41, length: 4, scopes: ["params"]), Token(location: 47, length: 6, scopes: ["type"]), Token(location: 58, length: 6, scopes: ["type"]), Token(location: 67, length: 4, scopes: ["string"]), Token(location: 71, length: 7, scopes: ["string", "subst"]), Token(location: 78, length: 1, scopes: ["string"])]),
        ("python", "@decorator\ndef f(x: int) -> int:\n    return x * 2  # double\nclass A(B): pass", [Token(location: 0, length: 10, scopes: ["meta"]), Token(location: 11, length: 3, scopes: ["keyword"]), Token(location: 15, length: 1, scopes: ["title.function"]), Token(location: 17, length: 3, scopes: ["params"]), Token(location: 20, length: 3, scopes: ["params", "built_in"]), Token(location: 28, length: 3, scopes: ["built_in"]), Token(location: 37, length: 6, scopes: ["keyword"]), Token(location: 48, length: 1, scopes: ["number"]), Token(location: 51, length: 8, scopes: ["comment"]), Token(location: 60, length: 5, scopes: ["keyword"]), Token(location: 66, length: 1, scopes: ["title.class"]), Token(location: 68, length: 1, scopes: ["title.class.inherited"]), Token(location: 72, length: 4, scopes: ["keyword"])]),
        ("json", "{\"a\": [1, true, null, \"s\"]}", [Token(location: 0, length: 1, scopes: ["punctuation"]), Token(location: 1, length: 3, scopes: ["attr"]), Token(location: 4, length: 1, scopes: ["punctuation"]), Token(location: 6, length: 1, scopes: ["punctuation"]), Token(location: 7, length: 1, scopes: ["number"]), Token(location: 8, length: 1, scopes: ["punctuation"]), Token(location: 10, length: 4, scopes: ["literal", "keyword"]), Token(location: 14, length: 1, scopes: ["punctuation"]), Token(location: 16, length: 4, scopes: ["literal", "keyword"]), Token(location: 20, length: 1, scopes: ["punctuation"]), Token(location: 22, length: 3, scopes: ["string"]), Token(location: 25, length: 1, scopes: ["punctuation"]), Token(location: 26, length: 1, scopes: ["punctuation"])]),
        ("diff", "--- a\n+++ b\n@@ -1 +1 @@\n-old\n+new", [Token(location: 0, length: 5, scopes: ["comment"]), Token(location: 6, length: 5, scopes: ["comment"]), Token(location: 24, length: 4, scopes: ["deletion"]), Token(location: 29, length: 4, scopes: ["addition"])]),
        ("markdown", "# Title\n**bold** *it* [link](http://x)\n- item", [Token(location: 0, length: 7, scopes: ["section"]), Token(location: 8, length: 8, scopes: ["strong"]), Token(location: 17, length: 4, scopes: ["emphasis"]), Token(location: 23, length: 4, scopes: ["string"]), Token(location: 29, length: 8, scopes: ["link"]), Token(location: 39, length: 1, scopes: ["bullet"])]),
        ("html", "<div class=\"x\">&amp; <b>hi</b></div><script>let a = 1</script>", [Token(location: 0, length: 1, scopes: ["tag"]), Token(location: 1, length: 3, scopes: ["tag", "name"]), Token(location: 4, length: 1, scopes: ["tag"]), Token(location: 5, length: 5, scopes: ["tag", "attr"]), Token(location: 10, length: 1, scopes: ["tag"]), Token(location: 11, length: 3, scopes: ["tag", "string"]), Token(location: 14, length: 1, scopes: ["tag"]), Token(location: 15, length: 5, scopes: ["symbol"]), Token(location: 21, length: 1, scopes: ["tag"]), Token(location: 22, length: 1, scopes: ["tag", "name"]), Token(location: 23, length: 1, scopes: ["tag"]), Token(location: 26, length: 2, scopes: ["tag"]), Token(location: 28, length: 1, scopes: ["tag", "name"]), Token(location: 29, length: 1, scopes: ["tag"]), Token(location: 30, length: 2, scopes: ["tag"]), Token(location: 32, length: 3, scopes: ["tag", "name"]), Token(location: 35, length: 1, scopes: ["tag"]), Token(location: 36, length: 1, scopes: ["tag"]), Token(location: 37, length: 6, scopes: ["tag", "name"]), Token(location: 43, length: 1, scopes: ["tag"]), Token(location: 44, length: 3, scopes: ["language:javascript", "keyword"]), Token(location: 47, length: 3, scopes: ["language:javascript"]), Token(location: 50, length: 2, scopes: ["language:javascript"]), Token(location: 52, length: 1, scopes: ["language:javascript", "number"]), Token(location: 53, length: 2, scopes: ["tag"]), Token(location: 55, length: 6, scopes: ["tag", "name"]), Token(location: 61, length: 1, scopes: ["tag"])]),
        ("js", "const x = `a${b}c`; this.y = /re/g;", [Token(location: 0, length: 5, scopes: ["keyword"]), Token(location: 10, length: 2, scopes: ["string"]), Token(location: 12, length: 4, scopes: ["string", "subst"]), Token(location: 16, length: 2, scopes: ["string"]), Token(location: 20, length: 4, scopes: ["variable.language"]), Token(location: 25, length: 1, scopes: ["property"]), Token(location: 29, length: 5, scopes: ["regexp"])]),
        ("notalanguage", "whatever", nil),
    ]

    @Test("Tokens match highlight.js in Node")
    func tokens() async {
        for (language, code, expected) in Self.tokenVectors {
            let tokens = await CodeHighlighter.shared.tokens(for: code, language: language)
            #expect(tokens == expected, "\(language)")
        }
    }

    @Test("An unknown language and an empty text are drawn plain")
    func plain() async {
        #expect(await CodeHighlighter.shared.tokens(for: "x", language: "notalanguage") == nil)
        #expect(await CodeHighlighter.shared.tokens(for: "", language: "swift") == nil)
        #expect(CodeHighlighter.shared.cachedTokens(for: "x", language: "notalanguage") == .some(nil))
    }

    nonisolated static let styleVectors: [([String], CodeTokenStyle)] = [
        (["keyword"], CodeTokenStyle(ink: .keyword)),
        (["meta"], CodeTokenStyle(ink: .decorator)),
        (["meta", "keyword"], CodeTokenStyle(ink: .keyword)),
        (["meta", "string"], CodeTokenStyle(ink: .string)),
        (["variable.language"], CodeTokenStyle(ink: .keyword)),
        (["variable"], CodeTokenStyle(ink: .variable)),
        (["title.class.inherited"], CodeTokenStyle(ink: .title)),
        (["built_in"], CodeTokenStyle(ink: .type)),
        (["symbol"], CodeTokenStyle(ink: .builtin)),
        (["string", "subst"], CodeTokenStyle(ink: .text)),
        (["section"], CodeTokenStyle(ink: .section, isBold: true)),
        (["section", "emphasis"], CodeTokenStyle(ink: .text, isBold: true, isItalic: true)),
        (["link"], CodeTokenStyle(ink: .link, isUnderlined: true)),
        (["addition"], CodeTokenStyle(ink: .addition, ground: .addition)),
        (["deletion"], CodeTokenStyle(ink: .deletion, ground: .deletion)),
        (["punctuation"], CodeTokenStyle()),
        (["tag", "name"], CodeTokenStyle(ink: .tag)),
        (["tag", "attr"], CodeTokenStyle(ink: .attribute)),
    ]

    @Test("Scopes resolve as Discord's stylesheet cascades them", arguments: styleVectors)
    func styles(scopes: [String], expected: CodeTokenStyle) {
        #expect(CodeTokenStyle.resolve(scopes) == expected)
    }

    @Test("The colours land on the text")
    func applied() async throws {
        let code = "let answer = 42"
        let tokens = try #require(await CodeHighlighter.shared.tokens(for: code, language: "swift"))
        let palette = CodePalette(room: .dark)
        let text = CodeText.highlighted(code, tokens: tokens, palette: palette)
        let keyword = text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let number = text.attribute(.foregroundColor, at: 13, effectiveRange: nil) as? NSColor
        #expect(keyword == palette.keyword)
        #expect(number == palette.number)
    }
}
