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
    var setSearch: (String) -> Void
    var clearSearch: () -> Void

    var body: some View { board }

    private var board: some View {
        ScrollView {
            LazyVStack(spacing: Spacing.snug) {
                if let guidelines = presentation.guidelines {
                    ForumGuidelines(text: guidelines)
                }

                // **Two layouts, two containers.** A gallery is not a list with
                // the pictures taken out — which is all it was, and it made the
                // control read as broken. It is a grid whose cards lead with the
                // picture, so it needs its own container rather than a flag on a
                // row.
                switch presentation.query.layout {
                case .list: rows
                case .gallery: grid
                }

                footer
            }
            .padding(.horizontal, Spacing.margin)
            .padding(.bottom, Spacing.group)
        }
        .scrollBounceBehavior(.always)
        // **The board opens at its newest post, and stays there.**
        //
        // Two things were moving it. A page of twenty-five rows was inserted
        // under `.animation(_:value:)` on the row count, so SwiftUI animated a
        // bulk insert inside a `LazyVStack` and the scroll offset drifted with
        // it — the board opened partway down, on posts a fortnight old. And
        // when content grows, a scroll view with no stated anchor is free to
        // keep whatever offset it had. A page arriving is not a gesture and
        // owes no animation; the anchor says where the list belongs.
        .defaultScrollAnchor(.top)
        .softScrollEdgesVertical()
        // **No `ignoresSafeArea` here, and its absence is the fix for a real
        // bug.** With it, the scroll view extended under the titlebar and the
        // first posts were hidden behind the bar — the board looked like it had
        // opened halfway down the list. Worse, the height the bar was padded by
        // was measured on *this* view, which ignored the inset and therefore
        // reported zero: §2's rule, "a reader that ignores an inset has already
        // been handed the region the inset describes". `safeAreaBar` composes
        // with the window's own safe area on its own; nothing here has to
        // measure anything.
        //
        // `safeAreaBar`, not `safeAreaInset`: the filter row registers as a bar,
        // which is what the scroll edge effect keys off. Without it the cards
        // slide under the chrome sharp and unreadable.
        .floatingTopBar {
            ForumFilterBar(
                presentation: presentation,
                setQuery: setQuery,
                newPost: newPost,
                setSearch: setSearch,
                clearSearch: clearSearch
            )
        }
    }

    private var rows: some View {
        ForEach(presentation.posts) { post in
            ForumPostRow(post: post) { open(post.id) }
                // **The batch is driven from the row appearing**, which is the
                // only signal that says which posts are about to be drawn. The
                // store filters out anything already asked for, so a list
                // scrolled up and down does not re-request — see
                // `requestForumPostDetails`.
                .onAppear { reveal([post.id]) }
        }
    }

    /// The gallery.
    ///
    /// `.adaptive` rather than a fixed column count: the board's width is the
    /// window's minus whatever columns are open beside it, and a count chosen
    /// here would be wrong the moment somebody opens a post or the roster.
    private var grid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Metrics.forumCardMinimum), spacing: Spacing.snug)],
            spacing: Spacing.snug
        ) {
            ForEach(presentation.posts) { post in
                ForumPostCard(post: post) { open(post.id) }
                    .onAppear { reveal([post.id]) }
            }
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
            ForumEmptyState(
                isSearching: presentation.isSearching,
                hasFilter: !presentation.query.tags.isEmpty
            )
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
    var open: () -> Void

    @State private var isHovering = false
    @Environment(\.motion) private var motion

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.post == rhs.post }

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

                if let url = post.thumbnailURL {
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

// MARK: - One post, as a card

/// A post in the gallery.
///
/// **The picture leads, and the tags ride on it.** That is the whole difference
/// from a row: a gallery exists to be scanned by image, so the picture takes the
/// card's width and the tags sit over its foot where they cost no vertical space.
/// A post with no picture is not a broken card — the opening line fills the same
/// block, so the grid stays even.
private struct ForumPostCard: View, Equatable {
    var post: ForumPostPresentation
    var open: () -> Void

    @State private var isHovering = false
    @Environment(\.motion) private var motion

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.post == rhs.post }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                byline
                title
                artwork
                footer
            }
            .padding(Spacing.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface.opacity(isHovering ? 0.9 : 0.55), in: card)
            .overlay {
                card.strokeBorder(Color.white.opacity(isHovering ? 0.10 : 0.05), lineWidth: 1)
            }
            .animation(motion.hover, value: isHovering)
            .contentShape(card)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(.isButton)
    }

    private var card: RoundedRectangle { .rect(cornerRadius: Radius.glass) }

    /// Who posted it and when it was *made* — not when it was last answered,
    /// which is what a list row says. See `ForumPostPresentation.postedAt`.
    private var byline: some View {
        HStack(spacing: Spacing.tight) {
            if post.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(.caption2))
                    .foregroundStyle(Ink.tertiary)
            }
            Text(post.authorName)
                .foregroundStyle(post.authorColorValue.map(Color.init(hex:)) ?? InkColor.secondary)
                .lineLimit(1)
            Text("Posted \(RelativeTime.compact(post.postedAt)) ago")
                .foregroundStyle(Ink.quaternary)
                .lineLimit(1)
        }
        .font(.system(.caption, weight: .medium))
    }

    private var title: some View {
        Text(post.title)
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(Ink.primary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var artwork: some View {
        ZStack(alignment: .bottomLeading) {
            if let url = post.thumbnailURL {
                RemoteImage(url: url, side: Metrics.forumCardArtHeight * 2) { Color.clear }
                    .frame(maxWidth: .infinity)
                    .frame(height: Metrics.forumCardArtHeight)
                    // `.fill`, so a wide screenshot and a tall one both fill the
                    // block and the grid's rows stay level.
                    .clipped()
                    .background(Palette.surfaceRaised)
            } else {
                // The opening line takes the picture's place rather than the
                // card collapsing — a grid of cards at two different heights
                // reads as a rendering fault.
                Text(post.preview)
                    .font(.system(.caption))
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(height: Metrics.forumCardArtHeight, alignment: .topLeading)
                    .padding(Spacing.base)
                    .background(Palette.surfaceRaised)
            }

            if !post.tags.isEmpty {
                ForumTagRow(tags: post.tags)
                    .padding(Spacing.base)
            }
        }
        .clipShape(.rect(cornerRadius: Radius.row))
    }

    private var footer: some View {
        HStack(spacing: Spacing.base) {
            Label {
                Text(post.messageCount, format: .number)
            } icon: {
                Image(systemName: "bubble.left.fill")
            }
            .font(.system(.caption, weight: .medium))
            .foregroundStyle(Ink.tertiary)
            .labelStyle(.titleAndIcon)

            Spacer(minLength: 0)

            if post.isMuted {
                stateGlyph("bell.slash.fill")
            }
            if post.isFollowed {
                stateGlyph("checkmark.circle.fill")
            }
            if post.isLocked {
                stateGlyph("lock.fill")
            }
            if post.isArchived {
                stateGlyph("archivebox.fill")
            }
            AvatarView(url: post.avatarURL, monogram: post.monogram, side: Metrics.avatarInline)
        }
    }

    private func stateGlyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(.caption2))
            .foregroundStyle(Ink.quaternary)
            .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        var parts: [String] = [post.title]
        if !post.tags.isEmpty { parts.append(post.tags.map(\.name).joined(separator: ", ")) }
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
    var setSearch: (String) -> Void
    var clearSearch: () -> Void

    @State private var isSortOpen = false
    @State private var isTagListOpen = false

    /// How many tags stand in the bar before the rest go behind "All".
    ///
    /// **Five, and a scroller is the wrong answer.** A horizontal scroll view
    /// inside a bar steals the trackpad gesture from the list it floats over,
    /// and a forum with twelve tags put every one of them in the bar — which is
    /// what a reader reported. Discord shows five and a chip; so does this.
    private static let inlineTagLimit = 5

    var body: some View {
        VStack(spacing: Spacing.base) {
            HStack(spacing: Spacing.base) {
                ForumSearchField(
                    text: presentation.searchText,
                    setText: setSearch,
                    clear: clearSearch
                )
                // **Only where the reader may actually post.** Absent rather
                // than disabled: a greyed New Post in a read-only forum is an
                // invitation that can only be refused — §5.5.
                if presentation.canPost {
                    newPostButton
                }
            }

            HStack(spacing: Spacing.base) {
                sortAndView
                if !presentation.availableTags.isEmpty {
                    Divider().frame(height: 16)
                    tagFilters
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.vertical, Spacing.base)
    }

    /// The tags, and the chip that holds the rest.
    private var tagFilters: some View {
        let inline = presentation.availableTags.prefix(Self.inlineTagLimit)
        let overflows = presentation.availableTags.count > Self.inlineTagLimit
        return HStack(spacing: Spacing.base) {
            ForEach(inline) { tag in
                tagButton(tag)
            }
            if overflows {
                allTagsButton
            }
        }
    }

    private func tagButton(_ tag: ForumTag) -> some View {
        let isOn = presentation.query.tags.contains(tag.id)
        return Button {
            var query = presentation.query
            // A chip toggles rather than replaces: filtering by two tags is the
            // whole reason `tag_setting` exists.
            if isOn { query.tags.remove(tag.id) } else { query.tags.insert(tag.id) }
            setQuery(query)
        } label: {
            ForumTagChip(tag: tag, isOn: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    private var allTagsButton: some View {
        Button {
            isTagListOpen = true
        } label: {
            HStack(spacing: Spacing.tight) {
                Text("All")
                // The count of tags the reader has lit, including any that are
                // behind this chip rather than in the bar — which is the whole
                // reason it carries a number.
                if !presentation.query.tags.isEmpty {
                    Text(presentation.query.tags.count, format: .number)
                        .font(.system(.caption2, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 15)
                        .padding(.vertical, 1)
                        .background(Palette.accent, in: .capsule)
                }
                Image(systemName: isTagListOpen ? "chevron.up" : "chevron.down")
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
        .popover(isPresented: $isTagListOpen, arrowEdge: .bottom) {
            ForumTagList(
                tags: presentation.availableTags,
                selected: presentation.query.tags,
                toggle: { id in
                    var query = presentation.query
                    if query.tags.contains(id) { query.tags.remove(id) } else { query.tags.insert(id) }
                    setQuery(query)
                },
                clear: {
                    var query = presentation.query
                    query.tags = []
                    setQuery(query)
                }
            )
            .presentationBackground(.clear)
        }
        .accessibilityLabel(Text("All tags"))
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

}

/// The full tag set, behind the "All" chip.
private struct ForumTagList: View {
    var tags: [ForumTag]
    var selected: Set<ForumTagID>
    var toggle: (ForumTagID) -> Void
    var clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            HStack(spacing: Spacing.base) {
                Text("Select Tags")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                Text(selected.count, format: .number)
                    .font(.system(.caption2, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 16)
                    .padding(.vertical, 2)
                    .background(
                        selected.isEmpty ? AnyShapeStyle(Color.white.opacity(0.2))
                            : AnyShapeStyle(Palette.accent),
                        in: .capsule
                    )
            }

            FlowLayout(spacing: Spacing.base) {
                ForEach(tags) { tag in
                    Button { toggle(tag.id) } label: {
                        ForumTagChip(tag: tag, isOn: selected.contains(tag.id))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(
                        selected.contains(tag.id) ? [.isButton, .isSelected] : .isButton
                    )
                }
            }

            Divider()
            Button("Clear all", action: clear)
                .buttonStyle(.plain)
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(selected.isEmpty ? AnyShapeStyle(Ink.quaternary) : AnyShapeStyle(Palette.accent))
                .disabled(selected.isEmpty)
        }
        .padding(Spacing.margin)
        .frame(width: 300)
        // A flyout over the board counts as being over content — §4 — so it is
        // clear glass with the shared tint, never `.regular`.
        .chromeOverMedia(tinted: Palette.flyoutTint, in: .rect(cornerRadius: Radius.card))
    }
}

/// The board's own search field.
///
/// **A request, not a filter** — the same route the Threads flyout uses, and
/// captured on a forum too: `forums search.har` sends
/// `?name=test&tag_setting=match_some` at a forum channel. So it searches the
/// whole forum, not the pages loaded.
private struct ForumSearchField: View {
    var text: String
    var setText: (String) -> Void
    var clear: () -> Void

    var body: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: "magnifyingglass")
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(Ink.tertiary)
            TextField(
                "Search posts",
                text: Binding(get: { text }, set: setText)
            )
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
        .frame(height: Metrics.control + Spacing.tight)
        .frame(maxWidth: .infinity)
        .background(Palette.surfaceRaised, in: .capsule)
        // A field never moves, so it catches no travelling specular highlight —
        // the still-life edge is what stops it reading as a slightly lighter
        // region on a near-black ground.
        .specularEdge(in: Capsule())
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
    var isSearching: Bool
    var hasFilter: Bool

    var body: some View {
        VStack(spacing: Spacing.base) {
            Image(systemName: symbolName)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Ink.quaternary)
            Text(title)
                .font(.system(.headline))
                .foregroundStyle(Ink.secondary)
            Text(detail)
                .font(.system(.caption))
                .foregroundStyle(Ink.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.section)
    }

    // A search that found nothing and a tag filter that matched nothing are
    // different situations with different ways out, so they say different
    // things. The search is named first: it is the more recent act.
    private var symbolName: String {
        if isSearching { return "magnifyingglass" }
        return hasFilter ? "line.3.horizontal.decrease.circle" : "bubble.left.and.bubble.right"
    }

    private var title: String {
        if isSearching { return "No posts match that" }
        return hasFilter ? "No posts match those tags" : "No posts yet"
    }

    private var detail: String {
        if isSearching { return "Try a shorter phrase." }
        return hasFilter ? "Try turning one off." : "Be the first to start one."
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
            newPost: { model.beginForumPost(in: channelID) },
            setSearch: { model.setThreadSearch($0, in: channelID) },
            clearSearch: { model.clearThreadSearch() }
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
            // A search belongs to the forum it was typed in. Carried across, it
            // would show one forum's hits under another's name.
            model.clearThreadSearch()
            model.openForum(id)
        }
    }
}
