import Foundation
import Testing
@testable import WingcordCore

/// Who may start a thread, what kind it becomes, and what it is called when
/// nobody names it — Discord's `406704` and `659617`.
@Suite("Starting a thread")
struct ThreadCreationTests {
    private let text = Channel(id: ChannelID(rawValue: 1), kind: .text)
    private let news = Channel(id: ChannelID(rawValue: 2), kind: .announcement)
    private let both: Permissions = [.viewChannel, .readMessageHistory, .createPublicThreads, .createPrivateThreads]

    private func message(kind: MessageKind = .default, flags: MessageFlags = []) -> Message {
        Message(id: MessageID(rawValue: 9), channelID: text.id, authorID: UserID(rawValue: 3), kind: kind, flags: flags)
    }

    @Test("The private box: free with both permissions, fixed on with private alone, absent without it")
    func privateMode() {
        #expect(ThreadCreation.privateMode(in: text, permissions: both) == .enabled)
        #expect(ThreadCreation.privateMode(in: text, permissions: [.viewChannel, .createPrivateThreads]) == .privateOnly)
        #expect(ThreadCreation.privateMode(in: text, permissions: [.viewChannel, .readMessageHistory, .createPublicThreads]) == .disabled)
        // An announcement channel takes no private threads.
        #expect(ThreadCreation.privateMode(in: news, permissions: both) == .disabled)
    }

    @Test("A thread starts from somebody's words, once")
    func fromMessage() {
        #expect(ThreadCreation.canCreatePublic(in: text, permissions: both, from: message()))
        #expect(!ThreadCreation.canCreatePublic(in: text, permissions: both, from: message(flags: .hasThread)))
        #expect(!ThreadCreation.canCreatePublic(in: text, permissions: both, from: message(kind: .userJoin)))
        // A thread holds no threads.
        let thread = Channel(id: ChannelID(rawValue: 4), kind: .publicThread)
        #expect(!ThreadCreation.canCreate(in: thread, permissions: both))
    }

    @Test("The kind Discord asks for")
    func kind() {
        #expect(ThreadCreation.kind(isPrivate: true, parent: text) == .privateThread)
        #expect(ThreadCreation.kind(isPrivate: false, parent: news) == .announcementThread)
        #expect(ThreadCreation.kind(isPrivate: false, parent: text) == .publicThread)
    }

    @Test("Discord's name for an unnamed thread")
    func defaultName() {
        #expect(ThreadCreation.defaultName(embedTitle: "Release notes", pollQuestion: nil, text: "x") == "Release notes")
        #expect(ThreadCreation.defaultName(embedTitle: nil, pollQuestion: "Pizza?", text: "x") == "Pizza?")
        // Leading markers go, and whole words fill up to forty.
        #expect(ThreadCreation.defaultName(embedTitle: nil, pollQuestion: nil, text: "## Hello there\nsecond line")
            == "Hello there")
        let long = "The quick brown fox jumps over the lazy dog again and again"
        #expect(ThreadCreation.defaultName(embedTitle: nil, pollQuestion: nil, text: long)
            == "The quick brown fox jumps over the lazy ")
        // One word longer than forty is cut, with Discord's "...".
        let word = String(repeating: "a", count: 45)
        #expect(ThreadCreation.defaultName(embedTitle: nil, pollQuestion: nil, text: word)
            == String(repeating: "a", count: 40) + "...")
    }
}
