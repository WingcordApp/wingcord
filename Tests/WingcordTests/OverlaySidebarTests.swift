import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The overlay sidebar's store-side decisions: who is in which band, what a
/// conversation's second line says, and which rooms are worth a row.
///
/// **Driven through `overlaySidebarPresentation`**, which is the value the
/// widget actually reads — §2. A test on a private helper would pass while the
/// projection that feeds the surface was wired to something else, which is the
/// exact failure `INVARIANTS.md` records for the board's merge.
@MainActor
@Suite("Overlay sidebar")
struct OverlaySidebarTests {

    private let readerID = UserID(rawValue: 1)
    private let friendInGame = UserID(rawValue: 2)
    private let friendOnline = UserID(rawValue: 3)
    private let friendOffline = UserID(rawValue: 4)
    private let friendFavourite = UserID(rawValue: 5)
    private let stranger = UserID(rawValue: 6)
    private let blocked = UserID(rawValue: 7)

    private let guildID = GuildID(rawValue: 10)
    private let room = ChannelID(rawValue: 11)
    private let emptyRoom = ChannelID(rawValue: 12)
    private let dmInGame = ChannelID(rawValue: 20)
    private let dmFavourite = ChannelID(rawValue: 21)
    private let dmBlocked = ChannelID(rawValue: 22)

    /// A reader with four friends in four states, a stranger, somebody blocked,
    /// three conversations and one busy room.
    private func model() -> AppModel {
        let model = AppModel()
        model.currentUserID = readerID
        model.users = [
            readerID: User(id: readerID, username: "reader", displayName: "Reader"),
            friendInGame: User(id: friendInGame, username: "playing", displayName: "Playing"),
            friendOnline: User(id: friendOnline, username: "around", displayName: "Around"),
            friendOffline: User(id: friendOffline, username: "gone", displayName: "Gone"),
            friendFavourite: User(id: friendFavourite, username: "pinned", displayName: "Pinned"),
            stranger: User(id: stranger, username: "nobody", displayName: "Nobody"),
            blocked: User(id: blocked, username: "blocked", displayName: "Blocked"),
        ]
        model.guilds = [guildID: Guild(id: guildID, name: "nice server", ownerID: readerID)]
        model.relationships = [
            friendInGame: .friend,
            friendOnline: .friend,
            friendOffline: .friend,
            friendFavourite: .friend,
            blocked: .friend,
            stranger: .incomingRequest,
        ]
        model.blockedUserIDs = [blocked]

        model.presences = [
            friendInGame: Presence(
                userID: friendInGame,
                status: .online,
                activities: PresenceActivities(list: [
                    Activity(kind: .playing, name: "Rust", applicationID: ApplicationID(rawValue: 99)),
                ])
            ),
            friendOnline: Presence(userID: friendOnline, status: .idle),
            friendOffline: Presence(userID: friendOffline, status: .offline),
            friendFavourite: Presence(userID: friendFavourite, status: .offline),
        ]

        var index = ChannelIndex()
        index.replaceChannels(
            [
                Channel(
                    id: room, kind: .voice, guildID: guildID, name: "lobby",
                    position: 0, userLimit: 5
                ),
                Channel(
                    id: emptyRoom, kind: .voice, guildID: guildID, name: "quiet",
                    position: 1
                ),
            ],
            inGuild: guildID
        )
        index.replacePrivateChannels([
            Channel(
                id: dmInGame, kind: .directMessage, name: "",
                lastMessageID: MessageID(rawValue: 900), recipientIDs: [readerID, friendInGame]
            ),
            Channel(
                id: dmFavourite, kind: .directMessage, name: "",
                lastMessageID: MessageID(rawValue: 800), recipientIDs: [readerID, friendFavourite]
            ),
            Channel(
                id: dmBlocked, kind: .directMessage, name: "",
                lastMessageID: MessageID(rawValue: 700), recipientIDs: [readerID, blocked]
            ),
        ])
        model.channelIndex = index
        model.pinnedChannelIDs = [dmFavourite]

        // `@everyone` can see and join, or the permission gate hides the room
        // and the third tab is empty for a reason nothing else in the test says.
        let everyone = RoleID(rawValue: guildID.rawValue)
        model.roles = [guildID: [
            everyone: Role(
                id: everyone, name: "@everyone", position: 0,
                permissions: [.viewChannel, .readMessageHistory, .connect, .speak]
            ),
        ]]
        model.members = [guildID: [readerID: Member(userID: readerID, roleIDs: [])]]

        model.voiceStates = [
            friendInGame: VoiceState(
                userID: friendInGame, channelID: room, guildID: guildID, sessionID: "a"
            ),
            friendOnline: VoiceState(
                userID: friendOnline, channelID: room, guildID: guildID, sessionID: "b"
            ),
        ]
        return model
    }

