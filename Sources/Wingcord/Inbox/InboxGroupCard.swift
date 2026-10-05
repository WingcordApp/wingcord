import SwiftUI
import WingcordCore

/// One channel's header over the messages under it.
///
/// **The same card whatever filled it.** A run of mentions, a channel's unread
/// messages, a group of bookmarks and a queue of scheduled messages are four
/// different fetches and one shape — which is the whole reason `InboxGrouping`
/// exists. What changes per tab is the trailing control and the row's own
/// accessory, and both are switched on `tab` in one place each.
///
/// **A flat fill and a hairline — not glass, and not a material either.** This
/// sits on the popover's own backdrop, so `.glassEffect` would be glass on glass
/// (§4 rule 2) and `.structuralSurface()` would be two materials in series. The
/// discovery cards take the material because they sit on the opaque reading
/// surface, where there is no first one. See `Palette.groupedFill`.
struct InboxGroupCard: View {
    var group: InboxGroup
    var tab: InboxTab
    var presentationRevision: UInt64
    var artworkGeneration: UInt64

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isHoveringHeader = false

    private var shape: RoundedRectangle { .rect(cornerRadius: Radius.glass) }

    /// Folded in the account's settings — Discord's `collapsedInInbox`. Only
    /// the Unreads tab folds.
    private var isCollapsed: Bool {
        guard tab == .unreads else { return false }
        if let guildID = group.eventsGuildID { return model.inboxCollapse.guildEvents.contains(guildID) }
        return model.inboxCollapse.channels.contains(group.channelID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !isCollapsed, !group.events.isEmpty {
                Divider().opacity(0.4)
                events
            } else if !group.rows.isEmpty, !isCollapsed {
                Divider().opacity(0.4)
                rows
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(shape)
        // A flat fill, not a material — see `Palette.groupedFill`. The popover
        // behind this already paints one, and a second in series reads as
        // frost rather than as a raised card.
        .background(Palette.groupedFill, in: shape)
        .overlay {
            shape.strokeBorder(Ink.quaternary, lineWidth: 1)
        }
        // **Only the Unreads tab fetches**, and only for a channel whose
        // messages are not already loaded. The other three tabs arrive with
        // their messages in the same response as their rows.
        // Keyed on the fold as well, so unfolding a group loads it — and a
        // folded one asks for nothing, which is Discord's own rule.
        .task(id: InboxGroupLoad(channelID: group.channelID, isCollapsed: isCollapsed)) {
            guard tab == .unreads, !isCollapsed, group.eventsGuildID == nil else { return }
            model.sessionController.loadUnreadGroup(group.channelID)
        }
    }

    // MARK: The header

    private var header: some View {
        HStack(spacing: Spacing.base) {
            Button {
                // An Events group opens the server's events, which is where
                // Discord's own goes.
                if let guildID = group.eventsGuildID {
                    model.closeInbox()
                    model.openEvents(inGuild: guildID)
                } else {
                    model.openInboxChannel(group.channelID)
                }
            } label: {
                HStack(spacing: Spacing.base) {
                    AvatarView(
                        url: group.iconURL,
                        monogram: group.monogram,
                        side: Metrics.avatarRow
                    )
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: Spacing.tight + 1) {
                            if let symbolName = group.symbolName {
                                Image(symbol: symbolName)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Ink.tertiary)
                                    .accessibilityHidden(true)
                            }
                            Text(group.name)
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundStyle(Ink.primary)
                                .lineLimit(1)
                            if group.mentionCount > 0 {
                                CountBadge(count: group.mentionCount)
                            }
                        }
                        if let breadcrumb = group.breadcrumb {
                            Text(breadcrumb)
                                .font(.system(.caption))
                                .foregroundStyle(Ink.secondary)
                                .lineLimit(1)
                                // A server name and a category name are both
                                // arbitrary length, and a breadcrumb that
                                // pushed the row wider would widen the panel.
                                .truncationMode(.tail)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!group.canOpen)
            .accessibilityLabel(
                group.breadcrumb.map { "\(group.name), \($0)" } ?? group.name
            )
            .accessibilityHint(group.canOpen ? "Opens the channel" : "")

            trailingAction
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, Spacing.base + 2)
        .background(isHoveringHeader ? Palette.hoverFill : .clear)
        .animation(motion.hover, value: isHoveringHeader)
        // One tracking area per group rather than one per row — see the note
        // on the row's own hover below.
        .onHover { hovering in
            guard isHoveringHeader != hovering else { return }
            isHoveringHeader = hovering
        }
    }

    /// The one control that acts on the whole group.
    ///
    /// **Per tab, and absent where there is nothing for it to do.** Bookmarks,
    /// reminders and scheduled messages are removed one at a time — there is no
    /// "clear this channel's bookmarks" act in the API and inventing one would
    /// be a button that means something different from what it says.
    @ViewBuilder
    private var trailingAction: some View {
        if tab == .unreads {
            Button {
                if let guildID = group.eventsGuildID {
                    model.sessionController.foldInboxEvents(guildID: guildID, collapsed: !isCollapsed)
                } else {
                    model.sessionController.foldInboxGroup(channelID: group.channelID, collapsed: !isCollapsed)
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Ink.secondary)
            .animation(motion.standard, value: isCollapsed)
            .help(isCollapsed ? "Expand" : "Collapse")
            .accessibilityLabel(Text(isCollapsed ? "Expand" : "Collapse"))
        }
        switch tab {
        case .unreads, .mentions:
            Button {
                if let guildID = group.eventsGuildID {
                    model.markInboxEventsRead(guildID)
                } else {
                    model.markInboxGroupRead(group.channelID)
                }
            } label: {
                Label("Mark As Read", systemImage: "checkmark")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .help("Mark as read")
            .disabled(!group.canOpen)
        case .bookmarks, .reminders, .scheduled:
            EmptyView()
        }
    }

    // MARK: The events

    /// A server's new events, each on a line of its own: what, and when. A
    /// line opens its event.
    private var events: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(group.events, id: \.id) { event in
                Button {
                    model.closeInbox()
                    model.openEvents(inGuild: event.guildID, event: event.id)
                } label: {
                    InboxEventLine(event: event)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, Spacing.tight)
    }

    // MARK: The messages

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(group.rows) { row in
                InboxMessageRow(
                    row: row,
                    tab: tab,
                    presentationRevision: presentationRevision,
                    artworkGeneration: artworkGeneration
                )
                if row.id != group.rows.last?.id {
                    Divider().opacity(0.25).padding(.leading, Spacing.snug)
                }
            }
        }
        .padding(.vertical, Spacing.tight)
    }
}

/// One message inside a group, and the one thing the reader can do to it.
struct InboxMessageRow: View {
    var row: InboxRow
    var tab: InboxTab
    var presentationRevision: UInt64
    var artworkGeneration: UInt64

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isHovering = false

    /// The draft being rewritten, or nil when the row is at rest.
    ///
    /// **Edited in place rather than in a presentation.** This row lives
    /// inside a popover, and a sheet raised from one is a window over a window
    /// — `INVARIANTS.md` §1 — while the thing being edited is one line of text
    /// that is already on screen. The field replaces the line it changes,
    /// which is `ProfileInlineEdits`' arrangement one surface over.
    @State private var draftEdit: String?
    /// The send time being moved, on the same argument.
    @State private var timeEdit: Date?
    @FocusState private var isEditingDraft: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            Button {
                open()
            } label: {
                body(of: row)
                    .frame(width: InboxFlyout.cardWidth(for: tab), alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(row.card == nil && row.draft == nil)
            .accessibilityLabel(row.card?.accessibilityLabel ?? row.draft ?? "Message unavailable")

            accessory
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, Spacing.base)
        .background(isHovering ? Palette.hoverFill : .clear)
        .animation(motion.hover, value: isHovering)
        // **Guarded, and the guard is the point.** `.onHover` compiles to an
        // AppKit tracking area whose geometry is re-derived as the list scrolls;
        // the write inside it is what would invalidate the row on every frame of
        // a scroll if it were unconditional.
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
    }

    /// What fills the row.
    ///
    /// Three cases, and each is a real state rather than a fallback:
    ///
    ///  - **A laid-out message.** The transcript's own renderer, so embeds, bot
    ///    tags, custom emoji, mentions, polls, forwards and attachments all draw
    ///    exactly as they do in the channel.
    ///  - **A draft.** A scheduled message has not been sent, so there is no
    ///    message object to lay out — only the reader's own text.
    ///  - **Neither.** A bookmark whose message was deleted. The row is drawn so
    ///    the reader can take the bookmark off; it is the only place they can.
    @ViewBuilder
    private func body(of row: InboxRow) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight + 1) {
            if let card = row.card {
                MessageCardCanvas(
                    card: card,
                    presentationRevision: presentationRevision,
                    artworkGeneration: artworkGeneration
                )
                // The height is the layout's. A measured height here would cost
                // a second layout pass per row and settle visibly on the first
                // frame.
                .frame(width: InboxFlyout.cardWidth(for: tab), height: card.height)
            } else if let editing = draftEdit {
                draftField(editing)
            } else if let draft = row.draft {
                Text(draft)
                    .font(.system(.body))
                    .foregroundStyle(Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Label("This message is no longer available", systemImage: "trash.slash")
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.tertiary)
            }
            stamp
        }
    }

