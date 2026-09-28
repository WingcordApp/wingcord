import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The session's one typing table: what the composer's line, the roster's dots
/// and the DM list's pill all read.
@MainActor
@Suite("Typing table")
struct TypingTableTests {

    private let dm = ChannelID(rawValue: 10)
    private let server = ChannelID(rawValue: 20)
    private let friend = UserID(rawValue: 2)

    private func model() -> AppModel {
        let model = AppModel()
        model.channelIndex.replacePrivateChannels([
            Channel(id: dm, kind: .directMessage, name: "", recipientIDs: [friend]),
        ])
        return model
    }

    @Test("Typing lives in its own table and never creates a transcript's box")
    func noBoxIsCreated() {
        let model = model()
        model.noteTyping(friend, in: dm, until: .now.addingTimeInterval(10))
        #expect(model.typers(in: dm)[friend] != nil)
        #expect(model.messages(in: dm) == nil)
    }

    @Test("Only a direct message's typing moves the DM list")
    func directMessageRevisionIsScoped() {
        let model = model()
        model.noteTyping(friend, in: server, until: .now.addingTimeInterval(10))
        #expect(model.directMessageTypingRevision == 0)
        model.noteTyping(friend, in: dm, until: .now.addingTimeInterval(10))
        #expect(model.directMessageTypingRevision == 1)
        #expect(model.isTypingInDirectMessage(dm, partner: friend))
    }

    @Test("A message from the typist ends their indicator at once")
    func messageClearsTyping() {
        let model = model()
        model.noteTyping(friend, in: dm, until: .now.addingTimeInterval(10))
        model.clearTyping(friend, in: dm)
        #expect(model.typers(in: dm).isEmpty)
    }

    @Test("Pruning drops what lapsed and names the next expiry")
    func pruning() {
        let model = model()
        let now = Date.now
        model.noteTyping(friend, in: dm, until: now.addingTimeInterval(-1))
        model.noteTyping(UserID(rawValue: 3), in: server, until: now.addingTimeInterval(5))
        let next = model.pruneTyping(now: now)
        #expect(model.typers(in: dm).isEmpty)
        #expect(next == now.addingTimeInterval(5))
    }
}
