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
    ///
    /// **And records the visit**, which is the quick switcher's Previous list.
    /// Here rather than in `selectChannel` because that is not the only way a
    /// channel becomes the destination — a selection restored at launch, a
    /// message link and a keyboard shortcut all arrive through this one
    /// `onChange`, and a recorder on the click handler would miss every one of
    /// them. `recordChannelVisit` is what refuses a previewed channel.
    func channelDidOpen(_ channelID: ChannelID) {
        recordChannelVisit(channelID)
        // A banner about a channel the reader is now reading is chrome
        // describing something they have already done.
        notifier.clear(channelID)
        // **A topic stays with the channel it was opened in** — Discord clears
        // it on `CHANNEL_SELECT` — or coming back would bring a panel up that
        // the reader put down by leaving.
        if let open = openTopic, open.channelID != channelID { openTopic = nil }
        sessionController.openChannel(channelID)
    }

    func sendMessage(
        _ content: String,
        in channelID: ChannelID,
        stickerIDs: [UInt64] = []
    ) {
        let box = messages(in: channelID)
        // An empty Return is not a send, so it must not flash a slowmode
        // refusal at somebody who has not tried to say anything.
        guard SessionController.isSendable(
            content, stickerIDs: stickerIDs, attachments: box?.attachments ?? []
        ) else { return }
        // A composer that is scheduling queues the message instead — and a
        // message posted on Thursday waits on no slowmode today. A sticker is
        // sent now: Discord's sticker send carries no time.
        if stickerIDs.isEmpty, let box, let date = box.scheduledAt {
            schedule(content, from: box, at: date, in: channelID)
            return
        }
        // **Held inside a slowmode wait, with everything left where it was** —
        // the draft, the reply and the tray. Discord's composer refuses the
        // same way (module `806150`): a send it knows the server will refuse
        // is not attempted.
        guard !holdsForSlowmode(channelID) else { return }
        guard let box else {
            sessionController.send(content, in: channelID, replyingTo: nil, stickerIDs: stickerIDs)
            return
        }
        sessionController.send(
            content,
            in: channelID,
            replyingTo: box.replyingTo,
            stickerIDs: stickerIDs,
            attachments: box.attachments
        )
        // **The composer empties at once — words, reply and files alike**, as
        // Discord's does. The send is in the transcript now, and a refused
        // upload is handed back by `MessageBox.returnToComposer`.
        mutateBox(channelID) {
            $0.draft = ""
            $0.replyingTo = nil
            $0.attachments = []
            $0.attachmentRefusal = nil
        }
    }

    /// A GIF from the picker, sent as its URL, which every client unfurls back
    /// into an embed — Discord's `isGif` send.
    ///
    /// **It takes the reply and the scheduled time with it, and leaves the
    /// words and the files where they are**: a GIF is a message of its own,
    /// not the end of the one being written. Discord's composer is not cleared
    /// by one (`shouldClear: false`); only the reply is used up.
    func sendGIF(_ url: URL, in channelID: ChannelID) {
        let box = messages(in: channelID)
        let content = url.absoluteString
        if let date = box?.scheduledAt {
            queueScheduled(content, at: date, replyingTo: box?.replyingTo, in: channelID)
        } else {
            guard !holdsForSlowmode(channelID) else { return }
            sessionController.send(content, in: channelID, replyingTo: box?.replyingTo)
        }
        mutateBox(channelID) { $0.replyingTo = nil }
    }

    /// The reader's own message as the transcript draws it until Discord
    /// answers — Discord's `createMessage`, which carries the words, the reply
    /// and the stickers and nothing a server would have to add.
    func echo(
        of request: OutgoingMessage.Request,
        id: MessageID,
        in channelID: ChannelID,
        author: UserID
    ) -> Message {
        let reference = request.replyingTo.map { replied in
            let quoted = message(replied, in: channelID)
            return MessageReference(
                messageID: replied,
                channelID: channelID,
                authorID: quoted?.authorID,
                isAuthorBot: quoted.flatMap { users[$0.authorID]?.isBot } ?? false,
                excerpt: MessageReference.excerpt(of: quoted?.content ?? ""),
                hasAttachment: !(quoted?.attachments.isEmpty ?? true)
                    || !(quoted?.stickers.isEmpty ?? true)
            )
        }
        return Message(
            id: id,
            channelID: channelID,
            authorID: author,
            content: request.content,
            kind: reference == nil ? .default : .reply,
            payload: MessagePayload(
                stickers: request.stickerIDs.compactMap(stickerRef),
                poll: request.poll?.poll(postedAt: id.timestamp),
                reference: reference,
                nonce: String(id.rawValue),
                listenAlong: request.listenAlong
            )
        )
    }

    /// A sticker the account can see, by id — a standard pack's, or a
    /// server's.
    func stickerRef(_ id: UInt64) -> StickerRef? {
        if let pack = standardPackIDByStickerID[id].flatMap({ standardStickerPacks[$0] }),
           let sticker = pack.stickers.first(where: { $0.id == id })
        {
            return sticker
        }
        for stickers in guildStickers.values {
            if let sticker = stickers.first(where: { $0.id == id }) { return sticker }
        }
        return nil
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

    /// Sets, changes or clears the reader's own custom status.
    ///
    /// **Published AND saved.** The socket is how everybody else sees it and
    /// the settings blob is what makes it survive a launch — this client did
    /// only the first for as long as it has had a status field, so a status set
    /// on a Monday was gone on Tuesday with nothing to say why.
    func updateSelfCustomStatus(_ status: CustomStatus?) {
        let next = status.flatMap { $0.isEmpty ? nil : $0 }
        guard selfCustomStatus != next else { return }
        let previous = selfCustomStatus
        selfCustomStatus = next
        sessionController.publishPresence()
        sessionController.writeCustomStatus(next, restoring: previous)
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
            // The payload box is immutable and shared, so a change builds a new
            // one rather than mutating what other holders can see.
            box.messages[index].payload = existing.replacingPoll(body(poll))
        }
        messageContentRevision &+= 1
    }

    func markRead(_ channelID: ChannelID) {
        // **The channel's newest, not the window's, when it is cut off from
        // the present.** The last loaded message is then a year old, and
        // acknowledging it would mark the channel read up to a year ago.
        let box = messageBoxes[channelID]
        let loaded = box?.hasMoreNewer == true ? nil : box?.messages.last?.id
        guard let newest = loaded ?? channelIndex[channelID]?.lastMessageID else { return }
        sessionController.acknowledge(newest, in: channelID)
    }

    /// Applies one reaction arriving or leaving, of one kind, to a loaded
    /// message.
    ///
    /// Reactions arrive as deltas, so the tally is adjusted rather than
    /// replaced — Discord does not resend the whole list, and rebuilding it
    /// would need a fetch per reaction. The arithmetic is Discord's own, in
    /// `ReactionTally`.
    ///
    /// - Parameter colors: a super reaction's palette. Kept only when the
    ///   emoji had none yet — see `ReactionTally.adding`.
    func applyReaction(
        _ emoji: EmojiRef,
        kind: ReactionKind,
        to messageID: MessageID,
        in channelID: ChannelID,
        added: Bool,
        isMine: Bool,
        colors: [UInt32] = []
    ) {
        let isDirectMessage = channelIndex[channelID]?.kind == .directMessage
        updateReactions(of: messageID, in: channelID) { reactions in
            added
                ? ReactionTally.adding(
                    emoji, kind: kind, isMine: isMine, colors: colors,
                    isDirectMessage: isDirectMessage, to: reactions
                )
                : ReactionTally.removing(emoji, kind: kind, isMine: isMine, from: reactions)
        }
    }

    /// `MESSAGE_REACTION_ADD_MANY`: several plain reactions in one dispatch,
    /// applied as Discord's `addReactionBatch` applies them — one add per
    /// person, in order.
    func applyReactionBatch(
        _ batch: [(EmojiRef, [UserID])],
        to messageID: MessageID,
        in channelID: ChannelID
    ) {
        let isDirectMessage = channelIndex[channelID]?.kind == .directMessage
        let reader = currentUserID
        updateReactions(of: messageID, in: channelID) { reactions in
            var result = reactions
            var changed = false
            for (emoji, users) in batch {
                for user in users {
                    guard let next = ReactionTally.adding(
                        emoji, kind: .normal, isMine: user == reader,
                        isDirectMessage: isDirectMessage, to: result
                    ) else { continue }
                    result = next
                    changed = true
                }
            }
            return changed ? result : nil
        }
    }

    /// A moderator cleared every reaction on a message, or one emoji's.
    func clearReactions(_ emoji: EmojiRef?, on messageID: MessageID, in channelID: ChannelID) {
        updateReactions(of: messageID, in: channelID) { reactions in
            guard let emoji else { return reactions.isEmpty ? nil : [] }
            return ReactionTally.removingEmoji(emoji, from: reactions)
        }
    }

    /// The one write every reaction change goes through.
    ///
    /// **Nothing is written when nothing changed.** The reducer answers nil for
    /// the gateway's echo of the reader's own reaction, which the optimistic
    /// write already counted — and a write here would rebuild the payload,
    /// bump the content revision and re-lay-out the row for a count that did
    /// not move.
    private func updateReactions(
        of messageID: MessageID,
        in channelID: ChannelID,
        _ transform: ([Reaction]) -> [Reaction]?
    ) {
        guard let index = messageBoxes[channelID]?.messages.firstIndex(where: { $0.id == messageID }),
              let message = messageBoxes[channelID]?.messages[index],
              let reactions = transform(message.reactions)
        else { return }
        mutateBox(channelID) { box in
            // The payload box is immutable and shared, so a change builds a new
            // one rather than mutating what other holders can see — through the
            // copy helper, which is the one place that knows every field.
            box.messages[index].payload = (message.payload ?? MessagePayload())
                .replacingReactions(reactions)
        }
        messageContentRevision &+= 1
    }
}
