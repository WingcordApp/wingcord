import Testing
@testable import Wingcord
import WingcordCore

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

    /// GitHub #25: `:sob` offers the built-in 😭 first, and a server's own
    /// `sob` under Discord's name for it, `:sob~1:`.
    @Test("The built-in emoji leads on its own name; the server's is sob~1")
    func builtInLeads() {
        let table = Self.table(custom: [("sob", 1, Self.server)])
        let matches = EmojiAutocomplete.matches(for: "sob", table: table)
        #expect(matches.first?.glyph == "😭")
        #expect(matches.contains { $0.name == "sob~1" && $0.id == 1 })
        #expect(Set(matches.map(\.name)).count == matches.count)
    }

    /// Two servers that both have `:blobcat:` give two names, as Discord's
    /// do: this server's keeps the name, the other's is `blobcat~1`.
    @Test("The same name in two servers is two names")
    func duplicateAcrossServers() {
        let table = Self.table(custom: [("blobcat", 1, Self.server), ("blobcat", 2, Self.other)])
        let names = EmojiAutocomplete.matches(for: "blob", table: table).map(\.name)
        #expect(names.contains("blobcat"))
        #expect(names.contains("blobcat~1"))
    }

    /// A locked server's emoji cannot be used in this channel, so offering them
    /// is offering a completion that sends as raw text.
    @Test("What can't be used here is not offered")
    func lockedAreSkipped() {
        let table = Self.table(custom: [("sobbing_cat", 1, Self.other)])
        let matches = EmojiAutocomplete.matches(for: "sob", table: table, offers: { $0.id != 1 })
        #expect(!matches.contains { $0.name == "sobbing_cat" })
    }

    @Test("The list is bounded")
    func listIsBounded() {
        let matches = EmojiAutocomplete.matches(for: "a", table: Self.table(custom: []), limit: 5)
        #expect(matches.count <= 5)
    }

    private static let server = GuildID(rawValue: 1_400_000_000_000_000_911)
    private static let other = GuildID(rawValue: 1_400_000_000_000_000_912)

    /// What the composer hands over: every Unicode name, then the servers'.
    private static func table(custom: [(String, UInt64, GuildID)]) -> EmojiNameTable {
        EmojiNameTable(
            unicode: AppModel.unicodeEmojiNames,
            custom: custom.map { EmojiNameTable.Custom(id: $0.1, name: $0.0, isAnimated: false, owner: .guild($0.2)) }
        )
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
