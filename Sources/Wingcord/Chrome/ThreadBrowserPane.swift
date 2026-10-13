import SwiftUI
import WingcordCore

/// Every thread in a channel.
///
/// **A popover off a real toolbar item**, which is the one place in this app a
/// presentation may be attached inline — §1: the item is chrome, there is one of
/// it, and it is not a row in a list. The same exception `PinnedMessagesPane`
/// lives under, and this follows its shape deliberately: two flyouts hanging off
/// adjacent toolbar items that were laid out differently would read as two
/// unrelated panels.
///
/// Each row goes somewhere: clicking one opens the thread in the panel beside
/// the transcript, which is the whole reason anybody opens this.
struct ThreadBrowserPane: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    /// A right-click on a row. Presented once, at this pane's root — the rule
    /// the window keeps (§2), for a list that lives in a popover of its own and
    /// whose rows' rects are in that popover's space.
    @State private var menuRequest: ThreadOptionsRequest?

    private static let width: CGFloat = 380
    private static let maximumHeight: CGFloat = 460
    /// See the note on the frame below.
    private static let minimumHeight: CGFloat = 280

    var body: some View {
        // Read at the top rather than inside the branches, so a page arriving
        // while the pane is open invalidates this body — a read that happens
        // only on one branch is a dependency only that branch registers.
        let presentation = model.threadBrowserPresentation(for: channelID)

        VStack(alignment: .leading, spacing: 0) {
            header
            content(presentation)
        }
        .frame(width: Self.width)
        // The same reservation the pins pane makes, and for the same reason:
        // AppKit sizes a popover from its content's first layout, and on that
        // pass this is a title and a field over a spinner. Without a floor the
        // flyout opens as a sliver and grows as the page lands.
        // **`alignment: .top`, or the reservation centres what it
        // reserved for.** A frame with a minimum taller than its content
        // centres that content by default, so the title and its notice
        // floated in the middle of the box with empty space above and
        // below. The floor exists to stop the popover opening as a
        // sliver; the alignment is what keeps the content where a
        // header belongs.
        .frame(
            minHeight: Self.minimumHeight,
            maxHeight: Self.maximumHeight,
            alignment: .top
        )
        .animation(motion.standard, value: presentation.rows.count)
        // The popover supplies the material; this must not add a second.
        .presentationBackground(.clear)
        .popover(
            item: $menuRequest,
            attachmentAnchor: .rect(.rect(menuRequest?.anchor ?? .zero)),
            arrowEdge: .trailing
        ) { request in
            ThreadOptionsMenu(threadID: request.threadID, place: .list, close: { menuRequest = nil })
                .environment(model)
                .presentationBackground(.clear)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack {
                Text("Threads")
                    .font(.system(.headline))
                    .foregroundStyle(Ink.primary)
                Spacer(minLength: 0)
                // Discord's toolbar Create, for somebody who may start one.
                if model.canStartThread(in: channelID) {
                    MessageRequestButton(title: "Create", isProminent: true, isBusy: false) {
                        startThread(location: "Thread Browser Toolbar")
                    }
                }
            }

            // Asks the server, debounced. The route searches the whole channel
            // rather than the pages loaded — see `AppModel.setThreadSearch`.
            ThreadSearchField(
                text: Binding(
                    get: { model.threadSearchText },
                    set: { model.setThreadSearch($0, in: channelID) }
                ),
                clear: { model.clearThreadSearch() }
            )
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.top, Spacing.margin)
        .padding(.bottom, Spacing.snug)
    }

    /// **Rows win.** A failure or a spinner only replaces the list when there is
    /// no list — a page that failed underneath a hundred loaded rows must not
    /// blank them, and a search in flight must not blank the results already on
    /// screen either.
    @ViewBuilder
    private func content(_ presentation: ThreadBrowserPresentation) -> some View {
        if !presentation.rows.isEmpty {
            list(presentation)
        } else if presentation.isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.group)
        } else if presentation.loadFailed {
            notice("Something went wrong.", symbolName: "exclamationmark.triangle")
        } else {
            emptyState
        }
    }

    /// Discord's empty popout (`k`), for a channel with no threads and a
    /// search that found none alike: the glyph, "There are no threads.", what
    /// a thread is for, and Create Thread for somebody who may start one.
    private var emptyState: some View {
        VStack(spacing: Spacing.base) {
            Image(symbol: DiscordGlyph.thread)
                .font(.system(size: 36))
                .foregroundStyle(Ink.tertiary)
                .accessibilityHidden(true)
            Text("There are no threads.")
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(Ink.primary)
            Text("Stay focused on a conversation with a thread - a temporary text channel.")
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            // Flat, as everything in a popover is — §4.9.
            if model.canStartThread(in: channelID) {
                MessageRequestButton(title: "Create Thread", isProminent: true, isBusy: false) {
                    startThread(location: "Thread Browser Empty State")
                }
                .padding(.top, Spacing.tight)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.margin)
        .padding(.vertical, Spacing.group)
    }

    /// Discord closes the popout and opens New Thread beside the channel.
    private func startThread(location: String) {
        model.closeThreadBrowser()
        model.startThread(in: channelID, location: location)
    }

    private func list(_ presentation: ThreadBrowserPresentation) -> some View {
        ScrollView {
            LazyVStack(spacing: Spacing.tight) {
                ForEach(presentation.rows) { row in
                    ThreadBrowserRowView(
                        row: row,
                        open: {
                            model.closeThreadBrowser()
                            model.openThread(row.id)
                        },
                        openMenu: { menuRequest = ThreadOptionsRequest(threadID: row.id, anchor: $0) }
                    )
                }

                if presentation.hasMore {
                    // The sentinel *is* the trigger, as it is on the board: a
                    // "load more" button on an infinite list is a control the
                    // reader has to find in order to keep reading.
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.snug)
                        .onAppear { model.loadMoreForumPosts(in: channelID) }
                }
            }
            .padding(.horizontal, Spacing.snug)
            .padding(.bottom, Spacing.snug)
        }
        .scrollBounceBehavior(.basedOnSize)
        .softScrollEdgesVertical()
    }

    private func notice(_ text: String, symbolName: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.snug) {
            Image(symbol: symbolName)
                .font(.system(size: 13))
                .foregroundStyle(Ink.tertiary)
            Text(text)
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.bottom, Spacing.margin)
    }
}

