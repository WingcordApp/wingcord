import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// A thread's three menus hold Discord's rows in Discord's order —
/// `thread-context` on a right-click, `io` beside the parent, `s0` over the
/// page — with what the reader cannot do left out.
struct ThreadMenuTests {
    private let me = UserID(rawValue: 7)

    private var forum: Channel {
        Channel(
            id: ChannelID(rawValue: 100),
            kind: .forum,
            guildID: GuildID(rawValue: 1),
            availableTags: [ForumTag(id: ForumTagID(rawValue: 1), name: "Question")]
        )
    }

    private func menu(
        permissions: Permissions,
        isLurking: Bool = false,
        offersSplitView: Bool = true
    ) -> ThreadMenu {
        let post = Channel(
            id: ChannelID(rawValue: 200),
            kind: .publicThread,
            guildID: GuildID(rawValue: 1),
            parentID: forum.id,
            ownerID: UserID(rawValue: 8),
            threadMetadata: ThreadMetadata()
        )
        let gate = ThreadGate(
            thread: post,
            parent: forum,
            permissions: permissions,
            canSend: true,
            userID: me,
            replyCount: 4,
            hasOpeningMessage: true
        )
        return ThreadMenu(
            threadID: post.id,
            guildID: GuildID(rawValue: 1),
            name: "help",
            isPost: true,
            isArchived: false,
            isLocked: false,
            isPinned: false,
            isInvitable: true,
            isJoined: true,
            isLurking: isLurking,
            isMuted: false,
            muteEnd: nil,
            notification: .onlyMentions,
            hasUnread: false,
            appliedTagIDs: [],
            gate: gate,
            offersSplitView: offersSplitView,
            link: "https://discord.com/channels/1/200"
        )
    }

    private let moderator: Permissions = [.viewChannel, .sendMessages, .sendMessagesInThreads, .manageThreads]
    private let member: Permissions = [.viewChannel, .sendMessages, .sendMessagesInThreads]

    @Test("A moderator's right-click on a post, in Discord's groups")
    func listForModerator() {
        #expect(menu(permissions: moderator).groups(at: .list, developerMode: false) == [
            [.markRead],
            [.follow, .closeOrOpen, .lock, .edit, .editTags, .copyLink],
            [.mute, .notifications],
            [.pin, .delete],
        ])
    }

    @Test("Somebody else's post, to a member: no moderation group at all")
    func listForMember() {
        #expect(menu(permissions: member).groups(at: .list, developerMode: true) == [
            [.markRead],
            [.follow, .copyLink],
            [.mute, .notifications],
            [.copyThreadID],
        ])
    }

    @Test("Beside the parent: Open in Full View, then Search and Pins")
    func panel() {
        #expect(menu(permissions: moderator).groups(at: .panel, developerMode: false) == [
            [.follow, .openFullView],
            [.mute, .notifications],
            [.edit, .pin, .editTags],
            [.search, .pins],
            [.closeOrOpen, .lock, .delete],
            [.copyLink],
        ])
    }

    @Test("Over the page: Jump To Top, and Open in Split View only where split view is on")
    func page() {
        let on = menu(permissions: moderator).groups(at: .page, developerMode: false)
        #expect(on[2] == [.jumpToTop, .edit, .pin, .editTags, .openSplitView])
        let off = menu(permissions: moderator, offersSplitView: false).groups(at: .page, developerMode: false)
        #expect(off[2] == [.jumpToTop, .edit, .pin, .editTags])
    }

    @Test("Previewing the server offers no Join")
    func lurking() {
        let groups = menu(permissions: member, isLurking: true).groups(at: .panel, developerMode: false)
        #expect(groups.first == [.openFullView])
    }
}
