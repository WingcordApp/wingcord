import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// When `@` and `#` open a list, and what they leave behind when one is picked.
///
/// The scan is pure, which is the point: what counts as a trigger is one
/// testable rule rather than something the composer works out while it is
/// being typed into.
@Suite("Mention autocomplete")
struct MentionAutocompleteTests {

    // MARK: When it opens

    @Test("A bare sigil opens the list")
    func bareSigilTriggers() {
        // **Zero-length, and this differs from the shortcode scanner on
        // purpose.** A bare `:` is a colon and there are thousands of emoji; a
        // bare `@` is somebody saying "somebody", and the list is how they say
        // who.
        #expect(MentionAutocomplete.trigger(in: "@")?.kind == .member)
        #expect(MentionAutocomplete.trigger(in: "@")?.query == "")
        #expect(MentionAutocomplete.trigger(in: "hey #")?.kind == .channel)
    }

    @Test("A sigil inside a word is part of that word")
    func sigilAfterAWordIsNotATrigger() {
        // The defect this prevents, in both flavours: an email address is not
        // a mention and a language is not a channel.
        #expect(MentionAutocomplete.trigger(in: "alex@example.com") == nil)
        #expect(MentionAutocomplete.trigger(in: "I write C#") == nil)
        #expect(MentionAutocomplete.trigger(in: "#ff0000") != nil)
    }

    @Test("A token with a space in it has ended")
    func whitespaceClosesTheToken() {
        // Somebody who typed `@alex hello` is writing a sentence, not still
        // choosing — and a list that stayed up would eat their Return.
        #expect(MentionAutocomplete.trigger(in: "@alex hello") == nil)
        #expect(MentionAutocomplete.trigger(in: "@alex") != nil)
    }

    @Test("The last sigil is the one being answered")
    func onlyTheLastSigilCounts() {
        // A message that already names two people is not three open lists: the
        // caret is at the end, and that is where the reader is typing.
        let trigger = MentionAutocomplete.trigger(in: "@alex and @nat")
        #expect(trigger?.query == "nat")
    }

    @Test("The later of `@` and `#` wins")
    func theLaterSigilWins() {
        #expect(MentionAutocomplete.trigger(in: "@alex in #gen")?.kind == .channel)
        #expect(MentionAutocomplete.trigger(in: "#gen with @al")?.kind == .member)
    }

    /// The offset exists so the composer can settle this: both scanners look
    /// only for their own sigil and neither can see the other, so `:sob @al`
    /// is an open shortcode *and* an open mention by each one's rules.
    @Test("The sigil's offset is carried, so a tie with `:` can be settled")
    func sigilOffsetIsCarried() {
        let text = ":sob @al"
        let trigger = MentionAutocomplete.trigger(in: text)
        let colon = text.distance(from: text.startIndex, to: text.firstIndex(of: ":")!)
        #expect(trigger?.sigilOffset == 5)
        #expect(colon < (trigger?.sigilOffset ?? 0))
    }

    // MARK: What it leaves behind

    @Test("Picking replaces the token and leaves a space")
    func applyingReplacesTheToken() {
        #expect(
            MentionAutocomplete.applying("<@7>", kind: .member, to: "hey @al")
                == "hey <@7> "
        )
        #expect(
            MentionAutocomplete.applying("<#9>", kind: .channel, to: "see #gen")
                == "see <#9> "
        )
    }

    /// **A mention is a token on the wire, not a name.** `@alex` is text and
    /// `<@7>` is a ping; a list that inserted the display name would look
    /// right and notify nobody.
    @Test("What is inserted is the wire form")
    func insertedTextIsTheWireForm() {
        let text = MentionAutocomplete.applying("<@7>", kind: .member, to: "@a")
        #expect(text.contains("<@7>"))
        #expect(!text.contains("@a "))
    }

    @Test("Picking with nothing typed still replaces the sigil")
    func applyingToABareSigil() {
        #expect(MentionAutocomplete.applying("<@7>", kind: .member, to: "@") == "<@7> ")
    }
}

/// Who and what the list actually offers.
///
/// **Through the store's own projection**, which is the only level at which
/// "is this wired up" is a question a test can answer — §2.
@MainActor
@Suite("Mention candidates")
struct MentionCandidateTests {

    private let me = UserID(rawValue: 1)
    private let guildID = GuildID(rawValue: 100)
    private let channelID = ChannelID(rawValue: 200)

