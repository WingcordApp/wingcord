import Foundation
import Testing
@testable import WingcordCore

/// Discord's ANSI parser, against Discord's own: every expected value below is
/// what module `626551` (the `ansi-sequence-parser` its arborium experiment
/// draws with) returned for the same input, run in Node — and the strip
/// against `319888`'s regex, as `999915` applies it inline.
@Suite("ANSI escapes")
struct ANSIEscapesTests {
    typealias Span = ANSIEscapes.Span

    static let vectors: [(String, [Span])] = [
        ("plain text", [Span(text: "plain text", foreground: nil, background: nil, decorations: [])]),
        ("\u{1B}[38;2;255;0;0mT\u{1B}[38;2;0;255;0me\u{1B}[38;2;0;0;255ms\u{1B}[38;2;255;0;0mt\u{1B}[0m \u{1B}[38;2;253;152;85mt\u{1B}[0m", [Span(text: "T", foreground: .rgb(red: 255, green: 0, blue: 0), background: nil, decorations: []), Span(text: "e", foreground: .rgb(red: 0, green: 255, blue: 0), background: nil, decorations: []), Span(text: "s", foreground: .rgb(red: 0, green: 0, blue: 255), background: nil, decorations: []), Span(text: "t", foreground: .rgb(red: 255, green: 0, blue: 0), background: nil, decorations: []), Span(text: " ", foreground: nil, background: nil, decorations: []), Span(text: "t", foreground: .rgb(red: 253, green: 152, blue: 85), background: nil, decorations: [])]),
        ("\u{1B}[31mred\u{1B}[0m plain", [Span(text: "red", foreground: .named(1), background: nil, decorations: []), Span(text: " plain", foreground: nil, background: nil, decorations: [])]),
        ("\u{1B}[1;4;32mbold under green\u{1B}[22m not bold\u{1B}[24m", [Span(text: "bold under green", foreground: .named(2), background: nil, decorations: [.bold, .underline]), Span(text: " not bold", foreground: .named(2), background: nil, decorations: [.underline])]),
        ("\u{1B}[31;0mresets first", [Span(text: "resets first", foreground: .named(1), background: nil, decorations: [])]),
        ("\u{1B}[mempty", [Span(text: "empty", foreground: nil, background: nil, decorations: [])]),
        ("\u{1B}[2mdim\u{1B}[22mx", [Span(text: "dim", foreground: nil, background: nil, decorations: [.dim]), Span(text: "x", foreground: nil, background: nil, decorations: [])]),
        ("\u{1B}[1m\u{1B}[2mboth\u{1B}[22mnone", [Span(text: "both", foreground: nil, background: nil, decorations: [.bold, .dim]), Span(text: "none", foreground: nil, background: nil, decorations: [])]),
        ("\u{1B}[38;5;196mcube\u{1B}[38;5;244mgrey\u{1B}[38;5;3mnamed3\u{1B}[38;5;256mpast", [Span(text: "cube", foreground: .table(196), background: nil, decorations: []), Span(text: "grey", foreground: .table(244), background: nil, decorations: []), Span(text: "named3", foreground: .table(3), background: nil, decorations: []), Span(text: "past", foreground: .table(256), background: nil, decorations: [])]),
        ("\u{1B}[48;5;21mbg\u{1B}[49mnone", [Span(text: "bg", foreground: nil, background: .table(21), decorations: []), Span(text: "none", foreground: nil, background: nil, decorations: [])]),
        ("\u{1B}[90mbright black\u{1B}[107mbright white bg", [Span(text: "bright black", foreground: .named(8), background: nil, decorations: []), Span(text: "bright white bg", foreground: .named(8), background: .named(15), decorations: [])]),
        ("\u{1B}[38;2;300;20mbad\u{1B}[0m", [Span(text: "bad", foreground: nil, background: nil, decorations: [])]),
        ("\u{1B}[38;2;10;20mshort", [Span(text: "short", foreground: nil, background: nil, decorations: [])]),
        ("\u{1B}[38:2:255:0:0mcolon", [Span(text: "colon", foreground: nil, background: nil, decorations: [])]),
        ("a\u{1B}[2Jb\u{1B}[?25lc\u{1B}[1 md", [Span(text: "a", foreground: nil, background: nil, decorations: []), Span(text: "b", foreground: nil, background: nil, decorations: []), Span(text: "c", foreground: nil, background: nil, decorations: []), Span(text: "d", foreground: nil, background: nil, decorations: [])]),
        ("\u{1B}[53mover\u{1B}[55mno", [Span(text: "over", foreground: nil, background: nil, decorations: [.overline]), Span(text: "no", foreground: nil, background: nil, decorations: [])]),
        ("\u{1B}[3;9mitalic strike\u{1B}[23;29m", [Span(text: "italic strike", foreground: nil, background: nil, decorations: [.italic, .strikethrough])]),
        ("\u{1B}[7;8mrev hidden\u{1B}[27;28m", [Span(text: "rev hidden", foreground: nil, background: nil, decorations: [.hidden, .reverse])]),
        ("\u{1B}[38;7mx", [Span(text: "x", foreground: nil, background: nil, decorations: [])]),
        ("\u{1B}[5;6mblink\u{1B}[25m", [Span(text: "blink", foreground: nil, background: nil, decorations: [])]),
        ("\u{1B}[12mx\u{1B}[30;40mblack", [Span(text: "x", foreground: nil, background: nil, decorations: []), Span(text: "black", foreground: .named(0), background: .named(0), decorations: [])]),
        ("\u{1B}[38;5;mempty table", [Span(text: "empty table", foreground: nil, background: nil, decorations: [])]),
        ("\u{1B}[38;5;1x5mweird", [Span(text: "5mweird", foreground: nil, background: nil, decorations: [])]),
        ("unterminated \u{1B}[31", [Span(text: "unterminated \u{1B}[31", foreground: nil, background: nil, decorations: [])]),
        ("\u{1B}[31", [Span(text: "\u{1B}[31", foreground: nil, background: nil, decorations: [])]),
        ("\u{1B}", [Span(text: "\u{1B}", foreground: nil, background: nil, decorations: [])]),
        ("", []),
        ("\u{1B}[0m", []),
        ("\u{1B}[31m\u{E9}\u{65E5}\u{672C}\u{1B}[0m\u{1F600}", [Span(text: "\u{E9}\u{65E5}\u{672C}", foreground: .named(1), background: nil, decorations: []), Span(text: "\u{1F600}", foreground: nil, background: nil, decorations: [])]),
        ("x\u{1B}[1;31;42;4mstack\u{1B}[39;49mreset colours", [Span(text: "x", foreground: nil, background: nil, decorations: []), Span(text: "stack", foreground: .named(1), background: .named(2), decorations: [.bold, .underline]), Span(text: "reset colours", foreground: nil, background: nil, decorations: [.bold, .underline])]),
        ("\u{1B}[38;5;016mzero padded", [Span(text: "zero padded", foreground: .table(16), background: nil, decorations: [])]),
        ("\u{1B}[38;2;1;2;3;4mextra", [Span(text: "extra", foreground: .rgb(red: 1, green: 2, blue: 3), background: nil, decorations: [.underline])]),
        // Discord's index is 1e20, past the table, which resolves to no
        // colour — as -1 does here.
        ("\u{1B}[38;5;99999999999999999999mhuge", [Span(text: "huge", foreground: .table(-1), background: nil, decorations: [])]),
    ]

