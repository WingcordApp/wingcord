import Foundation
import Testing
@testable import WingcordCore

/// The search field's filter grammar.
///
/// **The tokens are the query** — see `AppModel.runSearch()` — so a parse that
/// gets a token wrong does not fail loudly. It searches for the literal words
/// `from:` and `alex`, finds nothing, and reads as an empty server.
@Suite("Message search tokens")
struct MessageSearchTokenTests {

    // MARK: Parsing

    /// The rendering Discord's own field uses: a space after the colon.
    @Test("A token parses with or without the space Discord renders")
    func spacingIsAccepted() {
        for text in ["from: alexsample", "from:alexsample"] {
            let parsed = MessageSearchTokenizer.parse(text, endsOpen: false)
            #expect(parsed.tokens == [.init(kind: .from, value: "alexsample")])
            #expect(parsed.content.isEmpty)
        }
    }

    /// `in` is the keyword; `channel` is only the case name, because `in` is a
    /// Swift keyword.
    @Test("Every key the field accepts", arguments: [
        ("from: a", MessageSearchToken.Kind.from),
        ("mentions: a", .mentions),
        ("in: a", .channel),
        ("has: link", .has),
        ("pinned: true", .pinned),
        ("before: 2026-09-07", .before),
        ("after: 2026-09-07", .after),
        ("during: 2026-09-07", .during),
    ])
    func keys(text: String, kind: MessageSearchToken.Kind) {
        let parsed = MessageSearchTokenizer.parse(text, endsOpen: false)
        #expect(parsed.tokens.first?.kind == kind)
    }

    @Test("Words that are not tokens are the content")
    func contentIsWhatIsLeft() {
        let parsed = MessageSearchTokenizer.parse(
            "hey from: alexsample speaking of which", endsOpen: false
        )
        #expect(parsed.tokens == [.init(kind: .from, value: "alexsample")])
        #expect(parsed.content == "hey speaking of which")
    }

    /// A colon in ordinary prose is not a filter.
    @Test("An unknown key is left as words")
    func unknownKeysAreContent() {
        let parsed = MessageSearchTokenizer.parse("http://example.com note: this", endsOpen: false)
        #expect(parsed.tokens.isEmpty)
        #expect(parsed.content.contains("note:"))
    }

    // MARK: What is being typed

    /// **`editing` is what a suggestion list is for.** `from:` on its own offers
    /// everybody; that is the screenshot.
    @Test("A trailing key with no value is the token being typed")
    func trailingKeyIsEditing() {
        let parsed = MessageSearchTokenizer.parse("from:")
        #expect(parsed.editing == .init(kind: .from, value: ""))
        #expect(parsed.tokens.isEmpty)
    }

    /// **The space after the colon does not finish the token.** `from: ` is the
    /// caret waiting for a value — the screenshot's state, with the whole list
    /// showing — while `from: alex ` is finished. Telling those apart is the
    /// difference between an autocomplete that appears and one that never does.
    @Test("A key followed by a space is still being typed")
    func trailingSpaceAfterKeyIsStillEditing() {
        let parsed = MessageSearchTokenizer.parse("from: ")
        #expect(parsed.editing == .init(kind: .from, value: ""))
        #expect(parsed.tokens.isEmpty)
    }

    @Test("A partial value is the token being typed")
    func partialValueIsEditing() {
        let parsed = MessageSearchTokenizer.parse("from: al")
        #expect(parsed.editing == .init(kind: .from, value: "al"))
    }

    /// **Submission is not typing.** A trailing bare `from:` is an unfinished
    /// thought, and sending it as an empty filter would narrow nothing while
    /// looking like it narrowed something.
    @Test("A bare key is dropped on submission rather than sent empty")
    func bareKeyIsDroppedOnSubmit() {
        let parsed = MessageSearchTokenizer.parse("hey from:", endsOpen: false)
        #expect(parsed.editing == nil)
        #expect(parsed.tokens == [.init(kind: .from, value: "")])
        #expect(parsed.content == "hey")
    }

    /// A finished token followed by a space is no longer being edited — the next
    /// thing typed is a new word, not more of that value.
    @Test("A completed token stops being the one edited")
    func completedTokenIsNotEditing() {
        let parsed = MessageSearchTokenizer.parse("from: alexsample ")
        #expect(parsed.editing == nil)
        #expect(parsed.tokens == [.init(kind: .from, value: "alexsample")])
    }

    // MARK: Completing

    /// Picking a suggestion replaces the partial and leaves a trailing space, so
    /// choosing two filters in a row is one gesture.
    @Test("Completing replaces the partial and is ready for the next word")
    func completingReplacesThePartial() {
        let completed = MessageSearchTokenizer.completing(
            "from: al", with: .init(kind: .from, value: "alexsample")
        )
        #expect(completed == "from: alexsample ")
    }

    /// The value typed as its own chunk — `from:` then a space then `al` — has
    /// to take both chunks with it, or the key is left behind twice.
    @Test("Completing a value typed after the colon consumes the key too")
    func completingConsumesASplitKey() {
        let completed = MessageSearchTokenizer.completing(
            "hey from: al", with: .init(kind: .from, value: "alexsample")
        )
        #expect(completed == "hey from: alexsample ")
    }

    @Test("Completing a bare key fills its value")
    func completingABareKey() {
        let completed = MessageSearchTokenizer.completing(
            "from:", with: .init(kind: .from, value: "alexsample")
        )
        #expect(completed == "from: alexsample ")
    }

    /// Words already typed survive.
    @Test("Completing keeps the content around it")
    func completingKeepsContent() {
        let completed = MessageSearchTokenizer.completing(
            "hey speaking mentions:", with: .init(kind: .mentions, value: "alexsample")
        )
        #expect(completed == "hey speaking mentions: alexsample ")
    }

    /// A round trip: what the sheet renders must parse back to the same filters.
    @Test("A rendered token parses back to itself")
    func roundTrip() {
        let token = MessageSearchToken(kind: .has, value: "image")
        let parsed = MessageSearchTokenizer.parse(token.text, endsOpen: false)
        #expect(parsed.tokens == [token])
    }

    @Test("Keys are case-insensitive, because a field is typed into")
    func keysAreCaseInsensitive() {
        let parsed = MessageSearchTokenizer.parse("FROM: alex In: general", endsOpen: false)
        #expect(parsed.tokens.map(\.kind) == [.from, .channel])
    }
}
