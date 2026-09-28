import Foundation
import Testing
@testable import WingcordCore

/// What Discord's activity card says (modules `580763`, `160376`, `282197`).
@Suite("Activity card")
struct ActivityCardTests {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// **The card Alex photographed**: PreMiD's YouTube presence — the video
    /// as its details, the channel as its state.
    @Test("Watching YouTube: the video, the channel, and a screen on the clock")
    func youTube() {
        let card = ActivityCardContent(Activity(
            kind: .watching,
            name: "YouTube",
            state: "WholyMilk",
            details: "How to setup BL2 Mods in 2026",
            startedAt: start
        ))
        #expect(card.header == "Watching YouTube")
        #expect(card.platform == "youtube")
        #expect(card.title == "How to setup BL2 Mods in 2026")
        #expect(card.subtitle == "WholyMilk")
        #expect(card.detail == nil)
        #expect(card.clockGlyph == .screen)
        #expect(card.clockStart == start)
        #expect(!card.showsProgress)
    }

    @Test("Both ends known is a bar, not a clock")
    func progress() {
        let card = ActivityCardContent(Activity(
            kind: .watching, name: "YouTube", details: "A video",
            startedAt: start, endsAt: start.addingTimeInterval(600)
        ))
        #expect(card.showsProgress)
        #expect(card.clockStart == nil)
    }

    /// A game leads with its own name, and its party rides beside the clock —
    /// so the state is not also the third line.
    @Test("A game: its name, what it is doing, and the party by the clock")
    func gameWithParty() {
        let card = ActivityCardContent(Activity(
            kind: .playing,
            name: "Counter-Strike 2",
            state: "In Queue",
            details: "Competitive",
            startedAt: start,
            partySize: [2, 5]
        ))
        #expect(card.header == "Playing")
        #expect(card.title == "Counter-Strike 2")
        #expect(card.subtitle == "Competitive")
        #expect(card.detail == nil)
        #expect(card.party == "In Queue (2 of 5)")
        #expect(card.clockGlyph == .game)
    }

    @Test("A game with no party says its state on the third line")
    func gameWithoutParty() {
        let card = ActivityCardContent(Activity(
            kind: .playing, name: "Minecraft", state: "Survival", details: "In a world"
        ))
        #expect(card.detail == "Survival")
        #expect(card.party == nil)
    }

    @Test("A console says where it is played", arguments: [
        ("xbox", "Playing on Xbox"),
        ("ps5", "Playing on PlayStation"),
        ("desktop", "Playing"),
    ])
    func consoles(platform: String, header: String) {
        let card = ActivityCardContent(Activity(kind: .playing, name: "Halo", platform: platform))
        #expect(card.header == header)
    }

    @Test("Spotify is named with its mark")
    func spotify() {
        let card = ActivityCardContent(Activity(
            kind: .listening, name: "Spotify", state: "Porter Robinson",
            details: "Cheerleader", partyID: "spotify:1"
        ))
        #expect(card.header == "Listening to Spotify")
        #expect(card.platform == "spotify")
        #expect(card.title == "Cheerleader")
        #expect(card.clockGlyph == .music)
    }

    @Test("A show that names its episode gets it beside the clock", arguments: [
        ("Season 1, Episode 5", "S1E5"),
        ("Now: Season 12, Episode 3 (dub)", "S12E3"),
        ("Episode five", nil),
    ])
    func episodes(caption: String, episode: String?) {
        let card = ActivityCardContent(Activity(
            kind: .watching, name: "Crunchyroll", details: "A show", largeText: caption
        ))
        #expect(card.episode == episode)
    }

    @Test("The clock is m:ss, then h:mm:ss", arguments: [
        (2, "0:02"),
        (65, "1:05"),
        (3725, "1:02:05"),
    ])
    func clock(seconds: Int, text: String) {
        #expect(ActivityCardContent.clock(seconds) == text)
    }
}
