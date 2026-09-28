import Foundation
import WingcordCore

// MARK: - Where a message can be sent on to

extension AppModel {

    /// The message being forwarded, quoted.
    func forwardPreview(for request: ForwardRequest) -> QuotedMessage {
        guard let message = message(request.messageID, in: request.channelID) else {
            return QuotedMessage(
                authorName: "Unknown", avatarURL: nil, monogram: "?",
                timestamp: nil, excerpt: ""
            )
        }
        let author = users[message.authorID]
        return QuotedMessage(
            authorName: author?.preferredName ?? "Unknown",
            avatarURL: avatarURL(
                forUserID: message.authorID,
                inGuild: channelIndex.guildID(of: request.channelID),
                side: Metrics.avatarInline * 2
            ),
            monogram: author?.monogram ?? "?",
            timestamp: PresentationRevision.shared.timeline.time(message.sentAt),
            excerpt: Self.excerpt(of: message)
        )
    }

    /// Everywhere the reader may send a message, newest conversation first.
    ///
    /// **Built once when the sheet opens, and memoized on the three counters
    /// that can change the answer.** It walks every channel in the account
    /// through the permission gate — five thousand of them on a large one —
    /// which is far too much to do per keystroke in the sheet's search field, and
    /// exactly the right amount to do once.
    ///
    /// **Ordered by the newest message in each**, which is the only recency
    /// signal the store already holds and the one that puts the conversations
    /// somebody actually uses at the top. Discord ranks by its own frecency
    /// model; a client without that history should not invent one.
    ///
    /// The source channel is left out: forwarding a message into the channel it
    /// is already in is a control with nothing behind it. Nil where there is no
    /// source — a profile being shared.
    func forwardTargets(excluding source: ChannelID?) -> [ForwardTarget] {
        // Read before the cache is consulted, so a hit still registers the
        // dependencies its reader needs.
        let key = ForwardTargetMemoKey(
            structureRevision: channelIndex.structureRevision,
            roleRevision: roleRevision,
            identityRevision: identityRevision,
            source: source
        )
        if let forwardTargetCache, forwardTargetCache.key == key {
            return forwardTargetCache.value
        }

        var targets: [ForwardTarget] = []
        targets.reserveCapacity(64)

        for channelID in channelIndex.privateChannelIDs() where channelID != source {
            guard let channel = channelIndex[channelID],
                  permissionGate.canSend(in: channelID)
            else { continue }
            targets.append(
                ForwardTarget(
                    id: channelID,
                    name: displayName(of: channel),
                    subtitle: subtitle(ofPrivate: channel),
                    iconURL: conversationIcon(of: channel),
                    monogram: Self.monogram(of: displayName(of: channel)),
                    symbolName: nil,
                    recency: channel.lastMessageID?.rawValue ?? 0
                )
            )
        }

        for (guildID, guild) in guilds {
            for channelID in channelIndex.channelIDs(inGuild: guildID) where channelID != source {
                guard let channel = channelIndex[channelID],
                      channel.kind.isConversation,
                      permissionGate.canSend(in: channelID)
                else { continue }
                targets.append(
                    ForwardTarget(
                        id: channelID,
                        name: channel.name,
                        subtitle: guild.name,
                        iconURL: guild.iconHash.flatMap {
                            CDN.guildIcon(guildID: guildID, hash: $0, side: Metrics.avatarRow)
                        },
                        monogram: guild.monogram,
                        symbolName: channel.kind.symbolName,
                        recency: channel.lastMessageID?.rawValue ?? 0
                    )
                )
            }
        }

        targets.sort { $0.recency > $1.recency }
        forwardTargetCache = (key, targets)
        return targets
    }

    /// A conversation's face: the other person's, or the group's own icon.
    ///
    /// The same resolution the sidebar makes — a group DM carries an `icon`
    /// hash on a CDN path of its own, and a row built only for the one-to-one
    /// case leaves every group showing a bare plate.
    private func conversationIcon(of channel: Channel) -> URL? {
        switch channel.kind {
        case .directMessage:
            let partnerID = channel.recipientIDs.first { $0 != currentUserID }
            return partnerID.flatMap { users[$0] }
                .flatMap { avatarURL(for: $0, side: Metrics.avatarRow) }
        case .groupDirectMessage:
            return channel.iconHash.flatMap {
                CDN.channelIcon(channelID: channel.id, hash: $0, side: Metrics.avatarRow)
            }
        default:
            return nil
        }
    }

    /// The line under a conversation's name: the handle for one person, the
    /// count for a group. A server channel's line is its server, which the
    /// builder above sets directly.
    private func subtitle(ofPrivate channel: Channel) -> String? {
        if channel.kind == .groupDirectMessage {
            return "\(channel.recipientIDs.count + 1) members"
        }
        guard let userID = channel.recipientIDs.first else { return nil }
        return users[userID]?.handle
    }
}

/// One place a message can be forwarded to.
struct ForwardTarget: Identifiable, Hashable, Sendable {
    var id: ChannelID
    var name: String
    var subtitle: String?
    var iconURL: URL?
    var monogram: String
    /// A channel's kind glyph. Nil for a conversation, which shows a face.
    var symbolName: String?
    /// The newest message's snowflake, which is what the list is ordered by.
    var recency: UInt64

    /// Whether the row matches what has been typed. Matched against both lines,
    /// because "bitrig" is how somebody finds `#support` and the channel's own
    /// name does not contain it.
    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if name.localizedCaseInsensitiveContains(query) { return true }
        return subtitle?.localizedCaseInsensitiveContains(query) ?? false
    }
}

struct ForwardTargetMemoKey: Hashable, Sendable {
    var structureRevision: UInt64
    var roleRevision: UInt64
    /// Names and handles are drawn on every row, and a nickname change is the
    /// only thing that moves them.
    var identityRevision: UInt64
    var source: ChannelID?
}
