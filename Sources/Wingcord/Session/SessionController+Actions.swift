import Foundation
import WingcordCore
import WingcordNet

// MARK: - The wire side of a message action
//
// Everything here follows the pattern `castVote` set: the store has already
// written the optimistic answer, this sends it, and a refusal puts the store
// back exactly as it was. Reversing an optimistic write by arithmetic is what
// gets it wrong the moment a real update arrives from the gateway in between,
// so every revert carries the previous state rather than a delta.

extension SessionController {

    // MARK: Reactions

    func writeReaction(
        _ emoji: EmojiRef,
        on messageID: MessageID,
        in channelID: ChannelID,
        adding: Bool,
        pending: PendingReaction
    ) {
        Task { [weak self] in
            guard let self else { return }
            defer { model.reactionsInFlight.remove(pending) }
            do {
                if adding {
                    try await rest.addReaction(emoji, to: messageID, in: channelID)
                } else {
                    try await rest.removeReaction(emoji, from: messageID, in: channelID)
                }
            } catch {
                Self.trace("reaction \(messageID) failed: \(Self.describe(error))")
                // The exact inverse of the optimistic write. The gateway echoes
                // the reader's own reaction back as well, and the store's
                // reducer is idempotent on `isMine`, so a revert that crosses
                // an echo settles on the same count either way.
                model.applyReaction(
                    emoji, to: messageID, in: channelID, added: !adding, isMine: true
                )
            }
        }
    }

    // MARK: Editing and deleting

