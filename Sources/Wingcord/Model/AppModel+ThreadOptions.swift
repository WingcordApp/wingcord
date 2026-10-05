import CoreGraphics
import Foundation
import WingcordCore
import WingcordNet

// MARK: - A thread's own menu

/// Where a thread's menu was raised — Discord has three, and they hold
/// different items in a different order.
enum ThreadMenuPlace: Hashable, Sendable {
    /// A right-click on the thread: its row in the channel list, its card on a
    /// board, its row in the Threads browser — Discord's `thread-context`.
    case list
    /// The ⋯ over a thread open beside its parent — "Sidebar Overflow".
    case panel
    /// The ⋯ in the toolbar over a thread open as the page — "Toolbar
    /// Overflow".
    case page
}

/// A right-click on a thread, and the row to hang the menu off.
struct ThreadOptionsRequest: Identifiable, Hashable, Sendable {
    var threadID: ChannelID
    var anchor: CGRect
    var id: UInt64 { threadID.rawValue }
}

/// Delete Thread, Delete Post or Delete Message, waiting on Discord's
/// confirmation (`572874`).
struct ThreadDeletionRequest: Identifiable, Hashable, Sendable {
    var threadID: ChannelID
    var name: String
    var deletion: ThreadGate.Deletion
    var id: UInt64 { threadID.rawValue }
}

/// "Pin this post?" — a forum keeps one pinned post, so pinning a second
/// replaces the first (`41402`).
struct PinReplacementRequest: Identifiable, Hashable, Sendable {
    var postID: ChannelID
    var pinnedID: ChannelID
    var id: UInt64 { postID.rawValue }
}

/// Edit Thread or Edit Post — see `ThreadEditSheet`.
struct ThreadEditRequest: Identifiable, Hashable, Sendable {
    var threadID: ChannelID
    var id: UInt64 { threadID.rawValue }
}

/// Everything a thread's menu shows, resolved when it opens.
struct ThreadMenu {
    var threadID: ChannelID
    var guildID: GuildID
    var name: String
    /// A forum post, which takes Discord's other words: Follow Post, Close
    /// Post, Edit Post.
    var isPost: Bool
    var isArchived: Bool
    var isLocked: Bool
    var isPinned: Bool
    /// A private thread's "Anyone can invite" — on unless it was turned off.
    var isInvitable: Bool
    /// Whether the reader is in it. Mute and Notification Settings need a
    /// membership to live on, and Discord greys both out without one.
    var isJoined: Bool
    /// Previewing the server: Discord offers no Join.
    var isLurking: Bool
    var isMuted: Bool
    /// Discord's "Muted until 10/4, 5:16 PM" under Unmute — nothing for a mute
    /// with no end.
    var muteEnd: String?
    var notification: ThreadNotification
    /// Whether Mark As Read has anything to do.
    var hasUnread: Bool
    /// The post's tags that still exist in its forum.
    var appliedTagIDs: [ForumTagID]
    var gate: ThreadGate
    /// "Open in Split View", offered only where the reader keeps split view on.
    var offersSplitView: Bool
    var link: String

    /// Discord's cap on a post's tags.
    static let tagLimit = 5

    /// One row of the menu.
    enum Item: Hashable {
        case markRead
        case follow
        case openFullView
        case openSplitView
        case jumpToTop
        case closeOrOpen
        case lock
        case edit
        case editTags
        case copyLink
        case mute
        case notifications
        case invitable
        case pin
        case delete
        case search
        case pins
        case copyThreadID
    }

    /// Discord's groups for each place, in its order, with every row the reader
    /// cannot use left out — and every group left empty with it.
    ///
    /// The right-click is `612826`'s `thread-context`; the split view's ⋯ is
    /// `io`, and the page's is `s0` (both `8287e37da317f9ca`). Discord's page
    /// keeps Mute and Notification Settings on a bell in the header; this
    /// toolbar has no bell, so the page's menu carries them where the split
    /// view's does.
    func groups(at place: ThreadMenuPlace, developerMode: Bool) -> [[Item]] {
        let order: [[Item]] = switch place {
        case .list:
            [
                [.markRead],
                [.follow, .closeOrOpen, .lock, .edit, .editTags, .copyLink],
                [.mute, .notifications],
                [.invitable, .pin, .delete],
                [.copyThreadID],
            ]
        case .panel:
            [
                [.follow, .openFullView],
                [.mute, .notifications],
                [.edit, .pin, .editTags],
                [.search, .pins],
                [.invitable, .closeOrOpen, .lock, .delete],
                [.copyLink, .copyThreadID],
            ]
        case .page:
            [
                [.follow],
                [.mute, .notifications],
                [.jumpToTop, .edit, .pin, .editTags, .openSplitView],
                [.invitable, .closeOrOpen, .lock, .delete],
                [.copyLink, .copyThreadID],
            ]
        }
        return order
            .map { $0.filter { offers($0, developerMode: developerMode) } }
            .filter { !$0.isEmpty }
    }

