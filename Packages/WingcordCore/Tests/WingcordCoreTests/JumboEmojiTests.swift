import Foundation
import Testing
@testable import WingcordCore

/// A message made only of emoji is drawn three times the size, and the whole
/// question is what "only of emoji" means.
@Suite("Jumbo emoji")
struct JumboEmojiTests {

    private func document(_ source: String) -> MarkdownDocument {
        MarkdownParser().parse(source)
    }

    @Test("One Unicode emoji on its own")
    func singleUnicode() {
        #expect(document("😀").jumboEmojiCount == 1)
    }

    @Test("A custom emoji on its own")
    func singleCustom() {
        #expect(document("<:blobcat:123>").jumboEmojiCount == 1)
    }

    @Test("Both kinds together, and the spaces between them do not count")
    func mixed() {
        #expect(document("😀 <a:blobdance:456> 🎉").jumboEmojiCount == 3)
    }

    /// **The test the naive implementation fails.** Every digit reports
    /// `isEmoji` true — they are the bases of the keycap sequences — so a check
    /// written on that alone calls a year a row of emoji and draws "2025" at
    /// forty points.
    @Test(
        "Text that merely contains emoji-capable characters is not jumbo",
        arguments: ["2025", "#1", "*", "nice 😀", "😀 nice", "1 2 3"]
    )
    func notEmojiOnly(_ source: String) {
        #expect(document(source).jumboEmojiCount == nil)
    }

    @Test("Structure means the message is saying something", arguments: [
        "# 😀",
        "> 😀",
        "- 😀",
        "```\n😀\n```",
    ])
    func structureIsNotJumbo(_ source: String) {
        #expect(document(source).jumboEmojiCount == nil)
    }

    /// Past the ceiling the row is a wall of pictures rather than a message.
    @Test("A mosaic past the ceiling is drawn small")
    func ceiling() {
        let underLimit = String(repeating: "😀", count: MarkdownDocument.jumboEmojiLimit)
        let overLimit = String(repeating: "😀", count: MarkdownDocument.jumboEmojiLimit + 1)
        #expect(document(underLimit).jumboEmojiCount == MarkdownDocument.jumboEmojiLimit)
        #expect(document(overLimit).jumboEmojiCount == nil)
    }

    @Test("An empty message is not jumbo")
    func empty() {
        #expect(document("").jumboEmojiCount == nil)
    }

    /// A ZWJ family and a flag are single clusters, not the scalars in them.
    @Test("A sequence counts once")
    func sequences() {
        #expect(document("👨‍❤️‍👨").jumboEmojiCount == 1)
        #expect(document("🇬🇧").jumboEmojiCount == 1)
    }
}
