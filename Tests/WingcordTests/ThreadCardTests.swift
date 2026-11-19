import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// The thread card under a message that started a thread (docs/QUEUE-NOV19.md
/// T1–T2): Discord's count rules and short times, and the newest message
/// reaching the starter row from a sync, a live message and a deletion.
@MainActor
@Suite("Thread cards")
struct ThreadCardTests {
    private let guildID = GuildID(rawValue: 1)
    private let parentID = ChannelID(rawValue: 100)
    private let threadID = ChannelID(rawValue: 4_200_000_000_000_000_000)
    private let me = UserID(rawValue: 7)
    private let friend = UserID(rawValue: 42)

    @Test("The count reads as Discord's: See Thread, one, many, 50+ for old threads, 100k+")
    func countLabel() {
        func label(_ count: Int, id: UInt64 = 4_200_000_000_000_000_000) -> String {
            MessageThread(id: ChannelID(rawValue: id), name: "t", messageCount: count).countLabel
        }
        #expect(label(0) == "See Thread \u{203A}")
        #expect(label(1) == "1 Message \u{203A}")
        #expect(label(29) == "29 Messages \u{203A}")
        #expect(label(60, id: 900_000_000_000_000_000) == "50+ Messages \u{203A}")
        #expect(label(49, id: 900_000_000_000_000_000) == "49 Messages \u{203A}")
        #expect(label(100_000) == "100k+ Messages \u{203A}")
    }

    @Test("How long ago, in Discord's short form")
    func shortTimes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func age(_ seconds: TimeInterval) -> String {
            TimelineLayoutEngine.threadAge(now.addingTimeInterval(-seconds), now: now)
        }
        #expect(age(20) == "1m ago")
        #expect(age(5 * 60) == "5m ago")
        #expect(age(11 * 3_600) == "11h ago")
        #expect(age(3 * 86_400) == "3d ago")
        #expect(age(40 * 86_400) == ">30d ago")
    }

    private func model() -> AppModel {
        let model = AppModel()
        model.currentUserID = me
        model.guilds[guildID] = Guild(id: guildID, name: "g", ownerID: me)
        model.channelIndex.replaceChannels(
            [Channel(id: parentID, kind: .text, guildID: guildID, name: "general")],
            inGuild: guildID
        )
        model.channelIndex.upsertThread(Channel(
            id: threadID, kind: .publicThread, guildID: guildID, name: "Twelve Days", parentID: parentID
        ))
        return model
    }

    private func starter(count: Int) -> Message {
        Message(
            id: MessageID(rawValue: threadID.rawValue),
            channelID: parentID,
            authorID: me,
            content: "who is in",
            payload: MessagePayload(thread: MessageThread(id: threadID, name: "Twelve Days", messageCount: count))
        )
    }

    private func reply(_ id: UInt64, _ text: String) -> Message {
        Message(id: MessageID(rawValue: threadID.rawValue + id), channelID: threadID, authorID: friend, content: text)
    }

    private func starterThread(in model: AppModel) -> MessageThread? {
        model.messages(in: parentID)?.messages.first?.thread
    }

    @Test("A sync's newest message and count reach the loaded starter row, and one loaded later")
    func syncReachesStarter() {
        let model = model()
        var box = MessageBox()
        box.messages = [starter(count: 3)]
        model.setMessages(box, in: parentID)

        var synced = Channel(id: threadID, kind: .publicThread, guildID: guildID, name: "Twelve Days", parentID: parentID)
        synced.messageCount = 29
        model.receiveThreadSync(threads: [synced], newestMessages: [reply(9, "or **no** eta")])

        let thread = starterThread(in: model)
        #expect(thread?.messageCount == 29)
        #expect(thread?.latest?.authorID == friend)
        #expect(thread?.latest?.excerpt == "or no eta")

        // The parent's page loaded afresh picks the same up.
        model.setMessages(box, in: parentID)
        #expect(starterThread(in: model)?.latest?.excerpt == "or no eta")
    }

    @Test("A live message counts one more and becomes the newest; deleting it leaves Discord's empty line")
    func liveAndDeleted() {
        let model = model()
        var box = MessageBox()
        box.messages = [starter(count: 3)]
        model.setMessages(box, in: parentID)

        let live = reply(10, "on my way")
        model.noteThreadMessageCreated(live)
        #expect(starterThread(in: model)?.messageCount == 4)
        #expect(starterThread(in: model)?.latest?.excerpt == "on my way")

        model.noteThreadMessageDeleted(live.id, in: threadID)
        #expect(starterThread(in: model)?.messageCount == 3)
        #expect(starterThread(in: model)?.latest == nil)
        let line = TimelineLayoutEngine.threadChipLine(
            for: starterThread(in: model)!, style: .current(), authors: [:]
        )
        #expect(line.text == "There are no recent messages in this thread.")
        #expect(line.time != nil)
    }

    @Test("Archived and empty threads say so, without a time")
    func emptyLines() throws {
        var archived = MessageThread(id: threadID, name: "t", messageCount: 5, isArchived: true)
        archived.latest = ThreadLatestMessage(id: MessageID(rawValue: 1), authorID: friend, excerpt: "hi", hasAttachment: false)
        let a = TimelineLayoutEngine.threadChipLine(for: archived, style: .current(), authors: [:])
        #expect(a.text == "There are no recent messages in this thread.")
        #expect(a.time == nil)
        let empty = TimelineLayoutEngine.threadChipLine(
            for: MessageThread(id: threadID, name: "t", messageCount: 0), style: .current(), authors: [:]
        )
        #expect(empty.text == "There are no messages in this thread yet.")
    }
}
