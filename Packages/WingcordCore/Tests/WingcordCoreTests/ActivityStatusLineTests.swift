import Foundation
import Testing
@testable import WingcordCore

/// Discord's order for somebody's activities (its presence store, module
/// `290863`) and the one line it draws from them (`ActivityStatus`, module
/// `394871`). Every expectation below is a branch of those two modules.
@Suite("Activity order and the status line")
struct ActivityStatusLineTests {

    private func activity(
        _ kind: Activity.Kind,
        _ name: String,
        state: String? = nil,
        details: String? = nil,
        application: UInt64? = nil,
        createdAt: TimeInterval? = nil,
        isEmbedded: Bool = false,
        partyID: String? = nil,
        emoji: EmojiRef? = nil
    ) -> Activity {
        Activity(
            kind: kind,
            name: name,
            state: state,
            details: details,
            applicationID: application.map(ApplicationID.init(rawValue:)),
            emoji: emoji,
            createdAt: createdAt.map(Date.init(timeIntervalSince1970:)),
            isEmbedded: isEmbedded,
            partyID: partyID
        )
    }

    private func names(_ list: [Activity]) -> [String] { list.map(\.name) }

    // MARK: The order

    /// Alex's instinct, and Discord's rule with two more ranks above it:
    /// Competing, Streaming and Playing all come before Listening and Watching.
    @Test("Custom status, Competing, Streaming, Playing, then the rest")
    func rankOrder() {
        let presented = ActivityOrder.presented([
            activity(.listening, "Spotify"),
            activity(.watching, "YouTube"),
            activity(.playing, "Counter-Strike 2"),
            activity(.custom, "Custom Status"),
            activity(.streaming, "Twitch"),
            activity(.competing, "Arena"),
        ])
        #expect(names(presented) == [
            "Custom Status", "Arena", "Twitch", "Counter-Strike 2", "Spotify", "YouTube",
        ])
    }

    @Test("Within a rank, a rich presence leads and then the newest")
    func tieBreaks() {
        let presented = ActivityOrder.presented([
            activity(.listening, "Old bare", createdAt: 100),
            activity(.listening, "Rich", details: "a track", createdAt: 50),
            activity(.listening, "New bare", createdAt: 200),
        ])
        #expect(names(presented) == ["Rich", "New bare", "Old bare"])
    }

    /// JavaScript's sort is stable and Swift's is not, so a tie that is equal
    /// on every key has to come out in the order it arrived.
    @Test("A full tie keeps the order it arrived in")
    func stableTies() {
        let presented = ActivityOrder.presented([
            activity(.watching, "B"),
            activity(.watching, "A"),
            activity(.watching, "C"),
        ])
        #expect(names(presented) == ["B", "A", "C"])
    }

    @Test("Only the first-ranked Playing survives")
    func onePlaying() {
        let presented = ActivityOrder.presented([
            activity(.playing, "Older game", createdAt: 1),
            activity(.listening, "Spotify"),
            activity(.playing, "Newer game", createdAt: 2),
        ])
        #expect(names(presented) == ["Newer game", "Spotify"])
    }

    @Test("A presence is ordered where it is made")
    func presenceIsOrdered() {
        let presence = Presence(
            userID: UserID(rawValue: 1),
            status: .online,
            activities: PresenceActivities(list: [
                activity(.listening, "Spotify"),
                activity(.playing, "Counter-Strike 2"),
            ])
        )
        #expect(presence.primaryActivity?.name == "Counter-Strike 2")
    }

    // MARK: The line

    @Test("An activity alone: its glyph and its name, with no verb")
    func activityAlone() {
        let line = ActivityStatusLine.resolve(activities: [activity(.playing, "Counter-Strike 2")])
        #expect(line.glyph == .game)
        #expect(line.text == "Counter-Strike 2")
        #expect(line.overflow == 0)
        #expect(line.spokenLead == "Playing Counter-Strike 2")
        #expect(!line.hasStatus)
    }

    /// **The rule Alex asked for**: with a custom status that has words, the
    /// activity keeps only its glyph and the status takes the text.
    @Test("A custom status with words takes the text from the activity")
    func statusTakesTheText() {
        let wave = EmojiRef(name: "👋")
        let line = ActivityStatusLine.resolve(activities: ActivityOrder.presented([
            activity(.playing, "Counter-Strike 2"),
            activity(.custom, "Custom Status", state: "  back in 10  ", emoji: wave),
        ]))
        #expect(line.glyph == .game)
        #expect(line.text == nil)
        #expect(line.statusEmoji == wave)
        #expect(line.statusText == "back in 10")
        #expect(line.hasLead)
    }

    @Test("An emoji-only status leaves the activity its words")
    func emojiOnlyStatus() {
        let line = ActivityStatusLine.resolve(activities: [
            activity(.custom, "Custom Status", emoji: EmojiRef(name: "😴")),
            activity(.listening, "Apple Music", details: "a track"),
        ])
        #expect(line.text == "Apple Music")
        #expect(line.statusText == nil)
        #expect(line.hasStatus)
    }

    @Test("More than one activity is a count after the first")
    func overflowCounts() {
        let line = ActivityStatusLine.resolve(activities: ActivityOrder.presented([
            activity(.listening, "Spotify"),
            activity(.watching, "YouTube"),
            activity(.playing, "Counter-Strike 2"),
        ]))
        #expect(line.text == "Counter-Strike 2")
        #expect(line.overflow == 2)
    }

    @Test("The same application twice is one activity")
    func duplicatesCollapse() {
        let line = ActivityStatusLine.resolve(activities: [
            activity(.watching, "YouTube", application: 7),
            activity(.watching, "YouTube Music", application: 7),
        ])
        #expect(line.overflow == 0)
    }

    @Test("Glyphs follow the kind", arguments: [
        (Activity.Kind.playing, ActivityStatusLine.Glyph.game),
        (.competing, .game),
        (.listening, .music),
        (.watching, .screen),
        (.streaming, .screen),
    ])
    func glyphs(kind: Activity.Kind, glyph: ActivityStatusLine.Glyph) {
        let line = ActivityStatusLine.resolve(activities: [activity(kind, "App", details: "x")])
        #expect(line.glyph == glyph)
    }

    @Test("Spotify names the artists, joined the way it sends them")
    func spotifyArtists() {
        let line = ActivityStatusLine.resolve(activities: [
            activity(.listening, "Spotify", state: "Porter Robinson; Madeon", partyID: "spotify:42"),
        ])
        #expect(line.text == "Porter Robinson, Madeon")
        #expect(line.spokenLead == "Listening to Porter Robinson, Madeon")
    }

    @Test("A stream leads, named after the game, which is not counted twice")
    func streamLeads() {
        let line = ActivityStatusLine.resolve(
            activities: [activity(.playing, "Counter-Strike 2"), activity(.listening, "Spotify")],
            isStreaming: true
        )
        #expect(line.glyph == .screen)
        #expect(line.text == "Counter-Strike 2")
        #expect(line.overflow == 1)
    }

    @Test("A stream of no game is 'Sharing their screen'")
    func desktopStream() {
        let line = ActivityStatusLine.resolve(activities: [], isStreaming: true)
        #expect(line.text == "Sharing their screen")
    }

    @Test("In voice with nothing else to say, the call leads")
    func voiceLeads() {
        let line = ActivityStatusLine.resolve(activities: [], voice: .voiceChannel)
        #expect(line.glyph == .voice)
        #expect(line.text == "In voice")
        #expect(
            ActivityStatusLine.resolve(activities: [], voice: .stage).text == "In a stage"
        )
    }

    @Test("An activity leads a call, and the call is counted")
    func activityLeadsCall() {
        let line = ActivityStatusLine.resolve(
            activities: [activity(.playing, "Counter-Strike 2")],
            voice: .voiceChannel
        )
        #expect(line.glyph == .game)
        #expect(line.overflow == 1)
    }

    @Test("A bot's line draws no glyph and no count")
    func bots() {
        let line = ActivityStatusLine.resolve(
            activities: [activity(.playing, "Moderation"), activity(.watching, "the server")],
            isBot: true
        )
        #expect(line.glyph == nil)
        #expect(line.text == "Moderation")
        #expect(line.overflow == 0)
    }

    @Test("An embedded Activity is named, or 'In Activity'")
    func embedded() {
        #expect(ActivityStatusLine.resolve(
            activities: [activity(.playing, "Poker Night", isEmbedded: true)]
        ).glyph == .activity)
        #expect(ActivityStatusLine.resolve(
            activities: [activity(.playing, "", isEmbedded: true)]
        ).text == "In Activity")
    }

    @Test("Nothing to say is an empty line")
    func empty() {
        #expect(ActivityStatusLine.resolve(activities: []).isEmpty)
        #expect(ActivityStatusLine.resolve(
            activities: [activity(.custom, "Custom Status", state: "   ")]
        ).isEmpty)
    }
}