    /// - Parameter isOwner: whether the reader owns the server, which is the
    ///   cheapest way to give them every permission — including
    ///   `MENTION_EVERYONE`, which decides whether the two specials are
    ///   offered at all.
    private func model(isOwner: Bool = true) -> AppModel {
        let model = AppModel()
        model.currentUserID = me
        model.users[me] = User(id: me, username: "alex")
        model.users[UserID(rawValue: 2)] = User(
            id: UserID(rawValue: 2), username: "rowan", displayName: "robinresting"
        )
        model.users[UserID(rawValue: 3)] = User(
            id: UserID(rawValue: 3), username: "natalie", displayName: "nat"
        )
        model.guilds[guildID] = Guild(
            id: guildID, name: "Test", ownerID: isOwner ? me : UserID(rawValue: 999)
        )
        model.members[guildID] = [
            me: Member(userID: me, roleIDs: []),
            UserID(rawValue: 2): Member(userID: UserID(rawValue: 2), roleIDs: []),
            UserID(rawValue: 3): Member(userID: UserID(rawValue: 3), roleIDs: []),
        ]
        model.channelIndex.replaceChannels(
            [Channel(id: channelID, kind: .text, guildID: guildID, name: "general")],
            inGuild: guildID
        )
        return model
    }

    private func candidates(
        _ kind: MentionAutocomplete.Kind,
        _ query: String,
        isOwner: Bool = true
    ) -> [MentionCandidate] {
        model(isOwner: isOwner).mentionCandidates(
            for: MentionAutocomplete.Trigger(kind: kind, query: query, sigilOffset: 0),
            in: channelID
        )
    }

    /// **The bug the emoji list actually shipped with**, asserted here before
    /// it can happen: `matches` walked its catalog and then walked Unicode
    /// again, and every Unicode result was listed twice. Nothing in these two
    /// lists may repeat, for any query.
    @Test("Nothing is offered twice")
    func noDuplicates() {
        for query in ["", "n", "nat", "gen"] {
            for kind in [MentionAutocomplete.Kind.member, .channel] {
                let rows = candidates(kind, query)
                #expect(Set(rows.map(\.id)).count == rows.count, "\(kind) / '\(query)'")
            }
        }
    }

    @Test("A prefix matches either the name or the handle")
    func matchesNameOrHandle() {
        // People reach for whichever they remember, and Discord matches both.
        #expect(candidates(.member, "nat").contains { $0.title == "nat" })
        #expect(candidates(.member, "robinre").contains { $0.title == "robinresting" })
    }

    @Test("A bare `@` offers everybody, and the two specials above them")
    func bareSigilOffersEveryone() {
        let rows = candidates(.member, "")
        // Three members, plus `@everyone` and `@here` — which the reader holds
        // the permission for here, being the owner.
        #expect(rows.count == 5)
        #expect(rows.prefix(2).map(\.title) == ["@everyone", "@here"])
    }

    /// A mention is a token, and the token is what the parser reads back.
    @Test("A person's token is the wire form")
    func tokensAreWireForms() {
        let person = candidates(.member, "nat").first { $0.title == "nat" }
        #expect(person?.token == "<@3>")
        let channel = candidates(.channel, "gen").first
        #expect(channel?.token == "<#200>")
    }

    /// `MENTION_EVERYONE` decides whether the ping lands, so offering it
    /// without the permission is an inert control — §5.5.
    ///
    /// **Both directions, because one alone proves nothing.** A test that
    /// only checked the refusal would pass against a list that never offered
    /// it at all.
    @Test("`@everyone` is offered only with the permission")
    func everyoneNeedsThePermission() {
        #expect(candidates(.member, "every", isOwner: true).contains { $0.title == "@everyone" })
        #expect(!candidates(.member, "every", isOwner: false).contains { $0.title == "@everyone" })
    }

    /// A conversation has no roster and no `@everyone`, and the channel list
    /// has nothing to draw from.
    @Test("A direct message offers its recipients and no channels")
    func directMessageOffersRecipients() {
        let model = AppModel()
        model.currentUserID = me
        model.users[me] = User(id: me, username: "alex")
        model.users[UserID(rawValue: 2)] = User(id: UserID(rawValue: 2), username: "rowan")
        let dm = ChannelID(rawValue: 300)
        model.channelIndex.replacePrivateChannels([
            Channel(id: dm, kind: .directMessage, recipientIDs: [me, UserID(rawValue: 2)]),
        ])
        let people = model.mentionCandidates(
            for: MentionAutocomplete.Trigger(kind: .member, query: "", sigilOffset: 0), in: dm
        )
        #expect(people.count == 2)
        #expect(!people.contains { $0.title == "@everyone" })

        let channels = model.mentionCandidates(
            for: MentionAutocomplete.Trigger(kind: .channel, query: "", sigilOffset: 0), in: dm
        )
        #expect(channels.isEmpty)
    }
}
