import CoreGraphics
import Foundation
import Testing
@testable import Wingcord
import WingcordCore

/// Discord's event card in a transcript: under an event link, in place of an
/// invite that brought an event, and under the stage start that began one —
/// each once the card has measured itself.
@MainActor
struct EventCardLayoutTests {

    private let guildID = GuildID(rawValue: 603_970_300_668_805_120)
    private let eventID: UInt64 = 1_323_893_975_484_369_279
    private var link: String { "https://discord.com/events/\(guildID.rawValue)/\(eventID)" }

    private func measured(_ sizes: [CGSize]) -> HostedCardMeasure {
        var measure = HostedCardMeasure()
        for size in sizes { _ = measure.note(size) }
        return measure
    }

    private func event(status: ScheduledEvent.Status = .scheduled) -> ScheduledEvent {
        ScheduledEvent(
            id: eventID, guildID: guildID, name: "Town hall",
            startsAt: Date(timeIntervalSince1970: 1_800_000_000),
            status: status,
            location: .external("The park")
        )
    }

    private func laidOut(
        content: String,
        kind: MessageKind = .default,
        width: CGFloat = 700,
        sizes: [HostedCardKey: HostedCardMeasure] = [:],
        invites: [String: InviteLookup] = [:],
        liveEvent: TimelineLayoutEngine.LiveEvent? = nil,
        cache: inout [MessageID: TimelineLayoutEngine.CacheEntry]
    ) -> MessageRow? {
        let items: [TimelineItem] = [.message(TimelineMessage(
            message: Message(
                id: MessageID(rawValue: 1),
                channelID: ChannelID(rawValue: 1),
                authorID: UserID(rawValue: 1),
                content: content,
                kind: kind
            ),
            flags: [.head, .tail]
        ))]
        let laid = TimelineLayoutEngine(presentationRevision: 1).layout(
            TimelineLayoutEngine.Input(
                items: items,
                width: width,
                style: MessageTextStyle.current(),
                mentions: MentionContext(),
                channelName: "general",
                authors: [:],
                calendar: .current,
                settings: .comfortable,
                invites: invites,
                hostedCardSizes: sizes,
                guildID: guildID,
                liveEvent: liveEvent
            ),
            cache: &cache
        )
        guard let first = laid.first, case .message(let row) = first.kind else { return nil }
        return row
    }

    private func laidOut(
        content: String,
        kind: MessageKind = .default,
        width: CGFloat = 700,
        sizes: [HostedCardKey: HostedCardMeasure] = [:],
        invites: [String: InviteLookup] = [:],
        liveEvent: TimelineLayoutEngine.LiveEvent? = nil
    ) -> MessageRow? {
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        return laidOut(
            content: content, kind: kind, width: width, sizes: sizes,
            invites: invites, liveEvent: liveEvent, cache: &cache
        )
    }

    @Test("Until the card has measured itself, an event link is only a link")
    func unmeasured() throws {
        let row = try #require(laidOut(content: "see \(link)"))
        #expect(row.hostedCards.isEmpty)
    }

    @Test("A measured card is Discord's 432 wide in a wide column, at its measured height")
    func measuredWide() throws {
        let key = HostedCardKey.event(EventCardKey(guildID: guildID, eventID: eventID))
        let row = try #require(laidOut(
            content: "see \(link)",
            sizes: [key: measured([CGSize(width: 432, height: 310)])]
        ))
        #expect(row.hostedCards.map(\.rect.size) == [CGSize(width: 432, height: 310)])
    }

    /// The card is the column's width there, and its height is the nearest it
    /// has until the live card reports the one at that width.
    @Test("In a narrow column the card takes the column, and its height at that width once known")
    func measuredNarrow() throws {
        let key = HostedCardKey.event(EventCardKey(guildID: guildID, eventID: eventID))
        let first = try #require(laidOut(
            content: "see \(link)",
            width: 360,
            sizes: [key: measured([CGSize(width: 432, height: 310)])]
        ))
        let width = try #require(first.hostedCards.first?.rect.width)
        #expect(width < 432)
        #expect(first.hostedCards.first?.rect.height == 310)

        let second = try #require(laidOut(
            content: "see \(link)",
            width: 360,
            sizes: [key: measured([CGSize(width: 432, height: 310), CGSize(width: width, height: 346)])]
        ))
        #expect(second.hostedCards.first?.rect.height == 346)
    }

    /// `346542`'s `ly`: an invite carrying an event that is not over is that
    /// event's card, and the invite card is not drawn as well.
    @Test("An invite that brought an event not yet over is the event's card")
    func inviteWithEvent() throws {
        let code = "wingcord?event=\(eventID)"
        let invite = InviteCard(code: "wingcord", kind: .server, guildID: guildID, name: "Wingcord", event: event())
        let key = HostedCardKey.event(EventCardKey(guildID: guildID, eventID: eventID, invite: code))
        let row = try #require(laidOut(
            content: "come https://discord.gg/\(code)",
            sizes: [key: measured([CGSize(width: 432, height: 300)])],
            invites: [code: .resolved(invite)]
        ))
        #expect(row.hostedCards.map(\.key) == [key])
        #expect(row.inviteCards.isEmpty)
    }

    @Test("An invite whose event is over is the invite card again")
    func inviteWithEndedEvent() throws {
        let code = "wingcord?event=\(eventID)"
        let invite = InviteCard(
            code: "wingcord", kind: .server, guildID: guildID, name: "Wingcord", event: event(status: .completed)
        )
        let row = try #require(laidOut(
            content: "come https://discord.gg/\(code)",
            invites: [code: .resolved(invite)]
        ))
        #expect(row.hostedCards.isEmpty)
        #expect(row.inviteCards.count == 1)
    }

    /// Discord's `STAGE_START` renderer: the card only while the channel's
    /// live event has the line's topic for its name.
    @Test("A stage start wears the card of the live event it named, and no other")
    func stageStart() throws {
        let key = HostedCardKey.event(EventCardKey(guildID: guildID, eventID: eventID))
        let sizes = [key: measured([CGSize(width: 432, height: 300)])]
        let live = TimelineLayoutEngine.LiveEvent(guildID: guildID, id: eventID, name: "Town hall")
        let named = try #require(laidOut(content: "Town hall", kind: .stageStart, sizes: sizes, liveEvent: live))
        #expect(named.hostedCards.map(\.key) == [key])

        var other = live
        other.name = "Something else"
        let unnamed = try #require(laidOut(content: "Town hall", kind: .stageStart, sizes: sizes, liveEvent: other))
        #expect(unnamed.hostedCards.isEmpty)

        let ended = try #require(laidOut(content: "Town hall", kind: .stageStart, sizes: sizes))
        #expect(ended.hostedCards.isEmpty)
    }

    /// The event starting after the line was laid out must reach a row the
    /// cache already holds.
    @Test("An event going live gives a cached stage start its card")
    func stageStartRelaidOut() throws {
        let key = HostedCardKey.event(EventCardKey(guildID: guildID, eventID: eventID))
        let sizes = [key: measured([CGSize(width: 432, height: 300)])]
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        let before = try #require(laidOut(content: "Town hall", kind: .stageStart, sizes: sizes, cache: &cache))
        #expect(before.hostedCards.isEmpty)
        let live = TimelineLayoutEngine.LiveEvent(guildID: guildID, id: eventID, name: "Town hall")
        let after = try #require(laidOut(
            content: "Town hall", kind: .stageStart, sizes: sizes, liveEvent: live, cache: &cache
        ))
        #expect(after.hostedCards.map(\.key) == [key])
    }
}
