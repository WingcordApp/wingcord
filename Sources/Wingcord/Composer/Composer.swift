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

    @Environment(\.motion) private var motion
    @FocusState private var isFocused: Bool
    @State private var openTab: ExpressionMode?
    @State private var completionSelection = 0
    /// The query Escape was pressed on. The list is derived from the draft, so
    /// dismissing it cannot mean clearing a list — it means remembering the one
    /// the reader said no to, until they type something else.
    @State private var dismissedQuery: String?

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: Spacing.tight) {
            if !visibleCompletions.isEmpty {
                EmojiAutocompleteList(
                    query: completionQuery,
                    items: visibleCompletions,
                    selection: completionSelection,
                    onPick: commitCompletion,
                    onHover: { completionSelection = $0 }
                )
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
        // A new set of matches starts at the top. Keeping the index across a
        // changed list selects whatever happens to be in that slot, which is how
        // a completion list sends the wrong emoji.
        .onChange(of: completions) { _, _ in completionSelection = 0 }
    }

    private var composerRow: some View {
        HStack(alignment: .bottom, spacing: Spacing.base) {
            CircleControl(systemImage: "plus", label: "Add attachment", action: attach)

            HStack(alignment: .bottom, spacing: Spacing.base) {
                TextField(
                    isEditing ? "Edit this message" : "Message #\(channelName)",
                    text: $text,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(Typeface.messageBody)
                // White across the whole bar rather than the hierarchy: a
                // `.secondary` glyph washes out on glass, and a composer whose
                // placeholder is invisible reads as broken.
                .foregroundStyle(.white)
                .lineLimit(1...Metrics.composerMaxLines)
                .focused($isFocused)
                .onSubmit(send)
                // The completion list owns these keys while it is open, and
                // hands them straight back when it is not. Returning `.ignored`
                // is what lets Return still send and the arrows still move the
                // caret the rest of the time.
                .onKeyPress(.upArrow) { pressedUp() }
                .onKeyPress(.downArrow) { moveCompletion(1) }
                .onKeyPress(.return) { commitSelectedCompletion() }
                .onKeyPress(.tab) { commitSelectedCompletion() }
                .onKeyPress(.escape) {
                    // The completion list owns Escape while it is open; an edit
                    // owns it the rest of the time. Ordered, because dismissing
                    // the list and abandoning the edit in one press would throw
                    // away work the reader did not mean to lose.
                    if !visibleCompletions.isEmpty {
                        dismissCompletions()
                        return .handled
                    }
                    guard isEditing else { return .ignored }
                    cancelEdit()
                    return .handled
                }
                .frame(minHeight: Metrics.composerFieldMinHeight)

                expressionControls

                if hasText {
                    SendControl(action: send)
                        .transition(.materialize(from: .trailing))
                }
            }
            .padding(.horizontal, Spacing.snug)
            .padding(.vertical, Spacing.tight)
            .glassEffect(.regular, in: .rect(cornerRadius: Radius.glass))
            .animation(motion.glassMorph, value: hasText)
        }
        .contentShape(.rect)
        // Clicking anywhere on the bar puts the caret in the field, which is
        // what every composer on this platform does.
        .onTapGesture { isFocused = true }
    }

    /// What the list actually shows: the matches, unless this exact query was
    /// dismissed.
    private var visibleCompletions: [ExpressionItem] {
        completionQuery == dismissedQuery ? [] : completions
    }

    private func dismissCompletions() { dismissedQuery = completionQuery }

    /// Up has three meanings, in this order.
    ///
    /// The completion list owns it while it is open. Otherwise, in an EMPTY
    /// composer it replies to the newest message — where every other chat client
    /// puts it — and with a draft in progress it is handed back to the text view
    /// so the caret still moves. Swallowing it in the third case would take the
    /// arrow key away from anybody editing a multi-line message.
    private func pressedUp() -> KeyPress.Result {
        if !visibleCompletions.isEmpty { return moveCompletion(-1) }
        // An edit already has the composer; Up there is the caret, not a reply
        // to something else.
        guard !isEditing, text.isEmpty, replyToLatest() else { return .ignored }
        return .handled
    }

    private func moveCompletion(_ delta: Int) -> KeyPress.Result {
        guard !visibleCompletions.isEmpty else { return .ignored }
        // Wrapping, so holding a direction never dead-ends at either end of a
        // list this short.
        let count = visibleCompletions.count
        completionSelection = ((completionSelection + delta) % count + count) % count
        return .handled
    }

    private func commitSelectedCompletion() -> KeyPress.Result {
        let items = visibleCompletions
        guard items.indices.contains(completionSelection) else { return .ignored }
        commitCompletion(items[completionSelection])
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
