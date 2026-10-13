import Foundation
import Testing
@testable import WingcordCore

/// Discord's text preview, against Discord's own functions: every expected
/// value below is what `639169.C`, `417964.sJ`, `255438.up` and `684519`'s
/// `eS` and `eI` returned for the same input, run in Node.
@Suite("Plaintext preview")
struct PlaintextPreviewTests {
    private let english = Locale(identifier: "en_US")

    @Test("Which files are previewed, by the case-sensitive end of the name", arguments: [
        ("notes.txt", true),
        ("notes.TXT", false),
        ("README", false),
        ("a.tar.gz", false),
        ("x.swift", true),
        ("x.SAS", true),
        ("x.sas", true),
        ("log", true),
        ("app.log", true),
        ("data.csv", true),
        ("pic.svg", true),
        ("Makefile", false),
        ("makefile", true),
        ("x.cmake.in", false),
        ("x.in", false),
        ("x.", false),
        ("x.md", true),
        ("x.html.hbs", true),
        ("x.hbs", true),
    ])
    func previewable(name: String, expected: Bool) {
        #expect(PlaintextPreview.isPreviewable(filename: name) == expected)
    }

    @Test("The text is cleaned as Discord cleans it", arguments: [
        ("plain", "plain"),
        ("a\r\nb\r\n", "a\nb\n"),
        ("tab\there", "tab\there"),
        ("zwj\u{200D}x", "zwjx"),
        ("nbsp\u{A0}x", "nbspx"),
        ("bom\u{FEFF}x", "bomx"),
        ("ls\u{2028}x", "lsx"),
        ("bell\u{7}x", "bellx"),
        ("filler\u{3164}x", "fillerx"),
        ("em\u{2003}space", "emspace"),
        ("rtl\u{202E}x", "rtlx"),
        ("keep \u{E9}\u{E8} \u{1F600}", "keep \u{E9}\u{E8} \u{1F600}"),
        ("soft\u{AD}hyphen", "softhyphen"),
        ("nl\nok", "nl\nok"),
    ])
    func sanitised(text: String, expected: String) {
        #expect(PlaintextPreview.sanitise(text) == expected)
    }

    @Test("Sizes are Discord's, rounded up in thousands", arguments: [
        (0, "0 KB"),
        (1, "1 KB"),
        (999, "1 KB"),
        (1000, "1 KB"),
        (1001, "2 KB"),
        (14000, "14 KB"),
        (14072, "15 KB"),
        (999999, "1,000 KB"),
        (1000000, "1 MB"),
        (1000001, "2 MB"),
        (999000000, "999 MB"),
        (999000001, "1 GB"),
        (1500000000, "1.5 GB"),
        (1949999999, "2 GB"),
        (2050000000, "2.1 GB"),
    ])
    func size(bytes: Int, expected: String) {
        #expect(PlaintextPreview.fileSize(bytes, locale: english) == expected)
    }

    @Test("Expand and Collapse say how many lines", arguments: [
        (false, 12, true, "Expand (12 lines)"),
        (true, 12, true, "Collapse (12 lines)"),
        (false, 1204, false, "Expand (More than 1,204 lines)"),
        (false, 1, true, "Expand (1 line)"),
    ])
    func toggle(isExpanded: Bool, lines: Int, isWhole: Bool, expected: String) {
        #expect(PlaintextPreview.toggleTitle(isExpanded: isExpanded, lineCount: lines, isWholeFile: isWhole, locale: english) == expected)
    }

    private static let body = (1...120).map { "line \($0)" }.joined(separator: "\n")
    private static let short = "one\ntwo\nthree"

    @Test("The card shows six lines or a hundred, and says what it leaves out", arguments: [
        ("body", false, 0, "", 120, true, 6),
        ("body", false, 12345, "... (13 KB left)", 120, true, 6),
        ("body", true, 0, "\n... (20 lines)", 120, true, 100),
        ("body", true, 12345, "... (13 KB left)", 120, true, 100),
        ("short", false, 0, "", 3, false, 3),
        ("short", false, 12345, "... (13 KB left)", 3, false, 3),
        ("short", true, 0, "", 3, true, 3),
        ("short", true, 12345, "... (13 KB left)", 3, true, 3),
    ])
    func card(name: String, isExpanded: Bool, bytesLeft: Int, notice: String, lineCount: Int, offersToggle: Bool, shown: Int) {
        let contents = name == "body" ? Self.body : Self.short
        let excerpt = PlaintextPreview.excerpt(of: contents, isExpanded: isExpanded, bytesLeft: bytesLeft, locale: english)
        #expect(excerpt.notice == notice)
        #expect(excerpt.lineCount == lineCount)
        #expect(excerpt.offersToggle == offersToggle)
        #expect(excerpt.text.components(separatedBy: "\n").count == shown)
    }

    @Test("What is left is the total less what came")
    func bytesLeft() {
        #expect(PlaintextPreview.bytesLeft(contentRange: "bytes 0-50000/123456", contentLength: "50001") == 73455)
        #expect(PlaintextPreview.bytesLeft(contentRange: "bytes 0-99/100", contentLength: "100") == 0)
        #expect(PlaintextPreview.bytesLeft(contentRange: nil, contentLength: "100") == 0)
        #expect(PlaintextPreview.bytesLeft(contentRange: "bytes 0-1/*", contentLength: "2") == 0)
        #expect(PlaintextPreview.bytesLeft(contentRange: "bytes 0-9/100", contentLength: nil) == 99)
    }

    @Test("Decoded by the charset, the cut character dropped, then cleaned")
    func decoding() {
        let latin = Data([0x63, 0x61, 0x66, 0xE9])
        #expect(PlaintextPreview.text(of: latin, contentType: "text/plain; charset=iso-8859-1", bytesLeft: 0) == "caf\u{E9}")
        #expect(PlaintextPreview.text(of: Data("a\r\nb".utf8), contentType: "text/plain", bytesLeft: 0) == "a\nb")
        // A cut inside "é": the half character goes, and so does nothing else.
        let cut = Data("abc\u{E9}".utf8).dropLast()
        #expect(PlaintextPreview.text(of: cut, contentType: nil, bytesLeft: 10) == "abc")
        #expect(PlaintextPreview.text(of: Data("x".utf8), contentType: "application/octet-stream; charset=nonsense", bytesLeft: 0) == nil)
        #expect(PlaintextPreview.text(of: Data("x".utf8), contentType: "text/plain; charset=nonsense", bytesLeft: 0) == "x")
    }

    @Test("The language is the end of the name, and Markdown is four of them")
    func language() {
        #expect(PlaintextPreview.language(ofFilename: "notes.tar.md") == "md")
        #expect(PlaintextPreview.markdownLanguages == ["markdown", "md", "mkd", "mkdown"])
        #expect(PlaintextPreview.languages.count == 384)
        #expect(PlaintextPreview.languages.prefix(3) == ["1c", "4d", "abnf"])
    }
}
