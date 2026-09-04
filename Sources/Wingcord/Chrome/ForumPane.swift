import SwiftUI
import WingcordCore

// MARK: - A forum, as a board of posts
//
// **The reading surface, with one glass bar over it.** A board is content the
// reader is reading, not a page about the server — so the ground is opaque and
// the only floating thing is the bar carrying the filter controls, exactly as
// the transcript's only floating thing is the composer.
//
// The cards are `.ultraThinMaterial` structure rather than glass, and that is
// not a stylistic choice: §4 forbids `.interactive()` glass on a row in a
// scrolling list, because the cursor stands still while the row slides under it
// and the displacement is recomputed every frame — the card visibly wobbles.
// Glass floats; a list of posts sits.

struct ForumPane: View {
    var presentation: ForumPresentation
    var open: (ChannelID) -> Void
    var setQuery: (ForumQuery) -> Void
    var loadMore: () -> Void
    var reveal: ([ChannelID]) -> Void
    var newPost: () -> Void

    @Environment(\.motion) private var motion
    @State private var chromeHeight: CGFloat = 0

    var body: some View {
        board
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: {
                chromeHeight = $0
            }
    }

    private var board: some View {
        ScrollView {
            LazyVStack(spacing: Spacing.snug) {
                if let guidelines = presentation.guidelines {
                    ForumGuidelines(text: guidelines)
                }

                ForEach(presentation.posts) { post in
                    ForumPostRow(post: post, layout: presentation.query.layout) {
                        open(post.id)
                    }
                    // **The batch is driven from the row appearing**, which is
                    // the only signal that says which posts are about to be
                    // drawn. The store filters out anything already asked for,
                    // so a list scrolled up and down does not re-request — see
                    // `requestForumPostDetails`.
                    .onAppear { reveal([post.id]) }
                }
                .animation(motion.standard, value: presentation.posts.count)

                footer
            }
            .padding(.horizontal, Spacing.margin)
            .padding(.bottom, Spacing.group)
        }
        .scrollBounceBehavior(.always)
        .softScrollEdgesVertical()
        .ignoresSafeArea(.container, edges: .top)
        // `safeAreaBar`, not `safeAreaInset`: the filter row registers as a bar,
        // which is what the scroll edge effect keys off. Without it the cards
        // slide under the chrome sharp and unreadable.
        .floatingTopBar {
            ForumFilterBar(
                presentation: presentation,
                setQuery: setQuery,
                newPost: newPost
            )
            .padding(.top, chromeHeight)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if presentation.loadFailed {
            ForumRetryRow(retry: loadMore)
        } else if presentation.hasMore {
            // The sentinel *is* the trigger. A "load more" button on an infinite
            // list is a control the reader has to find in order to keep reading.
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.margin)
                .onAppear(perform: loadMore)
        } else if presentation.posts.isEmpty, !presentation.isLoading {
            ForumEmptyState(hasFilter: !presentation.query.tags.isEmpty)
        } else if !presentation.posts.isEmpty {
            Text("^[\(presentation.totalResults) post](inflect: true)")
                .font(.system(.caption))
                .foregroundStyle(Ink.quaternary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.margin)
        }
    }
}

// MARK: - One post

/// A post as a card.
///
/// `Equatable` over a value snapshot with **no closures in `==`** — a closure is
/// recreated on every parent evaluation and would make the comparison always
/// false, which is the failure mode that makes an `EquatableView` look like it
/// does nothing. §2.
private struct ForumPostRow: View, Equatable {
    var post: ForumPostPresentation
    var layout: ForumLayout
    var open: () -> Void

