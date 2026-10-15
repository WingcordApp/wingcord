import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import WingcordCore

/// Reads the store, hands the composer plain values.
///
/// The draft lives in the channel's `MessageBox` rather than in `@State` here,
/// so switching channels and coming back returns what was typed — and so an
/// eviction of the transcript never takes unsent input with it.
struct ComposerContainer: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model
    /// The file panel. `@State` here rather than on the store, because it is
    /// this window's presentation and nothing else in the app can raise it.
    @State private var isChoosingFiles = false
    /// The Photos library's picker, and what was picked in it — taken out as
    /// files and staged, then cleared.
    @State private var isPickingPhotos = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    /// Read here rather than inside the composer, so the composer stays a pure
    /// value view with no observable reference of its own.
    @State private var settings = AppSettings.shared

    var body: some View {
        @Bindable var model = model
        let box = model.messages(in: channelID)
        // Reading `roleRevision` registers the dependency the permission answer
        // below actually depends on — the gate itself is `@ObservationIgnored`,
        // so without this the composer would keep its old enabled state until
        // something unrelated invalidated the view.
        let _ = model.roleRevision
        Composer(
            channelName: model.channelIndex[channelID].map(model.displayName(of:)) ?? "",
            channelSigil: model.channelIndex[channelID]?.kind.isPrivate == true ? "@" : "#",
            shape: settings.chromeShape,
            controls: settings.composerControls,
            inlineControls: settings.composerControlsInline,
            // Vencord's SilentTyping icon (decision 17), when the plugin is on
            // and its "Show icon" is.
            silentTyping: settings.silentTyping && settings.silentTypingShowsIcon
                ? SilentTypingControl(isOn: settings.silentTypingIsOn) { settings.silentTypingIsOn.toggle() }
                : nil,
            focusKey: channelID,
            canSend: model.permissionGate.canSend(in: channelID),
            reply: reply,
            isEditing: box?.editing != nil,
            // **One field, two destinations.** An edit borrows the bar and must
            // not eat the draft underneath it, so the binding routes by which
            // state is live rather than by copying one into the other — a copy
            // is what loses whichever the reader abandoned.
            text: Binding(
                get: {
                    let box = model.messages(in: channelID)
                    return box?.editing?.text ?? box?.draft ?? ""
                },
                set: { newValue in
                    if model.messages(in: channelID)?.editing != nil {
                        // An edit is not typing in the channel: nobody is
                        // waiting on three dots for a message that already
                        // arrived.
                        model.mutateBox(channelID) { $0.editing?.text = newValue }
                        return
                    }
                    // Reported before the write, while the previous draft is
                    // still readable. **Only on growth**: deleting a mistake is
                    // not typing, and telling the channel it is keeps the
                    // indicator alive through a minute of somebody backspacing.
                    let previous = model.messages(in: channelID)?.draft ?? ""
                    if newValue.count > previous.count {
                        model.sessionController.reportTyping(in: channelID)
                    }
                    model.mutateBox(channelID) { $0.draft = newValue }
                }
            ),
            send: send(launch:),
            cancelReply: { model.cancelReply(in: channelID) },
            jumpToReply: { model.jumpToReply(in: channelID) },
            toggleReplyPing: { model.toggleReplyPing(in: channelID) },
            cancelEdit: { model.cancelEdit(in: channelID) },
            editLatest: { model.editLatestOwnMessage(in: channelID) },
            escapeTranscript: { model.escapeTranscript(in: channelID) },
            attachActions: attachActions,
            scheduledAt: box?.scheduledAt,
            setSchedule: { model.setSchedule($0, in: channelID) },
            pasteFiles: { model.stageAttachments($0, in: channelID) },
            canAttach: model.canAttachFiles(in: channelID),
            attachments: box?.attachments ?? [],
            attachmentRefusal: box?.attachmentRefusal,
            compressingFiles: box?.compressingFiles ?? 0,
            sendCompressed: { model.compressAttachments($0, in: channelID) },
            alwaysCompress: { model.alwaysCompressAttachments($0, in: channelID) },
            removeAttachment: { model.removeAttachment($0, in: channelID) },
            toggleAttachmentSpoiler: { model.toggleAttachmentSpoiler($0, in: channelID) },
            toggleAttachmentAnonymise: { model.toggleAttachmentAnonymise($0, in: channelID) },
            modifyAttachment: { id, filename, altText, isSpoiler in
                model.modifyAttachment(id, in: channelID, filename: filename, altText: altText, isSpoiler: isSpoiler)
            },
            dismissAttachmentRefusal: { model.dismissAttachmentRefusal(in: channelID) },
            completions: completions,
            completionQuery: completionQuery ?? "",
            commitCompletion: commit,
            mentionKind: mentionTrigger?.kind,
            mentionQuery: mentionTrigger?.query ?? "",
            mentionCandidates: mentionCandidates,
            commitMention: commitMention,
            mentionChip: { [channelID] in model.composerChip(for: $0, in: channelID) },
            mentionChipRevision: model.composerChipRevision,
            onPick: { model.apply($0.pick, in: channelID) },
            // Straight out rather than into the draft: picking a GIF is a
            // whole message, and the draft is left as it was.
            onPickGIF: { model.sendGIF($0.url, in: channelID) },
            activityChannelID: channelID,
            commandQuery: commandQuery,
            commandSections: commandSections,
            pickCommand: pick(_:),
            pendingCommand: pendingCommand,
            commandPrompt: commandPrompt,
            setCommandText: setCommandText,
            pickCommandOption: pick(option:),
            focusCommandOption: focus(option:),
            stepCommandOption: step(_:),
            backspaceCommand: backspaceCommand,
            cancelCommand: { model.mutateBox(channelID) { $0.command = nil } },
            submitCommand: submitCommand,
            pendingInteractions: pendingInteractions,
            // Only the request aimed at this conversation: a thread panel's
            // composer beside the main one must not open a picker too.
            controlRequest: model.composerControlRequest?.channelID == channelID
                ? model.composerControlRequest
                : nil,
            takeControlRequest: { model.composerControlRequest = nil },
            appLauncherRequest: model.appLauncherRequest?.channelID == channelID
                ? model.appLauncherRequest
                : nil,
            takeAppLauncherRequest: { model.appLauncherRequest = nil }
        )
        // A shortcode the reader finished typing becomes its emoji — see
        // `applyClosedShortcode`. Keyed on the text so it runs once per change
        // rather than on every evaluation of this body.
        .onChange(of: activeText) { applyClosedShortcode() }
        // **One importer on one view.** The rule §2 states is about a
        // presentation modifier on a list ROW — evaluated by every row on every
        // pass. There is exactly one composer, and the panel has to be anchored
        // to the window the `+` is in.
        // The menu bar's Upload a File…, for this conversation.
        .onChange(of: model.fileImportRequest) { _, request in
            guard request == channelID else { return }
            model.fileImportRequest = nil
            isChoosingFiles = true
        }
        .fileImporter(
            isPresented: $isChoosingFiles,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            model.stageAttachments(urls, in: channelID)
        }
        // **`.compatible`**: a HEIC photo comes out a JPEG and an HEVC video
        // H.264, which every client Discord has will show.
        .photosPicker(
            isPresented: $isPickingPhotos,
            selection: $pickedPhotos,
            maxSelectionCount: AppModel.attachmentCountLimit,
            matching: .any(of: [.images, .videos]),
            preferredItemEncoding: .compatible
        )
        .task(id: pickedPhotos) {
            guard !pickedPhotos.isEmpty else { return }
            let items = pickedPhotos
            var urls: [URL] = []
            for item in items {
                if let file = try? await item.loadTransferable(type: PhotoLibraryFile.self) {
                    urls.append(file.url)
                }
            }
            model.stageAttachments(urls, in: channelID)
            pickedPhotos = []
        }
        // `@game`'s search, a beat after the typing stops — Discord's 200
        // milliseconds — and once per query for the session.
        .task(id: gameSearchKey) {
            guard let gameSearchKey else { return }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await model.sessionController.searchGames(gameSearchKey)
        }
        .task(id: commandQuery == nil) {
            // Fetched the first time a `/` is typed in this channel, and never
            // again: the index carries 183 commands in 119 KB and the reference
            // client asks for it once. `loadCommandIndex` is guarded per scope.
            guard commandQuery != nil else { return }
            await model.sessionController.loadCommandIndex(for: channelID)
        }
    }

    // MARK: The + menu

    /// Discord's `channel-attach` rows this conversation can honour. Files and
    /// photos need `ATTACH_FILES`; the rest gate themselves on the store.
    private var attachActions: ComposerAttachActions {
        let canAttach = model.canAttachFiles(in: channelID)
        return ComposerAttachActions(
            uploadFile: canAttach ? { isChoosingFiles = true } : nil,
            selectPhotos: canAttach ? { isPickingPhotos = true } : nil,
            createThread: model.canStartThread(in: channelID)
                ? { model.startThread(in: channelID, location: "Plus Button") }
                : nil,
            createPoll: model.canPostPolls(in: channelID) ? { model.openPollEditor(in: channelID) } : nil,
            useApps: model.permissionGate.canUseCommands(in: channelID) ? { model.useApps(in: channelID) } : nil,
            listenAlong: model.listenAlongInvitationTitle(in: channelID).map { title in
                ComposerAttachActions.Invitation(title: title) { model.sendListenAlongInvite(in: channelID) }
            },
            schedule: model.canScheduleMessages(in: channelID) ? { model.setSchedule($0, in: channelID) } : nil
        )
    }

    // MARK: Slash commands

    private var pendingCommand: PendingCommand? { model.messages(in: channelID)?.command }

    /// The `/` query, when the bar is holding a draft rather than an edit.
    ///
    /// **An edit is not a command.** The composer's field is borrowed for both,
    /// and a message being edited that happens to start with a slash must not
    /// open a command list over it.
    private var commandQuery: String? {
        let box = model.messages(in: channelID)
        guard box?.editing == nil, box?.command == nil else { return nil }
        guard model.permissionGate.canUseCommands(in: channelID) else { return nil }
        return CommandQuery.query(in: box?.draft ?? "")
    }

    private var commandSections: [CommandSection] {
        guard let commandQuery else { return [] }
        return model.commandSections(in: channelID, matching: commandQuery)
    }

    private var commandPrompt: CommandOptionPrompt? {
        guard let pendingCommand else { return nil }
        return model.commandPrompt(for: pendingCommand, in: channelID)
    }

    private var pendingInteractions: [PendingInteraction] {
        model.pendingInteractions.values
            .filter { $0.channelID == channelID }
            .sorted { $0.nonce < $1.nonce }
    }

    /// Chosen from the `/` list. The draft that was being typed is cleared, not
    /// kept: it was `/8ba`, and a command bar with that still behind it would
    /// send it as text the moment the command is abandoned.
    private func pick(_ row: CommandRow) {
        model.mutateBox(channelID) { box in
            box.draft = ""
            box.command = PendingCommand(command: row.command)
        }
    }

    private func pick(option row: CommandOptionRow) {
        switch row.action {
        case .fill(let value):
            model.mutateBox(channelID) { box in
                guard let option = box.command?.focusedOption else { return }
                box.command?.commit(value, for: option)
            }
        case .focus(let name):
            focus(option: name)
        }
    }

    /// Puts the caret back into an option, **with its old answer still in the
    /// field**. A chip that can only be removed is a chip that cannot be fixed,
    /// and retyping a sentence to change one word is the whole reason this is
    /// not a text field.
    private func focus(option name: String) {
        model.mutateBox(channelID) { box in
            let previous = box.command?.argument(named: name)?.value.display ?? ""
            box.command?.clear(name)
            box.command?.text = previous
        }
    }

    private func setCommandText(_ text: String) {
        model.mutateBox(channelID) { $0.command?.text = text }
    }

    /// Fills the focused option with what is typed. False when there was
    /// nothing to fill, which is what lets Return fall through to running.
    private func commitCommandText() -> Bool {
        guard let pending = pendingCommand, let option = pending.focusedOption else { return false }
        let typed = pending.text.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return false }
        // A closed set never takes typed text: the list is the only valid
        // source, and committing a name where the wire wants a snowflake is a
        // value the application rejects. `INVARIANTS.md` §5.5 — a control that
        // cannot work must not look like one that can.
        guard !AppModel.isClosedSet(option), let value = option.value(from: typed) else {
            return false
        }
        model.mutateBox(channelID) { $0.command?.commit(value, for: option) }
        return true
    }

    /// Tab. Commits what is typed first, so moving on does not silently discard
    /// it — then falls through to the next option when there was nothing to
    /// commit.
    private func step(_ delta: Int) {
        // Committing already moves to the next option that needs one, which is
        // what Tab means when there is something in the field.
        if commitCommandText() { return }
        guard let command = pendingCommand else { return }
        let order = command.command.offeredParameters.map(\.name)
        guard let current = command.focused, let index = order.firstIndex(of: current)
        else { return }
        // Wrapping, so Tab never dead-ends on the last option of a command with
        // eight of them.
        focus(option: order[((index + delta) % order.count + order.count) % order.count])
    }

    /// Backspace on an empty option field. Takes the last answer back, or
    /// abandons the command when there is none.
    private func backspaceCommand() {
        model.mutateBox(channelID) { box in
            guard let last = box.command?.arguments.last else {
                box.command = nil
                return
            }
            box.command?.clear(last.name)
            box.command?.text = last.value.display
        }
    }

    /// Return, once nothing is listed: fill the option being typed into, then
    /// run the command if that was the last thing it wanted.
    ///
    /// **Completeness is re-read from the store after the commit, not before.**
    /// Filling the last required option is exactly what makes a command
    /// runnable, so a caller holding a snapshot from before the write would
    /// refuse to send precisely the command it had just finished — which is why
    /// the whole sequence is one function here rather than two closures in the
    /// view. `pendingCommand` below reads the box.
    private func submitCommand() {
        _ = commitCommandText()
        guard let pending = pendingCommand, pending.isComplete else { return }
        // **Half-typed answers are not silently thrown away.** A closed set —
        // a choice list, a person, a channel — refuses typed text, so somebody
        // part-way through naming one has a command that is technically
        // complete and an answer that is not. Sending there would drop what
        // they typed and run the command without it.
        if let option = pending.focusedOption,
           AppModel.isClosedSet(option),
           !pending.text.trimmingCharacters(in: .whitespaces).isEmpty
        {
            return
        }
        model.mutateBox(channelID) { $0.command = nil }
        Task { await model.sessionController.runCommand(pending, in: channelID) }
    }

    /// Whichever field the bar is showing. A completion typed while editing
    /// must be answered against the edit, not the draft behind it.
    private var activeText: String {
        let box = model.messages(in: channelID)
        return box?.editing?.text ?? box?.draft ?? ""
    }

    /// The shortcode being typed, if any.
    ///
    /// **Yields to a later `@` or `#`.** Both scanners look for their own
    /// sigil and neither can see the other, so `:sob @al` is an open
    /// shortcode *and* an open mention by each one's own rules. The reader is
    /// typing whichever sigil is further along; deciding that here is what
    /// keeps both scanners pure. See `MentionAutocomplete.Trigger.sigilOffset`.
    private var completionQuery: String? {
        let text = activeText
        guard let query = EmojiAutocomplete.query(in: text) else { return nil }
        if let trigger = mentionTrigger,
           let colon = text.lastIndex(of: ":"),
           text.distance(from: text.startIndex, to: colon) < trigger.sigilOffset
        {
            return nil
        }
        return query
    }

    /// The `@` or `#` being typed, if any.
    private var mentionTrigger: MentionAutocomplete.Trigger? {
        MentionAutocomplete.trigger(in: activeText)
    }

    /// What to offer for it.
    ///
    /// Resolved in the body for the same reason the shortcode matches are: it
    /// is a prefix search over tables the store already holds, and state would
    /// need invalidating from every place that can change the answer — a
    /// member arriving, a channel being created, a permission changing.
    private var mentionCandidates: [MentionCandidate] {
        guard let mentionTrigger else { return [] }
        return model.mentionCandidates(for: mentionTrigger, in: channelID)
    }

    /// What `@game` is searching for, normalised as Discord keys its answers.
    private var gameSearchKey: String? {
        guard let mentionTrigger, mentionTrigger.kind == .game else { return nil }
        return GameMentionSearch.normalized(mentionTrigger.query)
    }

    private func commitMention(_ candidate: MentionCandidate) {
        guard let kind = mentionTrigger?.kind else { return }
        // A picked game's name, so its chip — and the message once sent —
        // read it at once rather than "unknown-game".
        if kind == .game, let id = SessionController.gameMentionIDs(in: candidate.token).first {
            model.gameMentionNames[id] = candidate.title
        }
        model.mutateBox(channelID) { box in
            if let existing = box.editing?.text {
                box.editing?.text = MentionAutocomplete.applying(
                    candidate.token, kind: kind, to: existing
                )
            } else {
                box.draft = MentionAutocomplete.applying(
                    candidate.token, kind: kind, to: box.draft
                )
            }
        }
    }

    /// What to offer for it.
    ///
    /// Resolved in the body rather than kept in state: it is a prefix search
    /// over a memoized catalog, and state would need invalidating from three
    /// places that can each change the answer.
    private var completions: [ExpressionItem] {
        guard let completionQuery else { return [] }
        return EmojiAutocomplete.matches(
            for: completionQuery,
            custom: model.emojiCatalog.sections
        )
    }

    /// Turns a shortcode the reader typed all the way through into its emoji.
    ///
    /// **`:sob:` becomes the emoji without Tab**, which is what Discord does and
    /// what the completion list could only do on a keypress. The closing colon
    /// is the reader saying they are finished; taking them at their word is the
    /// whole feature.
    ///
    /// **Only on an exact name, and only when one thing owns it.** A prefix
    /// match would turn `:so:` into whatever happened to sort first, and two
    /// servers with an emoji of the same name is a coin toss this has no
    /// business making — it leaves those alone and the list still offers them.
    private func applyClosedShortcode() {
        let text = activeText
        guard let name = EmojiAutocomplete.closedShortcode(in: text) else { return }
        let exact = EmojiAutocomplete.matches(
            for: name,
            custom: model.emojiCatalog.sections
        ).filter { $0.name.lowercased() == name }
        guard exact.count == 1, case .insert(let replacement) = exact[0].pick else { return }
        model.mutateBox(channelID) { box in
            if let existing = box.editing?.text, existing == text {
                box.editing?.text = EmojiAutocomplete.applyingClosed(replacement, to: existing)
            } else if box.draft == text {
                box.draft = EmojiAutocomplete.applyingClosed(replacement, to: box.draft)
            }
        }
    }

    private func commit(_ item: ExpressionItem) {
        guard case .insert(let text) = item.pick else { return }
        model.mutateBox(channelID) { box in
            // Into whichever field the bar is showing, for the same reason the
            // binding routes: completing a shortcode while editing must land in
            // the edit and not in the draft behind it.
            if let existing = box.editing?.text {
                box.editing?.text = EmojiAutocomplete.applying(text, to: existing)
            } else {
                box.draft = EmojiAutocomplete.applying(text, to: box.draft)
            }
        }
    }

    /// The reply bar's name, resolved the way the transcript resolves an
    /// author — the server's name for them, their role's colour and gradient,
    /// their style's face — so the person reads the same in the bar as in the
    /// row they are being answered from.
    private var reply: ComposerReply? {
        guard let box = model.messages(in: channelID), let replyID = box.replyingTo,
              let message = box.messages.first(where: { $0.id == replyID }),
              model.users[message.authorID] != nil
        else { return nil }
        let font = NSFont.systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize,
            weight: .semibold
        )
        let guildID = model.channelIndex[channelID]?.guildID
        guard let author = model.authorInfo(
            for: [.message(TimelineMessage(message: message, flags: []))],
            inGuild: guildID,
            authorFont: font
        )[message.authorID] else { return nil }
        return ComposerReply(
            name: author.name,
            colorValue: author.colorValue,
            gradient: author.gradient,
            face: author.nameFace,
            tracking: author.nameTracking,
            pings: box.replyPings,
            showsMentionToggle: guildID != nil && message.authorID != model.currentUserID
        )
    }

    private func send(launch: SendLaunch?) {
        // Return commits whichever the bar is holding. One entry point, so the
        // send control, the key press and the menu item cannot disagree about
        // what pressing Send means while an edit is open.
        if model.messages(in: channelID)?.editing != nil {
            model.commitEdit(in: channelID)
            return
        }
        let draft = model.messages(in: channelID)?.draft ?? ""
        model.sendMessage(draft, in: channelID, launch: launch)
    }
}
