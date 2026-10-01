import Testing
import WingcordCore

/// The side of the reactors list, as Discord's modal builds it (`112753`).
@Suite("Reaction listing")
struct ReactionListingTests {

    @Test("An emoji with both kinds is two entries, and the list runs largest first")
    func splitAndOrder() {
        let fire = EmojiRef(name: "🔥")
        let grin = EmojiRef(name: "😀")
        let entries = ReactionListing.entries(of: [
            Reaction(emoji: fire, count: 12, isMine: false, burstCount: 3, burstColors: [0xF4900C]),
            Reaction(emoji: grin, count: 2, isMine: false),
        ])
        #expect(entries.map(\.count) == [12, 3, 2])
        #expect(entries.map(\.kind) == [.normal, .burst, .normal])
        #expect(entries[1].burstColors == [0xF4900C])
    }

    @Test("Equal counts keep the message's order, a super entry before its plain one")
    func ties() {
        let a = EmojiRef(name: "🅰️")
        let b = EmojiRef(name: "🅱️")
        let entries = ReactionListing.entries(of: [
            Reaction(emoji: a, count: 4, isMine: false, burstCount: 4),
            Reaction(emoji: b, count: 4, isMine: false),
        ])
        #expect(entries.map(\.id) == [
            ReactionListing.Key(emoji: a.reactionKey, kind: .burst),
            ReactionListing.Key(emoji: a.reactionKey, kind: .normal),
            ReactionListing.Key(emoji: b.reactionKey, kind: .normal),
        ])
    }

    @Test("An emoji nobody used in one half has no entry for it")
    func emptyHalves() {
        let shaq = EmojiRef(id: EmojiID(rawValue: 1_122_960_370_512_957_560), name: "x_shaq")
        let entries = ReactionListing.entries(of: [Reaction(emoji: shaq, count: 0, isMine: false, burstCount: 194)])
        #expect(entries.count == 1)
        #expect(entries.first?.kind == .burst)
    }
}
