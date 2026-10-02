import CoreGraphics
import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// The reader's Spotify on their status, the invitation it offers, and the
/// card a listen-along invitation draws from its host's presence.
@Suite("Listen along")
@MainActor
struct ListenAlongTests {

    private let readerID = UserID(rawValue: 1)
    private let hostID = UserID(rawValue: 2)
    private let guildID = GuildID(rawValue: 100)
    private let general = ChannelID(rawValue: 1001)
    private let dm = ChannelID(rawValue: 3001)

    private var hostParty: String { "spotify:\(hostID.rawValue)" }
    private var readerParty: String { "spotify:\(readerID.rawValue)" }

    private func model(showsActivity: Bool = true) -> AppModel {
        let model = AppModel()
        model.currentUserID = readerID
        model.users = [
            readerID: User(id: readerID, username: "alexsample", displayName: "alex"),
            hostID: User(id: hostID, username: "glassmage", displayName: "Glassmage"),
        ]
        model.guilds = [guildID: Guild(id: guildID, name: "Server", ownerID: readerID)]
        var index = ChannelIndex()
        index.replaceChannels([Channel(id: general, kind: .text, guildID: guildID, name: "general")], inGuild: guildID)
        index.replacePrivateChannels([Channel(id: dm, kind: .directMessage, recipientIDs: [hostID])])
        model.channelIndex = index
        model.connections = [AccountConnection(
            id: "31lktbiw5supkek5lw5fzysjsnzy", type: "spotify", name: "alex",
            isVerified: true, showsActivity: showsActivity, isVisibleOnProfile: true,
            isFriendSyncEnabled: false, isRevoked: false
        )]
        return model
    }

