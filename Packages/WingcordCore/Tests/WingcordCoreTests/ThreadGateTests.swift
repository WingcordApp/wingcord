import Foundation
import Testing
@testable import WingcordCore

/// Discord's thread menu rules (`406704` and the items over it), one reader at
/// a time: the author, a moderator, and somebody who is neither.
@Suite("What the reader may do to a thread")
struct ThreadGateTests {

    private let me = UserID(rawValue: 7)
    private let someoneElse = UserID(rawValue: 8)
    private let member: Permissions = [.viewChannel, .sendMessages, .sendMessagesInThreads]
    private let moderator: Permissions = [.viewChannel, .sendMessages, .sendMessagesInThreads, .manageThreads]

    private let tags = [
        ForumTag(id: ForumTagID(rawValue: 1), name: "Question"),
        ForumTag(id: ForumTagID(rawValue: 2), name: "Answered", isModerated: true),
    ]

    private var forum: Channel {
        Channel(id: ChannelID(rawValue: 100), kind: .forum, guildID: GuildID(rawValue: 1), availableTags: tags)
    }

    private var textChannel: Channel {
        Channel(id: ChannelID(rawValue: 101), kind: .text, guildID: GuildID(rawValue: 1))
    }

    private func thread(
        in parent: Channel,
        kind: ChannelKind = .publicThread,
        owner: UserID? = nil,
        archived: Bool = false,
        locked: Bool = false,
        flags: ChannelFlags = []
    ) -> Channel {
        Channel(
            id: ChannelID(rawValue: 200),
            kind: kind,
            guildID: GuildID(rawValue: 1),
            parentID: parent.id,
            ownerID: owner ?? me,
            threadMetadata: ThreadMetadata(isArchived: archived, isLocked: locked),
            flags: flags
        )
    }

    private func gate(
        _ thread: Channel,
        parent: Channel,
        permissions: Permissions,
        replies: Int = 0,
        hasOpeningMessage: Bool = true
    ) -> ThreadGate {
        ThreadGate(
            thread: thread,
            parent: parent,
            permissions: permissions,
            canSend: permissions.contains(.sendMessagesInThreads),
            userID: me,
            replyCount: replies,
            hasOpeningMessage: hasOpeningMessage
        )
    }

    @Test("The author of an open post edits, tags and closes it, and deletes it while unanswered")
    func authorOfOpenPost() {
        let gate = gate(thread(in: forum), parent: forum, permissions: member)
        #expect(gate.canEdit)
        #expect(gate.canEditTags)
        #expect(gate.canCloseOrOpen)
        #expect(!gate.canLock)
        #expect(!gate.canPin)
        #expect(gate.deletion == .post(deletesReplies: false))
        // Without Manage Threads, a moderated tag is not theirs to set.
        #expect(gate.usableTags.map(\.name) == ["Question"])
    }

    @Test("Once somebody has replied, the author may delete only the opening message — if it is there")
    func authorAfterReplies() {
        let answered = gate(thread(in: forum), parent: forum, permissions: member, replies: 3)
        #expect(answered.deletion == .openingMessage)
        let openerGone = gate(
            thread(in: forum), parent: forum, permissions: member, replies: 3, hasOpeningMessage: false
        )
        #expect(openerGone.deletion == nil)
    }

    @Test("A moderator locks, pins and deletes a post with every reply in it")
    func moderatorOnPost() {
        let gate = gate(
            thread(in: forum, owner: someoneElse), parent: forum, permissions: moderator, replies: 12
        )
        #expect(gate.canLock)
        #expect(gate.canPin)
        #expect(gate.canEdit)
        #expect(gate.deletion == .post(deletesReplies: true))
        #expect(gate.usableTags.count == 2)
    }

    @Test("Somebody else's post offers nothing to a member")
    func strangerOnPost() {
        let gate = gate(thread(in: forum, owner: someoneElse), parent: forum, permissions: member)
        #expect(!gate.canEdit)
        #expect(!gate.canEditTags)
        #expect(!gate.canCloseOrOpen)
        #expect(gate.deletion == nil)
    }

