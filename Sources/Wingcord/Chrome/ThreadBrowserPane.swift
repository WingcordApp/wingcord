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

    private static let width: CGFloat = 380
    private static let maximumHeight: CGFloat = 460

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
        .frame(maxHeight: Self.maximumHeight)
        .animation(motion.standard, value: presentation.rows.count)
        // The popover supplies the material; this must not add a second.
        .presentationBackground(.clear)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text("Threads")
                .font(.system(.headline))
                .foregroundStyle(Ink.primary)

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
            notice(
                presentation.isFiltered
                    ? "Could not search this channel's threads."
                    : "Could not load this channel's threads.",
                symbolName: "exclamationmark.triangle"
            )
        } else {
            notice(
                presentation.isFiltered
                    ? "No thread here matches that."
                    : "No threads here yet. Start one from a message's menu and it will show up.",
                symbolName: presentation.isFiltered ? "magnifyingglass" : "text.bubble"
            )
        }
    }

    private func list(_ presentation: ThreadBrowserPresentation) -> some View {
        ScrollView {
            LazyVStack(spacing: Spacing.tight) {
                ForEach(presentation.rows) { row in
                    ThreadBrowserRowView(row: row) {
                        model.closeThreadBrowser()
                        model.openThread(row.id)
                    }
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
            Image(systemName: symbolName)
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
            TextField("Search for a thread", text: $text)
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
        // A field never moves, so it catches no travelling specular highlight —
        // the still-life edge is what stops it reading as a slightly lighter
        // region on a near-black ground.
        .specularEdge(in: Capsule())
    }
}

/// One thread, as the flyout shows it.
private struct ThreadBrowserRowView: View {
    var row: ThreadBrowserRow
    var open: () -> Void

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
                    ThreadFaceStack(faces: row.faces, badge: row.memberBadge)
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
        Image(systemName: symbol)
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

/// The overlapping faces, and how many are not shown.
private struct ThreadFaceStack: View {
    var faces: [ThreadBrowserFace]
    var badge: String?

    /// How far each face is pulled onto the one before it. A third of the side:
    /// enough that they read as a group rather than a row, and not so much that
    /// a face becomes a sliver.
    private static let overlap = Metrics.avatarInline / 3

    var body: some View {
        HStack(spacing: Spacing.tight) {
            if !faces.isEmpty {
                HStack(spacing: -Self.overlap) {
                    ForEach(faces) { face in
                        AvatarView(
                            url: face.url,
                            monogram: face.monogram,
                            side: Metrics.avatarInline
                        )
                        // A ring in the row's own ground, so the faces read as
                        // stacked rather than as one smeared shape. Drawn as a
                        // stroke inside the circle rather than as a larger
                        // circle behind it, which would change the layout size.
                        .overlay {
                            Circle().strokeBorder(Palette.surface, lineWidth: 1.5)
                        }
                    }
                }
            }
            if let badge {
                Text(badge)
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                    .padding(.horizontal, Spacing.base)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.07), in: .capsule)
            }
        }
        .accessibilityHidden(true)
    }
}
