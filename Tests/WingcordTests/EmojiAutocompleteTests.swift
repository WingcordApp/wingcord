import Testing
@testable import Wingcord

/// The `:shortcode` completion's parsing.
///
/// Every case here is one the composer hits in ordinary typing, and the ones
/// that matter are the **negatives**: a completion list that opens on a URL's
/// scheme or on an already-finished `:tada:` is a list that covers the
/// transcript while somebody is trying to write.
@Suite("Emoji autocomplete")
struct EmojiAutocompleteTests {

    @Test("A colon at the start of a word opens a query")
    func opensOnAWord() {
        #expect(EmojiAutocomplete.query(in: ":sob") == "sob")
        #expect(EmojiAutocomplete.query(in: "hello :sob") == "sob")
        #expect(EmojiAutocomplete.query(in: "hello\n:sob") == "sob")
        #expect(EmojiAutocomplete.query(in: ":SOB") == "sob")
    }

    @Test("One character is not enough to complete on")
    func waitsForTwoCharacters() {
        #expect(EmojiAutocomplete.query(in: ":s") == nil)
        #expect(EmojiAutocomplete.query(in: ":") == nil)
        #expect(EmojiAutocomplete.query(in: ":so") == "so")
    }

    @Test("A colon inside a word is not a shortcode")
    func ignoresColonsInsideWords() {
        #expect(EmojiAutocomplete.query(in: "https://example.com") == nil)
        #expect(EmojiAutocomplete.query(in: "12:30") == nil)
        #expect(EmojiAutocomplete.query(in: "ratio 3:4") == nil)
    }

    @Test("A finished shortcode is left alone")
    func ignoresClosedShortcodes() {
        #expect(EmojiAutocomplete.query(in: ":tada:") == nil)
        #expect(EmojiAutocomplete.query(in: "nice :tada: work") == nil)
    }

    @Test("A space ends the query")
    func spaceEndsTheQuery() {
        #expect(EmojiAutocomplete.query(in: ":so much") == nil)
        #expect(EmojiAutocomplete.query(in: "") == nil)
        #expect(EmojiAutocomplete.query(in: "no colon here") == nil)
    }

    @Test("Committing replaces the token and leaves a separator")
    func commitReplacesTheToken() {
        #expect(EmojiAutocomplete.applying("😭", to: ":sob") == "😭 ")
        #expect(EmojiAutocomplete.applying("😭", to: "hello :sob") == "hello 😭 ")
        // A custom emoji goes in as its inline form, not as a name.
        let custom = "<:party:12345>"
        #expect(EmojiAutocomplete.applying(custom, to: "yes :par") == "yes \(custom) ")
    }

    @Test("The account's own emoji are offered before Unicode's")
    func customEmojiLead() {
        let section = ExpressionSection(
            id: "g",
            title: "Server",
            badge: .glyph("😀"),
            items: [ExpressionItem(
                id: "1", art: .image(nil, animated: false), name: "sobbing_cat", pick: .insert("<:sobbing_cat:1>")
            )]
        )
        let matches = EmojiAutocomplete.matches(for: "sob", custom: [section])
        #expect(matches.first?.name == "sobbing_cat")
        // …and Unicode still fills the rest of the list.
        #expect(matches.contains { $0.name == "sob" })
    }

    /// A locked server's emoji cannot be used in this channel, so offering them
    /// is offering a completion that sends as raw text.
    @Test("A locked server contributes nothing")
    func lockedSectionsAreSkipped() {
        let section = ExpressionSection(
            id: "g",
            title: "Server",
            badge: .glyph("😀"),
            items: [ExpressionItem(
                id: "1", art: .image(nil, animated: false), name: "sobbing_cat", pick: .insert("<:sobbing_cat:1>")
            )],
            isLocked: true
        )
        let matches = EmojiAutocomplete.matches(for: "sob", custom: [section])
        #expect(!matches.contains { $0.name == "sobbing_cat" })
    }

    @Test("The list is bounded")
    func listIsBounded() {
        let matches = EmojiAutocomplete.matches(for: "a", custom: [], limit: 5)
        #expect(matches.count <= 5)
    }
}
