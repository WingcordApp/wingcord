import AppKit
import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// `@time` and `@game`'s inputs, and the chips a picked mention becomes.
struct ComposerMentionTests {

    // MARK: The inputs

    @Test("`@time ` and `@game ` open their inputs, spaces and all")
    func inputTriggers() {
        let time = MentionAutocomplete.trigger(in: "see you @time tomorrow at 5pm")
        #expect(time?.kind == .time)
        #expect(time?.query == "tomorrow at 5pm")
        let game = MentionAutocomplete.trigger(in: "@game grand theft")
        #expect(game?.kind == .game)
        #expect(game?.query == "grand theft")
        // Just opened: an empty query.
        #expect(MentionAutocomplete.trigger(in: "@time ")?.query == "")
    }

    @Test("Without its space the word is still being looked up in the list")
    func wordBeforeItsSpace() {
        let trigger = MentionAutocomplete.trigger(in: "@time")
        #expect(trigger?.kind == .member)
        #expect(trigger?.query == "time")
        // Inside a word, or across a new line, it is nothing.
        #expect(MentionAutocomplete.trigger(in: "alex@time now") == nil)
        #expect(MentionAutocomplete.trigger(in: "@time\nlater") == nil)
    }

    @Test("Picking `@time` writes the word and a space, which opens its input")
    func pickingOpensTheInput() {
        let text = MentionAutocomplete.applying("@time", kind: .member, to: "lunch @ti")
        #expect(text == "lunch @time ")
        #expect(MentionAutocomplete.trigger(in: text)?.kind == .time)
        // And a picked time replaces the whole input.
        let picked = MentionAutocomplete.applying("<t:1790856000:s>", kind: .time, to: text + "tomorrow")
        #expect(picked == "lunch <t:1790856000:s> ")
    }

    @Test("Game searches are keyed as Discord keys them, and answered by the closest start")
    func gameSearchKeys() {
        #expect(GameMentionSearch.normalized("  Grand_Theft ") == "grand theft")
        #expect(GameMentionSearch.normalized("   ") == nil)
        var search = GameMentionSearch()
        let gta = GameSummary(id: ApplicationID(rawValue: 1), name: "Grand Theft Auto V")
        search.results["grand"] = [gta]
        #expect(search.closestResults(for: "grand th")?.first?.name == "Grand Theft Auto V")
        #expect(search.closestResults(for: "zelda") == nil)
        // Seven letters that found nothing: longer will not either.
        search.results["nothing"] = []
        #expect(search.isPointless("nothing at all"))
        search.results["noth"] = []
        #expect(!search.isPointless("nothx"))
    }

    @Test("Game mentions are found in a message as Discord's extractor finds them")
    func gameMentionIDs() {
        let ids = SessionController.gameMentionIDs(in: "play <@$123> or <@$45>, not <@$x> or <@123>")
        #expect(ids == [ApplicationID(rawValue: 123), ApplicationID(rawValue: 45)])
    }

    // MARK: Chips

    @Test("Every kind of token is found, by its place in the text")
    func scan() {
        let text = "hi <@1> <@!2> <@&3> <#4> <@$5> <t:6:R> <t:7>"
        let found = EditorMention.scan(text)
        #expect(found.map(\.mention) == [
            .user(UserID(rawValue: 1)),
            .user(UserID(rawValue: 2)),
            .role(RoleID(rawValue: 3)),
            .channel(ChannelID(rawValue: 4)),
            .game(ApplicationID(rawValue: 5)),
            .timestamp(Date(timeIntervalSince1970: 6), .relative),
            .timestamp(Date(timeIntervalSince1970: 7), .shortDateTime),
        ])
        #expect((text as NSString).substring(with: found[0].range) == "<@1>")
    }

    @Test("A token written in code is code")
    func codeIsLeftAlone() {
        let text = "`<@1>` and <@2>"
        let code = NSRange(location: 0, length: 6)
        #expect(EditorMention.scan(text, excluding: [code]).map(\.mention) == [.user(UserID(rawValue: 2))])
    }

    @Test("A caret never rests inside a chip; it moves through it the way it was going")
    func caretSnaps() {
        let chip = NSRange(location: 3, length: 4)
        let right = EditorMentionAtoms.snap(NSRange(location: 4, length: 0), from: NSRange(location: 3, length: 0), around: [chip])
        #expect(right == NSRange(location: 7, length: 0))
        let left = EditorMentionAtoms.snap(NSRange(location: 6, length: 0), from: NSRange(location: 7, length: 0), around: [chip])
        #expect(left == NSRange(location: 3, length: 0))
        // Outside a chip nothing moves.
        let free = NSRange(location: 1, length: 0)
        #expect(EditorMentionAtoms.snap(free, from: NSRange(location: 0, length: 0), around: [chip]) == free)
    }

    @Test("A delete that reaches into a chip takes all of it")
    func deleteTakesTheChip() {
        let chip = NSRange(location: 3, length: 4)
        // Backspace after the chip deletes its last character…
        #expect(EditorMentionAtoms.expand(NSRange(location: 6, length: 1), around: [chip]) == chip)
        // …and a selection across its edge takes the rest of it.
        #expect(EditorMentionAtoms.expand(NSRange(location: 1, length: 3), around: [chip]) == NSRange(location: 1, length: 6))
        // Typing beside it is typing.
        #expect(EditorMentionAtoms.expand(NSRange(location: 7, length: 0), around: [chip]) == NSRange(location: 7, length: 0))
    }

    @MainActor
    @Test("A chip's token is drawn clear and takes exactly the chip's width")
    func chipReservesItsWidth() throws {
        let font = NSFont.systemFont(ofSize: 13)
        let styler = MarkdownStyler(
            font: font, color: .white, syntaxColor: .gray, linkColor: .blue,
            codeFill: .darkGray, spoilerFill: .darkGray
        )
        let storage = NSTextStorage(string: "hi <@1> there")
        let chip = EditorChip(label: "@alex", ink: .blue, fill: .blue)
        let placements = styler.apply(to: storage, chips: { _ in chip })
        let placement = try #require(placements.first)
        #expect(placement.range == NSRange(location: 3, length: 4))
        let drawn = storage.attributedSubstring(from: placement.range)
        #expect(abs(drawn.size().width - styler.chipWidth("@alex")) < 0.5)
        let ink = storage.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor
        #expect(ink == .clear)
    }
}