    // MARK: Friends

    @Test("A friend in a game is banded apart from one who is merely online")
    func bandsFollowActivity() {
        let sections = model().overlaySidebarPresentation.friends
        let inGame = sections.first { $0.id == .inGame }
        let online = sections.first { $0.id == .online }
        #expect(inGame?.people.map(\.id) == [friendInGame])
        #expect(online?.people.map(\.id) == [friendOnline])
    }

    @Test("A favourite outranks their own status, which is the whole point of a pin")
    func favouriteWinsOverOffline() {
        let sections = model().overlaySidebarPresentation.friends
        #expect(sections.first?.id == .favorites)
        #expect(sections.first?.people.map(\.id) == [friendFavourite])
        // …and is therefore not also in the band their status would put them in.
        let offline = sections.first { $0.id == .offline }
        #expect(offline?.people.map(\.id) == [friendOffline])
    }

    @Test("Somebody blocked is not a friend, and somebody who merely asked is not either")
    func theTabAnswersItsOwnLabel() {
        let everyone = model().overlaySidebarPresentation.friends.flatMap(\.people).map(\.id)
        #expect(!everyone.contains(blocked))
        #expect(!everyone.contains(stranger))
        #expect(!everyone.contains(readerID))
    }

    @Test("A friend's row carries the conversation with them, so the click has somewhere to go")
    func rowsCarryTheirConversation() {
        let people = model().overlaySidebarPresentation.friends.flatMap(\.people)
        let playing = people.first { $0.id == friendInGame }
        #expect(playing?.channelID == dmInGame)
        #expect(playing?.subtitle == "Playing Rust")
        // Somebody with no conversation yet still gets a row — it opens one.
        let around = people.first { $0.id == friendOnline }
        #expect(around?.channelID == nil)
    }

    @Test("The reader's own name for somebody beats the one they chose")
    func nicknameWins() {
        let model = self.model()
        model.friendNicknames[friendOnline] = "roomie"
        let people = model.overlaySidebarPresentation.friends.flatMap(\.people)
        #expect(people.first { $0.id == friendOnline }?.displayName == "roomie")
        // And it is what the search matches on, or renaming somebody makes them
        // unfindable by the only name the reader sees.
        let matched = model.overlaySidebarPresentation
            .friends(matching: QuickSwitchRank.fold("roomie"))
            .flatMap(\.people)
        #expect(matched.map(\.id) == [friendOnline])
    }

    // MARK: Messages

    @Test("Favourites float, and a blocked conversation is not offered at all")
    func conversationOrder() {
        let rows = model().overlaySidebarPresentation.conversations
        #expect(rows.first?.id == dmFavourite)
        #expect(rows.first?.isFavorite == true)
        #expect(!rows.contains { $0.id == dmBlocked })
    }

    @Test("A conversation with no transcript loaded says the handle rather than nothing")
    func previewFallsBackToTheHandle() {
        let rows = model().overlaySidebarPresentation.conversations
        #expect(rows.first { $0.id == dmInGame }?.preview == "@playing")
    }

    @Test("A loaded transcript's last line is what the row shows")
    func previewFoldsTheLastMessage() {
        let model = self.model()
        var box = MessageBox()
        box.messages = [
            Message(
                id: MessageID(rawValue: 900),
                channelID: dmInGame,
                authorID: friendInGame,
                content: "**hey**\nare you on later"
            ),
        ]
        model.setMessages(box, in: dmInGame)
        let rows = model.overlaySidebarPresentation.conversations
        // Markdown folded and the newline collapsed — the same folder the reply
        // header uses, rather than a second answer to the same question.
        #expect(rows.first { $0.id == dmInGame }?.preview == "hey are you on later")
    }