    /// The line under a row that carries a time of its own.
    ///
    /// Only reminders and scheduled messages have one — a mention's timestamp is
    /// already drawn inside the card by the transcript's own painter, and
    /// repeating it would be the same fact twice.
    @ViewBuilder
    private var stamp: some View {
        let settings = PresentationRevision.shared.timeline
        if let editing = timeEdit {
            // One field for both tabs: a reminder's `due_at` and a scheduled
            // message's `send_at_timestamp` are the same question asked of two
            // rows, and the commit is what differs.
            timeField(editing)
        } else if let dueAt = row.dueAt {
            Label(
                "Due \(settings.timestampLabel(dueAt, calendar: .current))",
                systemImage: "bell"
            )
            .font(.system(.caption))
            // Overdue is the one state worth a colour: a reminder whose moment
            // has passed is the reason the reader opened this tab.
            .foregroundStyle(dueAt < .now ? AnyShapeStyle(Palette.unreadBadge) : AnyShapeStyle(Ink.secondary))
        } else if let scheduledAt = row.scheduledAt {
            HStack(spacing: Spacing.tight + 1) {
                Label(
                    "Sends \(settings.timestampLabel(scheduledAt, calendar: .current))",
                    systemImage: "calendar.badge.clock"
                )
                .font(.system(.caption))
                .foregroundStyle(Ink.secondary)
                if let reason = row.failureReason {
                    // A failed send that the reader never sees is a message they
                    // believe went out.
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(.caption))
                        .foregroundStyle(Palette.unreadBadge)
                        .lineLimit(1)
                }
            }
        }
    }

    /// The per-row act, revealed on hover.
    ///
    /// **Reserved whether or not it is showing.** A control that appears on
    /// hover and takes layout space with it would re-wrap every card in the
    /// group as the pointer crosses it.
    @ViewBuilder
    private var accessory: some View {
        Group {
            switch tab {
            case .mentions:
                // **One act, so a button and not a menu.** A disclosure onto a
                // single row is a click spent on nothing — the same rule the
                // Apps submenu follows.
                action("Dismiss", systemImage: "checkmark") {
                    model.dismissMention(row.id)
                }
            case .bookmarks:
                rowMenu {
                    Button("Jump to Message") { open() }
                        .disabled(row.card == nil)
                    Divider()
                    Button("Delete Bookmark", role: .destructive) {
                        model.removeSavedMessage(row.id, in: row.channelID)
                    }
                }
            case .reminders:
                rowMenu {
                    Button("Edit Reminder") { timeEdit = row.dueAt ?? .now }
                    Button("Jump to Message") { open() }
                        .disabled(row.card == nil)
                    Divider()
                    Button("Remove Reminder", role: .destructive) {
                        model.removeSavedMessage(row.id, in: row.channelID)
                    }
                }
            case .scheduled:
                rowMenu {
                    Button("Send Now") { model.sendScheduledMessageNow(row.id) }
                    Button("Edit Message") { draftEdit = row.draft ?? "" }
                    Button("Edit Schedule Time") { timeEdit = row.scheduledAt ?? .now }
                    Divider()
                    Button("Cancel Scheduled Message", role: .destructive) {
                        model.cancelScheduledMessage(row.id)
                    }
                }
            case .unreads:
                // Marking read is the group's act, not the message's — Discord
                // has no per-message read cursor. **Nothing, and no reserved
                // column either**: the excerpt below is one block for the whole
                // channel, so a 24-point gutter beside it is 24 points taken off
                // every embed in the tab for a control that does not exist.
                EmptyView()
            }
        }
        .frame(width: tab == .unreads ? 0 : InboxFlyout.accessoryGutter, height: 24)
        .opacity(isHovering ? 1 : 0)
        .animation(motion.fadeQuick, value: isHovering)
        // Hidden from the pointer as well as from the eye, so an invisible
        // button cannot be clicked by somebody who guessed where it was.
        .allowsHitTesting(isHovering)
    }

    /// The draft, being rewritten in place.
    ///
    /// **Return commits and Escape abandons**, which is the composer's own
    /// contract and the one this app states once: a list means Return picks,
    /// no list means Return commits. There is no list here.
    ///
    /// A commit that changes nothing sends no request — `editScheduledMessage`
    /// compares against the row it already holds — so opening the field and
    /// pressing Return costs nothing.
    @ViewBuilder
    private func draftField(_ text: String) -> some View {
        // **`EditableInlineField`'s own clothes, not a new field idiom.** The
        // profile edits a line where it is read with exactly this: a plain
        // field, the hover fill behind it, and the accent as a border only
        // while it has focus. A third spelling of "a short line being typed"
        // is a third thing to keep in step.
        TextField(
            "Message",
            text: Binding(get: { draftEdit ?? text }, set: { draftEdit = $0 }),
            axis: .vertical
        )
        .textFieldStyle(.plain)
        .font(.system(.body))
        .foregroundStyle(Ink.primary)
        .lineLimit(1...6)
        .focused($isEditingDraft)
        .padding(.horizontal, Spacing.base)
        .padding(.vertical, Spacing.tight + 1)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.hoverFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isEditingDraft ? Color.accentColor : .clear,
                    lineWidth: 1.5
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Scoped to the border, which is the only thing that reads focus — a
        // `.animation` on the row would rasterise the group underneath it, and
        // §1.5 is explicit about what that does to a material.
        .animation(motion.hover, value: isEditingDraft)
        .onSubmit(commitDraft)
        .onExitCommand { draftEdit = nil }
        .onAppear { isEditingDraft = true }
    }

    private func commitDraft() {
        if let edited = draftEdit { model.editScheduledMessage(row.id, content: edited) }
        draftEdit = nil
    }

    /// The send time, being moved in place.
    ///
    /// **A graphical picker is the wrong control in a 500-point row** and a
    /// field with a stepper is what macOS offers for a moment in time. Commit
    /// is the tick beside it rather than Return, because a `DatePicker` eats
    /// the key.
    @ViewBuilder
    private func timeField(_ date: Date) -> some View {
        HStack(spacing: Spacing.base) {
            DatePicker(
                "Sends",
                selection: Binding(get: { timeEdit ?? date }, set: { timeEdit = $0 }),
                in: Date.now...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .labelsHidden()
            .datePickerStyle(.field)
            .font(.system(.caption))

            Button("Save") {
                if let moved = timeEdit {
                    if tab == .reminders {
                        model.rescheduleReminder(row.id, in: row.channelID, to: moved)
                    } else {
                        model.rescheduleScheduledMessage(row.id, to: moved)
                    }
                }
                timeEdit = nil
            }
            .font(.system(.caption, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            Button("Cancel") { timeEdit = nil }
                .font(.system(.caption))
                .foregroundStyle(Ink.secondary)
        }
        .buttonStyle(.plain)
        .onExitCommand { timeEdit = nil }
    }

    /// The overflow beside a row.
    ///
    /// **A `Menu`, not a `.contextMenu`.** §2 forbids a context menu written
    /// inline on a list row because it is evaluated as part of every row's
    /// body — titles included — on every pass. A `Menu`'s items are built by
    /// the closure only when it is opened, so what a row costs at rest is its
    /// label: one glyph.
    private func rowMenu(@ViewBuilder _ items: () -> some View) -> some View {
        Menu {
            items()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(.rect)
        }
        // **The frame, the shape and the style go on the MENU, after the
        // style** — a borderless menu lays its own label out inside a control
        // of its own choosing, so a frame set on the label does not size it.
        // §1's rule, and the symptom is one control in a row wearing a
        // different size from its neighbours.
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24, height: 24)
        .foregroundStyle(Ink.secondary)
        .help("More")
        .accessibilityLabel("More actions")
    }

    private func action(
        _ title: String,
        systemImage: String,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Image(symbol: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Ink.secondary)
        .help(title)
        .accessibilityLabel(title)
    }

    private func open() {
        // A scheduled message has not been sent, so there is nothing to jump
        // to: the row's own act is cancelling it.
        guard row.card != nil else { return }
        model.openInboxRow(row.id, in: row.channelID)
    }
}

/// What an unread group's load is keyed on: the channel, and whether it is
/// folded.
private struct InboxGroupLoad: Hashable {
    var channelID: ChannelID
    var isCollapsed: Bool
}

/// One new event in an Events group: what, and when, lit under the pointer.
private struct InboxEventLine: View {
    var event: ScheduledEvent

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
            Image(systemName: "calendar")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Ink.tertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.name)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                Text(event.startsAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(.caption))
                    .foregroundStyle(Ink.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, Spacing.tight + 2)
        .background {
            if isHovering {
                Rectangle().fill(Palette.hoverFill)
            }
        }
        .contentShape(.rect)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.fadeQuick, value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
