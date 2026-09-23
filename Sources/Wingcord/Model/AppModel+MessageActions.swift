import AppKit
import Foundation
import WingcordCore
import WingcordNet

// MARK: - What a menu item does
//
// One entry point per act. Every one of them is gated here as well as where it
// is drawn: dimming a control is a statement, and a click is an action —
// `INVARIANTS.md` §5.5. A surface that offers Delete on somebody else's message
// and a store that performs it are two different bugs, and only the second one
// reaches Discord.

extension AppModel {

    // MARK: Resolving

    /// One message out of a loaded transcript, or out of a channel's pins.
    ///
    /// **Both, because a pinned message may not be in the transcript at all** —
    /// the pane lists messages from months back, and every action offered there
    /// has to resolve its subject.
    func message(_ messageID: MessageID, in channelID: ChannelID) -> Message? {
        if let found = messageBoxes[channelID]?.messages.first(where: { $0.id == messageID }) {
            return found
        }
        return pinnedMessages[channelID]?.first { $0.id == messageID }
    }

    /// What the reader may do to one message. Nil when the message is gone.
    func actions(for messageID: MessageID, in channelID: ChannelID) -> MessageActions {
        guard let message = message(messageID, in: channelID) else { return [] }
        return permissionGate.actions(for: message)
    }

    // MARK: Reacting

