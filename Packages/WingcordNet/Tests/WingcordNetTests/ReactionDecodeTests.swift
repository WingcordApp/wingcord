import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// Reactions on the wire: the entry a message carries, and the events that
/// move it.
///
/// The message entries are **captured** — `lottiesuperreaction.har`,
/// 2026-09-23, a channel whose one message carries twenty emoji and one super
/// reaction. The events are read the way Discord's own dispatcher reads them
/// (module `597643`); no capture of a super reaction *arriving* exists yet, so
/// those fixtures pin which fields are read rather than the whole shape.
@Suite("Reaction decoding")
struct ReactionDecodeTests {

    private static func reaction(_ json: String) throws -> Reaction {
        try JSONDecoder().decode(ReactionDTO.self, from: Data(json.utf8)).domain
    }

    private static func update(_ json: String) throws -> GatewayUpdate? {
        let frame = try JSONDecoder().decode(GatewayFrame.self, from: Data(json.utf8))
        return GatewayUpdate(frame.payload)
    }

    // MARK: A message's entries

    @Test("A super reaction is counted once, in its own half")
    func superReactionIsItsOwnHalf() throws {
        let entry = try Self.reaction("""
        {"emoji": {"id": "1122960370512957560", "name": "x_shaq"}, "count": 194,
         "count_details": {"burst": 194, "normal": 0},
         "burst_colors": ["#000000", "#301111", "#401b17", "#60342f", "#502722", "#401713",
                          "#50302c", "#30110e", "#703d37", "#70433e"],
         "me_burst": false, "burst_me": false, "me": false, "burst_count": 194}
        """)
        // `count` on the wire is the TOTAL. Reading it as the plain tally is
        // what drew this reaction a second time inside an empty plain chip.
        #expect(entry.count == 0)
        #expect(entry.burstCount == 194)
        #expect(entry.emoji.id == EmojiID(rawValue: 1_122_960_370_512_957_560))
        // Only the first three: that is all the palette ever reads.
        #expect(entry.burstColors == [0x00_00_00, 0x30_11_11, 0x40_1B_17])
    }

    @Test("A plain reaction keeps its count and has no palette")
    func plainReaction() throws {
        let entry = try Self.reaction("""
        {"emoji": {"id": null, "name": "🇹🇷"}, "count": 642,
         "count_details": {"burst": 0, "normal": 642}, "burst_colors": [],
         "me_burst": false, "burst_me": false, "me": false, "burst_count": 0}
        """)
        #expect(entry.count == 642)
        #expect(entry.burstCount == 0)
        #expect(entry.burstColors.isEmpty)
    }

    @Test("Without the details, the two top-level counts are read instead")
    func noDetailsFallsBack() throws {
        // Discord's own normalisation only replaces the counts when the details
        // are there.
        let entry = try Self.reaction("""
        {"emoji": {"name": "🔥"}, "count": 3, "burst_count": 1, "me": true, "burst_me": true}
        """)
        #expect(entry.count == 3)
        #expect(entry.burstCount == 1)
        #expect(entry.isMine)
        // `burst_me` is the older name for the same bit.
        #expect(entry.isMineBurst)
    }

    @Test("A malformed colour is dropped rather than drawn as black")
    func malformedColour() {
        #expect(ReactionDTO.palette(["#40", "#401b17", "nothex", "#ffffff"]) == [0x40_1B_17])
        #expect(ReactionDTO.palette(nil).isEmpty)
    }

    // MARK: The events

    @Test("A super reaction arriving carries its kind and the server's colours")
    func burstAdd() throws {
        let update = try Self.update("""
        {"op": 0, "s": 2823, "t": "MESSAGE_REACTION_ADD", "d": {
          "user_id": "96453564840469775", "type": 1, "burst": true,
          "message_id": "1522309183544885345", "channel_id": "1522308942204637325",
          "emoji": {"id": "1122960370512957560", "name": "x_shaq"},
          "burst_colors": ["#000000", "#301111", "#401b17", "#60342f"]}}
        """)
        guard case .reactionAdded(_, _, let emoji, let user, let kind, let colors) = update else {
            Issue.record("not a reaction add: \(String(describing: update))")
            return
        }
        #expect(emoji.name == "x_shaq")
        #expect(user == UserID(rawValue: 96_453_564_840_469_775))
        #expect(kind == .burst)
        #expect(colors == [0x00_00_00, 0x30_11_11, 0x40_1B_17])
    }

    @Test("A plain reaction arriving is plain, and one with no type at all is too")
    func plainAdd() throws {
        for body in [
            #""type": 0, "burst": false,"#,
            "",
        ] {
            let update = try Self.update("""
            {"op": 0, "s": 1, "t": "MESSAGE_REACTION_ADD", "d": {\(body)
              "user_id": "1", "message_id": "2", "channel_id": "3", "emoji": {"name": "👍"}}}
            """)
            guard case .reactionAdded(_, _, _, _, let kind, let colors) = update else {
                Issue.record("not a reaction add")
                continue
            }
            #expect(kind == .normal)
            #expect(colors.isEmpty)
        }
    }

    @Test("Removing a super reaction names the half it came out of")
    func burstRemove() throws {
        let update = try Self.update("""
        {"op": 0, "s": 9, "t": "MESSAGE_REACTION_REMOVE", "d": {
          "user_id": "1", "type": 1, "burst": true, "message_id": "2", "channel_id": "3",
          "emoji": {"id": "4", "name": "x_shaq"}}}
        """)
        guard case .reactionRemoved(_, _, _, _, let kind) = update else {
            Issue.record("not a reaction remove")
            return
        }
        #expect(kind == .burst)
    }

    @Test("A batch of plain reactions becomes emoji and the people who used them")
    func addMany() throws {
        let update = try Self.update("""
        {"op": 0, "s": 2831, "t": "MESSAGE_REACTION_ADD_MANY", "d": {
          "message_id": "2", "channel_id": "3", "guild_id": "5",
          "reactions": [{"users": ["10", "11"], "emoji": {"name": "🔥"}},
                        {"users": [], "emoji": {"name": "💀"}},
                        {"emoji": {"name": "✅"}}]}}
        """)
        guard case .reactionsAdded(_, _, let reactions) = update else {
            Issue.record("not a batch")
            return
        }
        // Entries naming nobody are dropped rather than counted as zero people.
        #expect(reactions.count == 1)
        #expect(reactions.first?.0.name == "🔥")
        #expect(reactions.first?.1 == [UserID(rawValue: 10), UserID(rawValue: 11)])
    }

    @Test("A moderator's clear is one message, or one emoji on it")
    func clears() throws {
        let all = try Self.update("""
        {"op": 0, "s": 1, "t": "MESSAGE_REACTION_REMOVE_ALL", "d": {
          "message_id": "2", "channel_id": "3", "guild_id": "5"}}
        """)
        guard case .reactionsCleared(let message, let channel) = all else {
            Issue.record("not a clear")
            return
        }
        #expect(message == MessageID(rawValue: 2) && channel == ChannelID(rawValue: 3))

        let one = try Self.update("""
        {"op": 0, "s": 2, "t": "MESSAGE_REACTION_REMOVE_EMOJI", "d": {
          "message_id": "2", "channel_id": "3", "emoji": {"id": "7", "name": "x_shaq"}}}
        """)
        guard case .reactionEmojiCleared(_, _, let emoji) = one else {
            Issue.record("not an emoji clear")
            return
        }
        #expect(emoji.id == EmojiID(rawValue: 7))
    }
}