    func edit(_ messageID: MessageID, in channelID: ChannelID, content: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let message = try await rest.editMessage(messageID, in: channelID, content: content)
                // **Merged, not replaced.** The edit route answers with the whole
                // message, but a `pinned` of false on a pinned message would
                // unpin it locally — the same class of bug the pins route has.
                model.mutateBox(channelID) { box in
                    guard let index = box.messages.firstIndex(where: { $0.id == messageID })
                    else { return }
                    box.messages[index].content = message.content
                    box.messages[index].editedAt = message.editedAt
                    if let payload = message.payload { box.messages[index].payload = payload }
                }
                model.messageContentRevision &+= 1
            } catch {
                Self.trace("edit \(messageID) failed: \(Self.describe(error))")
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    /// Deletes a message, and puts it back if the route refuses.
    ///
    /// **Removed optimistically.** A row that lingers for a round trip after
    /// Delete reads as the click having missed, and the reader presses again —
    /// which is a second DELETE against an id that is already gone.
    func delete(_ messageID: MessageID, in channelID: ChannelID) {
        guard let previous = model.message(messageID, in: channelID) else { return }
        model.mutateBox(channelID) { $0.remove(messageID) }
        model.messageContentRevision &+= 1
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.deleteMessage(messageID, in: channelID)
            } catch {
                Self.trace("delete \(messageID) failed: \(Self.describe(error))")
                model.mutateBox(channelID) { $0.upsert(previous) }
                model.messageContentRevision &+= 1
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    // MARK: Pins

    func setPinned(_ isPinned: Bool, messageID: MessageID, in channelID: ChannelID) {
        model.applyPin(isPinned, messageID: messageID, in: channelID)
        Task { [weak self] in
            guard let self else { return }
            do {
                if isPinned {
                    try await rest.pin(messageID, in: channelID)
                } else {
                    try await rest.unpin(messageID, in: channelID)
                }
            } catch {
                Self.trace("pin \(messageID) failed: \(Self.describe(error))")
                model.applyPin(!isPinned, messageID: messageID, in: channelID)
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    /// Fetches a channel's pins, once.
    ///
    /// **An absent entry means "not asked" and an empty one means "asked, and
    /// there are none".** Collapsing the two makes the pane ask again on every
    /// open, for every channel that has never pinned anything — which is most
    /// of them.
    func loadPins(in channelID: ChannelID) {
        guard model.pinnedMessages[channelID] == nil || model.pinsFailure[channelID] != nil else {
            return
        }
        guard model.pinsLoading.insert(channelID).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { model.pinsLoading.remove(channelID) }
            do {
                let page = try await rest.pinnedMessages(in: channelID)
                // The authors come with the page and have to: a pin from two
                // years ago is written by somebody no roster still carries.
                model.users.merge(page.authors) { existing, new in new.merged(over: existing) }
                model.pinnedMessages[channelID] = page.messages
                model.pinsFailure[channelID] = nil
                // A loaded transcript may hold the same messages with a stale
                // `isPinned`; this is the only pass that can put them right.
                model.markPinnedInTranscript(page.messages.map(\.id), in: channelID)
                model.identityRevision &+= 1
            } catch {
                Self.trace("pins \(channelID) failed: \(Self.describe(error))")
                model.pinsFailure[channelID] = Self.describe(error)
            }
        }
    }

    // MARK: Read state

    /// Rewinds the read cursor, and stops the transcript re-acknowledging it.
    ///
    /// **The local write has to come with a latch.** The reader is still looking
    /// at the channel, so the next inbound message would call `acknowledge` and
    /// silently undo what they just asked for. `suppressedAckChannelID` holds
    /// until the selection moves.
    func markUnread(after messageID: MessageID?, in channelID: ChannelID) {
        let mentionCount = model.readStates[channelID]?.mentionCount ?? 0
        var state = model.readStates[channelID] ?? ReadState()
        state.lastAcknowledgedID = messageID
        model.readStates[channelID] = state
        model.suppressedAckChannelID = channelID
        model.sidebarRevision &+= 1
        model.railRevision &+= 1
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.markUnread(
                    after: messageID, in: channelID, mentionCount: mentionCount
                )
            } catch {
                Self.trace("mark unread \(channelID) failed: \(Self.describe(error))")
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    // MARK: Forwarding

    func forward(
        _ messageID: MessageID,
        from sourceChannelID: ChannelID,
        to targets: [ChannelID],
        comment: String
    ) {
        model.forwardsInFlight.formUnion(targets)
        let nonce = Self.nonce()
        Task { [weak self] in
            guard let self else { return }
            // Sequentially, not in a group. Each target is a message send
            // against the same rate-limit bucket family, and a fan-out of ten
            // simply queues in the limiter while making the failure of one
            // indistinguishable from the failure of the rest.
            for (index, target) in targets.enumerated() {
                defer { model.forwardsInFlight.remove(target) }
                do {
                    let message = try await rest.forward(
                        messageID,
                        from: sourceChannelID,
                        to: target,
                        comment: comment,
                        nonce: nonce + String(index)
                    )
                    // Only into a transcript that is actually loaded. Writing
                    // into a box for a channel nobody has open creates one, and
                    // a box with a single message in it is a resident slot spent
                    // on a channel the reader is not reading.
                    guard model.messages(in: target)?.messages.isEmpty == false else { continue }
                    model.mutateBox(target) { $0.upsert(message) }
                    model.messageContentRevision &+= 1
                } catch {
                    Self.trace("forward to \(target) failed: \(Self.describe(error))")
                    model.reportActionFailure(Self.describe(error))
                }
            }
        }
    }

    // MARK: Relationships

    func writeBlock(_ isBlocked: Bool, userID: UserID) {
        Task { [weak self] in
            guard let self else { return }
            defer { model.relationshipsInFlight.remove(userID) }
            do {
                try await rest.setBlocked(isBlocked, userID: userID)
            } catch {
                Self.trace("block \(userID) failed: \(Self.describe(error))")
                model.revertRelationship(userID: userID, blocked: !isBlocked, ignored: nil)
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    func writeIgnore(_ isIgnored: Bool, userID: UserID) {
        Task { [weak self] in
            guard let self else { return }
            defer { model.relationshipsInFlight.remove(userID) }
            do {
                try await rest.setIgnored(isIgnored, userID: userID)
            } catch {
                Self.trace("ignore \(userID) failed: \(Self.describe(error))")
                model.revertRelationship(userID: userID, blocked: nil, ignored: !isIgnored)
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    func writeFriend(_ adds: Bool, userID: UserID, revertingTo previous: Relationship) {
        Task { [weak self] in
            guard let self else { return }
            defer { model.relationshipsInFlight.remove(userID) }
            do {
                try await rest.setFriend(adds, userID: userID)
            } catch {
                Self.trace("friend \(userID) failed: \(Self.describe(error))")
                // The whole previous state, not a delta: an accept that failed
                // has to leave an *incoming* request standing, and reversing it
                // by arithmetic gets that wrong.
                model.revertFriend(userID: userID, to: previous)
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    // MARK: Notes

    func writeNote(_ note: String, for userID: UserID) {
        guard model.notesInFlight.insert(userID).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { model.notesInFlight.remove(userID) }
            do {
                try await rest.setNote(note, for: userID)
            } catch {
                Self.trace("note \(userID) failed: \(Self.describe(error))")
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    // MARK: Invites

    /// Mints an invite and sends it, in the conversation with the person.
    ///
    /// **The DM is opened if it does not exist.** Inviting somebody the reader
    /// has never written to is the common case, and a client that silently does
    /// nothing there has offered a control that cannot work.
    func sendInvite(to userID: UserID, channelID: ChannelID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let link = try await rest.createInvite(in: channelID)
                let conversation = try await resolveDirectMessage(with: userID)
                _ = try await rest.sendMessage(
                    in: conversation, content: link, nonce: Self.nonce()
                )
            } catch {
                Self.trace("invite \(userID) failed: \(Self.describe(error))")
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    /// Opens the conversation with somebody, making it if there is not one yet,
    /// and takes the reader there.
    ///
    /// **The DM is created rather than the button being hidden**, which is a
    /// correction: the profile's Message control used to be drawn only where a
    /// conversation already existed, on the belief that opening one was a round
    /// trip this client did not make. It is `POST /users/@me/channels`, it is
    /// idempotent — called for somebody already written to it answers with the
    /// existing channel — and `sendInvite` has been using it all along.
    func openConversation(with userID: UserID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let channelID = try await resolveDirectMessage(with: userID)
                model.openDirectMessage(channelID)
            } catch {
                Self.trace("open DM \(userID) failed: \(Self.describe(error))")
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    private func resolveDirectMessage(with userID: UserID) async throws -> ChannelID {
        if let existing = model.directMessageChannel(with: userID) { return existing }
        let channel = try await rest.openDirectMessage(with: userID)
        model.channelIndex.upsert(channel)
        model.sidebarRevision &+= 1
        return channel.id
    }

    // MARK: Reporting

    func loadReportMenu(_ kind: ReportSubjectKind) {
        guard model.reportMenus[kind] == nil else { return }
        guard model.reportMenusLoading.insert(kind).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { model.reportMenusLoading.remove(kind) }
            do {
                model.reportMenus[kind] = try await rest.reportMenu(for: kind)
            } catch {
                Self.trace("report menu \(kind.rawValue) failed: \(Self.describe(error))")
                model.reportSubmission = .failed(Self.describe(error))
            }
        }
    }

    func submitReport(_ menu: ReportMenu, subject: ReportSubject, path: ReportPath) {
        // The tree's own language, so a category chosen in English is filed in
        // English. Discord localises the tree by this and by nothing else.
        let language = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.submitReport(
                    menu,
                    subject: subject,
                    breadcrumbs: path.nodeIDs,
                    elements: path.submissionElements(in: menu),
                    language: language
                )
                model.reportSubmission = .succeeded
            } catch {
                Self.trace("report failed: \(Self.describe(error))")
                model.reportSubmission = .failed(Self.describe(error))
            }
        }
    }

    // MARK: Shared

    /// A send nonce: the millisecond clock, which is what Discord's own clients
    /// use and what makes an echo matchable to the send that caused it.
    static func nonce() -> String {
        String(UInt64(Date.now.timeIntervalSince1970 * 1000))
    }
}

// MARK: - The wire side of a conversation

extension SessionController {

    /// Pins a direct message, or unpins it.
    ///
    /// **The reply replaces the set rather than confirming the bit.** The route
    /// answers with every override the private-channel pseudo-guild holds, and
    /// an override with nothing left on it is dropped — so applying the answer
    /// is both the confirmation and the correction, including for a pin some
    /// other client made while this one was asking.
    func writeDirectMessagePin(_ isPinned: Bool, channelID: ChannelID) {
        let previous = model.pinnedChannelIDs
        Task { [weak self] in
            guard let self else { return }
            defer { model.pinsInFlight.remove(channelID) }
            do {
                let pinned = try await rest.setDirectMessagePinned(
                    isPinned, channelID: channelID
                )
                model.applyPinnedChannels(pinned)
            } catch {
                Self.trace("pin \(channelID) failed: \(Self.describe(error))")
                model.applyPinnedChannels(previous)
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    func writeDirectMessageMute(_ duration: MuteDuration?, channelID: ChannelID) {
        let wasMuted = model.notificationPreferences.mutedChannelIDs.contains(channelID)
        Task { [weak self] in
            guard let self else { return }
            do {
                let muted = try await rest.setDirectMessageMuted(
                    duration, channelID: channelID
                )
                model.applyChannelMute(muted.contains(channelID), channelID: channelID)
            } catch {
                Self.trace("mute \(channelID) failed: \(Self.describe(error))")
                model.applyChannelMute(wasMuted, channelID: channelID)
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    /// Closes a conversation.
    ///
    /// **No optimistic removal to revert.** The row goes when `CHANNEL_DELETE`
    /// lands, which it does for the reader's own close as well as for a group
    /// they were removed from — taking the row out here as well would be two
    /// codepaths removing one row, and the second would have nothing to remove.
    func writeCloseDirectMessage(_ channelID: ChannelID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.closeDirectMessage(channelID)
            } catch {
                Self.trace("close \(channelID) failed: \(Self.describe(error))")
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    func writeFriendNickname(_ nickname: String?, for userID: UserID) {
        let previous = model.friendNicknames[userID]
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.setRelationshipNickname(nickname, for: userID)
            } catch {
                Self.trace("nickname \(userID) failed: \(Self.describe(error))")
                model.applyFriendNickname(previous, for: userID)
                model.reportActionFailure(Self.describe(error))
            }
        }
    }
}

extension SessionController {

    /// Bookmarks a message from the transcript's own menu, or takes it off.
    ///
    /// - Parameter dueAt: set to make it a reminder instead. **The same route
    ///   either way** — `due_at` is the only thing that separates a bookmark
    ///   from a reminder, so Create Reminder and Bookmark Message are one write
    ///   with one argument different.
    func writeBookmark(
        _ isSaved: Bool,
        messageID: MessageID,
        in channelID: ChannelID,
        dueAt: Date? = nil
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                if isSaved {
                    try await rest.saveMessage(messageID, in: channelID, dueAt: dueAt)
                } else {
                    try await rest.unsaveMessage(messageID, in: channelID)
                }
            } catch {
                Self.trace("bookmark \(messageID) failed: \(Self.describe(error))")
                model.revertBookmark(!isSaved, messageID: messageID)
                model.reportActionFailure(Self.describe(error))
            }
        }
    }
}

// MARK: - The wire side of a stage

extension SessionController {

    /// Raises the reader's hand, or lowers it.
    ///
    /// **`Date.now` is computed here, at the moment of sending.** Discord
    /// refuses a `request_to_speak_timestamp` in the past, so a value taken
    /// when the button was pressed and sent after an actor hop can lose the
    /// race with its own request — rarely, and therefore as an intermittent
    /// failure, which is the worst kind.
    func writeStageHand(_ isRaised: Bool, inGuild guildID: GuildID, channelID: ChannelID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.setSelfStageState(
                    inGuild: guildID,
                    channelID: channelID,
                    requestToSpeakAt: .some(isRaised ? Date.now : nil)
                )
            } catch {
                Self.trace("stage hand \(channelID): \(Self.describe(error))")
                model.applySelfStageRequest(isRaised ? nil : Date.now)
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    /// Moves somebody between speaker and audience.
    ///
    /// **Two routes behind one call**, and the difference is who: `@me` for
    /// the reader and `{user.id}` for anybody else. They take different bodies
    /// and hold different permissions — stepping down needs none, and every
    /// other combination needs `MUTE_MEMBERS` — so the split lives here rather
    /// than at each call site.
    func writeStageSuppress(
        _ suppress: Bool,
        userID: UserID?,
        inGuild guildID: GuildID,
        channelID: ChannelID
    ) {
        let subject = userID ?? model.currentUserID
        Task { [weak self] in
            guard let self else { return }
            do {
                if let userID {
                    try await rest.setStageSpeaker(
                        userID,
                        isSpeaker: !suppress,
                        inGuild: guildID,
                        channelID: channelID
                    )
                } else {
                    try await rest.setSelfStageState(
                        inGuild: guildID, channelID: channelID, suppress: suppress
                    )
                }
            } catch {
                Self.trace("stage suppress \(channelID): \(Self.describe(error))")
                if let subject { model.applyStageSuppress(!suppress, for: subject) }
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    func writeStartStage(
        channelID: ChannelID,
        guildID: GuildID,
        topic: String,
        notifyEveryone: Bool
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                if let stage = try await rest.startStage(
                    inChannel: channelID, topic: topic, notifyEveryone: notifyEveryone
                ) {
                    model.applyStage(stage)
                }
            } catch {
                Self.trace("start stage \(channelID): \(Self.describe(error))")
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    func writeStageTopic(_ topic: String, channelID: ChannelID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                if let stage = try await rest.setStageTopic(topic, inChannel: channelID) {
                    model.applyStage(stage)
                }
            } catch {
                Self.trace("stage topic \(channelID): \(Self.describe(error))")
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    func writeEndStage(channelID: ChannelID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.endStage(inChannel: channelID)
                model.applyStageEnded(channelID)
            } catch {
                Self.trace("end stage \(channelID): \(Self.describe(error))")
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    /// Asks whether a stage channel has anything running in it.
    ///
    /// **404 is the answer, not a failure** — see
    /// `DiscordREST.stageInstance`. Asked when a stage channel is opened,
    /// because READY carries only the stages that were already live and one
    /// started while this client was elsewhere reaches it no other way if the
    /// gateway event was missed across a resume.
    func loadStage(inChannel channelID: ChannelID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                if let stage = try await rest.stageInstance(inChannel: channelID) {
                    model.applyStage(stage)
                } else {
                    model.applyStageEnded(channelID)
                }
            } catch {
                Self.trace("stage \(channelID): \(Self.describe(error))")
            }
        }
    }
}
