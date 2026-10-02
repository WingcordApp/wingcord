import AppKit
import Foundation
import WingcordCore

// MARK: - Being told a message arrived
//
// The store's half: what the reader has chosen, what the window can see, and the
// words a banner carries. The *decision* is `NotificationPolicy`, which is pure
// and lives in `WingcordCore`; the machinery is `MessageNotifier`, which is the
// only thing here that knows Notification Center exists.

extension AppModel {

    /// Whether this message earns an interruption, and what it should say.
    ///
    /// Nil for the overwhelming majority — a message in a channel nobody has
    /// asked to be told about is the common case, and this is on the gateway's
    /// hot path.
    func notice(for message: Message) -> MessageNotice? {
        // The reader's own switch, before anything is looked up. Off, this is
        // one boolean per message and nothing else.
        guard AppSettings.shared.postsNotifications else { return nil }
        // A message request interrupts nobody — Discord's `shouldNotify` turns
        // one away before anything else is asked. It waits on its own page.
        guard let channel = channelIndex[message.channelID], channel.messageRequest == nil else {
            return nil
        }

        let guildID = channel.guildID
        let isRoleMention = message.mentionedRoleIDs.contains {
            mentionableIDs.contains($0.rawValue)
        }
        let subject = NotificationPolicy.Subject(
            channelID: message.channelID,
            guildID: guildID,
            isDirectMessage: channel.kind.isPrivate,
            isFromReader: message.authorID == currentUserID,
            isAuthorSilenced: blockedUserIDs.contains(message.authorID)
                || ignoredUserIDs.contains(message.authorID),
            // **Both halves.** A selected channel in a window nobody is looking
            // at is exactly the case a notification exists for.
            isOnScreen: message.channelID == selectedChannelID && NSApp.isActive,
            mentionsReader: message.mentionedUserIDs.contains(where: { $0 == currentUserID })
                || isRoleMention,
            isRoleMention: isRoleMention,
            mentionsEveryone: message.mentionsEveryone,
            guildDefault: guildID
                .flatMap { guilds[$0] }
                .map { MessageNotificationLevel(guildDefault: $0.defaultMessageNotifications) }
                ?? .allMessages
        )

        var preferences = notificationPreferences
        // **The reader's own floor, applied to the PREFERENCES rather than to
        // the answer.** Written as "and it was a mention" after the fact it
        // would also silence direct messages, which the policy deliberately
        // exempts from every level — and a mentions-only switch that muted DMs
        // is the one way this control could be actively harmful.
        if AppSettings.shared.notifiesOnlyForMentions, let guildID {
            preferences.guildLevels[guildID] = .onlyMentions
            preferences.channelLevels[message.channelID] = .onlyMentions
        }
        guard NotificationPolicy.shouldNotify(subject, preferences: preferences) else { return nil }

        return MessageNotice(
            channelID: message.channelID,
            messageID: message.id,
            title: notificationTitle(for: message, in: channel),
            subtitle: notificationSubtitle(for: channel),
            body: Self.excerpt(of: message)
        )
    }

    /// Follows a banner the reader pressed.
    ///
    /// **The same jump a message link takes**, and deliberately not a second
    /// path: the channel may be in a server that is not selected, the transcript
    /// may not be loaded, and both of those are already solved once. What is
    /// added here is the permission check, because a notification can outlive
    /// the access that produced it — somebody removed from a server still has
    /// its banners in Notification Centre, and pressing one must not open an
    /// empty transcript.
    func openNotifiedMessage(_ channelID: ChannelID, _ messageID: MessageID) {
        notifier.clear(channelID)
        guard canOpen(channelID) else { return }
        // A takeover is showing something that is not a channel, and a jump into
        // one has to put the column back first.
        closeDiscovery()
        closeQuickSwitch()
        profileRequest = nil
        sessionController.jumpToMessage(messageID, in: channelID)
    }

    /// Who wrote it. The **guild nickname** where there is one, which is the
    /// name the reader sees on every other surface for that person.
    private func notificationTitle(for message: Message, in channel: Channel) -> String {
        let author = users[message.authorID]
        if let guildID = channel.guildID,
           let nickname = members[guildID]?[message.authorID]?.nickname,
           !nickname.isEmpty
        {
            return nickname
        }
        return author?.preferredName ?? "Someone"
    }

    /// Where it was written.
    ///
    /// **Nil for a one-to-one conversation**, where the channel *is* the person
    /// already named in the title — a banner reading "alex / alex" says one
    /// thing twice and costs the line the message could have used.
    private func notificationSubtitle(for channel: Channel) -> String? {
        switch channel.kind {
        case .directMessage:
            return nil
        case .groupDirectMessage:
            return displayName(of: channel)
        default:
            let name = "#\(channel.name)"
            guard let guildID = channel.guildID, let guild = guilds[guildID] else { return name }
            return "\(name) · \(guild.name)"
        }
    }
}

/// One banner's worth of a message.
///
/// A value rather than three arguments, for the reason every other presentation
/// type here is one: the decision and the words are made together, and a caller
/// that could get one without the other would be a caller that can post a banner
/// the policy refused.
struct MessageNotice: Hashable, Sendable {
    var channelID: ChannelID
    var messageID: MessageID
    var title: String
    var subtitle: String?
    var body: String
}
