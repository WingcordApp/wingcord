import Foundation
import Testing
@testable import WingcordCore

/// The parser's contract, case by case.
///
/// Most of these are cases the dialect gets wrong if written naively, and each
/// one is here because getting it wrong is visible in a transcript rather than
/// because it is theoretically interesting.
@Suite("Markdown parser")
struct MarkdownParserTests {
    let parser = MarkdownParser()

    private func inline(_ source: String) -> [InlineNode] {
        parser.parseInline(source)
    }

    private func blocks(_ source: String) -> [BlockNode] {
        parser.parse(source).blocks
    }

    // MARK: Emphasis

    @Test("Plain text is one node and one allocation")
    func plainText() {
        #expect(inline("hello world") == [.text("hello world")])
    }

    @Test("Asterisk emphasis by run length")
    func asteriskEmphasis() {
        #expect(inline("*a*") == [.styled(.italic, [.text("a")])])
        #expect(inline("**a**") == [.styled(.bold, [.text("a")])])
        #expect(inline("***a***") == [.styled([.bold, .italic], [.text("a")])])
    }

    @Test("Underscore emphasis, and the underline pair")
    func underscoreEmphasis() {
        #expect(inline("_a_") == [.styled(.italic, [.text("a")])])
        #expect(inline("__a__") == [.styled(.underline, [.text("a")])])
    }

    @Test("snake_case survives, because underscore needs a word boundary")
    func snakeCaseIsNotEmphasis() {
        #expect(inline("snake_case_name") == [.text("snake_case_name")])
    }

    @Test("Asterisks inside a word still emphasise, matching Discord")
    func asteriskInsideWord() {
        let nodes = inline("a*b*c")
        #expect(nodes == [.text("a"), .styled(.italic, [.text("b")]), .text("c")])
    }

    @Test("A lone marker is literal, never an unterminated span")
    func loneMarkerIsLiteral() {
        #expect(inline("2 * 3 = 6") == [.text("2 * 3 = 6")])
        #expect(inline("a ~ b") == [.text("a ~ b")])
        #expect(inline("|") == [.text("|")])
    }

    @Test("Strikethrough and spoiler need doubled markers")
    func doubledOnlyMarkers() {
        #expect(inline("~~gone~~") == [.styled(.strikethrough, [.text("gone")])])
        #expect(inline("||secret||") == [.styled(.spoiler, [.text("secret")])])
        #expect(inline("~one~") == [.text("~one~")])
    }

