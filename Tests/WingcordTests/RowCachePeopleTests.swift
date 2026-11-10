import AppKit
import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// A laid-out row is checked against the people it names, and nobody else
/// (docs/PERFORMANCE.md, 2026-11-10).
///
/// The row cache keyed on a counter that moved with every user record in the
/// account, so a stranger writing in another server relaid every loaded row
/// the next time a message landed. Through the engine the transcript calls.
@MainActor
@Suite("Row cache and the people a row names")
struct RowCachePeopleTests {
    private static let author = UserID(rawValue: 7)
    private static let mentioned = UserID(rawValue: 8)
    private static let stranger = UserID(rawValue: 9)

    private static let mentioning = MessageID(rawValue: 1 << 22)
    private static let plain = MessageID(rawValue: 2 << 22)

    private var messages: [Message] {
        [
            Message(
                id: Self.mentioning, channelID: ChannelID(rawValue: 1), authorID: Self.author,
                content: "ask <@8> about it"
            ),
            Message(
                id: Self.plain, channelID: ChannelID(rawValue: 1), authorID: Self.author,
                content: "nobody is named here"
            ),
        ]
    }

    private func input(
        names: [UserID: String],
        authorName: String = "Wren",
        lookups: MentionLookups? = nil
    ) -> TimelineLayoutEngine.Input {
        var mentions = MentionContext(userNames: names)
        mentions.lookups = lookups
        return TimelineLayoutEngine.Input(
            items: TimelineReducer.rows(messages: messages, failed: []),
            width: 480,
            style: MessageTextStyle.current(),
            mentions: mentions,
            channelName: "general",
            authors: [
                Self.author: .init(
                    name: authorName, colorValue: nil, avatarURL: nil,
                    monogram: "W", decorationURL: nil, isBot: false
                ),
            ],
            calendar: .current,
            settings: .comfortable
        )
    }

    private let engine = TimelineLayoutEngine(presentationRevision: 1)

    @Test("Somebody the page does not name changing leaves every row as it was")
    func strangerChangesNothing() {
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        _ = engine.layout(input(names: [Self.mentioned: "Alder"]), cache: &cache)
        let before = (cache[Self.mentioning]?.row.textBlock, cache[Self.plain]?.row.textBlock)

        _ = engine.layout(
            input(names: [Self.mentioned: "Alder", Self.stranger: "Zed"]), cache: &cache
        )
        #expect(cache[Self.mentioning]?.row.textBlock === before.0)
        #expect(cache[Self.plain]?.row.textBlock === before.1)
    }

    @Test("A mentioned person's name changing sets that row again, and only that row")
    func mentionedNameRebuildsItsRow() {
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        _ = engine.layout(input(names: [Self.mentioned: "Alder"]), cache: &cache)
        let before = (cache[Self.mentioning]?.row.textBlock, cache[Self.plain]?.row.textBlock)

        _ = engine.layout(input(names: [Self.mentioned: "Birch"]), cache: &cache)
        #expect(cache[Self.mentioning]?.row.textBlock !== before.0)
        #expect(cache[Self.plain]?.row.textBlock === before.1)
    }

    @Test("Somebody not known when a row was set is set again once they are")
    func lateNameRebuildsItsRow() {
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        let lookups = MentionLookups()
        _ = engine.layout(input(names: [:], lookups: lookups), cache: &cache)
        // The pass says who its rows asked for, so the caller can name them.
        #expect(lookups.askedInPass == [Self.mentioned])
        let before = cache[Self.mentioning]?.row.textBlock

        _ = engine.layout(input(names: [Self.mentioned: "Alder"]), cache: &cache)
        #expect(cache[Self.mentioning]?.row.textBlock !== before)
    }

    @Test("A row taken from the cache still says who it names")
    func cachedRowsReportTheirNames() {
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        _ = engine.layout(input(names: [Self.mentioned: "Alder"]), cache: &cache)

        let lookups = MentionLookups()
        _ = engine.layout(input(names: [Self.mentioned: "Alder"], lookups: lookups), cache: &cache)
        #expect(lookups.askedInPass == [Self.mentioned])
    }

    /// The half of the fix that lives in the store: reverting the token to
    /// carry `identityRevision` fails here, which is the bug.
    @Test("The transcript's context names only who it is asked for, and does not move when somebody else changes")
    func pageContextLeavesPeopleOutOfItsToken() {
        let model = AppModel()
        model.users[Self.mentioned] = User(id: Self.mentioned, username: "alder", displayName: "Alder")
        model.users[Self.stranger] = User(id: Self.stranger, username: "zed")

        let before = model.mentionContext(naming: [Self.mentioned])
        #expect(before.userNames == [Self.mentioned: "Alder"])

        // A stranger writes somewhere: their record lands and the counter moves.
        model.users[Self.stranger] = User(id: Self.stranger, username: "zed", displayName: "Zed")
        model.identityRevision &+= 1

        let after = model.mentionContext(naming: [Self.mentioned])
        #expect(after.token == before.token)
        #expect(after.userNames == before.userNames)
        // Somebody the store does not know is left out rather than guessed.
        #expect(model.mentionContext(naming: [UserID(rawValue: 404)]).userNames.isEmpty)
        // The table of everybody still moves with them: its readers key on it.
        #expect(model.mentionContext().token != before.token)
    }

    @Test("An author's name changing sets their rows again")
    func authorChangeRebuildsTheirRows() {
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        _ = engine.layout(input(names: [Self.mentioned: "Alder"]), cache: &cache)
        #expect(cache[Self.plain]?.people.first?.info?.name == "Wren")

        _ = engine.layout(
            input(names: [Self.mentioned: "Alder"], authorName: "Robin"), cache: &cache
        )
        #expect(cache[Self.mentioning]?.people.first?.info?.name == "Robin")
        #expect(cache[Self.plain]?.people.first?.info?.name == "Robin")
        // And an unchanged author is a hit.
        let after = cache[Self.plain]?.row.textBlock
        _ = engine.layout(
            input(names: [Self.mentioned: "Alder"], authorName: "Robin"), cache: &cache
        )
        #expect(cache[Self.plain]?.row.textBlock === after)
    }
}
