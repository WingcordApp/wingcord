import SwiftUI
import WingcordCore

/// The composer, floating over the foot of the transcript.
///
/// **Plain glass, not `.interactive()`.** Interactive glass adds a hover
/// highlight and a displacement toward the cursor; on a bar this wide that reads
/// as the whole composer shifting under the pointer rather than as a control
/// responding. The composer also has no press or focus highlight at all — it is
/// one flat plate in every state, because hand-rolling a focus lift means
/// layering a gesture over the text field where it competes with caret placement
/// and selection.
///
/// **Where `+` and the send arrow sit is decided by the silhouette**, not here.
/// A capsule's ends *are* circles, so an enclosed circle collides with the
/// rounded end and both controls stay outside as glass bodies of their own; a
/// rounded rectangle has flat sides and spare corners, so both sit inside it as
/// regions cut into its material. `ChromeShape.enclosesFlankingControls` states
/// the rule and `ComposerChrome` is the one place that lays either out.
///
/// Colour is reserved for meaning: the send control is the only tinted thing
/// here, and only once there is something to send.
struct Composer: View {
    var channelName: String
    /// What the placeholder puts in front of that name.
    ///
    /// **A conversation is not a channel.** Discord says "Message @somebody" in
    /// a direct message and "Message #general" in a server, and this bar said
    /// `#` in both — so every DM in the app invited the reader to write to a
    /// channel named after a person. Passed in rather than derived here for the
    /// reason `shape` is: this view reaches for nothing observable, and the
    /// settings preview draws it with no channel behind it at all.
    var channelSigil: String = "#"
    /// The silhouette. Passed in rather than read from `AppSettings`, so the
    /// settings preview can show a shape the reader has not committed to yet —
    /// and so this view still reaches for nothing observable.
    var shape: ChromeShape = .boxy
    /// The order of the four trailing controls. Passed in for the reason `shape`
    /// is: this view reaches for nothing observable, and the settings editor
    /// draws it from the order being edited rather than from the one in force.
    var controls: ComposerControlOrder = .default
    /// Whether the trailing controls may be dragged into a new order.
    ///
    /// **Off in the window, on only in the editor that has a container for it.**
    /// `.reorderable()` marks a child draggable through its container; in the
    /// real composer there is no container, and a control that begins a drag
    /// session on press is a control whose click has to wait to find out whether
    /// it was one. These four are pressed constantly, so the cost is paid where
    /// the gesture is the point and nowhere else.
    var isReorderable: Bool = false
    /// What identifies the conversation the bar is writing to.
    ///
    /// **The caret follows it.** Opening a channel or switching to another one
    /// should leave the reader able to type, which is what every client on this
    /// platform does and what this bar did not: it kept the focus wherever the
    /// click had left it, so the first thing typed after changing channel went
    /// nowhere. A value rather than a `channelID`, because this view reaches for
    /// nothing observable and the settings preview has no channel at all.
    var focusKey: AnyHashable = 0
    var canSend: Bool
    var replyingToAuthor: String?
    /// Whether the bar is holding an edit rather than a new message. It changes
    /// three things at once — the banner, the placeholder and what Return does
    /// — so it is one flag rather than three parameters that can disagree.
    var isEditing: Bool = false
    @Binding var text: String