    // MARK: Voice

    @Test("A stage is not a voice channel, whoever is standing in it")
    func stagesAreNotRooms() {
        let model = self.model()
        var index = model.channelIndex
        index.upsert(Channel(
            id: ChannelID(rawValue: 13), kind: .stage, guildID: guildID,
            name: "office hours", position: 2
        ))
        model.channelIndex = index
        model.voiceStates[friendOffline] = VoiceState(
            userID: friendOffline, channelID: ChannelID(rawValue: 13),
            guildID: guildID, sessionID: "c"
        )
        let rooms = model.overlaySidebarPresentation.rooms
        #expect(!rooms.contains { $0.id == ChannelID(rawValue: 13) })
    }

    @Test("A room with nobody in it is not a row")
    func onlyOccupiedRooms() {
        let rooms = model().overlaySidebarPresentation.rooms
        #expect(rooms.map(\.id) == [room])
        #expect(rooms.first?.count == 2)
        #expect(rooms.first?.limit == 5)
    }

    @Test("The reader's own room sorts first, however few people are in it")
    func ownRoomFirst() {
        let model = self.model()
        model.voiceStates[readerID] = VoiceState(
            userID: readerID, channelID: emptyRoom, guildID: guildID, sessionID: "me"
        )
        model.connectedVoiceChannelID = emptyRoom
        let rooms = model.overlaySidebarPresentation.rooms
        #expect(rooms.first?.id == emptyRoom)
        #expect(rooms.first?.isJoined == true)
    }

    // MARK: Filtering

    @Test("The search folds case and diacritics on both sides")
    func searchIsFolded() {
        let presentation = model().overlaySidebarPresentation
        let matched = presentation.friends(matching: QuickSwitchRank.fold("PLAY"))
        #expect(matched.flatMap(\.people).map(\.id) == [friendInGame])
        // A query nothing answers empties the list rather than ignoring itself.
        #expect(presentation.friends(matching: QuickSwitchRank.fold("zzz")).isEmpty)
    }

    @Test("An empty query is not a filter")
    func emptyQueryPassesEverything() {
        let presentation = model().overlaySidebarPresentation
        #expect(presentation.friends(matching: "").count == presentation.friends.count)
        #expect(presentation.conversations(matching: "") == presentation.conversations)
        #expect(presentation.rooms(matching: "") == presentation.rooms)
    }

    // MARK: The memo

    @Test("The projection is memoized, and a presence change invalidates it")
    func memoInvalidates() {
        let model = self.model()
        let first = model.overlaySidebarPresentation
        // A second read with nothing changed is the same value.
        #expect(model.overlaySidebarPresentation == first)
        // A presence landing has to move it, or a friend who starts a game stays
        // in the wrong band for ever.
        model.presences[friendOnline] = Presence(
            userID: friendOnline,
            status: .online,
            activities: PresenceActivities(list: [Activity(kind: .playing, name: "Rust")])
        )
        model.presenceRevision &+= 1
        let second = model.overlaySidebarPresentation
        #expect(second != first)
        #expect(second.friends.first { $0.id == .inGame }?.people.count == 2)
    }
}

/// The chat window's list, which is one ordering rule and three edits of it.
@MainActor
@Suite("Overlay chat windows")
struct OverlayChatTests {

    private func controller() -> OverlayController { OverlayController() }
    private func id(_ value: UInt64) -> ChannelID { ChannelID(rawValue: value) }

    @Test("The most recently opened conversation is the one drawn")
    func newestIsActive() {
        let controller = self.controller()
        controller.focusChat(id(1))
        controller.focusChat(id(2))
        #expect(controller.activeChatChannelID == id(2))
        #expect(controller.railChatChannelIDs == [id(1)])
    }

