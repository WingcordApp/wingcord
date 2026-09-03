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
/// **`+` sits outside the plate.** At the plate's corner radius an enclosed
/// circle collides with the rounded end, which is the whole reason Discord's own
/// composer is a rounded rect rather than a capsule. Keeping `+` beside the
/// plate lets the plate keep its radius and lets `+` keep its circle.
///
/// Colour is reserved for meaning: the send control is the only tinted thing
/// here, and only once there is something to send.
struct Composer: View {
    var channelName: String
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
    var attach: () -> Void = {}
    /// The `:shortcode` completions for what is currently typed. Empty closes
    /// the list, which is the only thing that does.
    var completions: [ExpressionItem] = []
    var completionQuery: String = ""
    var commitCompletion: (ExpressionItem) -> Void = { _ in }
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

    @Environment(\.motion) private var motion
    @FocusState private var isFocused: Bool
    @State private var openTab: ExpressionMode?
    /// The launcher's own presentation. **Not folded into `openTab`**: that
    /// enum is the expression picker's three modes, and a fourth case would
    /// make every `switch` over it carry a branch that cannot draw a grid.
    @State private var isShowingApps = false
    @State private var completionSelection = 0
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
        .animation(motion.panel, value: pendingCommand?.command.id)
        .animation(motion.panel, value: pendingCommand?.focused)
        .animation(motion.fadeQuick, value: visibleCommandQuery == nil)
        .animation(motion.panel, value: pendingInteractions)
        // A new set of matches starts at the top. Keeping the index across a
        // changed list selects whatever happens to be in that slot, which is how
        // a completion list sends the wrong emoji.
        .onChange(of: completions) { _, _ in completionSelection = 0 }
        .onChange(of: commandSections) { _, _ in commandSelection = 0 }
        // …and the same for the option list, which changes on every keystroke
        // while a choice is being filtered.
        .onChange(of: commandPrompt?.rows) { _, _ in optionSelection = 0 }
    }

    private var composerRow: some View {
        HStack(alignment: .bottom, spacing: Spacing.base) {
            CircleControl(systemImage: "plus", label: "Add attachment", action: attach)

            HStack(alignment: .bottom, spacing: Spacing.base) {
                if let pendingCommand {
                    CommandComposerBar(pending: pendingCommand, onEdit: focusCommandOption)
                }

                TextField(placeholder, text: fieldText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Typeface.messageBody)
                    // White across the whole bar rather than the hierarchy: a
                    // `.secondary` glyph washes out on glass, and a composer
                    // whose placeholder is invisible reads as broken.
                    .foregroundStyle(.white)
                    .lineLimit(1...Metrics.composerMaxLines)
                    .focused($isFocused)
                    .onSubmit(pressedReturn)
                    // Whatever is open owns these keys, and hands them straight
                    // back when nothing is. Returning `.ignored` is what lets
                    // Return still send and the arrows still move the caret the
                    // rest of the time.
                    .onKeyPress(.upArrow) { pressedUp() }
                    .onKeyPress(.downArrow) { pressedDown() }
                    .onKeyPress(.return) { pressedReturnKey() }
                    .onKeyPress(.tab) { pressedTab() }
                    .onKeyPress(.delete) { pressedBackspace() }
                    .onKeyPress(.escape) { pressedEscape() }
                    .frame(minHeight: Metrics.composerFieldMinHeight)

                expressionControls

                if canCommit {
                    SendControl(action: pressedReturn)
                        .transition(.materialize(from: .trailing))
                }
            }
            .padding(.horizontal, Spacing.snug)
            .padding(.vertical, Spacing.tight)
            .glassEffect(.regular, in: .rect(cornerRadius: Radius.glass))
            .animation(motion.glassMorph, value: canCommit)
        }
        .contentShape(.rect)
        // Clicking anywhere on the bar puts the caret in the field, which is
        // what every composer on this platform does.
        .onTapGesture { isFocused = true }
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
        return isEditing ? "Edit this message" : "Message #\(channelName)"
    }

    /// Whether there is something to send. A command that has every required
    /// option answered counts, even with an empty field — that is exactly the
    /// `/wordle` case, which takes no options at all.
    private var canCommit: Bool {
        if let pendingCommand { return pendingCommand.isComplete }
        return hasText
    }

    /// What the list actually shows: the matches, unless this exact query was
    /// dismissed.
    private var visibleCompletions: [ExpressionItem] {
        completionQuery == dismissedQuery ? [] : completions
    }

    private func dismissCompletions() { dismissedQuery = completionQuery }

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
    private enum ActiveList { case option(Int), command(Int), completion(Int), none }

    private var activeList: ActiveList {
        if pendingCommand != nil {
            let count = commandPrompt?.rows.count ?? 0
            return count > 0 ? .option(count) : .none
        }
        if visibleCommandQuery != nil, !commandRows.isEmpty { return .command(commandRows.count) }
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

        case .completion:
            guard let item = visibleCompletions[safe: completionSelection] else { return .ignored }
            commitCompletion(item)
            return .handled

        case .none:
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
    private func pressedEscape() -> KeyPress.Result {
        if pendingCommand != nil {
            cancelCommand()
            return .handled
        }
        if visibleCommandQuery != nil {
            dismissedCommandQuery = commandQuery
            return .handled
        }
        if !visibleCompletions.isEmpty {
            dismissCompletions()
            return .handled
        }
        guard isEditing else { return .ignored }
        cancelEdit()
        return .handled
    }

    /// GIF, sticker and emoji — rightmost is the one reached for most.
    ///
    /// **A popover per control, not one shared between them.** A popover points
    /// at what opened it, and three controls sharing one leaves the arrow under
    /// whichever the group happened to centre on. Only one is ever presented,
    /// and the catalog behind them is memoized on the store, so the second and
    /// third cost a view value each.
    private var expressionControls: some View {
        HStack(spacing: Spacing.hair) {
            control(.gifs) {
                // The word, not a glyph. Every icon for this is a rectangle with
                // something in it, and at 26 points "GIF" is the only mark that
                // says GIF.
                Text("GIF")
                    .font(.system(size: 10, weight: .heavy))
            }
            control(.stickers) {
                // A sticker peeling off its sheet. Deliberately not a second
                // face: the emoji control beside it is already the face, and two
                // faces is two controls nobody can tell apart.
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(Typeface.controlGlyph)
            }
            control(.emoji) {
                Image(systemName: "face.smiling")
                    .font(Typeface.controlGlyph)
            }
            if activityChannelID != nil { appsControl }
        }
    }

    /// Apps and activities.
    ///
    /// Its own control rather than a fourth `ExpressionMode`, and its own
    /// popover for the reason the three beside it each have one: a popover
    /// points at what opened it, and a shared presentation leaves the arrow
    /// under whichever control the group happened to centre on.
    @ViewBuilder
    private var appsControl: some View {
        if let channelID = activityChannelID {
            Button {
                isShowingApps.toggle()
            } label: {
                // Four rounded pips. The mark Discord uses for this is a
                // four-dot cluster and it is the one thing about the surface
                // worth keeping — an app grid is what the icon means anywhere
                // it appears, and inventing a different glyph for a familiar
                // idea is the "familiarity" principle spent for nothing.
                Image(systemName: "circle.grid.2x2.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(
                        isShowingApps ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Ink.secondary)
                    )
                    .frame(width: Metrics.compactControl, height: Metrics.compactControl)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Apps")
            .accessibilityLabel("Apps")
            .popover(isPresented: $isShowingApps, arrowEdge: .top) {
                ActivityLauncher(channelID: channelID)
            }
        }
    }

    private func control(
        _ tab: ExpressionMode,
        @ViewBuilder mark: () -> some View
    ) -> some View {
        Button {
            openTab = openTab == tab ? nil : tab
        } label: {
            mark()
                .foregroundStyle(
                    openTab == tab ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Ink.secondary)
                )
                .frame(width: Metrics.compactControl, height: Metrics.compactControl)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(tab.rawValue)
        .accessibilityLabel(tab.rawValue)
        .popover(
            isPresented: Binding(
                get: { openTab == tab },
                set: { if !$0, openTab == tab { openTab = nil } }
            ),
            arrowEdge: .top
        ) {
            ExpressionPicker(
                mode: tab,
                onPick: { item in
                    onPick(item)
                    // A sticker sends and the picker's work is done; an emoji is
                    // typed, and a picker that closed after each one would make
                    // choosing three emoji three round trips.
                    if case .sticker = item.pick { openTab = nil }
                },
                onPickGIF: { gif in
                    onPickGIF(gif)
                    openTab = nil
                }
            )
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

/// A circular glass control beside the composer.
private struct CircleControl: View {
    var systemImage: String
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(Typeface.controlGlyph)
                .foregroundStyle(.white)
                .frame(
                    width: Metrics.composerControlHeight,
                    height: Metrics.composerControlHeight
                )
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        // Small discrete targets keep `.interactive()` — the displacement scales
        // with the surface, so on a 38pt circle it reads as the control
        // responding rather than as the bar moving.
        .interactiveChrome(in: .circle)
        .help(label)
        .accessibilityLabel(Text(label))
    }
}

/// The send control. The one tinted thing in the composer, and only once there
/// is something to send.
private struct SendControl: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(.body, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .emphasisChrome(Palette.accent, in: .circle)
        .keyboardShortcut(.return, modifiers: [])
        .accessibilityLabel(Text("Send"))
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
