import Foundation
import Testing
@testable import Wingcord
import WingcordCore

/// The running-activity store and the frame it opens (docs/ACTIVITIES-CALLS-PICKER.md,
/// decisions 1 and 2). Ids are made up.
@MainActor
@Suite("Activity instances")
struct ActivityInstancesTests {

    private let whiteboard = ApplicationID(rawValue: 1_070_087_967_294_631_976)
    private let wordle = ApplicationID(rawValue: 1_211_781_489_931_452_447)
    private let server = GuildID(rawValue: 1_400_000_000_000_000_001)
    private let hub = ChannelID(rawValue: 1_400_000_000_000_000_002)
    private let dm = ChannelID(rawValue: 1_400_000_000_000_000_009)
    private let me = UserID(rawValue: 1_300_000_000_000_000_001)
    private let friend = UserID(rawValue: 1_300_000_000_000_000_002)

    private func instance(
        _ app: ApplicationID, launch: String, in channel: ChannelID, guild: GuildID?,
        _ participants: [ActivityParticipant]
    ) -> ActivityInstance {
        ActivityInstance(
            applicationID: app, launchID: launch,
            location: ActivityLocation(guildID: guild, channelID: channel),
            participants: participants
        )
    }

    @Test("One instance per app per place; an empty one has ended")
    func applyAndEnd() {
        let store = ActivityInstances()
        store.apply(instance(whiteboard, launch: "10", in: hub, guild: server,
                             [ActivityParticipant(userID: friend, sessionID: "f")]))
        store.apply(instance(whiteboard, launch: "10", in: hub, guild: server,
                             [ActivityParticipant(userID: friend, sessionID: "f"),
                              ActivityParticipant(userID: me, sessionID: "mine", nonce: "n")]))
        #expect(store.instances(in: hub).count == 1)
        #expect(store.instance(of: whiteboard, in: hub)?.participants.count == 2)
        #expect(store.instance(for: me, session: "mine")?.launchID == "10")
        #expect(store.instance(for: me, session: "other client") == nil)
        #expect(store.instance(for: friend)?.channelID == hub)

        store.apply(instance(whiteboard, launch: "10", in: hub, guild: server, []))
        #expect(store.instance(of: whiteboard, in: hub) == nil)
        #expect(store.byLocation.isEmpty)
    }

    @Test("A server's bootstrap list replaces that server's, and a new connection keeps the DMs")
    func bootstrapReplaces() {
        let store = ActivityInstances()
        store.apply(instance(whiteboard, launch: "10", in: hub, guild: server,
                             [ActivityParticipant(userID: friend)]))
        store.apply(instance(wordle, launch: "20", in: dm, guild: nil,
                             [ActivityParticipant(userID: friend)]))
        // The server now lists nothing running: the whiteboard ended.
        store.replace(guild: server, with: [])
        #expect(store.instance(of: whiteboard, in: hub) == nil)
        #expect(store.instance(of: wordle, in: dm) != nil)

        store.replaceGuilds([server: [instance(whiteboard, launch: "11", in: hub, guild: server,
                                               [ActivityParticipant(userID: me)])]])
        #expect(store.instance(of: whiteboard, in: hub)?.launchID == "11")
        // DMs are listed by no bootstrap, so they stay until their own update.
        #expect(store.instance(of: wordle, in: dm) != nil)
    }

    @Test("Newest instance wins for a person; launch ids compare as numbers")
    func newestForPerson() {
        let store = ActivityInstances()
        store.apply(instance(whiteboard, launch: "999", in: hub, guild: server,
                             [ActivityParticipant(userID: friend)]))
        store.apply(instance(wordle, launch: "1000", in: dm, guild: nil,
                             [ActivityParticipant(userID: friend)]))
        #expect(store.instance(for: friend)?.launchID == "1000")
    }

    @Test("The frame names the instance it was put in, and its server")
    func frameURL() throws {
        let running = instance(whiteboard, launch: "1500000000000000123", in: hub, guild: server,
                               [ActivityParticipant(userID: me, sessionID: "mine")])
        let url = try #require(ActivityFrame.url(
            application: whiteboard, instance: running, proxyTicket: "ticket", isServerHubChannel: true
        ))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        #expect(url.host() == "1070087967294631976.discordsays.com")
        #expect(value("instance_id") == "i-1500000000000000123-gc-1400000000000000001-1400000000000000002")
        #expect(value("launch_id") == "1500000000000000123")
        #expect(value("location_id") == "gc-1400000000000000001-1400000000000000002")
        #expect(value("guild_id") == "1400000000000000001")
        #expect(value("channel_id") == "1400000000000000002")
        #expect(value("surface") == "5")
        // In a DM there is no server to name.
        let direct = instance(wordle, launch: "1500000000000000200", in: dm, guild: nil, [])
        let dmURL = try #require(ActivityFrame.url(application: wordle, instance: direct, proxyTicket: "t"))
        #expect(dmURL.query()?.contains("guild_id") == false)
    }

    @Test("A launch's waiter answers only its own record")
    func pendingMatches() {
        let app = ActivityApp(id: wordle, name: "Wordle", config: EmbeddedActivityConfig(supportedPlatforms: ["web"]))
        let launch = PendingActivityConnect(app: app, channelID: dm, nonce: "mine", ticket: "t")
        let running = instance(wordle, launch: "30", in: dm, guild: nil, [])
        #expect(launch.matches(running, record: ActivityParticipant(userID: me, sessionID: "s", nonce: "mine")))
        #expect(!launch.matches(running, record: ActivityParticipant(userID: me, sessionID: "s", nonce: "another launch")))
        // Somewhere else, or another app: never.
        #expect(!launch.matches(instance(wordle, launch: "31", in: hub, guild: server, []),
                                record: ActivityParticipant(userID: me, sessionID: "s", nonce: "mine")))
        // A join sends no nonce, so any record of ours in that app and place answers it.
        let join = PendingActivityConnect(app: app, channelID: dm, nonce: nil, ticket: "t")
        #expect(join.matches(running, record: ActivityParticipant(userID: me, sessionID: "s")))
    }
}