    /// Whether a row is there at all. Mark As Read, Mute and Notification
    /// Settings are always there and greyed out when they have nothing to act
    /// on, as Discord's are.
    private func offers(_ item: Item, developerMode: Bool) -> Bool {
        switch item {
        case .follow: !isLurking
        case .openSplitView: offersSplitView
        case .closeOrOpen: gate.canCloseOrOpen
        case .lock: gate.canLock
        case .edit: gate.canEdit
        case .editTags: gate.canEditTags
        case .invitable: gate.canSetInvitable
        case .pin: gate.canPin
        case .delete: gate.deletion != nil
        case .copyThreadID: developerMode
        case .markRead, .openFullView, .jumpToTop, .copyLink, .mute, .notifications, .search, .pins:
            true
        }
    }
}

extension ThreadMenuPlace {
    /// The `location` Discord's join and leave carry from each place.
    var followLocation: String {
        switch self {
        case .list: "Context Menu"
        case .panel: "Sidebar Overflow"
        case .page: "Toolbar Overflow"
        }
    }
}

extension AppModel {

    // MARK: Reading

    /// The menu for a thread, or nil for anything that is not one.
    func threadMenu(for threadID: ChannelID) -> ThreadMenu? {
        guard let thread = channelIndex[threadID], thread.kind.isThread,
              let guildID = thread.guildID
        else { return nil }
        let parent = thread.parentID.flatMap { channelIndex[$0] }
        let membership = threadMemberships[threadID]
        let openerID = MessageID(rawValue: threadID.rawValue)
        // Known from the board's card or from the transcript — Discord's own
        // store answers from the same two.
        let hasOpener = parent.flatMap { forumBoards[$0.id]?.firstMessages[threadID] } != nil
            || message(openerID, in: threadID) != nil
        let gate = ThreadGate(
            thread: thread,
            parent: parent,
            permissions: permissionGate.permissions(in: threadID),
            canSend: permissionGate.canSend(in: threadID),
            userID: currentUserID,
            replyCount: thread.threadMessageCount ?? 0,
            hasOpeningMessage: hasOpener
        )
        let unread = unreadState(of: thread)
        let isMuted = membership?.isMutedNow() ?? false
        let forumTagIDs = Set((parent?.availableTags ?? []).map(\.id))

        return ThreadMenu(
            threadID: threadID,
            guildID: guildID,
            name: displayName(of: thread),
            isPost: ThreadGate.isForumPost(thread, parent: parent),
            isArchived: thread.threadMetadata?.isArchived ?? false,
            isLocked: thread.threadMetadata?.isLocked ?? false,
            isPinned: thread.isPinnedPost,
            isInvitable: thread.threadMetadata?.isInvitable ?? true,
            isJoined: membership != nil,
            isLurking: guildPreview?.guildID == guildID,
            isMuted: isMuted,
            muteEnd: isMuted ? membership?.muteConfig?.endTime.map(Self.muteEnd) : nil,
            notification: membership?.notification ?? .onlyMentions,
            hasUnread: unread.unread || unread.mentions > 0,
            appliedTagIDs: thread.appliedTags.filter(forumTagIDs.contains),
            gate: gate,
            offersSplitView: syncedPreferences.opensThreadsInSplitView && thread.parentID != nil,
            link: "https://discord.com/channels/\(guildID.rawValue)/\(threadID.rawValue)"
        )
    }

    /// Discord's `j7h4AJ`, with the end as its own locale string — month, day,
    /// hour and minute, no year (`145408`).
    private static func muteEnd(_ end: Date) -> String {
        "Muted until \(end.formatted(.dateTime.month(.defaultDigits).day().hour().minute(.twoDigits)))"
    }

    // MARK: Opening

    /// A right-click on a thread wherever it is listed.
    func openThreadMenu(for threadID: ChannelID, anchor: CGRect) {
        guard channelIndex[threadID]?.kind.isThread == true else { return }
        dismissMessageSurfaces()
        channelOptionsMenu = nil
        threadOptionsMenu = ThreadOptionsRequest(threadID: threadID, anchor: anchor)
    }

    // MARK: State

    /// Close or Open. Discord's is not optimistic — the row changes when the
    /// server says it has — and a refused reopen says why in Discord's words.
    func setThreadArchived(_ archived: Bool, threadID: ChannelID) {
        guard let menu = threadMenu(for: threadID), menu.gate.canCloseOrOpen else { return }
        sessionController.writeThread(
            ThreadEdit(archived: archived), to: threadID, isPost: menu.isPost, reopening: !archived
        )
    }

    /// Lock or Unlock — Discord's sequence: a closed thread is opened first, and
    /// closed again by the same write that locks it (`867455`).
    func setThreadLocked(_ locked: Bool, threadID: ChannelID) {
        guard let menu = threadMenu(for: threadID), menu.gate.canLock else { return }
        sessionController.writeThreadLock(locked, to: threadID, wasArchived: menu.isArchived, isPost: menu.isPost)
    }

