import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore
@testable import WingcordNet

/// The fixes from the 2026-11-11 audit of `main..polish-nov`
/// (docs/PERFORMANCE.md), each held where it would break again.
@MainActor
@Suite("Branch audit fixes")
struct BranchAuditFixTests {

    // MARK: The picker's catalog

    private func catalog() -> ExpressionCatalog {
        ExpressionCatalog(sections: [
            ExpressionSection(
                id: "people",
                title: "People",
                badge: .glyph("😀"),
                items: [
                    ExpressionItem(id: "100", art: .glyph("💯"), name: "100", pick: .insert("💯")),
                    ExpressionItem(id: "eyes", art: .glyph("👀"), name: "eyes", pick: .insert("👀")),
                ]
            ),
        ])
    }

    @Test("The usage sections are built once, and again when a use lands")
    func usageSectionsAreMemoized() {
        let model = AppModel()
        model.expressionUsage = .empty()
        let base = catalog()

        let first = model.withUsageSections(base, stickers: false, reacting: false)
        let revision = model.expressionUsageRevision
        let second = model.withUsageSections(base, stickers: false, reacting: false)
        #expect(first == second)
        // One entry, and the read did not move what the memo keys on.
        #expect(model.usageCatalogCache.count == 1)
        #expect(model.expressionUsageRevision == revision)

        // A use moves the answer: the memo must not serve the old one.
        var usage = ExpressionUsage.empty()
        for _ in 0..<5 { usage.emojis.track("eyes", at: .now) }
        model.expressionUsage = usage
        let third = model.withUsageSections(base, stickers: false, reacting: false)
        let frequent = third.sections.first { $0.id == "usage.frequent" }
        #expect(frequent?.items.first?.id == "eyes")
        // Still one entry for this kind of picker.
        #expect(model.usageCatalogCache.count == 1)
    }

    @Test("A different catalog under the same usage is not served the old sections")
    func usageSectionsFollowTheirCatalog() {
        let model = AppModel()
        model.expressionUsage = .empty()
        let first = model.withUsageSections(catalog(), stickers: false, reacting: false)
        var other = catalog()
        other.sections[0].items.removeLast()
        let second = model.withUsageSections(other, stickers: false, reacting: false)
        #expect(first != second)
        #expect(second.sections.last?.items.count == 1)
    }

    @Test("Quick reactions are worked out once per channel and again when a use lands")
    func quickReactionsAreMemoized() {
        let model = AppModel()
        model.expressionUsage = .empty()
        let channel = ChannelID(rawValue: 9)
        let first = model.quickReactions(in: channel)
        #expect(first.map(\.name) == ["💯", "👍", "👎"])
        #expect(model.quickReactionsCache?.value == first)

        var usage = ExpressionUsage.empty()
        for _ in 0..<5 { usage.reactions.track("eyes", at: .now) }
        model.expressionUsage = usage
        #expect(model.quickReactions(in: channel).first?.name == "👀")
    }

    // MARK: Search tabs

    @Test("Only a route that did not understand the question turns the tabs off")
    func tabsFallbackIsNarrow() {
        #expect(SessionController.meansTabsNotUnderstood(.notFound))
        #expect(SessionController.meansTabsNotUnderstood(.decoding("no tabs")))
        #expect(SessionController.meansTabsNotUnderstood(.api(status: 400, code: 50035, message: nil)))
        #expect(SessionController.meansTabsNotUnderstood(.api(status: 405, code: nil, message: nil)))
        // A server having a bad minute is asked again next time.
        #expect(!SessionController.meansTabsNotUnderstood(.api(status: 500, code: nil, message: nil)))
        #expect(!SessionController.meansTabsNotUnderstood(.api(status: 503, code: nil, message: nil)))
        #expect(!SessionController.meansTabsNotUnderstood(.api(status: 429, code: nil, message: nil)))
        #expect(!SessionController.meansTabsNotUnderstood(.transport("offline")))
        #expect(!SessionController.meansTabsNotUnderstood(.forbidden(code: 50013)))
        #expect(!SessionController.meansTabsNotUnderstood(.unauthorized))
    }

    // MARK: Uses kept across a quit

    @Test("Unwritten uses survive in defaults until a write clears them")
    func pendingUsesRoundTrip() throws {
        let suite = "BranchAuditFixTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let user = UserID(rawValue: 42)
        let other = UserID(rawValue: 43)

        var uses = PendingExpressionUses()
        uses.emojis.append(.init(key: "eyes", at: Date(timeIntervalSince1970: 1_000)))
        uses.stickers.append(.init(id: 7, at: Date(timeIntervalSince1970: 2_000)))
        uses.store(for: user, in: defaults)

        let read = PendingExpressionUses.stored(for: user, in: defaults)
        #expect(read.emojis.map(\.key) == ["eyes"])
        #expect(read.stickers.map(\.id) == [7])
        // One account's uses are not another's.
        #expect(PendingExpressionUses.stored(for: other, in: defaults).isEmpty)

        PendingExpressionUses().store(for: user, in: defaults)
        #expect(PendingExpressionUses.stored(for: user, in: defaults).isEmpty)
    }

    @Test("Earlier uses stay ahead of later ones")
    func pendingUsesKeepTheirOrder() {
        var earlier = PendingExpressionUses()
        earlier.reactions.append(.init(key: "first", at: .now))
        var later = PendingExpressionUses()
        later.reactions.append(.init(key: "second", at: .now))
        #expect(later.following(earlier).reactions.map(\.key) == ["first", "second"])
    }

    // MARK: Announcements, read without a regex

    @Test("A lone link is a scheme, something after it, and no space", arguments: [
        ("https://example.com/a?b=c", true),
        ("http://x", true),
        ("https://", false),
        ("https://example.com and more", false),
        ("see https://example.com", false),
        ("ftp://example.com", false),
        ("", false),
    ])
    func loneLink(_ text: String, _ expected: Bool) {
        #expect(AppModel.isLoneLink(text) == expected)
    }

    @Test("A heading is one to three marks, a space, and words", arguments: [
        ("# Title", "Title"),
        ("##  Two spaces", "Two spaces"),
        ("### Deep", "Deep"),
        ("#### Too deep", nil),
        ("#NoSpace", nil),
        ("# ", nil),
        ("Plain", nil),
        ("", nil),
    ] as [(String, String?)])
    func heading(_ line: String, _ expected: String?) {
        #expect(AppModel.heading(in: line) == expected)
    }
}
