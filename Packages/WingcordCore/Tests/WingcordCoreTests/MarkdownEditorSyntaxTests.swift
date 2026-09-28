import Testing
@testable import WingcordCore

/// The markup in text being written, by where its markers are — the same
/// rules the transcript draws the message with.
struct MarkdownEditorSyntaxTests {

    private func marked(_ text: String) -> [(MarkdownSpan.Kind, String, String)] {
        let bytes = Array(text.utf8)
        return MarkdownEditorSyntax.spans(in: text).map { span in
            (span.kind,
             String(decoding: bytes[span.open], as: UTF8.self),
             String(decoding: bytes[span.content], as: UTF8.self))
        }
    }

    @Test("Bold, italic and a spoiler, with their markers")
    func inline() {
        let spans = marked("a **bold** and *it* and ||hidden||")
        #expect(spans.contains { $0.0 == .styled(.bold) && $0.1 == "**" && $0.2 == "bold" })
        #expect(spans.contains { $0.0 == .styled(.italic) && $0.1 == "*" && $0.2 == "it" })
        #expect(spans.contains { $0.0 == .styled(.spoiler) && $0.1 == "||" && $0.2 == "hidden" })
    }

    /// Discord's rule: `*` must hug what it wraps.
    @Test("Arithmetic is not emphasis")
    func arithmetic() {
        #expect(marked("a * b * c").isEmpty)
    }

    @Test("Nested emphasis is recorded in the outer text's offsets")
    func nested() {
        let spans = marked("**a __b__ c**")
        #expect(spans.contains { $0.0 == .styled(.underline) && $0.1 == "__" && $0.2 == "b" })
    }

    @Test("A fenced block is code, and nothing inside it is emphasis")
    func fence() {
        let spans = marked("```swift\nlet a = **b**\n```\n**after**")
        #expect(spans.contains { if case .codeBlock = $0.0 { $0.1 == "```swift" } else { false } })
        #expect(!spans.contains { $0.0 == .styled(.bold) && $0.2 == "b" })
        #expect(spans.contains { $0.0 == .styled(.bold) && $0.2 == "after" })
    }

    @Test("Line prefixes and subtext")
    func prefixes() {
        let spans = marked("> quoted\n-# small")
        #expect(spans.contains { $0.0 == .linePrefix && $0.1 == "> " })
        #expect(spans.contains { $0.0 == .subtext && $0.1 == "-# " && $0.2 == "small" })
    }
}