    @Test("Emphasis nests")
    func nestedEmphasis() {
        let nodes = inline("**bold and _italic_**")
        #expect(nodes == [
            .styled(.bold, [.text("bold and "), .styled(.italic, [.text("italic")])])
        ])
    }

    @Test("A span does not open on whitespace")
    func noOpenOnWhitespace() {
        #expect(inline("* not italic *") == [.text("* not italic *")])
    }

    // MARK: Code

    @Test("Inline code is literal inside")
    func inlineCodeIsLiteral() {
        #expect(inline("`**not bold**`") == [.code("**not bold**")])
    }

    @Test("A doubled fence lets a backtick live inside the span")
    func doubledInlineFence() {
        #expect(inline("``has ` inside``") == [.code("has ` inside")])
    }

    @Test("One leading and trailing space is stripped from a code span")
    func codeSpanPadding() {
        #expect(inline("`` ` ``") == [.code("`")])
    }

    @Test("Code inside emphasis does not close the emphasis")
    func codeDoesNotCloseEmphasis() {
        let nodes = inline("*a `b*c` d*")
        #expect(nodes == [.styled(.italic, [.text("a "), .code("b*c"), .text(" d")])])
    }

    @Test("A fenced block keeps its language and its content verbatim")
    func fencedCodeBlock() {
        let result = blocks("```swift\nlet x = **1**\n```")
        #expect(result == [.codeBlock(language: "swift", code: "let x = **1**")])
    }

    @Test("An unclosed fence runs to the end rather than reverting to prose")
    func unclosedFence() {
        let result = blocks("```\nstill code")
        #expect(result == [.codeBlock(language: nil, code: "still code")])
    }

    // MARK: Escapes

    @Test("A backslash escapes punctuation and nothing else")
    func escapes() {
        #expect(inline(#"\*not italic\*"# ) == [.text("*not italic*")])
    }

    @Test("A Windows path keeps its backslashes")
    func windowsPathSurvives() {
        #expect(inline(#"C:\Users\alex"#) == [.text(#"C:\Users\alex"#)])
    }

    // MARK: Mentions and tokens

    @Test("Every mention form resolves")
    func mentions() {
        #expect(inline("<@123>") == [.userMention(UserID(rawValue: 123))])
        #expect(inline("<@!123>") == [.userMention(UserID(rawValue: 123))])
        #expect(inline("<@&456>") == [.roleMention(RoleID(rawValue: 456))])
        #expect(inline("<#789>") == [.channelMention(ChannelID(rawValue: 789))])
    }

    @Test("Custom emoji, static and animated")
    func customEmoji() {
        #expect(inline("<:blob:12>") == [
            .customEmoji(EmojiRef(id: EmojiID(rawValue: 12), name: "blob", isAnimated: false))
        ])
        #expect(inline("<a:spin:34>") == [
            .customEmoji(EmojiRef(id: EmojiID(rawValue: 34), name: "spin", isAnimated: true))
        ])
    }

    @Test("A timestamp carries its style, defaulting to short date-time")
    func timestamps() {
        #expect(inline("<t:0:R>") == [.timestamp(Date(timeIntervalSince1970: 0), .relative)])
        #expect(inline("<t:0>") == [.timestamp(Date(timeIntervalSince1970: 0), .shortDateTime)])
    }

    @Test("Malformed angle tokens stay literal")
    func malformedAngleTokens() {
        #expect(inline("<@abc>") == [.text("<@abc>")])
        #expect(inline("a < b > c") == [.text("a < b > c")])
    }

    @Test("Mass mentions become nodes, and can be switched off")
    func massMentions() {
        #expect(inline("@everyone") == [.everyoneMention])
        #expect(inline("@here") == [.hereMention])
        var quiet = MarkdownParser(options: .init(allowsMassMentions: false))
        #expect(quiet.parseInline("@everyone") == [.text("@everyone")])
        quiet.options = .message
        #expect(quiet.parseInline("@everyone") == [.everyoneMention])
    }

    // MARK: Links

    @Test("A masked link keeps its label and its URL")
    func maskedLink() {
        #expect(inline("[docs](https://example.com)") == [
            .link(label: [.text("docs")], url: "https://example.com")
        ])
    }

    @Test("A non-http scheme is refused and left as text")
    func unsafeSchemeRefused() {
        let nodes = inline("[click](javascript:alert(1))")
        #expect(nodes == [.text("[click](javascript:alert(1))")])
    }

    @Test("A bare URL autolinks, and trailing punctuation stays in the sentence")
    func autoLink() {
        #expect(inline("see https://example.com now") == [
            .text("see "), .autoLink("https://example.com"), .text(" now"),
        ])
        #expect(inline("see https://example.com.") == [
            .text("see "), .autoLink("https://example.com"), .text("."),
        ])
    }

    @Test("A balanced closing paren stays in the URL")
    func autoLinkKeepsBalancedParen() {
        let nodes = inline("https://en.wikipedia.org/wiki/Swift_(language)")
        #expect(nodes == [.autoLink("https://en.wikipedia.org/wiki/Swift_(language)")])
    }

    @Test("An angle-wrapped URL is a suppressed-embed link")
    func angleWrappedURL() {
        #expect(inline("<https://example.com>") == [.autoLink("https://example.com")])
    }

    // MARK: Blocks

    @Test("Headings stop at three hashes and need a space")
    func headings() {
        #expect(blocks("# One") == [.heading(level: 1, [.text("One")])])
        #expect(blocks("### Three") == [.heading(level: 3, [.text("Three")])])
        #expect(blocks("#### Four") == [.paragraph([.text("#### Four")])])
        #expect(blocks("#nospace") == [.paragraph([.text("#nospace")])])
    }

    @Test("Subtext")
    func subtext() {
        #expect(blocks("-# quiet") == [.subtext([.text("quiet")])])
    }

    @Test("A quote gathers its whole run and parses one level in")
    func quotes() {
        let result = blocks("> **a**\n> b")
        #expect(result == [
            .quote([.paragraph([.styled(.bold, [.text("a")]), .lineBreak, .text("b")])])
        ])
    }

    @Test("A bare greater-than is not a quote")
    func bareGreaterThanIsNotAQuote() {
        #expect(blocks("2 > 1") == [.paragraph([.text("2 > 1")])])
    }

    @Test("Lists, ordered and not")
    func lists() {
        #expect(blocks("- a\n- b") == [
            .list(ordered: false, startIndex: 1, items: [
                [.paragraph([.text("a")])], [.paragraph([.text("b")])],
            ])
        ])
        #expect(blocks("3. a") == [
            .list(ordered: true, startIndex: 3, items: [[.paragraph([.text("a")])]])
        ])
    }

    @Test("A year at the start of a line is not a list")
    func yearIsNotAList() {
        #expect(blocks("2026. what a year") == [.paragraph([.text("2026. what a year")])])
    }

    @Test("A soft newline inside a paragraph is a real break")
    func softBreaksArePreserved() {
        #expect(blocks("a\nb") == [.paragraph([.text("a"), .lineBreak, .text("b")])])
    }

    @Test("Block syntax can be switched off for single-line surfaces")
    func inlineOnlyOptions() {
        let preview = MarkdownParser(options: .inlineOnly)
        #expect(preview.parse("# not a heading").blocks == [
            .paragraph([.text("# not a heading")])
        ])
    }

    // MARK: Plain text folding

    @Test("Plain text folds the whole tree for one accessibility label")
    func plainTextFolding() {
        let document = parser.parse("# Title\n**bold** and <@1> and `code`")
        #expect(document.plainText == "Title\nbold and @user and code")
    }

    // MARK: Robustness

    @Test("Pathological input terminates and loses nothing")
    func pathologicalInput() {
        let stars = String(repeating: "*", count: 500)
        #expect(!parser.parse(stars).blocks.isEmpty)

        let brackets = String(repeating: "[", count: 500)
        #expect(!parser.parse(brackets).blocks.isEmpty)

        let angles = String(repeating: "<", count: 500)
        #expect(!parser.parse(angles).blocks.isEmpty)

        // Deeply nested emphasis must stop recursing, not stack-overflow.
        let nested = String(repeating: "**", count: 40) + "x" + String(repeating: "**", count: 40)
        #expect(!parser.parse(nested).blocks.isEmpty)
    }

    @Test("Empty and whitespace input")
    func emptyInput() {
        #expect(parser.parse("").isEmpty)
        #expect(parser.parse("\n\n").blocks.count <= 2)
    }

    @Test("Non-ASCII text passes through byte scanning intact")
    func unicodePassesThrough() {
        let source = "héllo 🌍 日本語 **bold**"
        let nodes = inline(source)
        #expect(nodes == [.text("héllo 🌍 日本語 "), .styled(.bold, [.text("bold")])])
    }
}
