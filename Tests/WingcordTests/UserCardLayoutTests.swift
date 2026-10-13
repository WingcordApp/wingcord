import CoreGraphics
import Foundation
import Testing
@testable import Wingcord
import WingcordCore

/// A profile link in a message: Discord's user profile embed takes the space
/// its card measured, and the link's own unfurl gives way to it.
@MainActor
struct UserCardLayoutTests {

    private let link = "https://discord.com/users/732280746023186586"
    private let person = UserID(rawValue: 732_280_746_023_186_586)
    private let guildID = GuildID(rawValue: 7)

    private func laidOut(sizes: [HostedCardKey: CGSize]) -> MessageRow? {
        let items: [TimelineItem] = [.message(TimelineMessage(
            message: Message(
                id: MessageID(rawValue: 1),
                channelID: ChannelID(rawValue: 1),
                authorID: UserID(rawValue: 1),
                content: "look \(link)",
                payload: MessagePayload(embeds: [Embed(title: "Discord", kind: "article", url: link)])
            ),
            flags: [.head, .tail]
        ))]
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        let laid = TimelineLayoutEngine(presentationRevision: 1).layout(
            TimelineLayoutEngine.Input(
                items: items,
                width: 700,
                style: MessageTextStyle.current(),
                mentions: MentionContext(),
                channelName: "general",
                authors: [:],
                calendar: .current,
                settings: .comfortable,
                hostedCardSizes: sizes.mapValues { size in
                    var measure = HostedCardMeasure()
                    _ = measure.note(size)
                    return measure
                },
                guildID: guildID
            ),
            cache: &cache
        )
        guard let first = laid.first, case .message(let row) = first.kind else { return nil }
        return row
    }

    @Test("Until the card has measured itself, the link is only a link")
    func unmeasured() throws {
        let row = try #require(laidOut(sizes: [:]))
        #expect(row.hostedCards.isEmpty)
        #expect(row.embeds.count == 1)
    }

    @Test("A measured card takes its size, and the unfurl gives way")
    func measured() throws {
        let key = HostedCardKey.user(UserCardKey(userID: person, guildID: guildID))
        let row = try #require(laidOut(sizes: [key: CGSize(width: 300, height: 380)]))
        #expect(row.hostedCards.count == 1)
        #expect(row.hostedCards.first?.rect.size == CGSize(width: 300, height: 380))
        #expect(row.embeds.isEmpty)
    }

    /// The same person's card in another server is a different card.
    @Test("A card measured in another server is not this one")
    func otherServer() throws {
        let key = HostedCardKey.user(UserCardKey(userID: person, guildID: GuildID(rawValue: 8)))
        let row = try #require(laidOut(sizes: [key: CGSize(width: 300, height: 380)]))
        #expect(row.hostedCards.isEmpty)
    }
}
