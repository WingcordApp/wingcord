import Foundation
import WingcordCore
import WingcordNet

// MARK: - The clip player (docs/CLIPS-PRESENCE.md, Phase 4.5)
//
// What Discord's player in chat draws from a clip, and what it sends back
// (web build 641803, modules 682176 / 560149 / 478531 / 773503):
//
// - a header of the clip's title, its game and when it was made, with up to
//   four of its people and "N more participants";
// - while it plays, who is speaking at that moment ("Speaking indicators",
//   offered when the timeline has speech, on by default);
// - its moments on the scrubber, and its **timeline comments**: replies to the
//   clip's message carrying `media_mention {attachment_id, timestamp}`.
//   Discord files them in a media thread whose id is the attachment's
//   (`GET /channels/{attachment id}/messages?limit=100`, type 19), each copy
//   under the reply's own id — so the channel's reply and the thread's copy
//   are one comment. Sent from the player as a quick emoji or a reply, both
//   "To current time".

/// Somebody in a clip, as its header and its speaking list draw them.
struct ClipFace: Identifiable, Equatable, Sendable {
    var id: UserID
    var name: String
    var url: URL?
    var monogram: String
}

/// One reply at a moment of a clip.
struct TimelineComment: Identifiable, Equatable, Sendable {
    var id: MessageID
    var authorID: UserID
    var authorName: String
    var avatarURL: URL?
    var monogram: String
    var content: String
    /// Milliseconds into the clip.
    var timestampMS: Int
    /// A comment that is one emoji is drawn as itself on the scrubber, as
    /// Discord draws it; anything else is a speech bubble with its words.
    var emoji: Emoji?
    /// Still on its way — the reader's own, before Discord has it.
    var isPending = false

    enum Emoji: Equatable, Sendable {
        case unicode(String)
        case custom(name: String, url: URL?)
    }

    /// Discord's test (module 560149): the trimmed words are `<:name:id>` /
    /// `<a:name:id>`, or a single emoji.
    static func emoji(in content: String) -> Emoji? {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("<"), text.hasSuffix(">") {
            let parts = text.dropFirst().dropLast().split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0].isEmpty || parts[0] == "a", !parts[1].isEmpty,
                  let id = UInt64(parts[2])
            else { return nil }
            return .custom(
                name: String(parts[1]),
                url: CDN.emoji(id: EmojiID(rawValue: id), animated: parts[0] == "a", side: 20)
            )
        }
        guard text.count == 1, let character = text.first,
              character.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation })
                || (character.unicodeScalars.count > 1 && character.unicodeScalars.first?.properties.isEmoji == true)
        else { return nil }
        return .unicode(text)
    }
}

extension AppModel {

    /// Discord's quick reactions when the reader has no frequent ones of
    /// their own: its default frecency list's first three, as the activity
    /// card's are.
    static let clipQuickEmoji = ["👍", "👀", "😆"]

    /// The clip's people, in the order Discord sent them.
    func clipFaces(_ clip: AttachmentClip, in channelID: ChannelID?) -> [ClipFace] {
        let guildID = channelID.flatMap { channelIndex.guildID(of: $0) }
        return clip.participants.map { participant in
            let user = users[participant.id] ?? participant
            let member = guildID.flatMap { members[$0]?[participant.id] }
            let url = guildID.flatMap { guild in
                member?.avatarHash.flatMap { hash in
                    CDN.guildMemberAvatar(guildID: guild, userID: participant.id, hash: hash, side: Metrics.avatarInline)
                }
            } ?? avatarURL(for: user, side: Metrics.avatarInline)
            return ClipFace(
                id: participant.id,
                name: member?.resolvedName(user: user) ?? user.preferredName,
                url: url,
                monogram: user.monogram
            )
        }
    }

    /// Whether a timeline comment can be sent on a clip here.
    func canCommentOnClip(in channelID: ChannelID) -> Bool {
        connectionState == .ready && permissionGate.canSend(in: channelID)
    }