    @State private var isHovering = false
    @Environment(\.motion) private var motion

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.post == rhs.post && lhs.layout == rhs.layout
    }

    var body: some View {
        Button(action: open) {
            content
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(.isButton)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            if !post.tags.isEmpty {
                ForumTagRow(tags: post.tags)
            }

            HStack(alignment: .top, spacing: Spacing.snug) {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    title
                    if !post.preview.characters.isEmpty {
                        previewLine
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if layout == .list, let url = post.thumbnailURL {
                    RemoteImage(url: url, side: Metrics.forumThumbnail) { Color.clear }
                        .frame(width: Metrics.forumThumbnail, height: Metrics.forumThumbnail)
                        .clipShape(.rect(cornerRadius: Radius.row))
                }
            }

            metadata
        }
        .padding(Spacing.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface.opacity(isHovering ? 0.9 : 0.55), in: card)
        // A hair of white over the fill rather than a border: the same
        // relative-light idea the roster's lift uses, so it survives Reduce
        // Transparency and the system glass-intensity setting.
        .overlay {
            card.strokeBorder(Color.white.opacity(isHovering ? 0.10 : 0.05), lineWidth: 1)
        }
        .animation(motion.hover, value: isHovering)
        .contentShape(card)
    }

    private var card: RoundedRectangle { .rect(cornerRadius: Radius.glass) }

    private var title: some View {
        HStack(spacing: Spacing.tight) {
            if post.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(.caption2))
                    .foregroundStyle(Ink.tertiary)
                    .accessibilityHidden(true)
            }
            Text(post.title)
                .font(.system(.headline, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
    }

    private var previewLine: some View {
        // One attributed string rather than an `HStack` of two labels: the
        // author and the line after it wrap as one paragraph, which an HStack
        // cannot do — it would keep the name on its own line at any narrow
        // width. Composed in the model, not here — §2.
        Text(post.preview)
            .font(.system(.subheadline))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var metadata: some View {
        HStack(spacing: Spacing.base) {
            AvatarView(url: post.avatarURL, monogram: post.monogram, side: Metrics.avatarRow)

            Label {
                Text(post.messageCount, format: .number)
            } icon: {
                Image(systemName: "bubble.left.fill")
            }
            .font(.system(.caption, weight: .medium))
            .foregroundStyle(Ink.tertiary)
            .labelStyle(.titleAndIcon)

            Text(RelativeTime.compact(post.lastActivity))
                .font(.system(.caption))
                .foregroundStyle(Ink.quaternary)

            Spacer(minLength: 0)

            // State, and only where it is true. A row that always draws four
            // slots for badges is a row that is mostly empty boxes.
            if post.isMuted {
                stateGlyph("bell.slash.fill", label: "Muted")
            }
            if post.isFollowed {
                stateGlyph("checkmark.circle.fill", label: "Followed")
            }
            if post.isLocked {
                stateGlyph("lock.fill", label: "Locked")
            }
            if post.isArchived {
                stateGlyph("archivebox.fill", label: "Archived")
            }
        }
    }

    private func stateGlyph(_ symbol: String, label: String) -> some View {
        Image(systemName: symbol)
            .font(.system(.caption2))
            .foregroundStyle(Ink.quaternary)
            .help(label)
            .accessibilityHidden(true)
    }

    /// One node with a plain `String` label.
    ///
    /// **Not `.combine`** — that still has to resolve each descendant in order
    /// to merge it, and the accessibility tree is live whether or not VoiceOver
    /// is running. §2.
    private var accessibilityLabel: String {
        var parts: [String] = [post.title]
        if !post.tags.isEmpty {
            parts.append(post.tags.map(\.name).joined(separator: ", "))
        }
        if !post.authorName.isEmpty { parts.append("by \(post.authorName)") }
        parts.append("\(post.messageCount) messages")
        if post.isArchived { parts.append("archived") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Tags

private struct ForumTagRow: View {
    var tags: [ForumTag]

    var body: some View {
        // Wrapping rather than scrolling: five tags at a narrow width is two
        // lines, and a horizontal scroller inside a vertical list steals the
        // trackpad gesture from the list it is in.
        FlowLayout(spacing: Spacing.tight) {
            ForEach(tags) { tag in
                ForumTagChip(tag: tag, isOn: false, isCompact: true)
            }
        }
    }
}

/// One tag chip, in a post's row or in the filter bar.
struct ForumTagChip: View {
    var tag: ForumTag
    var isOn: Bool
    var isCompact = false

    var body: some View {
        HStack(spacing: Spacing.tight) {
            if let emoji = tag.emoji {
                ExpressionGlyph(emoji: emoji, side: isCompact ? 12 : 14)
            }
            Text(tag.name)
                .font(.system(isCompact ? .caption2 : .caption, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(isOn ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Ink.secondary))
        .padding(.horizontal, Spacing.base)
        .padding(.vertical, isCompact ? 3 : Spacing.tight)
        .background(
            isOn ? Palette.accent.opacity(0.18) : Color.white.opacity(0.07),
            in: .capsule
        )
    }
}

// MARK: - The bar

private struct ForumFilterBar: View {
    var presentation: ForumPresentation
    var setQuery: (ForumQuery) -> Void
    var newPost: () -> Void

    @State private var isSortOpen = false

    var body: some View {
        HStack(spacing: Spacing.base) {
            sortAndView
            if !presentation.availableTags.isEmpty {
                Divider().frame(height: 16)
                tagFilters
            }
            // **Only where the reader may actually post.** Absent rather than
            // disabled: a greyed New Post in a read-only forum is an invitation
            // that can only be refused — §5.5.
            if presentation.canPost {
                newPostButton
            }
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.vertical, Spacing.base)
    }

    private var newPostButton: some View {
        Button(action: newPost) {
            HStack(spacing: Spacing.tight) {
                Image(systemName: "square.and.pencil")
                Text("New Post")
            }
            .font(.system(.caption, weight: .semibold))
            .padding(.horizontal, Spacing.snug)
            .frame(height: Metrics.compactControl)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        // The one emphasised control on this surface. A bar where three things
        // are tinted has no emphasis at all — §4.
        .emphasisChrome(Palette.accent)
        .accessibilityLabel(Text("New post"))
    }

    private var sortAndView: some View {
        Button {
            isSortOpen = true
        } label: {
            HStack(spacing: Spacing.tight) {
                Image(systemName: "arrow.up.arrow.down")
                Text("Sort & View")
                Image(systemName: "chevron.down")
                    .font(.system(.caption2, weight: .semibold))
            }
            .font(.system(.caption, weight: .medium))
            .foregroundStyle(Ink.secondary)
            .padding(.horizontal, Spacing.snug)
            .frame(height: Metrics.compactControl)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .interactiveChrome()
        .popover(isPresented: $isSortOpen, arrowEdge: .bottom) {
            ForumSortMenu(query: presentation.query, setQuery: setQuery)
                // Two materials are never stacked: the popover's own background
                // is cleared so the content's glass is the only one. §4.
                .presentationBackground(.clear)
        }
        .accessibilityLabel(Text("Sort and view options"))
    }

    private var tagFilters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Spacing.base) {
                ForEach(presentation.availableTags) { tag in
                    let isOn = presentation.query.tags.contains(tag.id)
                    Button {
                        var query = presentation.query
                        // A chip toggles rather than replaces: filtering by two
                        // tags is the whole reason `tag_setting` exists.
                        if isOn { query.tags.remove(tag.id) } else { query.tags.insert(tag.id) }
                        setQuery(query)
                    } label: {
                        ForumTagChip(tag: tag, isOn: isOn)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.horizontal, 1)
        }
        .scrollIndicators(.never)
    }
}

// MARK: - Sort & View

private struct ForumSortMenu: View {
    var query: ForumQuery
    var setQuery: (ForumQuery) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.margin) {
            section("Sort by") {
                ForEach(ForumSortOrder.allCases, id: \.self) { order in
                    choice(order.title, isOn: query.sortOrder == order) {
                        var next = query
                        next.sortOrder = order
                        setQuery(next)
                    }
                }
            }
            section("View as") {
                ForEach(ForumLayout.allCases, id: \.self) { layout in
                    choice(layout.title, isOn: query.layout == layout) {
                        var next = query
                        next.layout = layout
                        setQuery(next)
                    }
                }
            }
            section("Tag Matching") {
                ForEach(TagMatching.allCases, id: \.self) { matching in
                    choice(matching.title, isOn: query.tagMatching == matching) {
                        var next = query
                        next.tagMatching = matching
                        setQuery(next)
                    }
                }
            }

            Divider()
            Button("Reset to default") {
                // The layout survives a reset, because it is the one part of the
                // query that is about how the reader wants to look at the board
                // rather than what they asked it for.
                setQuery(ForumQuery(layout: query.layout))
            }
            .buttonStyle(.plain)
            .font(.system(.caption, weight: .medium))
            .foregroundStyle(Ink.secondary)
        }
        .padding(Spacing.margin)
        .frame(width: 220)
        // A flyout over the board counts as being over content — §4 — so it is
        // clear glass with the shared tint, never `.regular`.
        .chromeOverMedia(tinted: Palette.flyoutTint, in: .rect(cornerRadius: Radius.card))
    }

    private func section(
        _ title: String,
        @ViewBuilder _ rows: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text(title)
                .font(.system(.caption2, weight: .semibold))
                .foregroundStyle(Ink.quaternary)
                .textCase(.uppercase)
            rows()
        }
    }

    private func choice(
        _ title: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.base) {
                Text(title)
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.primary)
                Spacer(minLength: Spacing.base)
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .font(.system(.subheadline))
                    .foregroundStyle(isOn ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Ink.quaternary))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - The small states

private struct ForumGuidelines: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(.subheadline))
            .foregroundStyle(Ink.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.snug)
            .background(Color.white.opacity(0.04), in: .rect(cornerRadius: Radius.glass))
    }
}

private struct ForumRetryRow: View {
    var retry: () -> Void

    var body: some View {
        VStack(spacing: Spacing.base) {
            Text("Could not load more posts.")
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
            Button("Try again", action: retry)
                .buttonStyle(.plain)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(Palette.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.group)
    }
}

private struct ForumEmptyState: View {
    var hasFilter: Bool

    var body: some View {
        VStack(spacing: Spacing.base) {
            Image(systemName: hasFilter ? "line.3.horizontal.decrease.circle" : "bubble.left.and.bubble.right")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Ink.quaternary)
            Text(hasFilter ? "No posts match those tags" : "No posts yet")
                .font(.system(.headline))
                .foregroundStyle(Ink.secondary)
            Text(hasFilter ? "Try turning one off." : "Be the first to start one.")
                .font(.system(.caption))
                .foregroundStyle(Ink.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.section)
    }
}

// MARK: - Container

/// Reads the store and hands the board its snapshot.
///
/// One container per surface — §2 — so a message arriving anywhere else cannot
/// invalidate a hundred cards.
struct ForumContainer: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model

    var body: some View {
        ForumPane(
            presentation: model.forumPresentation(for: channelID),
            open: { model.openThread($0) },
            setQuery: { model.setForumQuery($0, in: channelID) },
            loadMore: { model.loadMoreForumPosts(in: channelID) },
            reveal: { model.requestForumPostDetails($0, in: channelID) },
            newPost: { model.beginForumPost(in: channelID) }
        )
        .sheet(
            isPresented: Binding(
                get: { model.composingPostIn == channelID },
                set: { if !$0 { model.cancelForumPost() } }
            )
        ) {
            NewPostSheetContainer(channelID: channelID)
        }
        // `initial: true` rather than `.task`: the pane's identity survives a
        // channel change inside the same surface, and a `.task` keyed on nothing
        // would not run again for the second forum opened.
        .onChange(of: channelID, initial: true) { _, id in
            model.openForum(id)
        }
    }
}
