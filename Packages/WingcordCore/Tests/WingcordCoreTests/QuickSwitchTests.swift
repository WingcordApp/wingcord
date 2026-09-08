import Foundation
import Testing
@testable import WingcordCore

/// The switcher's grammar and its scorer.
///
/// The ordering is the part worth pinning: it is the one thing in this feature
/// that cannot be checked by looking at the screen, because a list that is
/// *nearly* right looks exactly like a list that is right.
@Suite("Quick switcher")
struct QuickSwitchTests {

    // MARK: The grammar

    @Test("A leading sigil is a filter and is taken off the needle")
    func sigilsParse() {
        #expect(QuickSwitchQuery.parse("@alex").filter == .people)
        #expect(QuickSwitchQuery.parse("@alex").needle == "alex")
        #expect(QuickSwitchQuery.parse("#general").filter == .textChannels)
        #expect(QuickSwitchQuery.parse("!lounge").filter == .voiceChannels)
        #expect(QuickSwitchQuery.parse("*sakura").filter == .servers)
        #expect(QuickSwitchQuery.parse("$gta").filter == .games)
    }

    /// The mode with nothing after it is a real state — it is what the reader
    /// sees for the beat between pressing `#` and typing.
    @Test("A bare sigil is a filter with an empty needle")
    func bareSigil() {
        let query = QuickSwitchQuery.parse("#")
        #expect(query.filter == .textChannels)
        #expect(query.isEmpty)
    }

    /// **Only at the start.** Otherwise a channel with a `#` in its name could
    /// never be searched for, and `read-#general` would silently become a
    /// channel filter.
    @Test("A sigil anywhere but the front is a character")
    func sigilMustLead() {
        let query = QuickSwitchQuery.parse("read #general")
        #expect(query.filter == nil)
        #expect(query.needle == "read #general")
    }

    @Test("The needle is folded, so case and diacritics do not decide a match")
    func needleIsFolded() {
        #expect(QuickSwitchQuery.parse("CAFÉ").needle == "cafe")
    }

    // MARK: The tiers

    @Test("Each tier is reached by the thing it describes")
    func tiers() {
        #expect(QuickSwitchRank.match("general", "general") == .exact)
        #expect(QuickSwitchRank.match("general-chat", "gen") == .prefix)
        #expect(QuickSwitchRank.match("off-topic", "top") == .wordPrefix)
        #expect(QuickSwitchRank.match("bug-reports", "epor") == .contains)
        #expect(QuickSwitchRank.match("brandonplays", "bro") == .subsequence)
        #expect(QuickSwitchRank.match("general", "zzz") == nil)
    }

    /// The one behaviour that makes a channel list searchable at all: people put
    /// an emoji in front of the name and nobody types it.
    @Test("An emoji in front of a name is a word boundary, not a wall")
    func emojiIsABoundary() {
        #expect(QuickSwitchRank.match("🌸│general", "general") == .wordPrefix)
        #expect(QuickSwitchRank.match("🌸│general", "gen") == .wordPrefix)
    }

    @Test("An empty needle matches nothing rather than everything")
    func emptyNeedleMatchesNothing() {
        #expect(QuickSwitchRank.match("general", "") == nil)
    }

    @Test("A needle longer than the name cannot match")
    func longerNeedle() {
        #expect(QuickSwitchRank.match("gen", "general") == nil)
    }

    /// A later, better hit wins over an earlier, worse one — otherwise
    /// `share-your-backgrounds` would rank as a bare `contains` for `back`.
    @Test("The best tier in the string is the one reported")
    func bestTierWins() {
        #expect(QuickSwitchRank.match("cabbage-backgrounds", "back") == .wordPrefix)
    }

    // MARK: The ordering

    /// The screenshot's own case: `bro` puts a server the account lives in above
    /// a game whose name starts with the letters.
    @Test("Frecency lifts a weaker match over a cold stronger one")
    func frecencyLiftsATier() {
        let lived = QuickSwitchRank.score(.contains, frecency: 1000)
        let cold = QuickSwitchRank.score(.prefix, frecency: 0)
        #expect(lived >= cold)
    }

    /// The ceiling is what stops the switcher becoming a most-recently-used list
    /// that ignores what was typed: a maxed `contains` reaches a cold `prefix`
    /// and goes no further.
    @Test("Frecency is worth exactly two tiers, and no more")
    func liftIsCapped() {
        #expect(QuickSwitchRank.score(.contains, frecency: 1000)
            == QuickSwitchRank.score(.prefix, frecency: 0))
        #expect(QuickSwitchRank.score(.subsequence, frecency: 1000)
            == QuickSwitchRank.score(.wordPrefix, frecency: 0))
        #expect(QuickSwitchRank.score(.subsequence, frecency: 1000)
            < QuickSwitchRank.score(.prefix, frecency: 0))
    }

    @Test("An exact match is out of reach of any lift")
    func exactCannotBeBeaten() {
        #expect(QuickSwitchRank.score(.exact, frecency: 0)
            > QuickSwitchRank.score(.prefix, frecency: 1000))
    }

    @Test("A missing or absurd frecency is clamped rather than trusted")
    func frecencyIsClamped() {
        #expect(QuickSwitchRank.score(.contains, frecency: -50)
            == QuickSwitchRank.score(.contains, frecency: 0))
        #expect(QuickSwitchRank.score(.contains, frecency: 99_999)
            == QuickSwitchRank.score(.contains, frecency: 1000))
    }
}