    @Test("A lock takes the author's own controls away; reopening a locked thread needs Manage Threads")
    func lockedThread() {
        let locked = gate(thread(in: forum, locked: true), parent: forum, permissions: member)
        #expect(!locked.canEdit)
        #expect(!locked.canCloseOrOpen)

        let closedAndLocked = thread(in: forum, archived: true, locked: true)
        #expect(!gate(closedAndLocked, parent: forum, permissions: member).canCloseOrOpen)
        #expect(gate(closedAndLocked, parent: forum, permissions: moderator).canCloseOrOpen)
    }

    @Test("A closed, unlocked thread is reopened — and so still edited — by anybody who can send in it")
    func closedThread() {
        let closed = thread(in: textChannel, owner: someoneElse, archived: true)
        let gate = gate(closed, parent: textChannel, permissions: member)
        #expect(gate.canCloseOrOpen)
        // Somebody else's: open again, but not theirs to edit.
        #expect(!gate.canEdit)

        let own = self.gate(thread(in: textChannel, archived: true), parent: textChannel, permissions: member)
        #expect(own.canEdit)
    }

    @Test("A thread off a message has no pin and no tags, and only Manage Threads deletes it")
    func threadInTextChannel() {
        let own = gate(thread(in: textChannel), parent: textChannel, permissions: member)
        #expect(!own.canPin)
        #expect(!own.canEditTags)
        #expect(own.deletion == nil)

        let moderated = gate(thread(in: textChannel), parent: textChannel, permissions: moderator)
        #expect(moderated.deletion == .thread)
    }

    @Test("Anyone can invite belongs to a private thread, and to Manage Threads")
    func invitable() {
        let privateThread = thread(in: textChannel, kind: .privateThread)
        #expect(!gate(privateThread, parent: textChannel, permissions: member).canSetInvitable)
        #expect(gate(privateThread, parent: textChannel, permissions: moderator).canSetInvitable)
        #expect(!gate(thread(in: textChannel), parent: textChannel, permissions: moderator).canSetInvitable)
    }

    @Test("A moderator report is resolved, not closed, locked or edited")
    func moderatorReport() {
        let report = thread(in: forum, owner: someoneElse, flags: .isModeratorReportChannel)
        let gate = gate(report, parent: forum, permissions: moderator)
        #expect(!gate.canLock)
        #expect(!gate.canEdit)
        #expect(!gate.canEditTags)
        #expect(!gate.canCloseOrOpen)
        #expect(gate.deletion == nil)
        // Deletable outright once its opening message is gone.
        let emptied = self.gate(report, parent: forum, permissions: moderator, hasOpeningMessage: false)
        #expect(emptied.deletion == .post(deletesReplies: true))
    }

    @Test("The edit page: the author renames and re-times; only a moderator sets slowmode")
    func editFields() {
        let own = gate(thread(in: forum), parent: forum, permissions: member)
        #expect(own.canRename)
        #expect(own.canChangeSettings)
        #expect(!own.canSetSlowmode)

        let moderated = gate(thread(in: forum, owner: someoneElse), parent: forum, permissions: moderator)
        #expect(moderated.canRename)
        #expect(moderated.canSetSlowmode)
        #expect(moderated.canChangeSettings)
    }

    @Test("Discord's confirmations, word for word")
    func confirmations() {
        #expect(ThreadGate.Deletion.thread.message(name: "help") ==
            "Are you sure you want to delete help? This cannot be undone.")
        #expect(ThreadGate.Deletion.post(deletesReplies: true).message(name: "help") ==
            "Are you sure you want to delete help? All message replies will also be deleted. "
            + "This cannot be undone.")
        #expect(ThreadGate.Deletion.openingMessage.title == "Delete Message")
    }
}