    private func playing(_ model: AppModel) {
        model.spotifyNowPlaying = SpotifyNowPlaying(
            accountID: "31lktbiw5supkek5lw5fzysjsnzy",
            item: SpotifyPlayback.Item(
                id: "6gbmylJ7sB7NFfMfTQHosf", name: "Alberto Balsalm", duration: 310_746,
                artists: [SpotifyPlayback.Artist(id: "a", name: "Aphex Twin")]
            ),
            startedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    private func hostListening(_ model: AppModel, party: String? = nil) {
        model.presences[hostID] = Presence(
            userID: hostID,
            status: .online,
            activities: PresenceActivities(list: [Activity(
                kind: .listening, name: "Spotify", state: "Aphex Twin", details: "Alberto Balsalm",
                largeImageKey: "spotify:ab67616d0000b2734bcecb123363f1f0f869257c",
                startedAt: Date(timeIntervalSince1970: 1_790_000_000),
                partyID: party ?? hostParty, syncID: "6gbmylJ7sB7NFfMfTQHosf", offersSync: true
            )])
        )
    }

    private func invite(_ party: String, in channelID: ChannelID, by author: UserID) -> Message {
        Message(
            id: MessageID(rawValue: 5 << 22),
            channelID: channelID,
            authorID: author,
            payload: MessagePayload(listenAlong: ListenAlongInvite(partyID: party))
        )
    }

    // MARK: The reader's status

    @Test("Spotify is on the status only where the connection says to show it")
    func shownByTheConnection() {
        let hidden = model(showsActivity: false)
        playing(hidden)
        #expect(hidden.spotifyActivity == nil)

        let shown = model()
        playing(shown)
        #expect(shown.spotifyActivity?.party?.id == readerParty)
        #expect(shown.publishedActivities.contains { $0.type == 2 && $0.name == "Spotify" })
    }

    @Test("Listening along joins the host's party")
    func alongJoinsTheParty() {
        let model = model()
        playing(model)
        model.listeningAlong = ListeningAlong(hostID: hostID, partyID: hostParty, trackID: "t", startedAt: .now)
        #expect(model.spotifyActivity?.party?.id == hostParty)
    }

    // MARK: The invitation

    @Test("The + menu offers the invitation by Discord's sentence, while Spotify is on the status")
    func invitationRow() {
        let model = model()
        #expect(model.listenAlongInvitationTitle(in: general) == nil)
        playing(model)
        #expect(model.listenAlongInvitationTitle(in: general) == "Invite #general to Listen to Spotify")
        #expect(model.listenAlongInvitationTitle(in: dm) == "Invite @Glassmage to Listen to Spotify")
    }

    @Test("Not to somebody already in the party")
    func notTwice() {
        let model = model()
        playing(model)
        hostListening(model, party: readerParty)
        #expect(model.listenAlongInvitationTitle(in: dm) == nil)
    }

    // MARK: The card

    @Test("A live party's card reads the host's track, and offers Join")
    func liveCard() throws {
        let model = model()
        model.mutateBox(general) { $0.messages = [invite(hostParty, in: general, by: hostID)] }
        hostListening(model)
        let card = try #require(model.listenAlongCards(in: general)[hostParty])
        #expect(card.title == "Alberto Balsalm by Aphex Twin")
        #expect(card.artworkURL?.absoluteString == "https://i.scdn.co/image/ab67616d0000b2734bcecb123363f1f0f869257c")
        #expect(card.listenerCount == 1)
        #expect(card.buttonTitle == "Join")
        #expect(card.isButtonEnabled)
    }

    @Test("A party whose host has stopped is over, which is no card state at all")
    func endedCard() {
        let model = model()
        model.mutateBox(general) { $0.messages = [invite(hostParty, in: general, by: hostID)] }
        #expect(model.listenAlongCards(in: general).isEmpty)
    }

    @Test("The reader's own party reads Joined and cannot be pressed")
    func ownCard() throws {
        let model = model()
        playing(model)
        model.mutateBox(general) { $0.messages = [invite(readerParty, in: general, by: readerID)] }
        let card = try #require(model.listenAlongCards(in: general)[readerParty])
        #expect(card.buttonTitle == "Joined")
        #expect(!card.isButtonEnabled)
        #expect(card.listenerCount == 1)
    }

    @Test("Without a Spotify account the button links one")
    func connectFirst() throws {
        let model = model()
        model.connections = []
        model.mutateBox(general) { $0.messages = [invite(hostParty, in: general, by: hostID)] }
        hostListening(model)
        let card = try #require(model.listenAlongCards(in: general)[hostParty])
        #expect(card.buttonTitle == "Connect Spotify")
        #expect(card.isButtonEnabled)
    }

    @Test("The profile's Listen Along says why it cannot, in Discord's words")
    func profileOffer() throws {
        let model = model()
        hostListening(model)
        let activity = try #require(model.presences[hostID]?.activities?.list.first)
        let offer = try #require(model.listenAlongOffer(for: hostID, activity: activity))
        #expect(offer.isEnabled)
        #expect(offer.help == "Listen along with Glassmage")

        model.listeningAlong = ListeningAlong(hostID: hostID, partyID: hostParty, trackID: "t", startedAt: .now)
        let along = try #require(model.listenAlongOffer(for: hostID, activity: activity))
        #expect(!along.isEnabled)
        #expect(along.help == "You're already along for this ride.")
    }

    @Test("An ended card is shorter: no button")
    func layout() {
        let invite = ListenAlongInvite(partyID: hostParty)
        let style = MessageTextStyle.current()
        let live = ListenAlongLayoutEngine.layout(invite, isLive: true, origin: .zero, availableWidth: 500, style: style)
        let ended = ListenAlongLayoutEngine.layout(invite, isLive: false, origin: .zero, availableWidth: 500, style: style)
        #expect(live.buttonRect != nil)
        #expect(ended.buttonRect == nil)
        #expect(ended.rect.height < live.rect.height)
        #expect(ListenAlongLayoutEngine.clock(since: .now.addingTimeInterval(-97), now: .now) == "1:37")
    }
}