    func setThreadInvitable(_ invitable: Bool, threadID: ChannelID) {
        guard let menu = threadMenu(for: threadID), menu.gate.canSetInvitable else { return }
        sessionController.writeThread(ThreadEdit(invitable: invitable), to: threadID, isPost: menu.isPost)
    }

    // MARK: Pinning a post

    /// Pin Post or Unpin Post. A forum keeps one pinned post: pinning a second
    /// asks first, and then unpins the first (`41402`).
    func setPostPinned(_ pinned: Bool, postID: ChannelID) {
        guard let post = channelIndex[postID], let menu = threadMenu(for: postID), menu.gate.canPin
        else { return }
        guard pinned else {
            sessionController.writePin(false, post: post)
            return
        }
        if let parentID = post.parentID,
           let pinnedID = channelIndex.threadIDs(inParent: parentID).first(where: {
               $0 != postID && channelIndex[$0]?.isPinnedPost == true
           })
        {
            pinReplacement = PinReplacementRequest(postID: postID, pinnedID: pinnedID)
            return
        }
        sessionController.writePin(true, post: post)
    }

    func confirmPinReplacement() {
        guard let request = pinReplacement else { return }
        pinReplacement = nil
        if let pinned = channelIndex[request.pinnedID] { sessionController.writePin(false, post: pinned) }
        if let post = channelIndex[request.postID] { sessionController.writePin(true, post: post) }
    }

    // MARK: Tags

    /// Puts a tag on a post or takes it off — Discord's Edit Tags, one tick at
    /// a time. A sixth tag is refused here, as Discord's row is greyed out.
    func togglePostTag(_ tagID: ForumTagID, postID: ChannelID) {
        guard let post = channelIndex[postID], let menu = threadMenu(for: postID), menu.gate.canEditTags
        else { return }
        var tags = menu.appliedTagIDs
        if let index = tags.firstIndex(of: tagID) {
            tags.remove(at: index)
        } else {
            guard tags.count < ThreadMenu.tagLimit,
                  menu.gate.usableTags.contains(where: { $0.id == tagID })
            else { return }
            tags.append(tagID)
        }
        sessionController.writeThread(
            ThreadEdit(appliedTags: tags),
            to: postID,
            isPost: true,
            reopenFirst: needsReopening(post)
        )
    }

    /// Discord's `unarchiveThreadIfNecessary`: a closed thread is opened before
    /// anything else about it changes — by anybody who could open it.
    func needsReopening(_ thread: Channel) -> Bool {
        guard let metadata = thread.threadMetadata, metadata.isArchived else { return false }
        return !metadata.isLocked || permissionGate.permissions(in: thread.id).contains(.manageThreads)
    }

    // MARK: Editing

    func editThread(_ threadID: ChannelID) {
        guard threadMenu(for: threadID)?.gate.canEdit == true else { return }
        threadEditor = ThreadEditRequest(threadID: threadID)
    }

    /// The edit sheet's save: a closed thread opened first, as Discord's save
    /// does, then one write of what changed. Discord's words when refused, nil
    /// once it lands.
    func saveThreadEdit(_ edit: ThreadEdit, to threadID: ChannelID) async -> String? {
        guard let thread = channelIndex[threadID], let menu = threadMenu(for: threadID), menu.gate.canEdit
        else { return "An error occurred, please try again." }
        return await sessionController.saveThread(
            edit, to: threadID, isPost: menu.isPost, reopenFirst: needsReopening(thread)
        )
    }

    // MARK: Deleting

    func requestThreadDeletion(_ threadID: ChannelID) {
        guard let menu = threadMenu(for: threadID), let deletion = menu.gate.deletion else { return }
        threadDeletion = ThreadDeletionRequest(threadID: threadID, name: menu.name, deletion: deletion)
    }

    /// Delete Message removes the post's opening message — its id is the
    /// post's own — and leaves the replies; the other two delete the channel.
    func confirmThreadDeletion() {
        guard let request = threadDeletion else { return }
        threadDeletion = nil
        guard threadMenu(for: request.threadID)?.gate.deletion == request.deletion else { return }
        switch request.deletion {
        case .openingMessage:
            sessionController.delete(MessageID(rawValue: request.threadID.rawValue), in: request.threadID)
        case .thread, .post:
            sessionController.deleteChannel(request.threadID)
        }
    }

    // MARK: Going somewhere

    /// Discord's Jump To Top: the thread's first message.
    func jumpToThreadTop(_ threadID: ChannelID) {
        sessionController.jumpToStart(of: threadID)
    }

    /// Search, from a thread beside its parent: Discord opens the thread as the
    /// page and puts the reader in the search field.
    func searchFromThread(_ threadID: ChannelID) {
        openThread(threadID, as: .fullView)
        searchFocusRequest &+= 1
    }

    /// Pins, from a thread beside its parent: opened as the page, with its pins.
    func showThreadPins(_ threadID: ChannelID) {
        openThread(threadID, as: .fullView)
        if openPinsChannelID != threadID { togglePinsPane(for: threadID) }
    }
}
