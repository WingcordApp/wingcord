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

    private static func subtitle(thread: Channel?, owner: User?) -> String? {
        if thread?.threadMetadata?.isLocked == true { return "Locked" }
        if thread?.threadMetadata?.isArchived == true { return "Archived" }
        guard let owner else { return nil }
        // `preferredName`, not `displayName`: the latter is optional, so
        // interpolating it printed `Started by Optional("Lina")` — and an
        // account with no global name would have had none at all.
        return "Started by \(owner.preferredName)"
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