    /// A clip's timeline comments, by their moment: the channel's own replies
    /// carrying its `media_mention`, the reader's sends on their way, and what
    /// its media thread held — one entry per comment.
    func timelineComments(on attachmentID: AttachmentID, in channelID: ChannelID) -> [TimelineComment] {
        let guildID = channelIndex.guildID(of: channelID)
        let box = messages(in: channelID)
        var seen: Set<MessageID> = []
        var comments: [TimelineComment] = []

        func take(_ message: Message, isPending: Bool) {
            guard let mention = message.mediaMention, mention.attachmentID == attachmentID,
                  seen.insert(message.id).inserted
            else { return }
            let user = users[message.authorID]
            let member = guildID.flatMap { members[$0]?[message.authorID] }
            comments.append(TimelineComment(
                id: message.id,
                authorID: message.authorID,
                authorName: member?.resolvedName(user: user) ?? user?.preferredName ?? "Unknown",
                avatarURL: avatarURL(forUserID: message.authorID, inGuild: guildID, side: Metrics.avatarInline),
                monogram: user?.monogram ?? "?",
                content: message.content,
                timestampMS: max(0, mention.timestampMS),
                emoji: TimelineComment.emoji(in: message.content),
                isPending: isPending
            ))
        }

        for message in box?.messages ?? [] { take(message, isPending: false) }
        for entry in box?.outbox ?? [] { take(entry.echo, isPending: entry.state == .sending) }
        for message in clipCommentThreads[attachmentID] ?? [] { take(message, isPending: false) }
        return comments.sorted { ($0.timestampMS, $0.id.rawValue) < ($1.timestampMS, $1.id.rawValue) }
    }

    /// Asks for a clip's media thread once, when it opens with comments on it.
    ///
    /// `--demo` asks nothing: its comments are the channel's own.
    func loadTimelineComments(on attachmentID: AttachmentID, of clip: AttachmentClip) {
        guard clip.hasTimelineComments, !LaunchOptions.current.usesDemoFixtures,
              connectionState == .ready, clipCommentFetches.insert(attachmentID).inserted
        else { return }
        Task {
            do {
                let page = try await sessionController.rest.messages(
                    in: ChannelID(rawValue: attachmentID.rawValue), limit: DiscordREST.historyPageSize
                )
                sessionController.absorb(page)
                clipCommentThreads[attachmentID] = page.messages
            } catch {
                // Read-only and best effort: the channel's own replies still
                // show, and the next open asks again.
                clipCommentFetches.remove(attachmentID)
                SessionController.trace("clip comments \(attachmentID.rawValue) failed: \(SessionController.describe(error))")
            }
        }
    }

    /// Sends a timeline comment — Discord's player's quick emoji and Reply:
    /// a reply to the clip's message at `milliseconds` into it, pinging its
    /// author unless that is the reader.
    /// - Parameter echoesLocally: `--demo`'s way — the reply lands in the
    ///   conversation and nothing is asked of Discord.
    func sendTimelineComment(
        _ text: String,
        at milliseconds: Int,
        on attachmentID: AttachmentID,
        of messageID: MessageID,
        in channelID: ChannelID,
        echoesLocally: Bool = LaunchOptions.current.usesDemoFixtures
    ) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, canCommentOnClip(in: channelID), let me = currentUserID else { return }
        let mention = MediaMention(attachmentID: attachmentID, timestampMS: max(0, milliseconds))
        let pings = knownMessage(messageID, in: channelID)?.authorID != me
        guard !echoesLocally else {
            echoDemoComment(words, mention: mention, replyingTo: messageID, pings: pings, in: channelID, author: me)
            return
        }
        sessionController.send(
            words, in: channelID, replyingTo: messageID, pingsRepliedAuthor: pings, mediaMention: mention
        )
    }

    /// `--demo` sends nothing: the comment lands in the conversation as
    /// Discord would hand it back.
    private func echoDemoComment(
        _ words: String, mention: MediaMention, replyingTo messageID: MessageID, pings: Bool,
        in channelID: ChannelID, author: UserID
    ) {
        let request = OutgoingMessage.Request(
            content: words, replyingTo: messageID, pingsRepliedAuthor: pings, mediaMention: mention
        )
        let latest = messages(in: channelID)?.messages.last?.sentAt ?? .now
        let id = SessionController.mintNonce(at: max(.now, latest.addingTimeInterval(0.001)))
        let message = echo(of: request, id: id, in: channelID, author: author)
        mutateBox(channelID) { $0.messages.append(message) }
        acknowledgeOwnMessage(id, in: channelID)
        messageContentRevision &+= 1
    }
}
