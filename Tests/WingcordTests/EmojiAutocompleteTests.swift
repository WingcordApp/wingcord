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

    /// **The fixture is the catalog, and that is the point of this test.**
    ///
    /// It used to pass a lone server section and assert that Unicode appeared
    /// anyway — which was true because `matches` walked Unicode a second time
    /// on its own. `EmojiCatalog` has appended the nine Unicode sections for a
    /// long time, so in the running app that second walk found everything
    /// twice: `:cry` listed `:cry:`, `:crying_cat_face:` and `:crystal_ball:`
    /// two times each. A fixture that did not look like the caller's input is
    /// what let it survive.
    @Test("The account's own emoji lead, and nothing is listed twice")
    func customEmojiLead() {
        let matches = EmojiAutocomplete.matches(for: "sob", custom: Self.catalog)
        #expect(matches.first?.name == "sobbing_cat")
        // Unicode still follows, because the catalog carries it.
        #expect(matches.contains { $0.name == "sob" })
        #expect(Set(matches.map(\.name)).count == matches.count)
    }

    /// The other duplicate, and it is not the same bug: an account in two
    /// servers that both use `:blobcat:` has two catalog entries with two ids
    /// and one name. Offering the reader the same picture twice is a choice
    /// with no difference in it.
    @Test("The same emoji in two servers is offered once")
    func duplicateAcrossServers() {
        let first = ExpressionSection(
            id: "g1", title: "One", badge: .glyph("😀"),
            items: [ExpressionItem(
                id: "1", art: .image(nil, animated: false),
                name: "blobcat", pick: .insert("<:blobcat:1>")
            )]
        )
        let second = ExpressionSection(
            id: "g2", title: "Two", badge: .glyph("😀"),
            items: [ExpressionItem(
                id: "2", art: .image(nil, animated: false),
                name: "blobcat", pick: .insert("<:blobcat:2>")
            )]
        )
        let matches = EmojiAutocomplete.matches(for: "blob", custom: [first, second])
        #expect(matches.filter { $0.name == "blobcat" }.count == 1)
    }

    /// What the composer actually hands over: the account's own emoji first,
    /// then Unicode's categories — which is what `EmojiCatalog` builds.
    private static var catalog: [ExpressionSection] {
        let server = ExpressionSection(
            id: "g",
            title: "Server",
            badge: .glyph("😀"),
            items: [ExpressionItem(
                id: "1", art: .image(nil, animated: false),
                name: "sobbing_cat", pick: .insert("<:sobbing_cat:1>")
            )]
        )
        return [server] + AppModel.unicodeSections(tone: .default)
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

/// A shortcode the reader typed all the way through.
///
/// **`:sob:` becomes the emoji without Tab** — the closing colon is somebody
/// saying they are finished, and the completion list could only act on a
/// keypress. The boundary rules are the open scanner's plus that colon, which
/// is what keeps `12:30:` and `https://a:b:` out of it.
@Suite("Finished shortcodes")
struct ClosedShortcodeTests {

    @Test("A finished shortcode is recognised")
    func recognisesAFinishedOne() {
        #expect(EmojiAutocomplete.closedShortcode(in: ":sob:") == "sob")
        #expect(EmojiAutocomplete.closedShortcode(in: "well :sob:") == "sob")
        #expect(EmojiAutocomplete.closedShortcode(in: "a\n:sob:") == "sob")
    }

    @Test("An unfinished one is not")
    func ignoresAnUnfinishedOne() {
        #expect(EmojiAutocomplete.closedShortcode(in: ":sob") == nil)
        #expect(EmojiAutocomplete.closedShortcode(in: "well :so") == nil)
    }

    /// The whole reason the opening colon needs a boundary: a time, a ratio and
    /// a URL scheme all end in the same shape.
    @Test("A colon that follows a word does not open one")
    func wordBoundaryHolds() {
        #expect(EmojiAutocomplete.closedShortcode(in: "12:30:") == nil)
        #expect(EmojiAutocomplete.closedShortcode(in: "https://a:b:") == nil)
    }

    @Test("A run with whitespace in it is not a shortcode")
    func whitespaceBreaksIt() {
        #expect(EmojiAutocomplete.closedShortcode(in: ": sob:") == nil)
        #expect(EmojiAutocomplete.closedShortcode(in: ":so b:") == nil)
    }

    @Test("Only the trailing one counts")
    func onlyTheTrailingOne() {
        #expect(EmojiAutocomplete.closedShortcode(in: ":tada: and :sob:") == "sob")
        #expect(EmojiAutocomplete.closedShortcode(in: ":tada: and more") == nil)
    }

    /// **No trailing space**, unlike the list's completion. The reader has
    /// already said where the word ends; adding a space would put one where
    /// they did not.
    @Test("Applying it leaves the caret where the reader left it")
    func appliesWithoutASpace() {
        #expect(EmojiAutocomplete.applyingClosed("😭", to: ":sob:") == "😭")
        #expect(EmojiAutocomplete.applyingClosed("😭", to: "well :sob:") == "well 😭")
        #expect(
            EmojiAutocomplete.applyingClosed("<:a:1>", to: "hi :a:") == "hi <:a:1>"
        )
    }
}