    var send: () -> Void = {}
    var cancelReply: () -> Void = {}
    var cancelEdit: () -> Void = {}
    /// Replies to the newest message. Returns false when there is nothing to
    /// reply to, so Up falls through to the text view instead of dying.
    var replyToLatest: () -> Bool = { false }
    /// Escape's last step, for the transcript this composer belongs to — see
    /// `AppModel.escapeTranscript(in:)`. Returns false when there was nothing
    /// to do, so the key falls through.
    var escapeTranscript: () -> Bool = { false }
    var attach: () -> Void = {}
    /// Files pasted into the field, staged as a drop stages them.
    var pasteFiles: ([URL]) -> Void = { _ in }
    /// Whether `+`, the drop target and a pasted file are offered at all. A
    /// channel that refuses files gets none of them — `INVARIANTS.md` §5.5 —
    /// and a paste there is the text paste it would be anywhere else.
    var canAttach: Bool = true
    /// Files staged for this message, and why the last one was refused.
    var attachments: [PendingAttachment] = []
    var attachmentRefusal: AttachmentRefusal?
    var removeAttachment: (PendingAttachment.ID) -> Void = { _ in }
    var toggleAttachmentSpoiler: (PendingAttachment.ID) -> Void = { _ in }
    var dismissAttachmentRefusal: () -> Void = {}
    /// True while the staged files are going up.
    var isUploading: Bool = false
    /// The `:shortcode` completions for what is currently typed. Empty closes
    /// the list, which is the only thing that does.
    var completions: [ExpressionItem] = []
    var completionQuery: String = ""
    var commitCompletion: (ExpressionItem) -> Void = { _ in }
    /// The `@` or `#` list. Nil for the kind is "not completing a mention",
    /// which is a different state from "completing one and nothing matches".
    var mentionKind: MentionAutocomplete.Kind?
    var mentionQuery: String = ""
    var mentionCandidates: [MentionCandidate] = []
    var commitMention: (MentionCandidate) -> Void = { _ in }
    /// How a mention token in the field is drawn — see `EditorMention`.
    var mentionChip: ((EditorMention) -> EditorChip?)?
    var mentionChipRevision: UInt64 = 0
    /// The picker, opened from the controls at the composer's trailing end.
    var onPick: (ExpressionItem) -> Void = { _ in }
    var onPickGIF: (GIF) -> Void = { _ in }
    /// The channel an activity would be launched into.
    ///
    /// **Nil hides the control rather than disabling it.** A composer with no
    /// channel behind it — the one a preview draws — has nothing to launch
    /// into, and a greyed-out button implies a permission that could be gained.
    /// `INVARIANTS.md` §5.5.
    var activityChannelID: ChannelID?

    // MARK: Slash commands

    /// The `/` list, while the draft is a command being searched for. Empty
    /// sections with a non-nil query is "nothing matches", which is a different
    /// state from "not searching" and draws differently.
    var commandQuery: String?
    var commandSections: [CommandSection] = []
    var pickCommand: (CommandRow) -> Void = { _ in }
    /// A command chosen and being filled in.
    var pendingCommand: PendingCommand?
    /// What to ask for next, and what may be picked for it.
    var commandPrompt: CommandOptionPrompt?
    /// What is being typed into the focused option.
    var setCommandText: (String) -> Void = { _ in }
    var pickCommandOption: (CommandOptionRow) -> Void = { _ in }
    var focusCommandOption: (String) -> Void = { _ in }
    /// Moves to the next option, or back to the previous one.
    var stepCommandOption: (Int) -> Void = { _ in }
    /// Takes back the last answered option; abandons the command when there is
    /// none left.
    var backspaceCommand: () -> Void = {}
    var cancelCommand: () -> Void = {}
    /// Fills the option being typed into, then runs the command if that was the
    /// last thing it wanted.
    ///
    /// **One closure, not a commit and a run.** The view holds a *snapshot* of
    /// the pending command taken at the last body evaluation, so a view that
    /// committed and then asked its own copy whether the command was complete
    /// would be asking the value from before the commit — and a command whose
    /// last required option had just been filled would refuse to send. The store
    /// is the only thing that can answer that question after the write, so the
    /// whole sequence lives there.
    var submitCommand: () -> Void = {}
    /// Interactions posted from this channel and not yet answered.
    var pendingInteractions: [PendingInteraction] = []
    /// The sticker picker, asked for at one pack — "View More Stickers" on a
    /// stock sticker's card. Handed in, for `shape`'s reason.
    var stickerPickerRequest: StickerPickerRequest?
    /// Tells the store the request was taken, so it opens the picker once.
    var takeStickerPickerRequest: () -> Void = {}

