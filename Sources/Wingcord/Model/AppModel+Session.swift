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
