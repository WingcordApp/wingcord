import Foundation
import Testing
@testable import WingcordCore

/// Discord's emoji naming (GitHub #25): Unicode names first, later duplicates
/// renamed `~1`, and its search order.
struct EmojiNameTableTests {

    private let here = GuildID(rawValue: 1_400_000_000_000_000_901)
    private let elsewhere = GuildID(rawValue: 1_400_000_000_000_000_902)

    private let unicode: [(glyph: String, names: [String])] = [
        ("😭", ["sob"]),
        ("👍", ["thumbsup", "+1", "thumbup"]),
        ("😂", ["joy"]),
        ("😹", ["joy_cat"]),
    ]

    private func table(_ custom: [EmojiNameTable.Custom]) -> EmojiNameTable {
        EmojiNameTable(unicode: unicode, custom: custom)
    }

    private func custom(_ id: UInt64, _ name: String, _ owner: EmojiNameTable.Owner) -> EmojiNameTable.Custom {
        EmojiNameTable.Custom(id: id, name: name, isAnimated: false, owner: owner)
    }

    @Test func aServersSobIsSobTilde1AndTheBuiltInKeepsItsName() throws {
        let table = table([custom(11, "sob", .guild(here))])
        let typed = try #require(table.entry(named: "sob"))
        #expect(typed.glyph == "😭")
        let theirs = try #require(table.entry(named: "sob~1"))
        #expect(theirs.id == 11)
        #expect(theirs.messageToken == "<:sob:11>")
        #expect(table.name(ofCustom: 11) == "sob~1")
    }

    @Test func thisServerComesBeforeTheOthersThenPacks() {
        let table = table([
            custom(21, "blob", .guild(here)),
            custom(22, "blob", .guild(elsewhere)),
            custom(23, "blob", .pack(7)),
        ])
        #expect(table.name(ofCustom: 21) == "blob")
        #expect(table.name(ofCustom: 22) == "blob~1")
        #expect(table.name(ofCustom: 23) == "blob~2")
    }

    @Test func aliasesFindTheUnicodeEmojiButAreNotReserved() throws {
        let table = table([custom(31, "+1", .guild(here))])
        // Discord counts the primary name only, so a custom "+1" keeps its name…
        #expect(table.name(ofCustom: 31) == "+1")
        // …and the alias still reaches 👍 only through the first entry that took it.
        #expect(try #require(table.entry(named: "thumbup")).glyph == "👍")
    }

    @Test func aClosingColonInAnotherCaseFindsTheOneNameOnly() throws {
        let table = table([custom(41, "PartyBlob", .guild(here))])
        #expect(try #require(table.entry(named: "partyblob")).id == 41)
        let twins = self.table([custom(42, "Wave", .guild(here)), custom(43, "WAVE", .guild(elsewhere))])
        #expect(twins.entry(named: "wave") == nil)
        #expect(twins.entry(named: "WAVE")?.id == 43)
    }

    @Test func searchPutsTheExactNameFirst() {
        let table = table([custom(51, "sob", .guild(here)), custom(52, "sobbing_cat", .guild(here))])
        let names = table.search("sob", limit: 10).map(\.name)
        #expect(names.first == "sob")
        #expect(names.contains("sob~1"))
        #expect(names.contains("sobbing_cat"))
    }

    @Test func searchMatchesAnywhereIgnoringUnderscores() {
        let table = table([])
        #expect(table.search("cat", limit: 10).map(\.name) == ["joy_cat"])
        #expect(table.search("joycat", limit: 10).map(\.name) == ["joy_cat"])
    }

    @Test func useLiftsAnEmojiAboveABetterMatch() {
        let table = table([custom(61, "sob", .guild(here))])
        // The server's sob~1 scores 2 (a prefix); the built-in 8. Used enough
        // (score 500 → ×5), the reader's own pick wins.
        let lifted = table.search("sob", limit: 10, score: { key in key == "61" ? 500 : nil })
        #expect(lifted.first?.id == 61)
    }

    @Test func offersFiltersWhatCannotBeUsedHere() {
        let table = table([custom(71, "sobfish", .guild(elsewhere))])
        let names = table.search("sob", limit: 10, offers: { $0.id != 71 }).map(\.name)
        #expect(!names.contains("sobfish"))
    }
}
