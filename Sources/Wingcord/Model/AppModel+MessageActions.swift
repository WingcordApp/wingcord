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
    ///
    /// **A send Discord has not taken is not a message yet**, and nothing a
    /// server keeps can be done to it: one still going gets no pill and no
    /// menu, and one refused gets the three things that mean anything — send
    /// it again, take its words, or drop it.
    func actions(for messageID: MessageID, in channelID: ChannelID) -> MessageActions {
        if let message = message(messageID, in: channelID) {
            return permissionGate.actions(for: message)
        }
        guard let entry = outgoing(messageID, in: channelID), entry.state == .failed else { return [] }
        return [.resend, .copyText, .delete]
    }

    /// One of the reader's own sends that Discord has not taken, by its echo's
    /// id.
    func outgoing(_ messageID: MessageID, in channelID: ChannelID) -> OutgoingMessage? {
        messageBoxes[channelID]?.outbox.first { $0.id == messageID }
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
        // ⇧ held as Reply is pressed starts it quiet, as in Discord.
        let quiet = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        let pings = !quiet && message(messageID, in: channelID)?.authorID != currentUserID
        mutateBox(channelID) {
            $0.replyingTo = messageID
            $0.replyPings = pings
            $0.editing = nil
        }
    }

    func cancelReply(in channelID: ChannelID) {
        guard messageBoxes[channelID]?.replyingTo != nil else { return }
        mutateBox(channelID) { $0.replyingTo = nil }
    }

    /// The reply bar's @ ON / OFF.
    func toggleReplyPing(in channelID: ChannelID) {
        guard messageBoxes[channelID]?.replyingTo != nil else { return }
        mutateBox(channelID) { $0.replyPings.toggle() }
    }

    /// The reply bar's label: the message being answered, with the same jump a
    /// quote's header takes.
    func jumpToReply(in channelID: ChannelID) {
        guard let target = messageBoxes[channelID]?.replyingTo else { return }
        sessionController.jumpToMessage(target, in: channelID)
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
    func commitEdit(in channelID: ChannelID, checksEmbeds: Bool = true) {
        guard let edit = messageBoxes[channelID]?.editing else { return }
        let trimmed = edit.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let rewrite = applyingFakeNitro(trimmed, stickerIDs: [], in: channelID)
        // The plugin asks on an edit too — with the edit still open behind it.
        if checksEmbeds, !trimmed.isEmpty, edit.hasChanges,
           needsFakeNitroEmbedPrompt(bypassed: rewrite.bypassed, in: channelID)
        {
            fakeNitroEmbedPrompt = FakeNitroEmbedPrompt { [weak self] in
                self?.commitEdit(in: channelID, checksEmbeds: false)
            }
            return
        }
        mutateBox(channelID) { $0.editing = nil }
        guard !trimmed.isEmpty, edit.hasChanges else { return }
        guard actions(for: edit.messageID, in: channelID).contains(.edit) else { return }
        sessionController.edit(edit.messageID, in: channelID, content: rewrite.content)
    }

    // MARK: Deleting

    /// Raises the confirmation. Nothing is deleted from here.
    ///
    /// **Always confirmed, including for the reader's own message.** There is no
    /// undo on this route, the target is a row under a pointer that may have
    /// moved, and Discord confirms it too.
    func requestDelete(of messageID: MessageID, in channelID: ChannelID) {
        // A refused send exists nowhere but here, so taking it away asks
        // nobody — Discord deletes its failed messages locally, with no prompt.
        if outgoing(messageID, in: channelID)?.state == .failed {
            dismissMessageSurfaces()
            mutateBox(channelID) { $0.outbox.removeAll { $0.id == messageID } }
            return
        }
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

    /// Sends the profile the Share Profile sheet is showing — Discord's
    /// handler: the link, and under it, after a blank line, whatever the reader
    /// wrote.
    func shareProfile(to targets: [ChannelID], comment: String) {
        guard let request = shareProfileRequest else { return }
        shareProfileRequest = nil
        let permitted = targets.filter { permissionGate.canSend(in: $0) }
        guard !permitted.isEmpty else { return }
        let words = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        sessionController.send(words.isEmpty ? request.link : "\(request.link)\n\n\(words)", to: permitted)
    }

    // MARK: The pasteboard

    func copyText(of messageID: MessageID, in channelID: ChannelID) {
        if let entry = outgoing(messageID, in: channelID) {
            Self.copy(entry.request.content)
            return
        }
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

    func openMessageMenu(
        for messageID: MessageID,
        in channelID: ChannelID,
        anchor: CGRect,
        selectedText: String? = nil
    ) {
        guard !actions(for: messageID, in: channelID).isEmpty else { return }
        dismissMessageSurfaces()
        messageMenu = MessageMenuRequest(
            messageID: messageID,
            channelID: channelID,
            anchor: anchor,
            selectedText: selectedText?.isEmpty == false ? selectedText : nil
        )
    }

    /// The selected words in a Google search, in the browser — Discord's.
    func searchWithGoogle(_ text: String) {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: text)]
        guard let url = components?.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// Closes every surface a message can raise.
    ///
    /// One call rather than four assignments at each site: opening the picker
    /// from the menu has to take the menu down, and a site that forgets one
    /// leaves two glass panels stacked over the same row.
    // MARK: Who reacted

    /// Opens the list of who reacted, on `selection` or on the largest entry.
    ///
    /// **Not one of the surfaces `dismissMessageSurfaces` takes down.** A
    /// right-click on somebody in the list raises the person menu, which
    /// clears those — and the list has to still be there under it.
    func openReactionsList(
        for messageID: MessageID,
        in channelID: ChannelID,
        selection: ReactionListing.Key? = nil
    ) {
        guard actions(for: messageID, in: channelID).contains(.viewReactions) else { return }
        dismissMessageSurfaces()
        reactionHover = nil
        reactionsList = ReactionsListRequest(
            messageID: messageID, channelID: channelID, selection: selection
        )
    }

    /// Whether the reader may take `userID`'s reaction off this message: their
    /// own always, anybody's with `removeReactions`.
    func canRemoveReaction(of userID: UserID, on messageID: MessageID, in channelID: ChannelID) -> Bool {
        userID == currentUserID || actions(for: messageID, in: channelID).contains(.removeReactions)
    }

    /// Takes one person's reaction off, from the list. Answers whether it went.
    ///
    /// The reader's own goes the way a click on the chip takes it back —
    /// optimistically, through the same guard. Anybody else's is a request
    /// whose effect arrives on the gateway like any other removal, so the
    /// count is not touched here and cannot be moved twice.
    func removeReaction(
        of userID: UserID,
        _ entry: ReactionListing,
        on messageID: MessageID,
        in channelID: ChannelID
    ) async -> Bool {
        guard canRemoveReaction(of: userID, on: messageID, in: channelID) else { return false }
        if userID == currentUserID {
            toggleReaction(entry.emoji, kind: entry.kind, location: .message, on: messageID, in: channelID)
            return true
        }
        let removed = await sessionController.removeReaction(
            of: userID, emoji: entry.emoji, kind: entry.kind, on: messageID, in: channelID
        )
        if !removed { reportActionFailure("That reaction couldn’t be removed.") }
        return removed
    }

    // MARK: Select menus

    func openSelectMenu(_ customID: String, on messageID: MessageID, in channelID: ChannelID, anchor: CGRect) {
        guard let menu = message(messageID, in: channelID)?.selectMenu(customID: customID)?.select else { return }
        dismissMessageSurfaces()
        selectMenu = SelectMenuRequest(
            messageID: messageID, channelID: channelID, customID: customID,
            anchor: anchor, selection: menu.defaultValues
        )
    }

    /// The menu an open list is of, as the message has it now.
    func selectMenuComponent(for request: SelectMenuRequest) -> MessageComponent? {
        message(request.messageID, in: request.channelID)?.selectMenu(customID: request.customID)
    }

    /// One option chosen or unchosen. **A menu that takes one sends it now and
    /// closes**, as Discord's does; one that takes several collects them until
    /// the list closes, and never past its maximum.
    func toggleSelectOption(_ value: String) {
        guard var request = selectMenu, let menu = selectMenuComponent(for: request)?.select else { return }
        if menu.isSingle {
            selectMenu = nil
            submitSelect([value], request: request)
            return
        }
        if request.selection.contains(value) {
            request.selection.remove(value)
        } else if request.selection.count < menu.maxValues {
            request.selection.insert(value)
        }
        selectMenu = request
    }

    /// The list closed. A menu that takes several sends what was chosen —
    /// Discord sends on close — when it changed and the application will take
    /// it. In the menu's own order, which is the order the application wrote.
    func closeSelectMenu() {
        guard let request = selectMenu else { return }
        selectMenu = nil
        guard let menu = selectMenuComponent(for: request)?.select, !menu.isSingle,
              request.selection != menu.defaultValues, menu.accepts(request.selection)
        else { return }
        submitSelect(menu.options.map(\.value).filter(request.selection.contains), request: request)
    }

    private func submitSelect(_ values: [String], request: SelectMenuRequest) {
        guard let message = message(request.messageID, in: request.channelID),
              let component = message.selectMenu(customID: request.customID)
        else { return }
        Task { await sessionController.chooseInSelect(values, of: component, on: message) }
    }

    func dismissMessageSurfaces() {
        if selectMenu != nil { closeSelectMenu() }
        if messageMenu != nil { messageMenu = nil }
        if reactionPicker != nil { reactionPicker = nil }
        if userMenu != nil { userMenu = nil }
    }

    // MARK: Reporting

    /// - Parameter isFirstDirectMessage: Discord's Report Spam at a DM's head,
    ///   which files the conversation's first message under its own menu.
    func requestReport(of messageID: MessageID, in channelID: ChannelID, isFirstDirectMessage: Bool = false) {
        guard let message = message(messageID, in: channelID),
              permissionGate.actions(for: message).contains(.report)
        else { return }
        dismissMessageSurfaces()
        let author = users[message.authorID]
        reportRequest = ReportRequest(
            subject: isFirstDirectMessage
                ? .firstDirectMessage(messageID, channelID: channelID)
                : .message(messageID, channelID: channelID),
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
        sessionController.loadReportMenu(isFirstDirectMessage ? .firstDirectMessage : .message)
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
        report(reason, as: .failure)
    }

    /// Says where a scheduled message stands — the confirmations Discord gives
    /// with a clock, since what was done happened in a list nobody is looking at.
    func reportScheduling(_ text: String) {
        report(text, as: .scheduling)
    }

    /// Says that an act landed, where Discord says so — see `ActionNotice.Kind.success`.
    func reportSuccess(_ text: String) {
        report(text, as: .success)
    }

    private func report(_ text: String, as kind: ActionNotice.Kind) {
        actionNoticeToken &+= 1
        actionNotice = ActionNotice(text: text, kind: kind, id: actionNoticeToken)
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