    @Environment(\.motion) private var motion
    @State private var isFocused = false
    /// Which of the four trailing controls has its flyout open.
    ///
    /// **Keyed on the control, not on the picker's mode.** Three of the four
    /// open an `ExpressionPicker` and the fourth opens the app grid; keying on
    /// `ExpressionMode` meant the odd one out needed a second latch beside this
    /// one, and two latches for one "what is open" question is how both end up
    /// true. `ComposerControl` is already the identity the reader's own order is
    /// written in terms of.
    @State private var openControl: ComposerControl?
    /// The pack the sticker picker opens at, when a card asked for one. Cleared
    /// the moment the picker is not the one showing, so opening it by hand
    /// later starts where the picker always starts.
    @State private var stickerSection: String?
    @State private var completionSelection = 0
    @State private var mentionSelection = 0
    /// The mention query the reader dismissed with Escape. Held so the list
    /// stays down for *that* token and comes back for the next one — the same
    /// latch the shortcode and command lists have.
    @State private var dismissedMentionQuery: String?
    /// Return was pressed in `@time` before a time was picked — Discord's
    /// "Pick a time to continue." Cleared by the next keystroke.
    @State private var isTimeUnpicked = false
    /// The query Escape was pressed on. The list is derived from the draft, so
    /// dismissing it cannot mean clearing a list — it means remembering the one
    /// the reader said no to, until they type something else.
    @State private var dismissedQuery: String?
    /// Where the keyboard is in the `/` list, and in the option list under it.
    /// Two counters, because the two lists are never open at once and sharing
    /// one would carry a row index from a list of commands into a list of
    /// choices.
    @State private var commandSelection = 0
    @State private var optionSelection = 0
    /// The `/` query Escape was pressed on, for the reason `dismissedQuery`
    /// exists: the list is derived from the draft, so dismissing it means
    /// remembering what was refused rather than clearing anything.
    @State private var dismissedCommandQuery: String?

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: Spacing.tight) {
            // **One flyout at a time, in this order.** A command being filled in
            // owns the surface above the bar; a command being searched for owns
            // it next; the emoji list only when neither does. They are three
            // answers to "what is this keystroke for", and showing two at once
            // would leave Return meaning two things.
            if let commandPrompt, pendingCommand != nil {
                CommandOptionList(
                    title: commandPrompt.title,
                    subtitle: commandPrompt.subtitle,
                    rows: commandPrompt.rows,
                    selection: optionSelection,
                    onPick: pickCommandOption,
                    onHover: { optionSelection = $0 }
                )
                .transition(.materialize(from: .bottom))
            } else if let query = visibleCommandQuery {
                CommandPalette(
                    query: query,
                    sections: commandSections,
                    selection: commandSelection,
                    onPick: pickCommand,
                    onHover: { commandSelection = $0 }
                )
                .transition(.materialize(from: .bottom))
            } else if let kind = mentionKind, !visibleMentions.isEmpty {
                MentionAutocompleteList(
                    kind: kind,
                    query: mentionQuery,
                    items: visibleMentions,
                    selection: mentionSelection,
                    onPick: commitMention,
                    onHover: { mentionSelection = $0 }
                )
                .transition(.materialize(from: .bottom))
            } else if isTimeInputShown {
                // `@time` with nothing to pick yet — Discord's bar over the box.
                TimeMentionHint(isUnpicked: isTimeUnpicked)
                    .transition(.materialize(from: .bottom))
            } else if !visibleCompletions.isEmpty {
                EmojiAutocompleteList(
                    query: completionQuery,
                    items: visibleCompletions,
                    selection: completionSelection,
                    onPick: commitCompletion,
                    onHover: { completionSelection = $0 }
                )
                .transition(.materialize(from: .bottom))
            }

            ForEach(pendingInteractions) { interaction in
                InteractionBanner(interaction: interaction)
                    .transition(.materialize(from: .bottom))
            }

            // **One banner, never two.** An edit and a reply are mutually
            // exclusive at the store — starting either cancels the other — so
            // the bar shows whichever is live and the reader never has to work
            // out what Return will do.
            if isEditing {
                ComposerBanner(
                    symbolName: "pencil",
                    text: "Editing message — Escape to cancel",
                    cancelLabel: "Cancel edit",
                    cancel: cancelEdit
                )
                .transition(.materialize(from: .bottom))
            } else if let replyingToAuthor {
                ComposerBanner(
                    symbolName: "arrowshape.turn.up.left.fill",
                    text: "Replying to \(replyingToAuthor)",
                    cancelLabel: "Cancel reply",
                    cancel: cancelReply
                )
                .transition(.materialize(from: .bottom))
            }

            if canSend, !attachments.isEmpty || attachmentRefusal != nil {
                AttachmentTray(
                    attachments: attachments,
                    refusal: attachmentRefusal,
                    remove: removeAttachment,
                    toggleSpoiler: toggleAttachmentSpoiler,
                    dismissRefusal: dismissAttachmentRefusal
                )
                .transition(.materialize(from: .bottom))
            }

            if canSend {
                composerRow
            } else {
                PermissionNotice()
            }
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.bottom, Spacing.snug)
        .animation(motion.panel, value: replyingToAuthor)
        .animation(motion.panel, value: isEditing)
        .animation(motion.standard, value: canSend)
        .animation(motion.fadeQuick, value: visibleCompletions.isEmpty)
        .animation(motion.fadeQuick, value: visibleMentions.isEmpty)
        .animation(motion.panel, value: pendingCommand?.command.id)
        .animation(motion.panel, value: pendingCommand?.focused)
        .animation(motion.fadeQuick, value: visibleCommandQuery == nil)
        .animation(motion.panel, value: pendingInteractions)
        // A new set of matches starts at the top. Keeping the index across a
        // changed list selects whatever happens to be in that slot, which is how
        // a completion list sends the wrong emoji.
        .onChange(of: completions) { _, _ in completionSelection = 0 }
        // The selection belongs to a query, not to the list: a new letter is a
        // new set of matches, and keeping row four selected would move the
        // choice under the reader.
        .onChange(of: mentionCandidates) { _, _ in mentionSelection = 0 }
        .onChange(of: mentionQuery) { _, _ in isTimeUnpicked = false }
        .onChange(of: commandSections) { _, _ in commandSelection = 0 }
        // …and the same for the option list, which changes on every keystroke
        // while a choice is being filtered.
        .onChange(of: commandPrompt?.rows) { _, _ in optionSelection = 0 }
        .onChange(of: stickerPickerRequest?.token, initial: true) { _, _ in
            guard let request = stickerPickerRequest else { return }
            stickerSection = request.sectionID
            openControl = .sticker
            takeStickerPickerRequest()
        }
        .onChange(of: openControl) { _, control in
            if control != .sticker { stickerSection = nil }
        }
    }

    private var composerRow: some View {
        ComposerChrome(shape: shape) {
            // A channel that refuses files gets no control at all rather than a
            // dimmed one — `INVARIANTS.md` §5.5. In the enclosed arrangement
            // that closes up against the field, which is right: there is
            // nothing to attach.
            if canAttach {
                ComposerAttachButton(shape: shape, action: attach)
            }
        } input: {
            HStack(alignment: .bottom, spacing: Spacing.base) {
                if let pendingCommand {
                    CommandComposerBar(pending: pendingCommand, onEdit: focusCommandOption)
                }

                // **Discord's box**: the markdown stays visible and styled as it
                // is typed, and a selection brings up the formatting bar. See
                // `MarkdownEditor`.
                MarkdownEditor(
                    text: fieldText,
                    isFocused: $isFocused,
                    placeholder: placeholder,
                    font: NSFont.preferredFont(forTextStyle: .body),
                    // Solid across the whole bar rather than the hierarchy: a
                    // `.secondary` glyph washes out on glass, and a composer
                    // whose placeholder is invisible reads as broken. See
                    // `InkColor.solid`.
                    ink: .composerSolid,
                    lines: 1...Metrics.composerMaxLines,
                    returnSubmits: true,
                    // Whatever is open owns these keys, and hands them straight
                    // back when nothing is. Handing one back is what lets Return
                    // still send and the arrows still move the caret the rest of
                    // the time.
                    onKey: { key in
                        let result: KeyPress.Result = switch key {
                        case .up: pressedUp()
                        case .down: pressedDown()
                        // Shift-Return is a new line, whatever is open.
                        case .return(let shift): shift ? .ignored : pressedReturnKey()
                        case .tab: pressedTab()
                        case .backspace: pressedBackspace()
                        case .escape: pressedEscape()
                        }
                        return result == .handled
                    },
                    onSubmit: pressedReturn,
                    onPasteFiles: canAttach ? { urls in
                        pasteFiles(urls)
                        return true
                    } : nil,
                    // A picked mention shows as Discord's box shows it, while
                    // the token stays what is typed and sent.
                    chips: mentionChip,
                    chipRevision: mentionChipRevision
                )
                .frame(minHeight: Metrics.composerFieldMinHeight)
            }
            // The field's own air, so a bar grown to three lines keeps it. The
            // row's height comes from this plus the field's minimum, which is
            // what leaves a 32-point control centred inside a 38-point bar
            // rather than setting the bar's height itself.
            .padding(.vertical, Spacing.tight)
        } controls: {
            expressionControls
        } send: {
            ComposerSendButton(shape: shape, isArmed: canCommit, action: pressedReturn)
        }
        .animation(motion.glassMorph, value: shape)
        .contentShape(.rect)
        // Clicking anywhere on the bar puts the caret in the field, which is
        // what every composer on this platform does.
        .onTapGesture { isFocused = true }
        // And so does opening a conversation. `.task(id:)` rather than
        // `.onChange`, so the first channel of a session is focused too — a
        // change handler has nothing to compare against on the way in.
        .task(id: focusKey) { isFocused = true }
    }

    /// **One field, three destinations.** A command borrows the bar exactly as
    /// an edit does, and routing by which state is live — rather than copying
    /// one into another — is what keeps the draft underneath intact when the
    /// reader abandons either.
    private var fieldText: Binding<String> {
        guard pendingCommand != nil else { return $text }
        return Binding(
            get: { pendingCommand?.text ?? "" },
            set: { setCommandText($0) }
        )
    }

    private var placeholder: String {
        if let option = pendingCommand?.focusedOption {
            return option.summary.isEmpty ? option.name : option.summary
        }
        if pendingCommand != nil { return "Press Return to run" }
        return isEditing ? "Edit this message" : "Message \(channelSigil)\(channelName)"
    }

    /// Whether there is something to send. A command that has every required
    /// option answered counts, even with an empty field — that is exactly the
    /// `/wordle` case, which takes no options at all.
    private var canCommit: Bool {
        if let pendingCommand { return pendingCommand.isComplete }
        // A message may be nothing but files, and a second press while they are
        // going up would upload every one of them twice.
        return (hasText || !attachments.isEmpty) && !isUploading
    }

    /// What the list actually shows: the matches, unless this exact query was
    /// dismissed.
    private var visibleCompletions: [ExpressionItem] {
        completionQuery == dismissedQuery ? [] : completions
    }

    private func dismissCompletions() { dismissedQuery = completionQuery }

    /// What the mention list shows: the matches, unless this exact query was
    /// dismissed.
    private var visibleMentions: [MentionCandidate] {
        mentionQuery == dismissedMentionQuery ? [] : mentionCandidates
    }

    /// `@time` open with nothing to pick: its hint shows instead of a list,
    /// until Escape sets it aside.
    private var isTimeInputShown: Bool {
        mentionKind == .time && visibleMentions.isEmpty && mentionQuery != dismissedMentionQuery
    }

    /// The `/` query, unless this exact one was dismissed — and never while a
    /// command is already being filled in.
    private var visibleCommandQuery: String? {
        guard pendingCommand == nil, let commandQuery, commandQuery != dismissedCommandQuery
        else { return nil }
        return commandQuery
    }

    private var commandRows: [CommandRow] { commandSections.flatMap(\.rows) }

    /// The rows the arrow keys are currently walking, if any.
    ///
    /// One property rather than a branch at each key handler: the three lists
    /// are mutually exclusive by construction — see `body` — and stating that
    /// once is what stops Up meaning two things.
    private enum ActiveList { case option(Int), command(Int), mention(Int), completion(Int), none }

    private var activeList: ActiveList {
        if pendingCommand != nil {
            let count = commandPrompt?.rows.count ?? 0
            return count > 0 ? .option(count) : .none
        }
        if visibleCommandQuery != nil, !commandRows.isEmpty { return .command(commandRows.count) }
        // Before the shortcode list, matching the order `body` draws them in.
        // The two are mutually exclusive by construction — the container hands
        // over at most one — and stating the order once is what stops Up
        // meaning two things.
        if !visibleMentions.isEmpty { return .mention(visibleMentions.count) }
        if !visibleCompletions.isEmpty { return .completion(visibleCompletions.count) }
        return .none
    }

    // MARK: The keyboard

    /// Up has four meanings, in this order.
    ///
    /// Whichever list is open owns it. Otherwise, in an EMPTY composer it
    /// replies to the newest message — where every other chat client puts it —
    /// and with a draft in progress it is handed back to the text view so the
    /// caret still moves. Swallowing it in that last case would take the arrow
    /// key away from anybody editing a multi-line message.
    private func pressedUp() -> KeyPress.Result {
        if case .none = activeList {
            // An edit or a command already has the composer; Up there is the
            // caret, not a reply to something else.
            guard !isEditing, pendingCommand == nil, text.isEmpty, replyToLatest()
            else { return .ignored }
            return .handled
        }
        return move(-1)
    }

    private func pressedDown() -> KeyPress.Result { move(1) }

    /// Wrapping, so holding a direction never dead-ends at either end of a list
    /// this short.
    private func move(_ delta: Int) -> KeyPress.Result {
        func wrapped(_ index: Int, _ count: Int) -> Int {
            ((index + delta) % count + count) % count
        }
        switch activeList {
        case .option(let count): optionSelection = wrapped(optionSelection, count)
        case .command(let count): commandSelection = wrapped(commandSelection, count)
        case .mention(let count): mentionSelection = wrapped(mentionSelection, count)
        case .completion(let count): completionSelection = wrapped(completionSelection, count)
        case .none: return .ignored
        }
        return .handled
    }

    /// Return, as one rule: **a list means it picks, no list means it commits.**
    ///
    /// Anything looser puts two meanings on one key — which is what happens the
    /// moment a command's remaining options are offered as a list under a field
    /// the reader is also typing a value into.
    private func pressedReturnKey() -> KeyPress.Result {
        switch activeList {
        case .option(let count):
            guard let row = commandPrompt?.rows[safe: optionSelection], count > 0 else {
                return .ignored
            }
            pickCommandOption(row)
            return .handled

        case .command:
            guard let row = commandRows[safe: commandSelection] else { return .ignored }
            pickCommand(row)
            return .handled

        case .mention:
            guard let item = visibleMentions[safe: mentionSelection] else { return .ignored }
            commitMention(item)
            return .handled

        case .completion:
            guard let item = visibleCompletions[safe: completionSelection] else { return .ignored }
            commitCompletion(item)
            return .handled

        case .none:
            // Discord will not send an `@time` nobody finished: it asks for a
            // time instead.
            if isTimeInputShown {
                isTimeUnpicked = true
                return .handled
            }
            guard pendingCommand != nil else { return .ignored }
            pressedReturn()
            return .handled
        }
    }

    /// What Return means once nothing is listed.
    ///
    /// **One press for the common case.** `/8ball am i good enough` has a single
    /// option, so committing and sending on the same key is what makes it feel
    /// like typing a message rather than filling in a form. See `submitCommand`
    /// for why both halves of that live in the store.
    private func pressedReturn() {
        if pendingCommand != nil { submitCommand() } else { send() }
    }

    /// Tab walks the command's options, and completes an emoji otherwise.
    private func pressedTab() -> KeyPress.Result {
        if pendingCommand != nil {
            stepCommandOption(1)
            return .handled
        }
        if let item = visibleMentions[safe: mentionSelection], !visibleMentions.isEmpty {
            commitMention(item)
            return .handled
        }
        guard let item = visibleCompletions[safe: completionSelection] else { return .ignored }
        commitCompletion(item)
        return .handled
    }

    /// Backspace on an empty option field takes the previous answer back.
    ///
    /// The gesture every token field on this platform has, and the reason the
    /// argument chips need no delete control of their own. It is handed straight
    /// back to the text view the moment there is anything to delete, so it never
    /// eats a character.
    private func pressedBackspace() -> KeyPress.Result {
        guard let pendingCommand, pendingCommand.text.isEmpty else { return .ignored }
        backspaceCommand()
        return .handled
    }

    /// Escape, in the order things must not be lost.
    ///
    /// A list dismisses first, then a command is abandoned, then an edit — so
    /// one press never throws away both a command and the message underneath it.
    /// Only a press none of them wanted reaches the transcript behind the bar,
    /// which is where Discord's own chain ends (module `92960`).
    private func pressedEscape() -> KeyPress.Result {
        if pendingCommand != nil {
            cancelCommand()
            return .handled
        }
        if visibleCommandQuery != nil {
            dismissedCommandQuery = commandQuery
            return .handled
        }
        if !visibleMentions.isEmpty || isTimeInputShown {
            dismissedMentionQuery = mentionQuery
            return .handled
        }
        if !visibleCompletions.isEmpty {
            dismissCompletions()
            return .handled
        }
        if isEditing {
            cancelEdit()
            return .handled
        }
        return escapeTranscript() ? .handled : .ignored
    }

    /// The four controls at the bar's trailing end, in the reader's own order.
    ///
    /// **A popover per control, not one shared between them.** A popover points
    /// at what opened it, and controls sharing one leave the arrow under
    /// whichever the group happened to centre on. Only one is ever presented,
    /// and the catalog behind them is memoized on the store, so the second and
    /// third cost a view value each.
    ///
    /// Apps is hidden where there is nothing to launch into — nil hides rather
    /// than disables, because a greyed-out button implies a permission that
    /// could be gained (§5.5). It keeps its slot in the order either way, so a
    /// reader who dragged it somewhere finds it there again in a channel that
    /// has one.
    @ViewBuilder
    private var expressionControls: some View {
        HStack(spacing: Spacing.hair) {
            if isReorderable {
                ForEach(controlOrder, content: expressionControl).reorderable()
            } else {
                ForEach(controlOrder, content: expressionControl)
            }
        }
        // The controls are 32 points inside a 38-point bar rather than setting
        // its height, so the box they sit in is the bar's.
        .frame(height: Metrics.composerControlHeight)
    }

    private func expressionControl(_ control: ComposerControl) -> some View {
        ComposerControlButton(
            label: control.label,
            isActive: openControl == control,
            shape: shape,
            // Inert in the editor: dragging a control there must not also open
            // a picker, and a preview that opened one would be presenting a
            // flyout over the settings window.
            action: isReorderable ? nil : { openControl = openControl == control ? nil : control }
        ) {
            ComposerControlMark(control: control)
        }
        .popover(isPresented: flyoutBinding(for: control), arrowEdge: .top) {
            flyout(for: control)
        }
    }

    /// The order, minus whatever this channel cannot offer.
    private var controlOrder: [ComposerControl] {
        guard activityChannelID == nil else { return controls.controls }
        return controls.controls.filter { $0 != .apps }
    }

    /// **The setter may only clear when this control is the one showing.**
    /// Clearing unconditionally lets a dismissal arriving while a second
    /// control's popover is opening take the new one down with it.
    private func flyoutBinding(for control: ComposerControl) -> Binding<Bool> {
        Binding(
            get: { openControl == control },
            set: { if !$0, openControl == control { openControl = nil } }
        )
    }

    @ViewBuilder
    private func flyout(for control: ComposerControl) -> some View {
        if let mode = control.expressionMode {
            ExpressionPicker(
                mode: mode,
                initialSectionID: control == .sticker ? stickerSection : nil,
                onPick: { item in
                    onPick(item)
                    // A sticker sends and the picker's work is done; an emoji is
                    // typed, and a picker that closed after each one would make
                    // choosing three emoji three round trips.
                    if case .sticker = item.pick { openControl = nil }
                },
                onPickGIF: { gif in
                    onPickGIF(gif)
                    openControl = nil
                }
            )
        } else if let channelID = activityChannelID {
            ActivityLauncher(channelID: channelID)
        }
    }
}

