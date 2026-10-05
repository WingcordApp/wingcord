import Foundation
import WingcordCore

// MARK: - What the thread panel needs
//
// A plain value snapshot with no model reference — §2. The thread's menu is not
// in it: the ⋯ raises `ThreadOptionsMenu`, which resolves its own rows when it
// opens rather than on every evaluation of a header whose menu is usually shut.

struct ThreadPanelPresentation {
    var channelID: ChannelID
    var name: String
    /// The thread's own glyph — Discord's, with the lock on a private one.
    var symbolName: String
    /// "Started by …", or what a thread's state is when that matters more.
    var subtitle: String?
    /// Whether this is a forum post rather than a thread off a message — a
    /// post is the page beside its board, and takes the wider column.
    var isPost: Bool
    var isMuted: Bool
    /// "Muted until 5:16 PM", when there is an end to name.
    var muteSummary: String?
}

extension AppModel {

    func threadPanelPresentation(for channelID: ChannelID) -> ThreadPanelPresentation {
        let thread = channelIndex[channelID]
        let membership = threadMemberships[channelID]
        let parent = thread?.parentID.flatMap { channelIndex[$0] }
        let isMuted = membership?.isMutedNow() ?? false

        return ThreadPanelPresentation(
            channelID: channelID,
            name: thread?.name ?? "Thread",
            symbolName: thread?.kind.symbolName ?? DiscordGlyph.thread,
            subtitle: Self.subtitle(thread: thread, owner: thread?.ownerID.flatMap { users[$0] }),
            isPost: parent?.isForumLike ?? false,
            isMuted: isMuted,
            muteSummary: isMuted ? Self.muteSummary(membership?.muteConfig) : nil
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
