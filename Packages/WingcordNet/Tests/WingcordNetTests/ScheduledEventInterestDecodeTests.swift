import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// The interest routes, read off `scheduled event.har` — the counts, the
/// people, and the PUT's own reply — verbatim apart from trimming.
struct ScheduledEventInterestDecodeTests {

    @Test("Counts: the series' and each asked-about date's, keyed on the date")
    func counts() throws {
        let captured = #"""
        {"guild_scheduled_event_count":611,"guild_scheduled_event_exception_counts":{"1588436611891200000":623}}
        """#
        let counts = try JSONDecoder().decode(ScheduledEventCountsDTO.self, from: Data(captured.utf8)).domain
        #expect(counts.series == 611)
        #expect(counts.occurrences[1_588_436_611_891_200_000] == 623)
    }

    @Test("The PUT's reply for one date carries the date; the series' does not")
    func rsvpReplies() throws {
        let date = #"""
        {"guild_scheduled_event_id":"1323893975484369279","guild_scheduled_event_exception_id":"1588436611891200000","user_id":"987654321987654321","response":1}
        """#
        let series = #"""
        {"guild_scheduled_event_id":"1323893975484369279","user_id":"987654321987654321","response":1}
        """#
        let one = try #require(try JSONDecoder().decode(ScheduledEventRSVPDTO.self, from: Data(date.utf8)).domain)
        #expect(one.occurrence == 1_588_436_611_891_200_000)
        #expect(one.response == .interested)
        let all = try #require(try JSONDecoder().decode(ScheduledEventRSVPDTO.self, from: Data(series.utf8)).domain)
        #expect(all.occurrence == nil)
        #expect(all.eventID == 1_323_893_975_484_369_279)
    }

    @Test("A date's 'not this one' decodes as uninterested, beside the series' yes")
    func peopleList() throws {
        let captured = #"""
        [{"guild_scheduled_event_id":"1323893975484369279","user_id":"78777797702582272",
          "user":{"id":"78777797702582272","username":"tolver","avatar":"5c7a00ec198fc5f945e8e90f3fbe97a8","discriminator":"0","global_name":"Mateo"},
          "response":1},
         {"guild_scheduled_event_id":"1323893975484369279","guild_scheduled_event_exception_id":"1588436611891200000",
          "user_id":"98455211681885722",
          "user":{"id":"98455211681885722","username":"kip4242","avatar":null,"discriminator":"0","global_name":"KIP"},
          "member":{"avatar":null,"banner":null,"communication_disabled_until":null,"flags":42,
                    "joined_at":"2023-06-30T10:42:22.975000+00:00","nick":null,"pending":false,
                    "premium_since":null,"roles":[]},
          "response":0}]
        """#
        // The REST decoder, which reads Discord's timestamps.
        let rows = try DiscordREST.decoder.decode([ScheduledEventUserDTO].self, from: Data(captured.utf8))
            .compactMap(\.domain)
        #expect(rows.count == 2)
        #expect(rows[0].user.displayName == "Mateo")
        #expect(rows[0].rsvp.occurrence == nil)
        #expect(rows[1].rsvp.response == .uninterested)
        #expect(rows[1].rsvp.occurrence == 1_588_436_611_891_200_000)
        #expect(rows[1].member != nil)
    }

    @Test("An event's rule and its moved dates come through whole")
    func eventRuleAndExceptions() throws {
        let captured = #"""
        {"id":"1323893975484369279","guild_id":"603970300668805120","name":"the last thread of the year",
         "scheduled_start_time":"2027-01-01T06:00:00+00:00","status":1,"entity_type":3,"channel_id":null,
         "entity_metadata":{"location":"pork's house"},
         "recurrence_rule":{"start":"2026-01-01T06:00:00+00:00","end":null,"frequency":0,"interval":1,
                            "by_weekday":null,"by_n_weekday":null,"by_month":[1],"by_month_day":[1],
                            "by_year_day":null,"count":null},
         "guild_scheduled_event_exceptions":[{"event_exception_id":"1720708182835200000","event_id":"1323893975484369279",
            "guild_id":"603970300668805120","scheduled_start_time":null,"scheduled_end_time":null,"is_canceled":true}]}
        """#
        let dto = try DiscordREST.decoder.decode(ScheduledEventDTO.self, from: Data(captured.utf8))
        let event = try #require(dto.domain(fallbackGuildID: GuildID(rawValue: 603_970_300_668_805_120)))
        #expect(event.rule?.frequency == .yearly)
        #expect(event.exceptions.first?.isCanceled == true)
        #expect(event.status(of: 1_720_708_182_835_200_000) == .canceled)
        #expect(event.currentOccurrenceID == 1_588_436_611_891_200_000)
    }
}
