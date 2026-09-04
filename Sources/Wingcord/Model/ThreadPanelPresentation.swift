import Foundation
import WingcordCore

// MARK: - What the thread panel needs
//
// A plain value snapshot with no model reference — §2 — with the two clipboard
// actions carried as closures rather than as strings the view would have to
// build. They are captured from the store at snapshot time, so the panel never
// reaches for the model and the link is composed once rather than on every
// evaluation of a menu that is usually closed.

struct ThreadPanelPresentation {
    var channelID: ChannelID
    var name: String
    /// "Started by …", or what a thread's state is when that matters more.
    var subtitle: String?
    /// Whether this is a forum post rather than a thread off a message. The two
    /// take different verbs — Discord says Follow/Unfollow for a post and
    /// Join/Leave for a thread, and the distinction is real: a post has no
    /// message it hangs off to return to.
    var isPost: Bool
    /// A post's own tags, resolved against its forum's `availableTags`.
    ///
    /// **Only a post has them**, and they are the one thing about it that has
    /// nowhere else to go: the board's row shows them, and without them here the
    /// panel is the only view of a post that does not say what it is filed
    /// under. Empty for a thread off a message.
    var tags: [ForumTag]
    var isFollowed: Bool
    var isMuted: Bool
    /// "Muted until 5:16 PM", when there is an end to name.
    var muteSummary: String?
    var notification: ThreadNotification
    var isArchived: Bool
    var isLocked: Bool
    var canSend: Bool
    var copyLink: () -> Void
    var copyID: () -> Void
}

extension AppModel {

    func threadPanelPresentation(for channelID: ChannelID) -> ThreadPanelPresentation {
        let thread = channelIndex[channelID]
        let membership = threadMemberships[channelID]
        let parent = thread?.parentID.flatMap { channelIndex[$0] }
        let metadata = thread?.threadMetadata
        let isMuted = membership?.isMutedNow() ?? false

        return ThreadPanelPresentation(
            channelID: channelID,
            name: thread?.name ?? "Thread",
            subtitle: Self.subtitle(thread: thread, owner: thread?.ownerID.flatMap { users[$0] }),
            isPost: parent?.isForumLike ?? false,
            tags: Self.tags(of: thread, in: parent),
            isFollowed: membership != nil,
            isMuted: isMuted,
            muteSummary: isMuted ? Self.muteSummary(membership?.muteConfig) : nil,
            notification: membership?.notification ?? .onlyMentions,
            isArchived: metadata?.isArchived ?? false,
            isLocked: metadata?.isLocked ?? false,
            // **Archived is not closed.** A message sent to an archived thread
            // un-archives it, so the composer stays live there — only a lock, or
            // a missing permission, takes it away.
            canSend: permissionGate.canSend(in: channelID) && !(metadata?.isLocked ?? false),
            copyLink: { [weak self] in
                guard let self else { return }
                let guild = channelIndex.guildID(of: channelID).map(\.rawValue.description)
                    ?? "@me"
                Self.copy("https://discord.com/channels/\(guild)/\(channelID.rawValue)")
            },
            copyID: { Self.copy(channelID.description) }
        )
    }

    /// A post's tags, joined against the forum that defines them.
    ///
    /// A tag id the forum no longer lists is dropped rather than drawn as a
    /// number — deleting a tag leaves its id behind on every post that had it.
    private static func tags(of thread: Channel?, in parent: Channel?) -> [ForumTag] {
        guard let thread, let parent, parent.isForumLike, !thread.appliedTags.isEmpty else {
            return []
        }
        var byID: [ForumTagID: ForumTag] = [:]
        byID.reserveCapacity(parent.availableTags.count)
        for tag in parent.availableTags { byID[tag.id] = tag }
        return thread.appliedTags.compactMap { byID[$0] }
    }

    private static func subtitle(thread: Channel?, owner: User?) -> String? {
        if thread?.threadMetadata?.isLocked == true { return "Locked" }
        if thread?.threadMetadata?.isArchived == true { return "Archived" }
        guard let owner else { return nil }
        return "Started by \(owner.displayName)"
    }

    /// "Muted until 5:16 PM", or the plain word when there is no end.
    ///
    /// The time only, not the date, for anything ending today — which every
    /// duration but the last two does. A full date on a fifteen-minute mute is
    /// noise in a header that has one line.
    private static func muteSummary(_ config: ThreadMuteConfig?) -> String {
        guard let endTime = config?.endTime else { return "Muted" }
        let sameDay = Calendar.current.isDate(endTime, inSameDayAs: .now)
        let stamp = sameDay
            ? endTime.formatted(.dateTime.hour().minute(.twoDigits))
            : endTime.formatted(.dateTime.day().month().hour().minute(.twoDigits))
        return "Muted until \(stamp)"
    }
}