    /// Adds or takes back the reader's own reaction of `kind`, whichever the
    /// chip is not.
    ///
    /// **Applied optimistically and then sent**, for the reason a vote is: the
    /// chip is the only feedback the click has, and a count that moves one round
    /// trip later reads as the click having missed. A refusal puts it back.
    ///
    /// The gate is asked for the right bit: joining a reaction that is already
    /// on the message needs nothing but being able to see the channel, where
    /// starting a new one needs `ADD_REACTIONS`. Collapsing the two would grey
    /// out every chip in exactly the channels where the existing chips are the
    /// only ones anybody may use.
    ///
    /// A super reaction adds three rules, all Discord's:
    ///
    ///  - **It is Nitro's**, to add and to take back. Discord answers either
    ///    without it with an upsell; this client sells nothing, so it answers
    ///    with nothing, and the chip does not offer itself as a control.
    ///  - **One emoji is one kind per person.** Somebody who reacted plainly
    ///    with an emoji cannot super react with it, or the other way round —
    ///    Discord explains that before sending anything, in the words below.
    ///  - **Its colours come first.** The optimistic write carries the palette
    ///    Discord derives from the emoji's own picture, and the reducer keeps it
    ///    over the server's — so the send waits for the picture, which the chip
    ///    has almost always already drawn.
    func toggleReaction(
        _ emoji: EmojiRef,
        kind: ReactionKind = .normal,
        location: ReactionLocation,
        on messageID: MessageID,
        in channelID: ChannelID
    ) {
        guard let message = message(messageID, in: channelID) else { return }
        let existing = message.reactions.first { $0.emoji.isSameReaction(as: emoji) }
        let permitted = permissionGate.actions(for: message)
        let needed: MessageActions = existing == nil ? .addReaction : .joinReaction
        guard permitted.contains(needed), kind == .normal || hasNitro else { return }

        let adding = !(existing?.isMine(kind) ?? false)
        if adding, existing?.isMine(kind == .burst ? .normal : .burst) == true {
            reportActionFailure(
                "You can’t react and super react with the same emoji. There’s a lot of "
                    + "emoji to choose from, so maybe try another one."
            )
            return
        }

        let pending = PendingReaction(messageID: messageID, emoji: emoji.reactionKey, kind: kind)
        guard reactionsInFlight.insert(pending).inserted else { return }

        guard kind == .burst, adding else {
            applyReaction(emoji, kind: kind, to: messageID, in: channelID, added: adding, isMine: true)
            sessionController.writeReaction(
                emoji, kind: kind, location: location,
                on: messageID, in: channelID, adding: adding, pending: pending
            )
            return
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        Task { [weak self] in
            let colors = await SuperReactionArt.palette(for: emoji, scale: scale)
            guard let self else { return }
            applyReaction(
                emoji, kind: .burst, to: messageID, in: channelID,
                added: true, isMine: true, colors: colors
            )
            sessionController.writeReaction(
                emoji, kind: .burst, location: location,
                on: messageID, in: channelID, adding: true, pending: pending
            )
        }
    }

    /// Opens the picker beside a message.
    func openReactionPicker(for messageID: MessageID, in channelID: ChannelID, anchor: CGRect) {
        guard actions(for: messageID, in: channelID).contains(.addReaction) else { return }
        dismissMessageSurfaces()
        reactionPicker = ReactionPickerRequest(
            messageID: messageID, channelID: channelID, anchor: anchor
        )
    }

    // MARK: Replying

    /// Points the composer at a message.
    ///
    /// An edit and a reply are mutually exclusive — the composer holds one text
    /// and one banner — so starting either cancels the other rather than
    /// stacking two banners the reader has to read to know what Enter will do.
    func beginReply(to messageID: MessageID, in channelID: ChannelID) {
        guard actions(for: messageID, in: channelID).contains(.reply) else { return }
        mutateBox(channelID) {
            $0.replyingTo = messageID
            $0.editing = nil
        }
    }

    func cancelReply(in channelID: ChannelID) {
        guard messageBoxes[channelID]?.replyingTo != nil else { return }
        mutateBox(channelID) { $0.replyingTo = nil }
    }

    // MARK: Editing

    func beginEdit(of messageID: MessageID, in channelID: ChannelID) {
        guard let message = message(messageID, in: channelID),
              permissionGate.actions(for: message).contains(.edit)
        else { return }
        mutateBox(channelID) {
            $0.editing = MessageEdit(
                messageID: messageID, text: message.content, original: message.content
            )
            $0.replyingTo = nil
        }
    }

    func cancelEdit(in channelID: ChannelID) {
        guard messageBoxes[channelID]?.editing != nil else { return }
        mutateBox(channelID) { $0.editing = nil }
    }

    /// Commits the edit the composer is holding.
    ///
    /// An empty body is not an edit — Discord refuses it, and the reader almost
    /// certainly meant Delete. Unchanged text is not an edit either: sending it
    /// would stamp "(edited)" on a message nobody changed.
    func commitEdit(in channelID: ChannelID) {
        guard let edit = messageBoxes[channelID]?.editing else { return }
        mutateBox(channelID) { $0.editing = nil }
        let trimmed = edit.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, edit.hasChanges else { return }
        guard actions(for: edit.messageID, in: channelID).contains(.edit) else { return }
        sessionController.edit(edit.messageID, in: channelID, content: trimmed)
    }

    // MARK: Deleting

    /// Raises the confirmation. Nothing is deleted from here.
    ///
    /// **Always confirmed, including for the reader's own message.** There is no
    /// undo on this route, the target is a row under a pointer that may have
    /// moved, and Discord confirms it too.
    func requestDelete(of messageID: MessageID, in channelID: ChannelID) {
        guard let message = message(messageID, in: channelID),
              permissionGate.actions(for: message).contains(.delete)
        else { return }
        dismissMessageSurfaces()
        deleteRequest = DeleteMessageRequest(
            messageID: messageID,
            channelID: channelID,
            authorName: users[message.authorID]?.preferredName ?? "Unknown",
            excerpt: Self.excerpt(of: message),
            isOwn: message.authorID == currentUserID
        )
    }

    func confirmDelete() {
        guard let request = deleteRequest else { return }
        deleteRequest = nil
        guard actions(for: request.messageID, in: request.channelID).contains(.delete) else {
            return
        }
        sessionController.delete(request.messageID, in: request.channelID)
    }

    // MARK: Pinning

    func togglePin(of messageID: MessageID, in channelID: ChannelID) {
        let permitted = actions(for: messageID, in: channelID)
        if permitted.contains(.unpin) {
            sessionController.setPinned(false, messageID: messageID, in: channelID)
        } else if permitted.contains(.pin) {
            sessionController.setPinned(true, messageID: messageID, in: channelID)
        }
    }

    /// Writes a pin's new state into everything that shows it.
    ///
    /// **The transcript and the pane, in one place.** A message carries its own
    /// `isPinned`, so the pane cannot be the only record — a menu opened on the
    /// transcript reads the message, and a pin recorded only in the pane would
    /// leave that menu offering Pin on a message that is already pinned.
    func applyPin(_ isPinned: Bool, messageID: MessageID, in channelID: ChannelID) {
        mutateBox(channelID) { box in
            guard let index = box.messages.firstIndex(where: { $0.id == messageID }) else {
                return
            }
            box.messages[index].isPinned = isPinned
        }
        if var pinned = pinnedMessages[channelID] {
            if isPinned {
                if !pinned.contains(where: { $0.id == messageID }),
                   var message = message(messageID, in: channelID)
                {
                    message.isPinned = true
                    // Newest first, which is the order the route answers in.
                    pinned.insert(message, at: 0)
                }
            } else {
                pinned.removeAll { $0.id == messageID }
            }
            pinnedMessages[channelID] = pinned
        }
        messageContentRevision &+= 1
    }

    /// Opens the pins pane for the channel being read.
    func togglePinsPane(for channelID: ChannelID) {
        if openPinsChannelID == channelID {
            openPinsChannelID = nil
            return
        }
        openPinsChannelID = channelID
        sessionController.loadPins(in: channelID)
    }

    // MARK: Read state

    /// Leaves everything from `messageID` onward unread.
    ///
    /// The route acknowledges the message *before* the one chosen, which is what
    /// makes the chosen one the first unread. The reader is also sent out of the
    /// channel's ack path for as long as they stay in it — see
    /// `SessionController.markUnread`.
    func markUnread(from messageID: MessageID, in channelID: ChannelID) {
        guard actions(for: messageID, in: channelID).contains(.markUnread) else { return }
        let previous = messageBoxes[channelID]?.messages
            .last { $0.id.rawValue < messageID.rawValue }?
            .id
        sessionController.markUnread(after: previous, in: channelID)
    }

    // MARK: Forwarding

    func requestForward(of messageID: MessageID, in channelID: ChannelID) {
        guard actions(for: messageID, in: channelID).contains(.forward) else { return }
        dismissMessageSurfaces()
        forwardRequest = ForwardRequest(messageID: messageID, channelID: channelID)
    }

    /// Sends the message on to every channel that was ticked.
    ///
    /// Each target is gated on its own: a list built when the sheet opened is a
    /// list that can be a minute old, and a role change in between is exactly
    /// the case §5.5 is about.
    func forward(to targets: [ChannelID], comment: String) {
        guard let request = forwardRequest else { return }
        forwardRequest = nil
        let permitted = targets.filter { permissionGate.canSend(in: $0) }
        guard !permitted.isEmpty else { return }
        sessionController.forward(
            request.messageID, from: request.channelID, to: permitted, comment: comment
        )
    }

    // MARK: The pasteboard

    func copyText(of messageID: MessageID, in channelID: ChannelID) {
        guard let message = message(messageID, in: channelID),
              permissionGate.actions(for: message).contains(.copyText)
        else { return }
        Self.copy(message.content)
    }

    func copyLink(to messageID: MessageID, in channelID: ChannelID) {
        guard actions(for: messageID, in: channelID).contains(.copyLink) else { return }
        let guild = channelIndex.guildID(of: channelID).map(\.rawValue.description) ?? "@me"
        Self.copy(
            "https://discord.com/channels/\(guild)/\(channelID.rawValue)/\(messageID.rawValue)"
        )
    }

    func copyID(of messageID: MessageID, in channelID: ChannelID) {
        guard actions(for: messageID, in: channelID).contains(.copyID) else { return }
        Self.copy(messageID.description)
    }

    /// One writer for the whole app.
    ///
    /// `clearContents()` first is not optional: `setString` appends to whatever
    /// types the pasteboard already holds, so pasting into an app that prefers
    /// RTF would hand it the *previous* copy's rich text beside this one's
    /// plain string.
    static func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    // MARK: Menus

    func openMessageMenu(for messageID: MessageID, in channelID: ChannelID, anchor: CGRect) {
        guard !actions(for: messageID, in: channelID).isEmpty else { return }
        dismissMessageSurfaces()
        messageMenu = MessageMenuRequest(
            messageID: messageID, channelID: channelID, anchor: anchor
        )
    }

    /// Closes every surface a message can raise.
    ///
    /// One call rather than four assignments at each site: opening the picker
    /// from the menu has to take the menu down, and a site that forgets one
    /// leaves two glass panels stacked over the same row.
    func dismissMessageSurfaces() {
        if messageMenu != nil { messageMenu = nil }
        if reactionPicker != nil { reactionPicker = nil }
        if userMenu != nil { userMenu = nil }
    }

    // MARK: Reporting

    func requestReport(of messageID: MessageID, in channelID: ChannelID) {
        guard let message = message(messageID, in: channelID),
              permissionGate.actions(for: message).contains(.report)
        else { return }
        dismissMessageSurfaces()
        let author = users[message.authorID]
        reportRequest = ReportRequest(
            subject: .message(messageID, channelID: channelID),
            preview: .quoted(QuotedMessage(
                authorName: author?.preferredName ?? "Unknown",
                avatarURL: avatarURL(
                    forUserID: message.authorID,
                    inGuild: channelIndex.guildID(of: channelID),
                    side: Metrics.avatarInline * 2
                ),
                monogram: author?.monogram ?? "?",
                timestamp: PresentationRevision.shared.timeline.time(message.sentAt),
                excerpt: Self.excerpt(of: message)
            ))
        )
        sessionController.loadReportMenu(.message)
    }

    func requestReport(of userID: UserID, inGuild guildID: GuildID?) {
        guard userID != currentUserID, let user = users[userID] else { return }
        dismissMessageSurfaces()
        reportRequest = ReportRequest(
            subject: .user(userID, guildID: guildID),
            preview: .quoted(QuotedMessage(
                authorName: user.preferredName,
                avatarURL: avatarURL(
                    forUserID: userID, inGuild: guildID, side: Metrics.avatarInline * 2
                ),
                monogram: user.monogram,
                timestamp: nil,
                excerpt: user.handle
            ))
        )
        sessionController.loadReportMenu(.user)
    }

    /// Reports one tile on somebody's board.
    ///
    /// **Both ids travel.** The widget's id says which tile and the person's
    /// says whose board it is on; Discord's route requires the pair, and a
    /// report carrying only the first would be unattributable.
    ///
    /// The tile is looked up rather than passed in: the menu that raises this
    /// lives inside the board, and handing a whole resolved tile through a
    /// closure would capture a value that goes stale the moment the games land.
    func reportWidget(_ widgetID: String, of userID: UserID) {
        guard userID != currentUserID,
              let tile = boardPresentation(for: userID)?.tiles.first(where: { $0.id == widgetID })
        else { return }
        dismissMessageSurfaces()
        reportRequest = ReportRequest(
            subject: .widget(id: widgetID, userID: userID),
            preview: .widget(tile)
        )
        sessionController.loadReportMenu(.widget)
    }

    func submitReport(path: ReportPath) {
        guard let request = reportRequest,
              let menu = reportMenus[request.subject.kind]
        else { return }
        reportSubmission = .sending
        sessionController.submitReport(menu, subject: request.subject, path: path)
    }

    func dismissReport() {
        reportRequest = nil
        reportSubmission = nil
    }

    // MARK: Failures

    /// Says that an act did not land.
    ///
    /// A refused pin, delete or block is a click that visibly did something and
    /// then visibly undid it, which reads as the app being broken rather than as
    /// the server saying no. The notice says which.
    func reportActionFailure(_ reason: String) {
        actionFailureToken &+= 1
        actionFailure = ActionFailure(reason: reason, id: actionFailureToken)
    }

    // MARK: Pins, from the fetch

    /// Marks a loaded transcript's copies of these messages pinned.
    ///
    /// The pins route is the only place the client learns the pin state of a
    /// message it fetched over history, because history's own `pinned` is
    /// authoritative only at the moment it was fetched.
    func markPinnedInTranscript(_ ids: [MessageID], in channelID: ChannelID) {
        guard !ids.isEmpty, messageBoxes[channelID]?.messages.isEmpty == false else { return }
        let pinned = Set(ids)
        var changed = false
        mutateBox(channelID) { box in
            for index in box.messages.indices where pinned.contains(box.messages[index].id) {
                guard !box.messages[index].isPinned else { continue }
                box.messages[index].isPinned = true
                changed = true
            }
        }
        if changed { messageContentRevision &+= 1 }
    }

    // MARK: Shared

    /// One line of a message, for a confirmation or a quote.
    ///
    /// A message with no words still has to be describable — a picture, a
    /// sticker, an embed — or the confirmation asks about a blank line.
    static func excerpt(of message: Message) -> String {
        if !message.content.isEmpty {
            return String(message.content.prefix(140))
        }
        if !message.attachments.isEmpty {
            return message.attachments.count == 1
                ? message.attachments[0].filename
                : "\(message.attachments.count) attachments"
        }
        if !message.stickers.isEmpty { return message.stickers[0].name }
        if let forwarded = message.forwarded, !forwarded.content.isEmpty {
            return String(forwarded.content.prefix(140))
        }
        if !message.embeds.isEmpty { return "Embed" }
        if message.poll != nil { return "Poll" }
        return "Message"
    }
}

extension AppModel {

    /// Saves a message for later, or takes the bookmark off.
    ///
    /// **The groundwork for an inbox, and it does nothing visible yet.**
    /// Discord lists saved messages in an inbox this client does not have; what
    /// exists here is the write, so the surface that lists them later has
    /// something to list. See `DiscordREST.setMessageSaved`.
    func toggleBookmark(of messageID: MessageID, in channelID: ChannelID) {
        let actions = actions(for: messageID, in: channelID)
        guard !actions.isDisjoint(with: [.bookmark, .unbookmark]) else { return }
        let isSaved = !bookmarkedMessageIDs.contains(messageID)
        if isSaved {
            bookmarkedMessageIDs.insert(messageID)
        } else {
            bookmarkedMessageIDs.remove(messageID)
        }
        messageContentRevision &+= 1
        dismissMessageSurfaces()
        sessionController.writeBookmark(isSaved, messageID: messageID, in: channelID)
    }

    /// Rolls a bookmark back after the route refused it.
    func revertBookmark(_ wasSaved: Bool, messageID: MessageID) {
        if wasSaved {
            bookmarkedMessageIDs.insert(messageID)
        } else {
            bookmarkedMessageIDs.remove(messageID)
        }
        messageContentRevision &+= 1
    }
}
