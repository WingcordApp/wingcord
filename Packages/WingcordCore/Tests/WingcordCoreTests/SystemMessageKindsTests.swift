import Foundation
import Testing
@testable import WingcordCore

/// The lines Discord draws for the kinds Wingcord used to show as a bare
/// "Message" (Alex, 2026-11-18: "add support for these friend messages"), and
/// the call line's colour and length ("discord makes some icons green").
struct SystemMessageKindsTests {
    private let me = UserID(rawValue: 10)
    private let them = UserID(rawValue: 20)

    private func message(
        _ kind: MessageKind, author: UserID, content: String = "", call: MessageCall? = nil
    ) -> Message {
        Message(
            id: MessageID(rawValue: 1_300_000_000_000_000_000),
            channelID: ChannelID(rawValue: 2),
            authorID: author,
            content: content,
            kind: kind,
            payload: MessagePayload(call: call)
        )
    }

    private func line(_ sentence: SystemSentence?) -> String {
        guard let sentence else { return "" }
        return sentence.prefix + sentence.name + sentence.suffix + sentence.emphasis + sentence.tail
    }

    @Test("Discord's numbers for the kinds that were unknown")
    func kinds() {
        #expect(MessageKind(rawValue: 67) == .friendRequestAccepted)
        #expect(MessageKind(rawValue: 65) == .voiceSession)
        #expect(MessageKind(rawValue: 68) == .mediaMentionMessage)
        #expect(MessageKind(rawValue: 66) == .unknown)
    }

    @Test("A friend request line, both ways, with and without a note")
    func friendRequest() {
        let own = SystemMessageText.sentence(
            for: message(.friendRequestAccepted, author: me, content: "hey there"), name: "Robin", viewerID: me
        )
        #expect(line(own) == "You accepted Robin\u{2019}s friend request. They said: hey there")
        #expect(own?.emphasis == "hey there")
        #expect(own?.tint == .affirmative)

        let theirs = SystemMessageText.sentence(
            for: message(.friendRequestAccepted, author: them, content: "hi"), name: "Ana", viewerID: me
        )
        #expect(line(theirs) == "Ana accepted your friend request. You said: hi")

        let bare = SystemMessageText.sentence(for: message(.friendRequestAccepted, author: me), name: "Ana", viewerID: me)
        #expect(line(bare) == "You accepted Ana\u{2019}s friend request.")
        let bareTheirs = SystemMessageText.sentence(for: message(.friendRequestAccepted, author: them), name: "Ana", viewerID: me)
        #expect(line(bareTheirs) == "Ana accepted your friend request.")
    }

    @Test("A call is green, says how long it lasted, and is red for whoever missed it")
    func call() {
        let started = message(.call, author: them)
        let ended = started.sentAt.addingTimeInterval(5 * 60)

        let open = SystemMessageText.sentence(for: started, name: "Ana", viewerID: me)
        #expect(line(open) == "Ana started a call.")
        #expect(open?.tint == .affirmative)

        let joined = SystemMessageText.sentence(
            for: message(.call, author: them, call: MessageCall(participantIDs: [them, me], endedAt: ended)),
            name: "Ana", viewerID: me
        )
        #expect(line(joined) == "Ana started a call that lasted 5 minutes.")
        #expect(joined?.tint == .affirmative)

        let missed = SystemMessageText.sentence(
            for: message(.call, author: them, call: MessageCall(participantIDs: [them], endedAt: ended)),
            name: "Ana", viewerID: me
        )
        #expect(line(missed) == "You missed a call from Ana that lasted 5 minutes.")
        #expect(missed?.tint == .destructive)
    }

    @Test("A call's length in moment's humanize words")
    func durations() {
        #expect(SystemMessageText.callDuration(10) == "a few seconds")
        #expect(SystemMessageText.callDuration(44) == "a few seconds")
        #expect(SystemMessageText.callDuration(45) == "a minute")
        #expect(SystemMessageText.callDuration(89) == "a minute")
        #expect(SystemMessageText.callDuration(90) == "2 minutes")
        #expect(SystemMessageText.callDuration(44 * 60) == "44 minutes")
        #expect(SystemMessageText.callDuration(45 * 60) == "an hour")
        #expect(SystemMessageText.callDuration(3 * 3600) == "3 hours")
        #expect(SystemMessageText.callDuration(22 * 3600) == "a day")
    }

    @Test("Kinds Discord draws as ordinary messages are not system rows")
    func ordinary() {
        #expect(!message(.chatWallpaperSet, author: them).isSystemEvent)
        #expect(!message(.mediaMentionMessage, author: them).isSystemEvent)
        #expect(message(.friendRequestAccepted, author: them).isSystemEvent)
    }

    @Test("A line with no words yet says so instead of a bare 'Message'")
    func notYet() {
        let sentence = SystemMessageText.sentence(for: message(.purchaseNotification, author: them), name: "Ana")
        #expect(line(sentence) == "Ana sent something Wingcord can\u{2019}t show yet.")
    }
}
