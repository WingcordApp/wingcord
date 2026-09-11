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
/// **Structure, not glass.** This sits on the panel's ground rather than
/// floating over content, so it takes `.structuralSurface()` with a hairline —
/// `INVARIANTS.md` §4 rule 3, and the same treatment the discovery cards get.
/// Glass here would be a material over a material.
struct InboxGroupCard: View {
    var group: InboxGroup
    var tab: InboxTab
    var presentationRevision: UInt64
    var artworkGeneration: UInt64

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isHoveringHeader = false

    private var shape: RoundedRectangle { .rect(cornerRadius: Radius.glass) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !group.rows.isEmpty {
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
        .task(id: group.channelID) {
            guard tab == .unreads else { return }
            model.sessionController.loadUnreadGroup(group.channelID)
        }
    }

    // MARK: The header

    private var header: some View {
        HStack(spacing: Spacing.base) {
            Button {
                model.openInboxChannel(group.channelID)
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
                                Image(systemName: symbolName)
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
        switch tab {
        case .unreads, .mentions:
            Button {
                model.markInboxGroupRead(group.channelID)
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

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            Button {
                open()
            } label: {
                body(of: row)
                    .frame(width: InboxFlyout.cardWidth, alignment: .leading)
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
                .frame(width: InboxFlyout.cardWidth, height: card.height)
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
        if let dueAt = row.dueAt {
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
                action("Dismiss", systemImage: "checkmark") {
                    model.dismissMention(row.id)
                }
            case .bookmarks, .reminders:
                action("Remove", systemImage: "xmark") {
                    model.removeSavedMessage(row.id, in: row.channelID)
                }
            case .scheduled:
                action("Cancel", systemImage: "xmark") {
                    model.cancelScheduledMessage(row.id)
                }
            case .unreads:
                // Marking read is the group's act, not the message's — Discord
                // has no per-message read cursor.
                Color.clear
            }
        }
        .frame(width: 24, height: 24)
        .opacity(isHovering ? 1 : 0)
        .animation(motion.fadeQuick, value: isHovering)
        // Hidden from the pointer as well as from the eye, so an invisible
        // button cannot be clicked by somebody who guessed where it was.
        .allowsHitTesting(isHovering)
    }

    private func action(
        _ title: String,
        systemImage: String,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Image(systemName: systemImage)
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
