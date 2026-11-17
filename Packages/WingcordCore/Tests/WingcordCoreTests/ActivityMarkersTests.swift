import Foundation
import Testing
@testable import WingcordCore

/// Discord's markers per kind and per place (`506326`): docs/ACTIVITY-CARDS.md
/// decision 5.
struct ActivityMarkersTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let author = UserID(rawValue: 2)

    private func entry(_ subject: RecentActivity.Subject, _ traits: [RecentActivity.Trait] = []) -> RecentActivity {
        RecentActivity(id: "1", authorID: author, subject: subject, traits: traits)
    }

    private func words(_ markers: [ActivityMarker]) -> [String] {
        markers.map { marker in
            if case .words(let text) = marker.text { return text }
            return "clock"
        }
    }

    @Test func topArtistSaysLessOnTheCard() {
        let artist = entry(.listening(track: "T", artist: "A", artworkURL: nil), [.week, .weeklyCount(14)])
        let context = ActivityMarkers.Context(now: now)
        #expect(words(ActivityMarkers.markers(for: artist, at: .card, context: context)) == ["14 tracks this week"])
        #expect(words(ActivityMarkers.markers(for: artist, at: .popout, context: context))
            == ["Top Artist \u{2013} 14 tracks this week"])
    }

    @Test func mostPlayedRoundsTheWeeksHours() {
        let top = entry(.topGame(name: "G", applicationID: nil), [.week, .duration(12.4 * 3600)])
        let context = ActivityMarkers.Context(now: now)
        #expect(words(ActivityMarkers.markers(for: top, at: .card, context: context)) == ["Most played: 12h"])
        #expect(words(ActivityMarkers.markers(for: top, at: .popout, context: context)) == ["Most played \u{2014} 12h this week"])
    }

    @Test func aGameKeepsDiscordsOrder() {
        let game = entry(.game(name: "G", applicationID: nil), [.newPlayer, .trending, .marathon, .duration(4 * 3600)])
        let context = ActivityMarkers.Context(party: "In a Match (2 of 4)", voiceChannelName: "lounge", now: now)
        let card = ActivityMarkers.markers(for: game, at: .card, context: context)
        #expect(words(card) == ["clock", "In a Match (2 of 4)", "lounge", "New Player", "Trending", "4h Marathon"])
        #expect(card[3].tintsSymbol, "New Player's glyph is green on the card")
        #expect(!card[3].tintsText)
        #expect(card[5].tooltip == "Played for 4h")
        // The popout has a voice bar instead, and no green glyph.
        let popout = ActivityMarkers.markers(for: game, at: .popout, context: context)
        #expect(!words(popout).contains("lounge"))
        #expect(popout.first { $0.symbol == "leaf.fill" }?.tintsSymbol == false)
    }

    @Test func returningIsShortOnTheCardOnly() throws {
        let since = Calendar(identifier: .gregorian).date(byAdding: .month, value: -2, to: now)!
        let game = entry(.game(name: "G", applicationID: nil), [.returning(lastPlayed: since)])
        let context = ActivityMarkers.Context(now: now)
        let card = try #require(ActivityMarkers.markers(for: game, at: .card, context: context).last)
        #expect(card.text == .words("Returning"))
        #expect(card.tooltip?.hasPrefix("Returning after") == true)
        let popout = try #require(ActivityMarkers.markers(for: game, at: .popout, context: context).last)
        #expect(popout.text != .words("Returning"))
    }

    @Test func aLiveClockIsGreenOnTheCard() {
        var game = entry(.game(name: "G", applicationID: nil), [.live])
        game.expiresAt = now.addingTimeInterval(600)
        let card = ActivityMarkers.markers(for: game, at: .card, context: .init(now: now))
        #expect(card.first?.tintsText == true)
        let popout = ActivityMarkers.markers(for: game, at: .popout, context: .init(now: now))
        #expect(popout.first?.tintsText == false)
    }

    @Test func watchedMediaShowsItsEpisode() {
        var show = entry(.watched(title: "Show", subtitle: nil, applicationID: nil))
        show.details.episodeText = "Season 2, Episode 11"
        let markers = ActivityMarkers.markers(for: show, at: .card, context: .init(now: now))
        #expect(words(markers) == ["clock", "S2E11"])
        #expect(markers.last?.accessibilityText == "Season 2, Episode 11")
    }

    @Test func discordsDrawRules() {
        #expect(!ActivityCardRules.isDrawable(entry(.listening(track: "T", artist: nil, artworkURL: nil), [.weeklyCount(3)]),
                                              isStillListening: false))
        #expect(ActivityCardRules.isDrawable(entry(.listening(track: "T", artist: nil, artworkURL: nil), [.week, .weeklyCount(3)]),
                                             isStillListening: false))
        #expect(!ActivityCardRules.isDrawable(entry(.listeningSession(track: "T", artists: [], artworkURL: nil)),
                                              isStillListening: false))
    }

    @Test func partyWords() {
        #expect(ActivityCardRules.partyText(state: "In a Match", size: [2, 4]) == "In a Match (2 of 4)")
        #expect(ActivityCardRules.partyText(state: nil, size: [3]) == "3")
        #expect(ActivityCardRules.partyText(state: "Lobby", size: nil) == "Lobby")
        #expect(ActivityCardRules.partyText(state: nil, size: nil) == nil)
    }
}
