import Foundation
import WingcordCore

/// Which list the Message Requests page shows — Discord's two pills.
enum MessageRequestsTab: Hashable, Sendable {
    case requests
    case spam
}

/// One row of the Message Requests page.
struct MessageRequestRow: Hashable, Sendable, Identifiable {
    var id: ChannelID
    var userID: UserID?
    var name: String
    var handle: String?
    var avatarURL: URL?
    var monogram: String
    /// Discord's "5m ago", from the newest message.
    var age: String?
    /// The servers in common, once the sender's profile has answered.
    var mutualServers: MutualServerSummary?
    var isBusy: Bool
    var isPreviewed: Bool
}

/// Up to three shared servers' marks, and how many there are — the line under
/// a request's name (Discord's `ts`).
struct MutualServerSummary: Hashable, Sendable {
    struct Mark: Hashable, Sendable, Identifiable {
        var id: GuildID
        var iconURL: URL?
        var monogram: String
    }

    var marks: [Mark]
    var count: Int
}

// MARK: - Message requests
//
// Conversations from people the reader has not let in yet — Discord's
// `MessageRequestStore` and `SpamMessageRequestStore`. They are kept out of the
// conversation list by `ChannelIndex.privateChannelIDs()`, and live on a page of
// their own behind a row at the head of that list.

extension AppModel {

    /// The page is up — the direct-message home only, as Discord's is.
    var isMessageRequestsShown: Bool { isMessageRequestsOpen && selectedGuildID == nil }

    /// The Friends page is up — the home's, like the requests page.
    var isFriendsShown: Bool { isFriendsOpen && selectedGuildID == nil }

    func openFriends() {
        if discovery != nil { closeDiscovery() }
        // Its row is on the conversations page, which a swipe brings up while
        // a server is open (REDESIGN.md R8): the page is the home's.
        if selectedGuildID != nil { selectGuild(nil) }
        isMessageRequestsOpen = false
        previewedChannelID = nil
        profileRequest = nil
        expressionInfoRequest = nil
        isFriendsOpen = true
    }

    func openMessageRequests() {
        if discovery != nil { closeDiscovery() }
        // See `openFriends`: the row can be on screen while a server is open.
        if selectedGuildID != nil { selectGuild(nil) }
        isFriendsOpen = false
        guard !isMessageRequestsOpen else { return }
        isMessageRequestsOpen = true
        messageRequestsTab = .requests
        previewedChannelID = nil
        // Anchored to rects in the transcript the page replaces.
        profileRequest = nil
        expressionInfoRequest = nil
    }

    /// How many requests are pending, for the row's badge and the page's
    /// heading. Spam is counted on its own pill and never badged.
    var pendingMessageRequestCount: Int { channelIndex.messageRequestIDs(.pending).count }
    var spamRequestCount: Int { channelIndex.messageRequestIDs(.spam).count }

    /// One tab's rows, newest first.
    func messageRequestRows(_ tab: MessageRequestsTab) -> [MessageRequestRow] {
        let now = Date.now
        return channelIndex.messageRequestIDs(tab == .spam ? .spam : .pending).map { channelID in
            let channel = channelIndex[channelID]
            let senderID = channel?.recipientIDs.first { $0 != currentUserID }
            let sender = senderID.flatMap { users[$0] }
            let name = sender?.preferredName ?? channel.map(displayName(of:)) ?? "Unknown"
            return MessageRequestRow(
                id: channelID,
                userID: senderID,
                name: name,
                handle: sender?.handle,
                avatarURL: sender.flatMap { avatarURL(for: $0, side: Metrics.avatarMessage) },
                monogram: sender?.monogram ?? Self.monogram(of: name),
                age: channel?.lastMessageID.map { RelativeAge.label(since: $0.timestamp, now: now) },
                mutualServers: senderID.flatMap(mutualServerSummary(with:)),
                isBusy: messageRequestsInFlight.contains(channelID),
                isPreviewed: previewedChannelID == channelID
            )
        }
    }

    /// The line under a request's name, once the profile has answered. Nil
    /// while it has not — "No Mutual Servers" is a fact, not a placeholder.
    private func mutualServerSummary(with userID: UserID) -> MutualServerSummary? {
        guard messageRequestProfilesAsked.contains(userID), !profilesLoading.contains(userID),
              !profileFetchFailures.contains(userID)
        else { return nil }
        let mutual = users[userID]?.decoration?.mutualGuilds ?? []
        return MutualServerSummary(
            marks: mutual.prefix(3).compactMap { entry in
                guard let guild = guilds[entry.id] else { return nil }
                return MutualServerSummary.Mark(
                    id: guild.id,
                    iconURL: guild.iconHash.flatMap {
                        CDN.guildIcon(guildID: guild.id, hash: $0, side: Metrics.avatarRow)
                    },
                    monogram: guild.monogram
                )
            },
            count: mutual.count
        )
    }

    /// Asks for a sender's profile, for the servers in common — Discord's row
    /// fetches it when it has none. Once a session per person.
    func loadMessageRequestSender(_ userID: UserID) {
        guard messageRequestProfilesAsked.insert(userID).inserted else { return }
        sessionController.loadProfile(of: userID, inGuild: nil)
    }

    /// Opens a request beside the page, or closes it — a second click on the
    /// row being read is how every disclosure here closes.
    func previewMessageRequest(_ channelID: ChannelID) {
        previewedChannelID = previewedChannelID == channelID ? nil : channelID
    }

    /// Accept DM. The conversation joins the list and opens, as Discord's
    /// does once the request is taken.
    func acceptMessageRequest(_ channelID: ChannelID) {
        guard messageRequestsInFlight.insert(channelID).inserted else { return }
        sessionController.acceptMessageRequest(channelID)
    }

    /// Ignore, Decline: the reader leaves the conversation.
    func declineMessageRequest(_ channelID: ChannelID) {
        guard messageRequestsInFlight.insert(channelID).inserted else { return }
        sessionController.declineMessageRequest(channelID)
    }

    /// Discord's sentence for a request that would not update (`EDYbS+`).
    static let messageRequestFailure =
        "Uh oh! Something went wrong while updating this message request. Please wait a moment and try again."
}
