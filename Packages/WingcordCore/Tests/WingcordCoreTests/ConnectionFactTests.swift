import Foundation
import Testing
@testable import WingcordCore

/// What a linked service says about an account.
///
/// **These are rendered by the key's shape, not by a table of every key**, so
/// the tests that matter are the ones about shapes nobody has captured: a
/// service Discord adds next month sends keys this file has never seen, and the
/// only guard on it drawing something sane is here.
@Suite("Connection facts")
struct ConnectionFactTests {

    private func fact(_ key: String, _ value: String) -> ConnectionFact? {
        ConnectionFact(key: key, rawValue: value)
    }

    // MARK: Captured payloads

    @Test("Steam's own metadata, as captured")
    func steam() throws {
        let account = ConnectedAccount(
            id: "76561199084011500",
            service: "steam",
            name: "雪乃",
            isVerified: true,
            metadata: [
                "created_at": "2020-08-08T15:29:17",
                "game_count": "16",
                "item_count_dota2": "-1",
                "item_count_tf2": "0",
            ]
        )
        let facts = account.facts
        // The join date leads, the game count follows, and **both item counts
        // are dropped**: `-1` is Steam's "not applicable" sentinel and `0` is a
        // count worth nobody's attention.
        #expect(facts.map(\.key) == ["created_at", "game_count"])
        if case .count(let value, let noun) = facts.last?.content {
            #expect(value == 16)
            #expect(noun == "Games")
        } else {
            Issue.record("a game count should be a count")
        }
    }

    @Test("Reddit's, from the documented example")
    func reddit() {
        let account = ConnectedAccount(
            id: "run&hide", service: "reddit", name: "alien", isVerified: true,
            metadata: ["gold": "0", "mod": "1", "total_karma": "20223", "created_at": "2019-05-02T20:28:37"]
        )
        let facts = account.facts
        #expect(facts.map(\.key) == ["created_at", "total_karma", "mod"])
        #expect(facts.contains { $0.content == .count(20223, noun: "Karma") })
        #expect(facts.contains { $0.content == .flag("Moderator") })
        // `gold: "0"` is a badge they do not have.
        #expect(!facts.contains { $0.key == "gold" })
    }

    @Test("Twitter's, from the documented example")
    func twitter() {
        let account = ConnectedAccount(
            id: "123456", service: "twitter", name: "discord", isVerified: true,
            metadata: [
                "verified": "1",
                "followers_count": "100000",
                "statuses_count": "100000",
                "created_at": "2016-01-01T00:00:00",
            ]
        )
        let facts = account.facts
        #expect(facts.contains { $0.content == .count(100_000, noun: "Followers") })
        // `statuses_count` is "Posts" everywhere it appears, which no mechanical
        // derivation gets right.
        #expect(facts.contains { $0.content == .count(100_000, noun: "Posts") })
        // The seal beside the name already says this; a "Verified" badge under
        // it says it twice.
        #expect(!facts.contains { $0.key == "verified" })
    }

    // MARK: Shapes nothing has captured

    @Test("A count-shaped key nobody has seen still draws")
    func unknownCount() throws {
        let fact = try #require(fact("clip_count", "42"))
        #expect(fact.content == .count(42, noun: "Clip"))
    }

    @Test("A total-shaped key drops its prefix")
    func totalPrefix() throws {
        let fact = try #require(fact("total_matches", "9"))
        #expect(fact.content == .count(9, noun: "Matches"))
    }

    @Test("A count in the middle of a key still resolves, and reads as English")
    func itemCountReversed() throws {
        // Steam's own shape. The count is infixed, so the suffix and prefix
        // rules both miss it — and a key that resolves to no noun is dropped
        // entirely rather than drawn wrong, which is why this needs a test.
        let fact = try #require(fact("item_count_dota2", "310"))
        #expect(fact.content == .count(310, noun: "Dota2 Items"))
    }

    @Test("A value that is neither a date, a count nor a flag draws nothing")
    func unrenderable() {
        #expect(fact("region", "eu-west") == nil)
        #expect(fact("score", "12.5") == nil)
        #expect(fact("anything", "") == nil)
    }

    @Test("A date with no timezone still parses")
    func bareDate() throws {
        // **Connection metadata dates carry no zone**, unlike every other date
        // on this API, and the strict parser rejects them outright — the symptom
        // is a connection row with no "Member since" line.
        let fact = try #require(fact("created_at", "2020-08-08T15:29:17"))
        guard case .since(let date) = fact.content else {
            Issue.record("created_at should be a date")
            return
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(calendar.dateComponents([.year, .month], from: date).year == 2020)
    }

    @Test("An unparseable date is dropped rather than shown as 1970")
    func badDate() {
        #expect(fact("created_at", "yesterday") == nil)
    }

    @Test("Dates lead, counts follow, badges last")
    func ordering() {
        let account = ConnectedAccount(
            id: "1", service: "x", name: "n", isVerified: false,
            metadata: ["mod": "1", "total_karma": "5", "created_at": "2019-05-02T20:28:37"]
        )
        #expect(account.facts.map(\.sortRank) == [0, 1, 2])
    }

    @Test("A service that publishes nothing has no line")
    func noMetadata() {
        let account = ConnectedAccount(id: "1", service: "spotify", name: "n", isVerified: true)
        #expect(account.facts.isEmpty)
    }
}