/// The strip that says a command was sent and is waiting to be answered.
///
/// **`POST /interactions` answers `204` with an empty body**, so the socket is
/// the only thing that ever says whether an application took the command. Until
/// it does, the reader has pressed Return and nothing has appeared — and a
/// composer that says nothing there is a composer that looks broken for the
/// three seconds a bot is allowed to think.
///
/// The same shape and the same glass as the reply and edit banners beside it,
/// deliberately: it is the bar saying what it is doing, which is what that strip
/// already means.
private struct InteractionBanner: View {
    var interaction: PendingInteraction

    var body: some View {
        HStack(spacing: Spacing.base) {
            if interaction.failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(.caption))
                    .foregroundStyle(Palette.destructive)
            } else {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(message)
                .font(.system(.caption))
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, Spacing.base)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.chip))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(message))
    }

    /// What the wire actually said, and no more. `INTERACTION_FAILURE` carries
    /// `{id, nonce}` and nothing else — inventing a reason here would be
    /// inventing one.
    private var message: String {
        interaction.failed
            ? "\(interaction.applicationName) did not answer \(interaction.label)"
            : "\(interaction.applicationName) is running \(interaction.label)…"
    }
}

extension Collection {
    /// The element at `index`, or nil.
    ///
    /// A keyboard selection and the list it indexes are two pieces of state, and
    /// they are briefly out of step every time the list changes underneath a
    /// held arrow key. Crashing on that is not a defence against it.
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// The strip above the composer that says what the bar is holding.
///
/// One type for both states rather than one per state: they are the same shape,
/// the same glass and the same dismiss control, and two copies is two places for
/// the corner radius to drift.
private struct ComposerBanner: View {
    var symbolName: String
    var text: String
    var cancelLabel: String
    var cancel: () -> Void

