import Foundation
import WingcordCore

// MARK: - Session plumbing
//
// The store's side of the connection. It owns the controller so that a view can
// ask for a sign-in without knowing a socket exists, and so teardown has exactly
// one owner.

extension AppModel {

    func beginSession(token: String) {
        sessionController.beginSession(token: token)
    }

    func resumeSession(for account: StoredAccount) {
        sessionController.resumeSession(for: account)
    }

    func signOut() {
        sessionController.signOut()
    }

    /// Called when a channel becomes the destination: loads its newest page and
    /// subscribes to its roster.
    func channelDidOpen(_ channelID: ChannelID) {
        sessionController.openChannel(channelID)
    }

    func sendMessage(
        _ content: String,
        in channelID: ChannelID,
        stickerIDs: [UInt64] = []
    ) {
        let replyingTo = messages(in: channelID)?.replyingTo
        sessionController.send(
            content, in: channelID, replyingTo: replyingTo, stickerIDs: stickerIDs
        )
        mutateBox(channelID) {
            $0.draft = ""
            $0.replyingTo = nil
        }
    }

    /// Puts what a picker chose into the draft, or sends it if it is a sticker.
    ///
    /// A sticker is a message; an emoji is text. Routing both through one entry
    /// point is what keeps the composer from having to know the difference.
    func apply(_ pick: ExpressionItem.Pick, in channelID: ChannelID) {
        switch pick {
        case .sticker(let id):
            sendMessage("", in: channelID, stickerIDs: [id])
        case .insert(let text):
            mutateBox(channelID) { box in
                // A separator, unless the draft already ends in one. Two emoji
                // picked in a row must not fuse into one unparseable token.
                let needsSpace = !box.draft.isEmpty && !(box.draft.last?.isWhitespace ?? true)
                box.draft += (needsSpace ? " " : "") + text
            }
        }
    }

    /// Changes what everybody else sees.
    ///
    /// **Written to the store and published to the gateway together.** The store
    /// is what the now bar draws, so writing only there leaves the reader
    /// looking at a status nobody else has; publishing only to the socket leaves
    /// the bar showing the old one until a presence for the account happens to
    /// come back. The pair is one action, so it lives in one place.
    func updateSelfStatus(_ status: PresenceStatus) {
        guard selfStatus != status else { return }
        selfStatus = status
        sessionController.publishPresence()
    }

    func updateSelfCustomStatus(_ text: String?, emoji: String? = nil) {
        let normalized = text.flatMap { $0.isEmpty ? nil : $0 }
        guard selfCustomStatus != normalized || selfCustomStatusEmoji != emoji else { return }
        selfCustomStatus = normalized
        selfCustomStatusEmoji = emoji
        sessionController.publishPresence()
    }

    /// Casts the reader's vote in a poll.
    ///
    /// **Applied optimistically and then sent**, for the same reason a message
    /// is: the tally is the only feedback a vote has, and a bar that appears one
    /// round trip after the click reads as the click having missed. A failure
    /// puts the poll back exactly as it was.
    func vote(for answerID: Int, on messageID: MessageID, in channelID: ChannelID) {
        guard let before = poll(messageID, in: channelID), !before.isClosed else { return }
        applyVote(answerID, on: messageID, in: channelID)
        sessionController.castVote(
            answerID, on: messageID, in: channelID, revertingTo: before
        )
    }

    /// One message's poll, if it has one.
    func poll(_ messageID: MessageID, in channelID: ChannelID) -> Poll? {
        messageBoxes[channelID]?.messages.first { $0.id == messageID }?.poll
    }

