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
        kind: ReactionKind,
        location: ReactionLocation,
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
                    try await rest.addReaction(
                        emoji, kind: kind, location: location, to: messageID, in: channelID
                    )
                } else {
                    try await rest.removeReaction(
                        emoji, kind: kind, location: location, from: messageID, in: channelID
                    )
                }
            } catch {
                Self.trace("reaction \(messageID) \(kind) failed: \(Self.describe(error))")
                // The exact inverse of the optimistic write. The gateway echoes
                // the reader's own reaction back as well, and the store's
                // reducer is idempotent on the reader's own, so a revert that
                // crosses an echo settles on the same count either way.
                model.applyReaction(
                    emoji, kind: kind, to: messageID, in: channelID,
                    added: !adding, isMine: true
                )
                // **Said, not only undone.** A chip that quietly changes back
                // reads as a click that missed; Discord's own words — too many
                // reactions on the message, or a super reaction the account
                // cannot send — say what actually happened.
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    /// People who reacted with `emoji` of `kind` — the first three for a chip's
    /// tooltip, a hundred at a time after `after` for the reactors list —
    /// harvested into the store so their names resolve: a reactor is very
    /// often somebody in no roster the reader has loaded. Nil when the route
    /// refuses.
    func reactors(
        of emoji: EmojiRef,
        kind: ReactionKind,
        on messageID: MessageID,
        in channelID: ChannelID,
        limit: Int = 3,
        after: UserID? = nil
    ) async -> [UserID]? {
        do {
            let users = try await rest.reactors(
                of: emoji, kind: kind, on: messageID, in: channelID, limit: limit, after: after
            )
            // One write for the batch, as a page of history is harvested.
            model.users.merge(users.map { ($0.id, $0) }) { existing, new in new.merged(over: existing) }
            return users.map(\.id)
        } catch {
            Self.trace("reactors \(messageID) failed: \(Self.describe(error))")
            return nil
        }
    }

    /// Takes somebody else's reaction off — a moderator's act, from the
    /// reactors list. Answers whether the server took it; the count moves
    /// when the gateway says so, as it does for anybody else's removal.
    func removeReaction(
        of userID: UserID,
        emoji: EmojiRef,
        kind: ReactionKind,
        on messageID: MessageID,
        in channelID: ChannelID
    ) async -> Bool {
        do {
            try await rest.removeReaction(
                emoji, kind: kind, location: .message, from: messageID, in: channelID, of: userID
            )
            return true
        } catch {
            Self.trace("remove reaction of \(userID) on \(messageID) failed: \(Self.describe(error))")
            return false
        }
    }

    // MARK: Editing and deleting

    func edit(_ messageID: MessageID, in channelID: ChannelID, content: String) {
        // **A quiet reply stays quiet.** Discord's edit re-sends the no-ping
        // mentions for a reply whose quoted author is in hand and was not
        // pinged by it; without them, saving a typo pings them after all.
        let keepsReplyQuiet = model.message(messageID, in: channelID).map { message in
            guard message.kind == .reply, let quoted = message.reference?.authorID else { return false }
            return !message.mentionedUserIDs.contains(quoted)
        } ?? false
        Task { [weak self] in
            guard let self else { return }
            do {
                let message = try await rest.editMessage(
                    messageID, in: channelID, content: content, keepsReplyQuiet: keepsReplyQuiet
                )
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
    ///
    /// A message that is not loaded is deleted all the same: a post's opening
    /// message can go from its card on the board — Delete Message — where its
    /// transcript was never opened.
    func delete(_ messageID: MessageID, in channelID: ChannelID) {
        let previous = model.message(messageID, in: channelID)
        if previous != nil {
            model.mutateBox(channelID) { $0.remove(messageID) }
            model.messageContentRevision &+= 1
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.deleteMessage(messageID, in: channelID)
            } catch {
                Self.trace("delete \(messageID) failed: \(Self.describe(error))")
                if let previous {
                    model.mutateBox(channelID) { $0.upsert(previous) }
                    model.messageContentRevision &+= 1
                }
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
                    receiveOwn(message, in: target)
                } catch {
                    Self.trace("forward to \(target) failed: \(Self.describe(error))")
                    model.reportActionFailure(Self.describe(error))
                }
            }
        }
    }

    /// Sends one message to several conversations — a shared profile.
    ///
    /// Sequential, for `forward`'s reason: one rate-limit family, and a failure
    /// that names its own target.
    func send(_ content: String, to targets: [ChannelID]) {
        model.forwardsInFlight.formUnion(targets)
        let nonce = Self.nonce()
        Task { [weak self] in
            guard let self else { return }
            for (index, target) in targets.enumerated() {
                defer { model.forwardsInFlight.remove(target) }
                do {
                    let message = try await rest.sendMessage(
                        in: target, content: content, nonce: nonce + String(index)
                    )
                    // Only into a transcript that is actually loaded — see
                    // `forward`.
                    guard model.messages(in: target)?.messages.isEmpty == false else { continue }
                    receiveOwn(message, in: target)
                } catch {
                    Self.trace("share to \(target) failed: \(Self.describe(error))")
                    model.reportActionFailure(Self.describe(error))
                }
            }
        }
    }

    /// Shares a custom theme into conversations — Discord's share modal's
    /// send, `shared_client_theme`, with whatever the reader wrote as the
    /// message's words. Lands as the theme's card.
    ///
    /// Sequential, for `forward`'s reason.
    func shareTheme(_ theme: SharedClientTheme, to targets: [ChannelID], comment: String) {
        model.forwardsInFlight.formUnion(targets)
        let nonce = Self.nonce()
        Task { [weak self] in
            guard let self else { return }
            for (index, target) in targets.enumerated() {
                defer { model.forwardsInFlight.remove(target) }
                do {
                    let message = try await rest.sendMessage(
                        in: target, content: comment, nonce: nonce + String(index), sharedTheme: theme
                    )
                    guard model.messages(in: target)?.messages.isEmpty == false else { continue }
                    receiveOwn(message, in: target)
                } catch {
                    Self.trace("theme share to \(target) failed: \(Self.describe(error))")
                    model.reportActionFailure(Self.describe(error))
                }
            }
        }
    }

    /// The account's own custom themes, once a session — Saved Themes lists
    /// them beside the ones kept on this Mac. Discord's client has no route to
    /// change the list, so nothing here writes back.
    ///
    /// **Left absent on a failure**, so the next visit to Appearance asks again.
    func loadAccountCustomThemes() {
        guard model.connectionState == .ready, model.accountCustomThemes == nil,
              !accountCustomThemesFetchInFlight
        else { return }
        accountCustomThemesFetchInFlight = true
        Task { [weak self] in
            guard let self else { return }
            defer { accountCustomThemesFetchInFlight = false }
            do {
                model.accountCustomThemes = try await rest.customThemes()
            } catch {
                Self.trace("custom themes failed: \(Self.describe(error))")
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

    /// Discord's Add Friend: a request to whoever answers to `tag`, and the
    /// sentence the sheet shows either way — Discord's own, from its
    /// `sendRequest` and the error mapping beside it.
    func sendFriendRequest(to tag: String, note: String = "") async -> Result<String, FriendRequestFailure> {
        var tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        // "@name" is how a username is written everywhere else in the app.
        if !tag.contains("#"), tag.hasPrefix("@") { tag.removeFirst() }
        guard !tag.isEmpty else { return .failure(FriendRequestFailure(message: Self.friendRequestDefault)) }
        // Refused here rather than by the server, in the server's words.
        guard note.count <= FriendRequestNote.maximumLength else {
            return .failure(FriendRequestFailure(message: Self.friendRequestNoteRefused))
        }
        let parts = tag.split(separator: "#", maxSplits: 1).map(String.init)
        do {
            try await rest.sendFriendRequest(
                username: parts[0],
                discriminator: parts.count > 1 ? Int(parts[1]) : nil,
                note: FriendRequestNote.cleaned(note)
            )
            return .success("Success! Your friend request to \(tag) was sent.")
        } catch DiscordREST.Failure.api(_, let code, let message) {
            Self.trace("friend request to \(tag) failed: \(code.map(String.init) ?? "-") \(message ?? "")")
            let text: String = switch code {
            case 80000: "\(tag) isn't accepting friend requests right now."
            case 80002: "Bots can't be added as friends."
            case 80003: "That's you! You can't send yourself a friend request."
            case 80007: "You're already friends with that user!"
            case 30002: "You've reached the most friends Discord allows."
            // Discord tests `body.note`; here a form error can only be about the
            // one free-text field the body has, when a note was sent at all.
            case 50035 where !note.isEmpty: Self.friendRequestNoteRefused
            default: Self.friendRequestDefault
            }
            return .failure(FriendRequestFailure(message: text))
        } catch {
            Self.trace("friend request to \(tag) failed: \(Self.describe(error))")
            return .failure(FriendRequestFailure(message: Self.describe(error)))
        }
    }

    private static let friendRequestDefault =
        "Hm, didn't work. Double check that the username is correct."

    private static let friendRequestNoteRefused =
        "Notes can only contain plain text and must be under 120 characters."

    /// A link that adds the reader as a friend, for Add Friend's Copy Friend Link.
    func createFriendLink() async throws -> String {
        "https://discord.gg/\(try await rest.createFriendInvite())"
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
    /// Where a resolved conversation is opened.
    ///
    /// **One resolver, two destinations.** The route that makes a DM is
    /// idempotent and is the only place that may make one; a second copy of it
    /// for the overlay would be a second place for a conversation to be created
    /// twice. What differs is a single line at the end, so it is a parameter.
    enum ConversationDestination {
        /// The main window navigates to it.
        case window
        /// It opens as a chat window on the overlay, over whatever is running.
        case overlay
    }

    func openConversation(
        with userID: UserID,
        to destination: ConversationDestination = .window,
        then followUp: ((ChannelID) -> Void)? = nil
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let channelID = try await resolveDirectMessage(with: userID)
                switch destination {
                case .window: model.openDirectMessage(channelID)
                case .overlay: model.overlay.openChat(channelID)
                }
                followUp?(channelID)
            } catch {
                Self.trace("open DM \(userID) failed: \(Self.describe(error))")
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    /// Answers somebody's custom status — with an emoji, or with words.
    ///
    /// **There is no status route. It is a direct message.** Captured both ways
    /// in `reply + react to status.har`: reacting and replying both `POST` to
    /// the conversation with the person, and the only thing that makes them
    /// *about* a status is the content the client composes —
    ///
    ///     > -# *Reacted to robinresting's status*
    ///     > 🤷🏿 test
    ///     😺
    ///
    /// A blockquote carrying a subtext-italic header and the status itself, then
    /// the answer on its own line. No `message_reference`, no new field, no
    /// second endpoint — which is why this reads as a quoted reply on every
    /// client including the ones that have never heard of the feature.
    ///
    /// **The handle, not the display name.** The capture says
    /// `robinresting's status` where that account's display name is something
    /// else; a client that wrote the display name would compose a sentence
    /// Discord's own never does.
    func answerStatus(
        of userID: UserID,
        handle: String,
        status: CustomStatus,
        answer: String
    ) {
        let content = Self.statusAnswer(handle: handle, status: status, answer: answer)
        guard !content.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let conversation = try await resolveDirectMessage(with: userID)
                _ = try await rest.sendMessage(
                    in: conversation, content: content, nonce: Self.nonce()
                )
            } catch {
                Self.trace("status answer \(userID) failed: \(Self.describe(error))")
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    /// The message body, exactly as the capture composes it.
    ///
    /// **"Reacted" for a bare emoji and "Replied" for words**, which is the only
    /// difference between the two in the capture — the header is the whole
    /// distinction, and Discord picks it from what the reader sent.
    static func statusAnswer(
        handle: String,
        status: CustomStatus,
        answer: String
    ) -> String {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // A single emoji and nothing else is a reaction; anything with words in
        // it is a reply.
        let isReaction = trimmed.unicodeScalars.allSatisfy {
            $0.properties.isEmoji || $0.properties.isEmojiModifier
                || $0.properties.isVariationSelector || $0 == "\u{200D}"
        }
        let verb = isReaction ? "Reacted" : "Replied"
        // The status as it reads: its emoji, a space, then its words. Either
        // half may be missing and the quote still has to be one line.
        let quoted = [status.emoji.map(Self.plainEmoji), status.text]
            .compactMap { $0 }
            .joined(separator: " ")
        return "> -# *\(verb) to \(handle)'s status*\n> \(quoted)\n\(trimmed)"
    }

    /// An emoji as it goes into message text: the glyph for a Unicode one, and
    /// `<:name:id>` for a custom one — the composer's own spelling.
    private static func plainEmoji(_ emoji: EmojiRef) -> String {
        guard let id = emoji.id else { return emoji.name }
        return "<\(emoji.isAnimated ? "a" : ""):\(emoji.name):\(id.rawValue)>"
    }

    func resolveDirectMessage(with userID: UserID) async throws -> ChannelID {
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
                // Discord's Report Spam leaves the conversation it was about.
                if case .firstDirectMessage(_, let channelID) = subject {
                    model.closeDirectMessage(channelID)
                }
            } catch {
                Self.trace("report failed: \(Self.describe(error))")
                model.reportSubmission = .failed(Self.describe(error))
            }
        }
    }

    // MARK: Groups

    /// Discord's Edit Group, saved.
    func renameGroup(_ channelID: ChannelID, to name: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.renameGroup(channelID, to: name)
            } catch {
                Self.trace("rename group failed: \(Self.describe(error))")
            }
        }
    }

    /// Add Friends to DM: one write a person. The roster fills from the
    /// socket's `CHANNEL_RECIPIENT_ADD`.
    func addGroupRecipients(_ userIDs: [UserID], to channelID: ChannelID) {
        Task { [weak self] in
            guard let self else { return }
            for userID in userIDs {
                do {
                    try await rest.addGroupRecipient(userID, to: channelID)
                } catch {
                    Self.trace("add \(userID) to group failed: \(Self.describe(error))")
                }
            }
        }
    }

    // MARK: Shared

    /// A send nonce, which is what makes an echo matchable to the send that
    /// caused it.
    static func nonce() -> String { String(mintNonce().rawValue) }

    /// A snowflake minted now — Discord's own nonce, and the id a send's local
    /// echo is drawn under until Discord's answer replaces it.
    ///
    /// **A snowflake rather than a bare clock**, which is what this used to be:
    /// the echo sorts and is dated by its id, and two sends in one millisecond
    /// need two ids — the sequence in the low bits is Discord's answer to that.
    static func mintNonce(at date: Date = .now) -> MessageID {
        let millisecond = UInt64(max(0, date.timeIntervalSince1970 * 1000))
        if millisecond == nonceClock.millisecond {
            nonceClock.sequence &+= 1
        } else {
            nonceClock = (millisecond, 0)
        }
        return MessageID(minting: date, sequence: nonceClock.sequence)
    }

    private static var nonceClock: (millisecond: UInt64, sequence: UInt64) = (0, 0)
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

    /// Answers a moderator's invitation to speak: the hand down either way,
    /// and the suppression lifted on Accept — Discord's own body,
    /// `{suppress, request_to_speak_timestamp: null, channel_id}`.
    func writeStageInviteAnswer(_ accept: Bool, inGuild guildID: GuildID, channelID: ChannelID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.setSelfStageState(
                    inGuild: guildID,
                    channelID: channelID,
                    suppress: !accept,
                    requestToSpeakAt: .some(nil)
                )
            } catch {
                Self.trace("stage invite answer \(channelID): \(Self.describe(error))")
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    /// Writes one permission overwrite on a channel. The gateway's channel
    /// update is what moves the model, as it does for the settings pages.
    func writeChannelOverwrite(
        in channelID: ChannelID,
        subjectID: UInt64,
        isRole: Bool,
        allow: Permissions,
        deny: Permissions
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.setChannelOverwrite(
                    in: channelID, subjectID: subjectID, isRole: isRole, allow: allow, deny: deny
                )
            } catch {
                Self.trace("channel overwrite \(channelID): \(Self.describe(error))")
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

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
                    // Discord's own `L(channel, suppress)`: the hand comes down
                    // with every move of one's own, or an unsuppressed
                    // moderator would read as an invitation still waiting.
                    try await rest.setSelfStageState(
                        inGuild: guildID, channelID: channelID, suppress: suppress,
                        requestToSpeakAt: .some(nil)
                    )
                }
            } catch {
                Self.trace("stage suppress \(channelID): \(Self.describe(error))")
                if let subject { model.applyStageSuppress(!suppress, for: subject) }
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    /// Starts a stage, then steps the reader onto it — Discord's own order
    /// (module 849736, `Nx`): the instance, and only then up, silently, so the
    /// chat gains no "is now a speaker." for the person who started it.
    ///
    /// Throws Discord's refusal of the stage itself, for the dialog that
    /// asked; a refused step up is the moderator's to retry with Speak on
    /// Stage, and is only traced.
    func startStage(
        channelID: ChannelID,
        guildID: GuildID,
        topic: String,
        notifyEveryone: Bool,
        scheduledEventID: UInt64?
    ) async throws {
        do {
            if let stage = try await rest.startStage(
                inChannel: channelID,
                topic: topic,
                notifyEveryone: notifyEveryone,
                scheduledEventID: scheduledEventID
            ) {
                model.applyStage(stage)
            }
        } catch {
            Self.trace("start stage \(channelID): \(Self.describe(error))")
            throw error
        }
        guard let userID = model.currentUserID else { return }
        model.applyStageSuppress(false, for: userID)
        do {
            try await rest.setSelfStageState(
                inGuild: guildID,
                channelID: channelID,
                suppress: false,
                requestToSpeakAt: .some(nil),
                silent: true
            )
        } catch {
            Self.trace("start stage \(channelID) step up: \(Self.describe(error))")
            model.applyStageSuppress(true, for: userID)
        }
    }

    /// Discord's Edit Stage. Throws its refusal for the dialog that asked.
    func setStageTopic(_ topic: String, privacyLevel: StagePrivacyLevel, channelID: ChannelID) async throws {
        do {
            if let stage = try await rest.setStageTopic(topic, privacyLevel: privacyLevel, inChannel: channelID) {
                model.applyStage(stage)
            }
        } catch {
            Self.trace("stage topic \(channelID): \(Self.describe(error))")
            throw error
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

// MARK: - Message requests

extension SessionController {

    /// Accept DM: Discord answers with the conversation, no longer a request,
    /// which is filed in its place and opened.
    func acceptMessageRequest(_ channelID: ChannelID) {
        Task { [weak self] in
            guard let self else { return }
            defer { model.messageRequestsInFlight.remove(channelID) }
            do {
                let accepted = try await rest.acceptMessageRequest(channelID)
                model.channelIndex.upsert(accepted)
                model.permissionGate.invalidate()
                model.sidebarRevision &+= 1
                model.selectChannel(channelID)
            } catch {
                Self.trace("accept request \(channelID) failed: \(Self.describe(error))")
                model.reportActionFailure(AppModel.messageRequestFailure)
            }
        }
    }

    /// Ignore and Decline: the reader leaves, and the conversation goes. The
    /// gateway's `CHANNEL_DELETE` says the same a moment later.
    func declineMessageRequest(_ channelID: ChannelID) {
        Task { [weak self] in
            guard let self else { return }
            defer { model.messageRequestsInFlight.remove(channelID) }
            do {
                try await rest.declineMessageRequest(channelID)
                model.forgetChannel(channelID)
            } catch {
                Self.trace("decline request \(channelID) failed: \(Self.describe(error))")
                model.reportActionFailure(AppModel.messageRequestFailure)
            }
        }
    }
}

/// Why a friend request did not go, in the words the sheet shows.
struct FriendRequestFailure: Error, Equatable {
    var message: String
}

// MARK: - Conversation previews

extension SessionController {
    /// The newest message of each conversation in the list that has none yet,
    /// for its preview line (REDESIGN.md R9).
    ///
    /// **One request, when the list is first there** — Discord's mobile app's
    /// own (`DiscordREST.preloadMessages`), for up to a hundred conversations,
    /// most recent first; conversations already asked about are never asked
    /// again on this connection, and a conversation opened since has its
    /// transcript, which is better. Off with Settings › Appearance › Window ›
    /// Message previews.
    func loadDirectMessagePreviews() {
        guard AppSettings.shared.loadsMessagePreviews, !isLoadingPreviews,
              model.connectionState == .ready
        else { return }
        let wanted = model.channelIndex.privateChannelIDs().filter { channelID in
            guard !requestedPreviewChannels.contains(channelID),
                  let newest = model.channelIndex[channelID]?.lastMessageID
            else { return false }
            return model.latestDirectMessages[channelID]?.id != newest
        }
        let batch = Array(wanted.prefix(DiscordREST.previewChannelLimit))
        guard !batch.isEmpty else { return }
        requestedPreviewChannels.formUnion(batch)
        isLoadingPreviews = true
        Task { [weak self] in
            guard let self else { return }
            defer { isLoadingPreviews = false }
            do {
                let page = try await rest.preloadMessages(channelIDs: batch)
                absorb(page)
                model.receivePreviews(page.messages)
            } catch {
                Self.trace("previews for \(batch.count) conversations failed: \(Self.describe(error))")
            }
        }
    }
}