    @Test("Spans match Discord's parser, quirks included")
    func spans() {
        for (input, expected) in Self.vectors {
            #expect(ANSIEscapes.spans(in: input) == expected, "\(input.debugDescription)")
        }
    }

    @Test("The text a block spells has no escapes left")
    func plainText() {
        let input = "\u{1B}[38;2;255;0;0mT\u{1B}[38;2;0;255;0me\u{1B}[0m \u{1B}[2Jok"
        #expect(ANSIEscapes.plainText(of: input) == "Te ok")
    }

    @Test("The 256 table past the sixteen")
    func table() {
        let expected = ["#000000", "#00005f", "#000087", "#0000af", "#0000d7", "#0000ff", "#005f00", "#005f5f", "#005f87", "#005faf", "#005fd7", "#005fff", "#008700", "#00875f", "#008787", "#0087af", "#0087d7", "#0087ff", "#00af00", "#00af5f", "#00af87", "#00afaf", "#00afd7", "#00afff", "#00d700", "#00d75f", "#00d787", "#00d7af", "#00d7d7", "#00d7ff", "#00ff00", "#00ff5f", "#00ff87", "#00ffaf", "#00ffd7", "#00ffff", "#5f0000", "#5f005f", "#5f0087", "#5f00af", "#5f00d7", "#5f00ff", "#5f5f00", "#5f5f5f", "#5f5f87", "#5f5faf", "#5f5fd7", "#5f5fff", "#5f8700", "#5f875f", "#5f8787", "#5f87af", "#5f87d7", "#5f87ff", "#5faf00", "#5faf5f", "#5faf87", "#5fafaf", "#5fafd7", "#5fafff", "#5fd700", "#5fd75f", "#5fd787", "#5fd7af", "#5fd7d7", "#5fd7ff", "#5fff00", "#5fff5f", "#5fff87", "#5fffaf", "#5fffd7", "#5fffff", "#870000", "#87005f", "#870087", "#8700af", "#8700d7", "#8700ff", "#875f00", "#875f5f", "#875f87", "#875faf", "#875fd7", "#875fff", "#878700", "#87875f", "#878787", "#8787af", "#8787d7", "#8787ff", "#87af00", "#87af5f", "#87af87", "#87afaf", "#87afd7", "#87afff", "#87d700", "#87d75f", "#87d787", "#87d7af", "#87d7d7", "#87d7ff", "#87ff00", "#87ff5f", "#87ff87", "#87ffaf", "#87ffd7", "#87ffff", "#af0000", "#af005f", "#af0087", "#af00af", "#af00d7", "#af00ff", "#af5f00", "#af5f5f", "#af5f87", "#af5faf", "#af5fd7", "#af5fff", "#af8700", "#af875f", "#af8787", "#af87af", "#af87d7", "#af87ff", "#afaf00", "#afaf5f", "#afaf87", "#afafaf", "#afafd7", "#afafff", "#afd700", "#afd75f", "#afd787", "#afd7af", "#afd7d7", "#afd7ff", "#afff00", "#afff5f", "#afff87", "#afffaf", "#afffd7", "#afffff", "#d70000", "#d7005f", "#d70087", "#d700af", "#d700d7", "#d700ff", "#d75f00", "#d75f5f", "#d75f87", "#d75faf", "#d75fd7", "#d75fff", "#d78700", "#d7875f", "#d78787", "#d787af", "#d787d7", "#d787ff", "#d7af00", "#d7af5f", "#d7af87", "#d7afaf", "#d7afd7", "#d7afff", "#d7d700", "#d7d75f", "#d7d787", "#d7d7af", "#d7d7d7", "#d7d7ff", "#d7ff00", "#d7ff5f", "#d7ff87", "#d7ffaf", "#d7ffd7", "#d7ffff", "#ff0000", "#ff005f", "#ff0087", "#ff00af", "#ff00d7", "#ff00ff", "#ff5f00", "#ff5f5f", "#ff5f87", "#ff5faf", "#ff5fd7", "#ff5fff", "#ff8700", "#ff875f", "#ff8787", "#ff87af", "#ff87d7", "#ff87ff", "#ffaf00", "#ffaf5f", "#ffaf87", "#ffafaf", "#ffafd7", "#ffafff", "#ffd700", "#ffd75f", "#ffd787", "#ffd7af", "#ffd7d7", "#ffd7ff", "#ffff00", "#ffff5f", "#ffff87", "#ffffaf", "#ffffd7", "#ffffff", "#080808", "#121212", "#1c1c1c", "#262626", "#303030", "#3a3a3a", "#444444", "#4e4e4e", "#585858", "#626262", "#6c6c6c", "#767676", "#808080", "#8a8a8a", "#949494", "#9e9e9e", "#a8a8a8", "#b2b2b2", "#bcbcbc", "#c6c6c6", "#d0d0d0", "#dadada", "#e4e4e4", "#eeeeee"]
        for (offset, hex) in expected.enumerated() {
            let rgb = ANSIEscapes.tableRGB(16 + offset)
            let made = rgb.map { String(format: "#%02x%02x%02x", $0.red, $0.green, $0.blue) }
            #expect(made == hex, "index \(16 + offset)")
        }
        #expect(ANSIEscapes.tableRGB(15) == nil)
        #expect(ANSIEscapes.tableRGB(256) == nil)
    }

    @Test("Inline, only the style sequences come out", arguments: [
        ("\u{1B}[31mred\u{1B}[0m", "red"),
        ("\u{1B}[1;m", "\u{1B}[1;m"),
        ("\u{1B}[38;2;1;2;3m", ""),
        ("\u{1B}[38:5:2mx", "x"),
        ("\u{1B}[2J", "\u{1B}[2J"),
        ("\u{1B}[m", "\u{1B}[m"),
        ("a\u{1B}[12;34;56mb", "ab"),
        ("\u{1B}[1;2;m", "\u{1B}[1;2;m"),
    ])
    func strip(input: String, output: String) {
        #expect(ANSIEscapes.strippingStyleSequences(from: input) == output)
    }
}
