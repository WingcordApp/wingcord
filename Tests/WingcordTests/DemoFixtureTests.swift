import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// What `--demo` actually contains.
///
/// **A fixture that quietly loses half of itself is the most expensive kind of
/// bug in this tree**, because every surface built against it then looks wrong
/// for a reason that is not in the surface. Two of these landed in one session:
/// the reader's call held one participant where four sections of the fixture
/// describe five, and the private channel list evicted the transcript it had
/// just seeded. Both were invisible until somebody photographed a widget.
@MainActor
@Suite("Demo fixtures")
struct DemoFixtureTests {

    private func model() -> AppModel {
        let model = AppModel()
        DemoFixtures.populate(model)
        return model
    }

    @Test("The reader is in a call with four other people in it")
    func theCallHasItsCast() throws {
        let presentation = try #require(model().voicePresentation)
        #expect(presentation.participants.count == 5)
        // Every mark the tiles and the overlay's roster can draw, at once.
        #expect(presentation.participants.contains { $0.isSilenced })
        #expect(presentation.participants.contains { $0.isDeafened })
        #expect(presentation.participants.contains { $0.canWatch })
        #expect(presentation.participants.contains { $0.isCameraOn })
    }

    @Test("A second room somewhere else is in use, so the overlay's Voice tab has two")
    func roomsElsewhere() {
        let rooms = model().overlaySidebarPresentation.rooms
        #expect(rooms.count >= 2)
        #expect(rooms.contains { $0.isJoined })
        #expect(rooms.contains { !$0.isJoined })
        // One with a ceiling and one without, which are the two shapes the
        // counter has.
        #expect(rooms.contains { $0.limit > 0 })
        #expect(rooms.contains { $0.limit == 0 })
    }

    @Test("The conversation the overlay opens has a transcript behind it")
    func theFirstConversationIsLoaded() throws {
        let model = self.model()
        let channelID = try #require(model.channelIndex.privateChannelIDs().first)
        // `residentChannelLimit` is three, so seeding more transcripts than that
        // silently evicts the earliest — and the earliest is this one.
        #expect(model.messages(in: channelID)?.messages.isEmpty == false)
    }

    @Test("A conversation is named for the other person, not for the reader")
    func conversationsAreNamedForTheOtherPerson() throws {
        let model = self.model()
        let channelID = try #require(model.channelIndex.privateChannelIDs().first)
        let channel = try #require(model.channelIndex[channelID])
        let reader = try #require(model.currentUserID)
        // Discord's `recipients` excludes the account. A fixture that includes
        // it puts the reader's own name in the title of every conversation.
        #expect(!channel.recipientIDs.contains(reader))
        #expect(!model.displayName(of: channel).contains("alex"))
    }

    @Test("Most conversations are read, so the unread dot means something")
    func readStatesExist() {
        let rows = model().overlaySidebarPresentation.conversations
        #expect(rows.contains { $0.isUnread })
        #expect(rows.contains { !$0.isUnread })
        #expect(rows.contains { $0.mentionCount > 0 })
    }

    @Test("Friends fill every band the overlay's list draws")
    func friendsFillTheBands() {
        let sections = model().overlaySidebarPresentation.friends
        let bands = Set(sections.map(\.id))
        #expect(bands.contains(.favorites))
        #expect(bands.contains(.inGame))
        #expect(bands.contains(.online))
        #expect(sections.allSatisfy { !$0.people.isEmpty })
    }
}