/// The name filter.
///
/// Its own small view so a keystroke invalidates the field rather than the list
/// underneath it — the list is rebuilt by the store write either way, but the
/// focus ring and the glyph are not.
private struct ThreadSearchField: View {
    @Binding var text: String
    var clear: () -> Void

    var body: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: "magnifyingglass")
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(Ink.tertiary)
            TextField("Search for Thread Name", text: $text)
                .textFieldStyle(.plain)
                .font(.system(.subheadline))
            if !text.isEmpty {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(.caption))
                        .foregroundStyle(Ink.tertiary)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear the search"))
            }
        }
        .padding(.horizontal, Spacing.snug)
        .frame(height: Metrics.compactControl)
        .background(Palette.surfaceRaised, in: .capsule)
        // A hairline, so the field has an edge on a dark ground.
        .overlay { Capsule().strokeBorder(Palette.edge) }
    }
}

/// One thread, as the flyout shows it.
private struct ThreadBrowserRowView: View {
    var row: ThreadBrowserRow
    var open: () -> Void
    var openMenu: (CGRect) -> Void

    @Environment(\.motion) private var motion
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: Spacing.snug) {
                VStack(alignment: .leading, spacing: 2) {
                    title
                    subtitle
                }
                Spacer(minLength: Spacing.tight)
                if !row.faces.isEmpty || row.memberBadge != nil {
                    FaceStack(faces: row.faces, badge: row.memberBadge)
                }
            }
            .padding(Spacing.base)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(isHovered ? Palette.hoverFill : .clear)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard hovering != isHovered else { return }
            isHovered = hovering
        }
        .animation(motion.fadeQuick, value: isHovered)
        .onSecondaryClick(inPopover: true, perform: openMenu)
        // One node with a plain label — §2. `.combine` still has to resolve
        // every descendant in order to merge it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(.isButton)
    }

    private var title: some View {
        HStack(spacing: Spacing.tight) {
            if row.isLocked {
                stateGlyph("lock.fill")
            } else if row.isArchived {
                stateGlyph("archivebox.fill")
            }
            Text(row.name)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            if row.isFollowed {
                stateGlyph("checkmark.circle.fill")
            }
        }
    }

    private var subtitle: some View {
        HStack(spacing: Spacing.tight) {
            if let startedBy = row.startedBy {
                Text("Started by \(startedBy)")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("·")
            }
            Text("Last active \(row.lastActive)")
                .lineLimit(1)
        }
        .font(.system(.caption))
        .foregroundStyle(Ink.tertiary)
    }

    private func stateGlyph(_ symbol: String) -> some View {
        Image(symbol: symbol)
            .font(.system(.caption2))
            .foregroundStyle(Ink.quaternary)
            .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        var parts = [row.name]
        if let startedBy = row.startedBy { parts.append("started by \(startedBy)") }
        parts.append("last active \(row.lastActive)")
        if row.isArchived { parts.append("archived") }
        if row.isFollowed { parts.append("followed") }
        return parts.joined(separator: ", ")
    }
}
