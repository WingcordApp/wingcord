import AppKit
import Foundation
import Testing
@testable import Wingcord
import WingcordCore

/// Discord's event card as the app hosts it: what it draws, and its one
/// button by Discord's rules (`427080`'s `$`).
@MainActor
struct EventLinkCardTests {

    private let guildID = GuildID(rawValue: 10)
    private let room = ChannelID(rawValue: 20)
    private let eventID: UInt64 = 1_323_893_975_484_369_279

    private func model(joined: Bool = true, events: [ScheduledEvent]) -> AppModel {
        let model = AppModel()
        model.currentUserID = UserID(rawValue: 1)
        if joined {
            model.guilds = [guildID: Guild(id: guildID, name: "Wingcord", ownerID: UserID(rawValue: 2))]
        }
        model.scheduledEvents = joined ? [guildID: events] : [:]
        if !joined { for event in events { model.linkedEvents[event.id] = event } }
        return model
    }

    private func event(
        status: ScheduledEvent.Status = .scheduled,
        location: ScheduledEvent.Location = .external("The park"),
        imageHash: String? = nil,
        rule: RecurrenceRule? = nil
    ) -> ScheduledEvent {
        ScheduledEvent(
            id: eventID, guildID: guildID, name: "Town hall",
            description: "Everybody welcome. Bring questions.",
            imageHash: imageHash,
            startsAt: Date(timeIntervalSince1970: 1_800_000_000),
            status: status,
            location: location,
            rule: rule
        )
    }

    private var key: EventCardKey { EventCardKey(guildID: guildID, eventID: eventID) }

    @Test("The card draws its event, at Discord's widest, under a 164-point cover")
    func drawsItsEvent() {
        let plain = HostedCardHosts.measure(.event(key), model: model(events: [event()]))
        #expect(plain.width == 432)
        // The name, the description and the footer's button are all there.
        #expect(plain.height > 100)
        let covered = HostedCardHosts.measure(.event(key), model: model(events: [event(imageHash: "abc")]))
        #expect(covered.height == plain.height + 164)
    }

    @Test("No event yet, no card")
    func noEvent() {
        #expect(HostedCardHosts.measure(.event(key), model: model(events: [])).height == 0)
    }

    /// Discord's `p$`: a weekly series at 18:00 UTC has no date at 19:00.
    @Test("A date the series cannot have draws nothing")
    func impossibleDate() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let series = event(rule: RecurrenceRule(start: start, frequency: .weekly))
        let model = model(events: [series])
        let wrong = EventCardKey(
            guildID: guildID, eventID: eventID,
            occurrence: ScheduledEvent.occurrenceID(startingAt: start.addingTimeInterval(7 * 86_400 + 3_600))
        )
        #expect(HostedCardHosts.measure(.event(wrong), model: model).height == 0)
        let right = EventCardKey(
            guildID: guildID, eventID: eventID,
            occurrence: ScheduledEvent.occurrenceID(startingAt: start.addingTimeInterval(7 * 86_400))
        )
        #expect(HostedCardHosts.measure(.event(right), model: model).height > 0)
    }

    @Test("The button follows Discord's order")
    func button() {
        let outsider = model(joined: false, events: [event()])
        #expect(outsider.cardAction(for: key, event: event()) == .joinServer)

        let member = model(events: [event()])
        #expect(member.cardAction(for: key, event: event(status: .active)) == .viewDetails)
        #expect(member.cardAction(for: key, event: event(status: .active, location: .voice(room))) == .join)
        member.connectedVoiceChannelID = room
        #expect(member.cardAction(for: key, event: event(status: .active, location: .voice(room))) == .goToChannel)
        #expect(member.cardAction(for: key, event: event(status: .completed)) == .over)
        #expect(member.cardAction(for: key, event: event(status: .canceled)) == .over)
        #expect(member.cardAction(for: key, event: event()) == .interested(false))
        member.eventAnswers[eventID] = EventAnswers(series: .interested)
        #expect(member.cardAction(for: key, event: event()) == .interested(true))
    }
}