    /// Writes a vote into the loaded transcript.
    ///
    /// Single-choice only, which is what this client offers: the route replaces
    /// the whole ballot, so a second pick on a multiselect poll would silently
    /// drop the first — see `DiscordREST.vote`.
    func applyVote(_ answerID: Int, on messageID: MessageID, in channelID: ChannelID) {
        replacePoll(on: messageID, in: channelID) { poll in
            var updated = poll
            for index in updated.answers.indices {
                let wasMine = updated.answers[index].isMine
                let isMine = updated.answers[index].id == answerID
                updated.answers[index].isMine = isMine
                if isMine, !wasMine { updated.answers[index].count += 1 }
                if wasMine, !isMine {
                    updated.answers[index].count = max(0, updated.answers[index].count - 1)
                }
            }
            return updated
        }
    }

    /// Puts a poll back the way it was, after a vote that did not land.
    func restorePoll(_ poll: Poll, on messageID: MessageID, in channelID: ChannelID) {
        replacePoll(on: messageID, in: channelID) { _ in poll }
    }

    private func replacePoll(
        on messageID: MessageID,
        in channelID: ChannelID,
        _ body: (Poll) -> Poll
    ) {
        mutateBox(channelID) { box in
            guard let index = box.messages.firstIndex(where: { $0.id == messageID }),
                  let existing = box.messages[index].payload,
                  let poll = existing.poll
            else { return }
            var message = box.messages[index]
            // The payload box is immutable and shared, so a change builds a new
            // one rather than mutating what other holders can see.
            message.payload = MessagePayload(
                attachments: existing.attachments,
                embeds: existing.embeds,
                reactions: existing.reactions,
                stickers: existing.stickers,
                components: existing.components,
                displayComponents: existing.displayComponents,
                poll: body(poll),
                mentionedUserIDs: existing.mentionedUserIDs,
                mentionedRoleIDs: existing.mentionedRoleIDs,
                mentionsEveryone: existing.mentionsEveryone,
                referencedMessageID: existing.referencedMessageID,
                referencedChannelID: existing.referencedChannelID,
                webhookID: existing.webhookID,
                nonce: existing.nonce
            )
            box.messages[index] = message
        }
        messageContentRevision &+= 1
    }

    func markRead(_ channelID: ChannelID) {
        guard let newest = messageBoxes[channelID]?.messages.last?.id
            ?? channelIndex[channelID]?.lastMessageID
        else { return }
        sessionController.acknowledge(newest, in: channelID)
    }

    /// Applies a reaction add or remove to a loaded message.
    ///
    /// Reactions arrive as deltas, so the count is adjusted rather than
    /// replaced — Discord does not resend the whole list, and rebuilding it
    /// would need a fetch per reaction.
    func applyReaction(
        _ emoji: EmojiRef,
        to messageID: MessageID,
        in channelID: ChannelID,
        added: Bool,
        isMine: Bool
    ) {
        mutateBox(channelID) { box in
            guard let index = box.messages.firstIndex(where: { $0.id == messageID }) else {
                return
            }
            var message = box.messages[index]
            var reactions = message.reactions
            if let position = reactions.firstIndex(where: { $0.emoji == emoji }) {
                var reaction = reactions[position]
                reaction.count += added ? 1 : -1
                if isMine { reaction.isMine = added }
                if reaction.count <= 0 {
                    reactions.remove(at: position)
                } else {
                    reactions[position] = reaction
                }
            } else if added {
                reactions.append(Reaction(emoji: emoji, count: 1, isMine: isMine))
            }

            // The payload box is immutable and shared, so a change builds a new
            // one rather than mutating what other holders can see.
            let existing = message.payload
            message.payload = MessagePayload(
                attachments: existing?.attachments ?? [],
                embeds: existing?.embeds ?? [],
                reactions: reactions,
                stickers: existing?.stickers ?? [],
                mentionedUserIDs: existing?.mentionedUserIDs ?? [],
                mentionedRoleIDs: existing?.mentionedRoleIDs ?? [],
                mentionsEveryone: existing?.mentionsEveryone ?? false,
                referencedMessageID: existing?.referencedMessageID,
                referencedChannelID: existing?.referencedChannelID,
                webhookID: existing?.webhookID,
                nonce: existing?.nonce
            )
            box.messages[index] = message
        }
        messageContentRevision &+= 1
    }
}
