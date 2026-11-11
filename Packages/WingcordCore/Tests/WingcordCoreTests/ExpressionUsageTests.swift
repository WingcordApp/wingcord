import Foundation
import Testing
@testable import WingcordCore

/// Discord's frecency for emoji and stickers (`283047`, bonus 100, 42 shown)
/// and the defaults it seeds an empty table with.
@Suite("Expression frecency")
struct ExpressionUsageTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("A new account's quick reactions are Discord's: 💯 👍 👎")
    func defaultsForANewAccount() {
        let usage = ExpressionUsage.empty(now: now)
        #expect(usage.quickReactions(now: now) { _ in true } == ["100", "thumbsup", "thumbsdown"])
        #expect(Array(usage.seeded(now: now).emojis.ranked.prefix(3)) == ["thumbsup", "eyes", "laughing"])
        // Seeds are for showing: the tables themselves stay empty.
        #expect(usage.reactions.history.isEmpty)
    }

    @Test("Used often and lately beats used once; what cannot be used is skipped")
    func ranking() {
        var usage = ExpressionUsage.empty(now: now)
        for day in 0..<4 { usage.reactions.track("fire", at: now.addingTimeInterval(-Double(day) * 86_400)) }
        usage.reactions.track("skull", at: now.addingTimeInterval(-50 * 86_400))
        usage.reactions.track("eyes", at: now)
        #expect(usage.reactions.ranked.first == "fire")
        #expect(usage.quickReactions(now: now) { $0 != "eyes" } == ["fire", "skull"])
    }

    @Test("A use older than eighty days still counts one; ten samples are kept")
    func samples() {
        var table = ExpressionFrecency(now: now)
        for index in 0..<12 { table.track("old", at: now.addingTimeInterval(-Double(100 + index) * 86_400)) }
        #expect(table.history["old"]?.recentUses.count == 10)
        #expect(table.history["old"]?.totalUses == 12)
        #expect((table.history["old"]?.score ?? 0) > 0)
    }
}

/// Discord's names for Unicode emoji, where this table leads with another.
@Suite("Discord's emoji names")
struct DiscordEmojiNameTests {
    @Test("👍 is thumbsup and 💩 is poop to Discord, whatever this table leads with")
    func names() {
        #expect(UnicodeEmoji.discordName(for: "👍") == "thumbsup")
        #expect(UnicodeEmoji.discordName(for: "👍🏽") == "thumbsup")
        #expect(UnicodeEmoji.discordName(for: "💩") == "poop")
        #expect(UnicodeEmoji.discordName(for: "🤔") == "thinking")
        #expect(UnicodeEmoji.discordName(for: "💯") == "100")
    }

    @Test("And back: Discord's name finds its glyph")
    func glyphs() {
        #expect(UnicodeEmoji.glyph(forDiscordName: "thumbsup") == "👍")
        #expect(UnicodeEmoji.glyph(forDiscordName: "thinking") == "🤔")
        #expect(UnicodeEmoji.glyph(forDiscordName: "100") == "💯")
    }
}