    var body: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: symbolName)
                .font(.system(.caption))
                .foregroundStyle(Ink.tertiary)
            Text(text)
                .font(.system(.caption))
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
            Spacer(minLength: Spacing.tight)
            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.system(.caption2, weight: .bold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(cancelLabel))
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, Spacing.base)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.chip))
    }
}

/// What stands in for the composer where the reader cannot post.
///
/// Deliberately the same shape and the same glass as the composer it replaces,
/// so the foot of the transcript does not change height when navigating between
/// a channel you can post in and one you cannot.
private struct PermissionNotice: View {
    var body: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(.caption))
                .foregroundStyle(Ink.tertiary)
            Text("You do not have permission to send messages in this channel.")
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.snug)
        .frame(minHeight: Metrics.composerControlHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.glass))
    }
}

/// `@time` before a time is picked — Discord's bar over the box: the word,
/// and what it does, or that a time is still wanted.
private struct TimeMentionHint: View {
    var isUnpicked: Bool

    var body: some View {
        HStack(spacing: Spacing.base) {
            Text("@time")
                .font(.system(.caption, weight: .bold))
                .foregroundStyle(Ink.primary)
            Text(isUnpicked ? "Pick a time to continue." : "Refer to a time dynamically in the viewer's time zone")
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(isUnpicked ? AnyShapeStyle(Palette.destructive) : AnyShapeStyle(Ink.secondary))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, Spacing.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Clear, untinted: what passes under it is the transcript's content.
        .glassEffect(.clear, in: .rect(cornerRadius: Radius.glass, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