    @Test("Re-opening one already open brings it forward rather than duplicating it")
    func focusMovesRatherThanAdds() {
        let controller = self.controller()
        controller.focusChat(id(1))
        controller.focusChat(id(2))
        controller.focusChat(id(1))
        #expect(controller.chatChannelIDs == [id(1), id(2)])
    }

    @Test("The rail is capped, and it is the oldest that goes")
    func railIsCapped() {
        let controller = self.controller()
        for value in 1...(UInt64(OverlayController.chatLimit) + 2) {
            controller.focusChat(id(value))
        }
        #expect(controller.chatChannelIDs.count == OverlayController.chatLimit)
        #expect(!controller.chatChannelIDs.contains(id(1)))
        #expect(!controller.chatChannelIDs.contains(id(2)))
    }

    @Test("Closing the drawn one promotes the next off the rail")
    func closingPromotes() {
        let controller = self.controller()
        controller.focusChat(id(1))
        controller.focusChat(id(2))
        controller.closeChat(id(2))
        #expect(controller.activeChatChannelID == id(1))
        controller.closeAllChats()
        #expect(!controller.hasOpenChat)
    }

    @Test("A reply field holds the toast it is open on, and only that one")
    func theReplyHolds() {
        let controller = self.controller()
        let notice = OverlayNotice(
            title: "alex", body: "hey", monogram: "A",
            channelID: id(1), messageID: MessageID(rawValue: 5)
        )
        let other = OverlayNotice(
            title: "kim", body: "hi", monogram: "S",
            channelID: id(1), messageID: MessageID(rawValue: 6)
        )
        #expect(!controller.holdsNotice(notice.id))
        controller.beginReply(to: notice)
        #expect(controller.holdsNotice(notice.id))
        #expect(!controller.holdsNotice(other.id))
        controller.cancelReply()
        #expect(!controller.holdsNotice(notice.id))
    }

    @Test("Sweeping down a roster does not close the card that has just opened")
    func hoverIsOwnedByTheRowThatSetIt() {
        let controller = self.controller()
        let anchor = CGRect(x: 0, y: 0, width: 100, height: 20)
        controller.hoverStream(UserID(rawValue: 1), anchor: anchor)
        controller.hoverStream(UserID(rawValue: 2), anchor: anchor)
        // The leave for the first row arrives AFTER the enter for the second.
        controller.endStreamHover(UserID(rawValue: 1))
        #expect(controller.streamHover?.userID == UserID(rawValue: 2))
        controller.endStreamHover(UserID(rawValue: 2))
        #expect(controller.streamHover == nil)
    }
}

/// Who may take a click while the overlay is asleep.
///
/// **The locked state belongs to the game**, and the toast is the one exception:
/// its own hint promises a click will reply, and answering a notification is the
/// single thing on this overlay somebody does without leaving the match.
@MainActor
@Suite("Overlay click-through")
struct OverlayHitTestingTests {

    private func controller() -> OverlayController { OverlayController() }

    @Test("Asleep, only the toast takes a click")
    func lockedPassesEverythingButTheToast() {
        let controller = self.controller()
        #expect(controller.isLocked)
        #expect(controller.acceptsHits(.notifications))
        for kind in [OverlayWidgetKind.voice, .streams, .videoTiles, .clips, .friends] {
            #expect(!controller.acceptsHits(kind), "\(kind.rawValue)")
        }
    }

    @Test("Awake, everything takes a click")
    func unlockedAcceptsEverything() {
        let controller = self.controller()
        controller.setLocked(false)
        #expect(OverlayWidgetKind.allCases.allSatisfy(controller.acceptsHits))
    }

    @Test("Replying does not wake the overlay")
    func replyingKeepsTheLock() {
        // Unlocking to type one line would dim the screen and draw eight
        // widgets over a match.
        let controller = self.controller()
        let notice = OverlayNotice(
            title: "alex", body: "hey", monogram: "A",
            channelID: ChannelID(rawValue: 1), messageID: MessageID(rawValue: 5)
        )
        controller.beginReply(to: notice)
        #expect(controller.isLocked)
        #expect(controller.isReplying)
        controller.cancelReply()
        #expect(!controller.isReplying)
    }
}
