import SwiftUI
import WingcordCore

// MARK: - A forum, as a board of posts
//
// **The reading surface, with nothing over it but the toolbar row**, which carries
// every control this page has (`ForumToolbar`). A board is content the reader is
// reading, not a page about the server.
//
// The cards are `.ultraThinMaterial` structure rather than glass, and that is
// not a stylistic choice: §4 forbids `.interactive()` glass on a row in a
// scrolling list, because the cursor stands still while the row slides under it
// and the displacement is recomputed every frame — the card visibly wobbles.
// Glass floats; a list of posts sits.

struct ForumPane: View {
    var presentation: ForumPresentation
    var open: (ChannelID) -> Void
    /// A right-click on a post: its own menu, `ThreadOptionsMenu`.
    var openMenu: (ChannelID, CGRect) -> Void
    var loadMore: () -> Void
    var reveal: ([ChannelID]) -> Void
    var newPost: () -> Void
    var newPostTitled: (String) -> Void
    var clearSearch: () -> Void
    /// A click on a row's reaction.
    var react: (ChannelID, ForumPostReaction) -> Void
    /// "N New Posts": what's waiting comes in, and the order is made fresh.
    var showNewPosts: () -> Void

    /// The board's width, for the gallery's column count. Moves on a resize,
    /// never on a scroll.
    @State private var boardWidth: CGFloat = 0
    @State private var scrollPosition = ScrollPosition(edge: .top)
    /// How far down the header reaches. Read from the safe area outside the part
    /// that runs under it, as a transcript's is.
    @State private var chromeHeight: CGFloat = 0
    @Environment(\.motion) private var motion

    var body: some View {
        board
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { chromeHeight = $0 }
            // A board stays where it was left only within one forum.
            .onChange(of: presentation.channelID) { scrollPosition.scrollTo(edge: .top) }
            .overlay(alignment: .top) {
                // **The animation is the pill's alone.** On the board it would take in
                // the rows the pill's press brings, and a bulk insert under an
                // animation is what `defaultScrollAnchor` below is there for.
                ZStack {
                    if presentation.newPostCount > 0 {
                        ForumNewPostsPill(count: presentation.newPostCount, action: showWaitingPosts)
                            .padding(.top, Spacing.base)
                            .transition(.materialize(from: .top, blurring: false))
                    }
                }
                .animation(motion.standard, value: presentation.newPostCount > 0)
            }
    }

    private func showWaitingPosts() {
        showNewPosts()
        withAnimation(motion.standard) { scrollPosition.scrollTo(edge: .top) }
    }

    private var board: some View {
        ScrollView {
            LazyVStack(spacing: Spacing.snug) {
                if presentation.isSearching {
                    ForumSearchSummary(
                        isSearching: presentation.isLoading,
                        count: presentation.posts.count,
                        phrase: presentation.searchText.trimmingCharacters(in: .whitespacesAndNewlines),
                        canPost: presentation.canPost,
                        clear: clearSearch,
                        newPostTitled: newPostTitled
                    )
                }

                section(presentation.posts)

                // Discord's "Older Posts", over the archived pages — and only
                // under live posts, where it divides something.
                if !presentation.olderPosts.isEmpty {
                    if !presentation.posts.isEmpty { ForumOlderPostsDivider() }
                    section(presentation.olderPosts)
                }

                footer
            }
            .padding(.horizontal, Spacing.margin)
            .padding(.bottom, Spacing.group)
        }
        .scrollPosition($scrollPosition)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boardWidth = $0 }
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
        // **Under the header and paying for it as a margin, with the rows dissolving
        // on the way**, as a transcript's do. The tags on the toolbar row are no glass
        // of their own, so a row passing sharp behind them is two lines of text on
        // top of each other. There's no toolbar for a system edge effect to key off.
        // The margin is what stops the first post starting behind the header.
        .contentMargins(.top, chromeHeight + ForumTopFade.settle, for: .scrollContent)
        .contentMargins(.top, chromeHeight, for: .scrollIndicators)
        .mask { ForumTopFade(chromeHeight: chromeHeight) }
        .ignoresSafeArea(.container, edges: .top)
    }

    /// **Two layouts, two containers.** A gallery is not a list with the
    /// pictures taken out — which is all it was, and it made the control read
    /// as broken. It is a grid whose cards lead with the picture, so it needs
    /// its own container rather than a flag on a row.
    @ViewBuilder
    private func section(_ posts: [ForumPostPresentation]) -> some View {
        switch presentation.query.layout {
        case .list: rows(posts)
        case .gallery: grid(posts)
        }
    }

    private func rows(_ posts: [ForumPostPresentation]) -> some View {
        ForEach(posts) { post in
            ForumPostRow(
                post: post,
                showsThumbnail: boardWidth == 0 || boardWidth >= ForumPostRow.thumbnailBoardWidth,
                open: { open(post.id) },
                openMenu: { openMenu(post.id, $0) },
                react: { react(post.id, $0) }
            )
                // **The batch is driven from the row appearing**, which is the
                // only signal that says which posts are about to be drawn. The
                // store filters out anything already asked for, so a list
                // scrolled up and down does not re-request — see
                // `requestForumPostDetails`.
                .onAppear { reveal([post.id]) }
        }
    }

    /// The gallery, in Discord's columns — see `ForumGallery`. Counted from
    /// the board's own width, which is the window's minus whatever columns are
    /// open beside it.
    private func grid(_ posts: [ForumPostPresentation]) -> some View {
        let columns = ForumGallery.columns(forWidth: boardWidth - 2 * Spacing.margin)
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: ForumGallery.gap), count: columns),
            spacing: ForumGallery.gap
        ) {
            ForEach(posts) { post in
                ForumGalleryCard(
                    post: post,
                    artRatio: presentation.isMedia ? 9.0 / 16 : 2.0 / 3,
                    open: { open(post.id) },
                    openMenu: { openMenu(post.id, $0) },
                    react: { react(post.id, $0) }
                )
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
        } else if presentation.posts.isEmpty, presentation.olderPosts.isEmpty,
                  !presentation.isLoading, !presentation.isSearching
        {
            // A search that found nothing says so in its own line above.
            ForumEmptyState(
                channelName: presentation.name,
                filterCount: presentation.query.tags.count,
                canPost: presentation.canPost,
                newPost: newPost
            )
        }
    }
}

/// The mask that dissolves the board under the header.
///
/// **Not `TranscriptTopFade`**, whose ramp reaches well past the header: a transcript
/// has a welcome at its head to fade, and a board's first post would open half gone.
/// This one is whole just below the row, and gone by the middle of its controls.
private struct ForumTopFade: View {
    var chromeHeight: CGFloat

    /// How far below the header the rows are whole, and so where the first one opens.
    static let settle: CGFloat = 6
    /// How far the ramp runs above that.
    private static let ramp: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: max(0, chromeHeight + Self.settle - Self.ramp))
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white.opacity(0.25), location: 0.42),
                    .init(color: .white, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Self.ramp)
            Color.white
        }
        .allowsHitTesting(false)
    }
}

// MARK: - One post

/// A post as a card.
///
/// `Equatable` over a value snapshot with **no closures in `==`** — a closure is
/// recreated on every parent evaluation and would make the comparison always
/// false, which is the failure mode that makes an `EquatableView` look like it
/// does nothing. §2.
struct ForumPostRow: View, Equatable {
    /// How wide the board has to be for a row to keep its picture. Beside a post
    /// in a small window it's a couple of hundred points, and a row holding its
    /// counts and a picture was wider than that: it spilled out of both sides.
    static let thumbnailBoardWidth: CGFloat = 360

    var post: ForumPostPresentation
    var showsThumbnail = true
    var open: () -> Void
    var openMenu: (CGRect) -> Void
    var react: (ForumPostReaction) -> Void = { _ in }

    @State private var isHovering = false
    @Environment(\.motion) private var motion

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.post == rhs.post && lhs.showsThumbnail == rhs.showsThumbnail
    }

    var body: some View {
        Button(action: open) {
            content
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .onSecondaryClick(perform: openMenu)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(.isButton)
        .forumReactionAction(post.reaction, react: react)
    }

    private var content: some View {
        // The picture beside all of it, as Discord's is: under the words it would
        // leave a gap at every row whose title is one line long.
        HStack(alignment: .center, spacing: Spacing.snug) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                if post.isPinned || !post.tags.isEmpty {
                    ForumPostTagRow(post: post)
                }

                VStack(alignment: .leading, spacing: Spacing.tight) {
                    title
                    if !post.preview.characters.isEmpty {
                        previewLine
                    }
                }

                metadata
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsThumbnail, let media = post.media.first {
                ForumMediaTile(media: media, side: Metrics.forumThumbnail, marks: .small)
                    .frame(width: Metrics.forumThumbnail, height: Metrics.forumThumbnail)
                    .clipShape(.rect(cornerRadius: Radius.row))
            }
        }
        .padding(Spacing.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface.opacity(isHovering ? 0.9 : 0.55), in: card)
        // A hair of white over the fill rather than a border: the same
        // relative-light idea the roster's lift uses, so it survives Reduce
        // Transparency and the system glass-intensity setting.
        .overlay {
            card.strokeBorder(isHovering ? Palette.hairlineHovered : Palette.hairline, lineWidth: 1)
        }
        .animation(motion.hover, value: isHovering)
        .contentShape(card)
    }

    private var card: RoundedRectangle { .rect(cornerRadius: Radius.glass) }

    /// The title, and Discord's "NEW" after it (`ej`). The pin is the tag
    /// row's now, as Discord's is.
    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
            Text(post.titleText)
                .font(.system(.headline, weight: post.isUnread ? .semibold : .regular))
                .foregroundStyle(Ink.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if post.isNew {
                ForumNewBadge()
            }
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

            if let reaction = post.reaction {
                ForumReactionChip(reaction: reaction, toggle: { react(reaction) })
            }

            ForumMessageCount(count: post.messageCount, unreadWords: post.unreadWords)

            // The first thing to go when there's no room: the counts are what's
            // being scanned for.
            Text(RelativeTime.compact(post.lastActivity))
                .font(.system(.caption))
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
                .layoutPriority(-1)

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
        Image(symbol: symbol)
            .font(.system(.caption2))
            .foregroundStyle(Ink.secondary)
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
        if let unread = post.unreadWords { parts.append("\(unread) new") }
        if let count = post.reaction?.count { parts.append(count == 1 ? "1 reaction" : "\(count) reactions") }
        if post.isArchived { parts.append("archived") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - What a row and a card share

/// The count of a post's messages, and Discord's "(N New)" after it, in the accent's
/// semibold (`ey`). Unread differs in weight and colour, never by paling what's read.
private struct ForumMessageCount: View {
    var count: Int
    var unreadWords: String?

    var body: some View {
        HStack(spacing: Spacing.tight) {
            Label {
                Text(count, format: .number)
            } icon: {
                Image(systemName: "bubble.left.fill")
            }
            .font(.system(.caption, weight: .medium))
            .foregroundStyle(Ink.secondary)
            .labelStyle(.titleAndIcon)
            if let unreadWords {
                Text("(\(unreadWords) New)")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .lineLimit(1)
            }
        }
        .fixedSize()
    }
}

/// The reaction a post's row offers: Discord's `eC` and `eS`. A button of its own
/// inside the row, whose click takes it rather than opening the post.
private struct ForumReactionChip: View {
    var reaction: ForumPostReaction
    var toggle: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.motion) private var motion

    private var shape: RoundedRectangle { .rect(cornerRadius: TimelineMetrics.reactionChipRadius, style: .continuous) }

    private var burst: SuperReactionPalette.Style? {
        reaction.palette.map { colorScheme == .dark ? $0.dark : $0.light }
    }

    private var ink: Color {
        if let burst { return Color(hex: burst.accent) }
        return reaction.isMine ? Palette.accent : InkColor.secondary
    }

    private var fill: Color {
        if let burst { return Color(hex: burst.background).opacity(burst.opacity) }
        return reaction.isMine ? Palette.accent.opacity(0.18) : Palette.hoverFill
    }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Spacing.tight) {
                ExpressionGlyph(emoji: reaction.emoji, side: 14)
                if let count = reaction.count {
                    Text(count, format: .number)
                        .font(.system(.caption, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(ink)
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 6)
            .frame(minWidth: TimelineMetrics.reactionChipHeight)
            .frame(height: TimelineMetrics.reactionChipHeight)
            .background(fill, in: shape)
            .overlay {
                if reaction.isMine { shape.strokeBorder(ink.opacity(0.7), lineWidth: 1) }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(reaction.isReadOnly)
        .fixedSize()
        .animation(motion.standard, value: reaction.count)
    }
}

extension View {
    /// What the chip does, for somebody who can't reach it: the row is one element.
    /// The same view whether there's a reaction or not, so a post gaining its first
    /// doesn't become a new row.
    fileprivate func forumReactionAction(
        _ reaction: ForumPostReaction?,
        react: @escaping (ForumPostReaction) -> Void
    ) -> some View {
        accessibilityActions {
            if let reaction, !reaction.isReadOnly {
                Button(reaction.isMine ? "Remove your reaction" : "React") { react(reaction) }
            }
        }
    }
}

/// What's written over a post's picture.
///
/// **A plain fill, not clear glass**, because these are in a scrolling list: glass
/// floats, and a board has a dozen of these moving at once (§4).
private enum ForumMediaInk {
    static let fill = Color.black.opacity(0.5)
}

/// One picture on a board. The whole of the space it's given, whatever the picture's
/// shape, covered if it's a spoiler, and marked if it's a video or a GIF.
private struct ForumMediaTile: View {
    enum Marks { case small, regular }

    var media: ForumPostMedia
    /// The largest side it'll be drawn at, for the decode.
    var side: CGFloat
    var marks: Marks = .regular

    /// A spoiler is decoded small: nothing fine is going to be seen of it, and the
    /// blur over it costs less on fewer pixels.
    private var decodeSide: CGFloat { media.isSpoiler ? min(side, 48) : side }

    var body: some View {
        Color.clear
            .overlay {
                RemoteImage(url: media.url, side: decodeSide) { Palette.surfaceRaised }
                    .scaledToFill()
                    .blur(radius: media.isSpoiler ? (marks == .small ? 8 : 18) : 0, opaque: media.isSpoiler)
                    .overlay {
                        if media.isSpoiler { Color.black.opacity(0.28) }
                    }
            }
            .clipped()
            .overlay {
                if media.isSpoiler {
                    mark("eye.slash.fill", label: "Spoiler")
                } else if media.isVideo {
                    mark("play.fill", label: "Video")
                }
            }
            .overlay(alignment: .topLeading) {
                if media.isAnimated, !media.isSpoiler {
                    Text("GIF")
                        .font(.system(.caption2, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(height: 20)
                        .background(ForumMediaInk.fill, in: .capsule)
                        .padding(Spacing.tight)
                        .accessibilityLabel(Text("GIF"))
                }
            }
    }

    private func mark(_ symbol: String, label: String) -> some View {
        let circle: CGFloat = marks == .small ? 28 : 40
        return Image(systemName: symbol)
            .font(.system(size: circle * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: circle, height: circle)
            .background(ForumMediaInk.fill, in: .circle)
            .accessibilityLabel(Text(label))
    }
}

/// A post's pictures in the gallery: Discord's `lL`. One fills the block, two share
/// it, three are one tall and two stacked, four are two by two, and any more say how
/// many on the last.
private struct ForumMediaMosaic: View {
    var media: [ForumPostMedia]

    private static let gap: CGFloat = 4

    private var shown: [ForumPostMedia] { Array(media.prefix(WingcordCore.ForumPostCard.mosaicLimit)) }
    private var hidden: Int { max(0, media.count - shown.count) }

    var body: some View {
        switch shown.count {
        case 1:
            tile(0, side: ForumGallery.maximumWidth)
        case 2:
            HStack(spacing: Self.gap) {
                tile(0)
                tile(1)
            }
        case 3:
            HStack(spacing: Self.gap) {
                tile(0)
                VStack(spacing: Self.gap) {
                    tile(1)
                    tile(2)
                }
            }
        default:
            VStack(spacing: Self.gap) {
                HStack(spacing: Self.gap) {
                    tile(0)
                    tile(1)
                }
                HStack(spacing: Self.gap) {
                    tile(2)
                    tile(3)
                }
            }
        }
    }

    private func tile(_ index: Int, side: CGFloat = ForumGallery.maximumWidth / 2) -> some View {
        ForumMediaTile(media: shown[index], side: side)
            .overlay(alignment: .bottomTrailing) {
                if index == shown.count - 1, hidden > 0 {
                    Text("+\(hidden)")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, Spacing.base)
                        .frame(height: 26)
                        .background(ForumMediaInk.fill, in: .capsule)
                        .padding(Spacing.tight)
                        .accessibilityLabel(Text("\(hidden) more"))
                }
            }
    }
}

/// "N New Posts": Discord's `sU`, over the top of the list rather than in its head,
/// so it can be seen from anywhere in it.
private struct ForumNewPostsPill: View {
    var count: Int
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.tight) {
                Image(systemName: "arrow.up")
                    .font(.system(.footnote, weight: .bold))
                Text(count == 1 ? "1 New Post" : "\(count) New Posts")
                    .font(.system(.subheadline, weight: .semibold))
                    .contentTransition(.numericText())
            }
            // Solid, because what's under this glass is anybody's picture.
            .foregroundStyle(InkColor.solid)
            .padding(.horizontal, Spacing.margin)
            .frame(height: 36)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .fixedSize()
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
private struct ForumGalleryCard: View, Equatable {
    var post: ForumPostPresentation
    /// The picture block's height to its width: Discord's, ⅔, and 9:16 in a media
    /// channel, so a grid's rows stay level whatever anyone posted.
    var artRatio: CGFloat
    var open: () -> Void
    var openMenu: (CGRect) -> Void
    var react: (ForumPostReaction) -> Void

    @State private var isHovering = false
    @Environment(\.motion) private var motion

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.post == rhs.post && lhs.artRatio == rhs.artRatio }

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
                card.strokeBorder(isHovering ? Palette.hairlineHovered : Palette.hairline, lineWidth: 1)
            }
            .animation(motion.hover, value: isHovering)
            .contentShape(card)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .onSecondaryClick(perform: openMenu)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(.isButton)
        .forumReactionAction(post.reaction, react: react)
    }

    private var card: RoundedRectangle { .rect(cornerRadius: Radius.glass) }

    /// Who posted it and when it was *made* — not when it was last answered,
    /// which is what a list row says. See `ForumPostPresentation.postedAt`.
    ///
    /// Discord's "NEW" rides at its trailing end, as the gallery card's does.
    private var byline: some View {
        HStack(spacing: Spacing.tight) {
            Text(post.authorName)
                .foregroundStyle(post.authorColorValue.map(Color.init(hex:)) ?? InkColor.secondary)
                .lineLimit(1)
            Text(postedWords)
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
            if post.isNew {
                Spacer(minLength: Spacing.tight)
                ForumNewBadge()
            }
        }
        .font(.system(.caption, weight: .medium))
    }

    private var postedWords: String {
        let age = RelativeTime.compact(post.postedAt)
        return age == "now" ? "Posted just now" : "Posted \(age) ago"
    }

    private var title: some View {
        Text(post.titleText)
            .font(.system(.subheadline, weight: post.isUnread ? .semibold : .regular))
            .foregroundStyle(Ink.primary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var artwork: some View {
        // `Color.clear` and a ratio decide the block, whatever's in it: a picture
        // can't stretch the card, and the words can't shrink it.
        Color.clear
            .aspectRatio(1 / artRatio, contentMode: .fit)
            .overlay {
                if post.media.isEmpty {
                    // The opening line takes the picture's place rather than the
                    // card collapsing — a grid of cards at two different heights
                    // reads as a rendering fault.
                    Text(post.openingWords)
                        .font(.system(.subheadline))
                        .foregroundStyle(Ink.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(Spacing.snug)
                        .background(Palette.surfaceRaised)
                } else {
                    ForumMediaMosaic(media: post.media)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if post.isPinned || !post.tags.isEmpty {
                    ForumPostTagRow(post: post, isOverMedia: !post.media.isEmpty)
                        .padding(Spacing.base)
                }
            }
            .clipShape(.rect(cornerRadius: Radius.row))
    }

    private var footer: some View {
        HStack(spacing: Spacing.base) {
            if let reaction = post.reaction {
                ForumReactionChip(reaction: reaction, toggle: { react(reaction) })
            }

            ForumMessageCount(count: post.messageCount, unreadWords: post.unreadWords)

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
        Image(symbol: symbol)
            .font(.system(.caption2))
            .foregroundStyle(Ink.secondary)
            .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        var parts: [String] = [post.title]
        if !post.tags.isEmpty { parts.append(post.tags.map(\.name).joined(separator: ", ")) }
        if !post.authorName.isEmpty { parts.append("by \(post.authorName)") }
        parts.append("\(post.messageCount) messages")
        if let unread = post.unreadWords { parts.append("\(unread) new") }
        if let count = post.reaction?.count { parts.append(count == 1 ? "1 reaction" : "\(count) reactions") }
        if post.isArchived { parts.append("archived") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Tags

/// A post's tag row, as Discord's (`52933`): the pin, then three of its tags —
/// the ones the board's filter lit drawn lit — then "+N" for the rest.
///
/// **Three and a count, not a wrapping list.** Five tags at a narrow width wrap
/// to a second line that every other card then lacks; Discord caps the row and
/// names the rest on hover.
private struct ForumPostTagRow: View {
    var post: ForumPostPresentation
    /// Over a picture, which the row's own pale chips disappear on.
    var isOverMedia = false

    private static let shown = 3

    var body: some View {
        HStack(spacing: Spacing.base) {
            if post.isPinned {
                // Discord's `.pinIcon`: a 22-point circle in the brand colour,
                // the pin white inside it, "Pinned" on hover.
                Image(systemName: "pin.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Palette.accent, in: .circle)
                    .help("Pinned")
                    .accessibilityLabel(Text("Pinned"))
            }
            ForEach(post.tags.prefix(Self.shown)) { tag in
                ForumTagChip(
                    tag: tag, isOn: post.filteredTagIDs.contains(tag.id), isCompact: true, isOverMedia: isOverMedia
                )
            }
            if post.tags.count > Self.shown {
                let rest = post.tags.dropFirst(Self.shown)
                Text("+\(rest.count)")
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(isOverMedia ? AnyShapeStyle(.white) : AnyShapeStyle(Ink.secondary))
                    .padding(.horizontal, Spacing.base)
                    .padding(.vertical, 3)
                    .background(isOverMedia ? ForumMediaInk.fill : Palette.hoverFill, in: .capsule)
                    .help(rest.map(\.name).joined(separator: ", "))
            }
        }
        .frame(height: 24)
    }
}

/// Discord's "NEW" on a post nobody has opened since it arrived — its text
/// badge (`812993`) in `--brand-260` with `--brand-560` lettering, eyebrow
/// type, 20 points tall.
private struct ForumNewBadge: View {
    var body: some View {
        Text("new")
            .textCase(.uppercase)
            .font(.system(.subheadline, weight: .bold))
            .foregroundStyle(Palette.newBadgeInk)
            .padding(.horizontal, Spacing.base)
            .frame(height: 20)
            .background(Palette.newBadgeFill, in: .rect(cornerRadius: 8, style: .continuous))
            .fixedSize()
    }
}

/// Discord's eyebrow over the archived pages.
private struct ForumOlderPostsDivider: View {
    var body: some View {
        Text("Older Posts")
            .textCase(.uppercase)
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(Ink.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 16)
            .padding(.top, Spacing.margin)
            .padding(.bottom, Spacing.base)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The line under the search field while a search is showing (`ix`'s
/// matching-posts row): "Searching...", "No matching posts", or how many
/// posts matched — and Clear.
private struct ForumSearchSummary: View {
    var isSearching: Bool
    var count: Int
    var phrase: String
    var canPost: Bool
    var clear: () -> Void
    /// Discord's one box was both the search and the title of a new post. Here the
    /// two are apart, so a search that found nothing offers the other half.
    var newPostTitled: (String) -> Void

    var body: some View {
        HStack(spacing: Spacing.base) {
            Text(summary)
                .font(.system(.caption))
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
            if !isSearching {
                Button("Clear", action: clear)
                    .buttonStyle(.plain)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(Palette.accent)
            }
            if !isSearching, count == 0, canPost {
                Button("New post titled \u{201C}\(phrase)\u{201D}") { newPostTitled(phrase) }
                    .buttonStyle(.plain)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var summary: String {
        if isSearching { return "Searching..." }
        if count == 0 { return "No matching posts" }
        return count == 1 ? "1 post with \"\(phrase)\"" : "\(count) posts with \"\(phrase)\""
    }
}

/// One tag chip, in a post's row or in the filter bar.
struct ForumTagChip: View {
    var tag: ForumTag
    var isOn: Bool
    var isCompact = false
    var isOverMedia = false

    private var ink: AnyShapeStyle {
        if isOverMedia { return AnyShapeStyle(.white) }
        return isOn ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Ink.secondary)
    }

    private var fill: Color {
        if isOverMedia { return isOn ? Palette.accent : .black.opacity(0.5) }
        return isOn ? Palette.accent.opacity(0.18) : Palette.hoverFill
    }

    var body: some View {
        HStack(spacing: Spacing.tight) {
            if let emoji = tag.emoji {
                ExpressionGlyph(emoji: emoji, side: isCompact ? 12 : 14)
            }
            Text(tag.name)
                .font(.system(isCompact ? .caption2 : .caption, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, Spacing.base)
        .padding(.vertical, isCompact ? 3 : Spacing.tight)
        .background(fill, in: .capsule)
    }
}

// MARK: - The small states

private struct ForumRetryRow: View {
    var retry: () -> Void

    var body: some View {
        VStack(spacing: Spacing.base) {
            Text("Something went wrong.")
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

/// Discord's empty board (`nw`), in its words: "Be the first to start the
/// conversation!" and its question about the channel — or, under a tag filter,
/// that nothing carries those tags yet — and Create a post for somebody who may.
private struct ForumEmptyState: View {
    var channelName: String
    /// How many tags the board is filtered by.
    var filterCount: Int
    var canPost: Bool
    var newPost: () -> Void

    var body: some View {
        VStack(spacing: Spacing.base) {
            Text(title)
                .font(.system(.headline, weight: .semibold))
                .foregroundStyle(Ink.primary)
            Text(detail)
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
            if canPost {
                MessageRequestButton(title: "Create a post", isProminent: false, isBusy: false, action: newPost)
                    .padding(.top, Spacing.tight)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.section)
    }

    private var tagWords: String { filterCount == 1 ? "this tag" : "these tags" }

    private var title: String {
        filterCount > 0 ? "There are no posts with \(tagWords) yet!" : "Be the first to start the conversation!"
    }

    private var detail: String {
        filterCount > 0
            ? "Be the first to start a conversation with \(tagWords)"
            : "What do you want to post about in #\(channelName)?"
    }
}

/// Discord's gallery columns (`a33c78e7986fdb46`'s `sk`): between 320 and 450
/// points wide, 16 apart — as many as the midpoint of what the two bounds
/// would fit.
enum ForumGallery {
    static let minimumWidth: CGFloat = 320
    static let maximumWidth: CGFloat = 450
    static let gap: CGFloat = 16

    static func columns(forWidth width: CGFloat) -> Int {
        guard width > minimumWidth else { return 1 }
        let widest = width / maximumWidth
        return max(Int((widest + (width / minimumWidth - widest) / 2).rounded(.down)), 1)
    }
}

/// "Add media to the original post?": Discord's `R` in `538899`, its words and its
/// three ways out, with the post's row as it'd look. Return adds it to the post.
struct ForumAddMediaCard: View {
    var prompt: ForumAddMediaPrompt

    @Environment(AppModel.self) private var model

    var body: some View {
        ModalAlert(
            title: "Add media to the original post?",
            message: Text("This will add a thumbnail to your post in the list view."),
            actions: [
                ModalAlertAction(title: "Cancel", symbolName: nil, role: .cancel, isEnabled: !prompt.isUploading) {},
                ModalAlertAction(title: "Don't Add", symbolName: nil, role: .secondary, isEnabled: !prompt.isUploading) {
                    prompt.sendAnyway()
                },
                ModalAlertAction(
                    title: "Add to Post", symbolName: nil, role: .act, closes: false, isWorking: prompt.isUploading
                ) {
                    Task { await model.addMediaToPost() }
                },
            ]
        ) {
            VStack(spacing: Spacing.base) {
                if let row = model.forumAddMediaPreview(prompt) {
                    ForumPostRow(post: row, open: {}, openMenu: { _ in })
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                if let failure = prompt.failure {
                    Text(failure)
                        .font(.system(.subheadline))
                        .foregroundStyle(Palette.destructive)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .modalDismissDisabled(prompt.isUploading)
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
    @Environment(\.motion) private var motion
    @State private var isDropTargeted = false

    var body: some View {
        ForumPane(
            presentation: model.forumPresentation(for: channelID),
            open: { model.openThread($0) },
            openMenu: { model.openThreadMenu(for: $0, anchor: $1) },
            loadMore: { model.loadMoreForumPosts(in: channelID) },
            reveal: { model.requestForumPostDetails($0, in: channelID) },
            newPost: { model.beginForumPost(in: channelID) },
            newPostTitled: { model.beginForumPost(in: channelID, title: $0) },
            clearSearch: { model.clearThreadSearch() },
            react: { postID, reaction in
                model.toggleReaction(
                    reaction.emoji,
                    kind: reaction.kind,
                    location: .inlineButton,
                    on: MessageID(rawValue: postID.rawValue),
                    in: postID
                )
            },
            showNewPosts: { model.refreshForumOrder(channelID) }
        )
        // **The whole board takes a drop**, and it opens New Post with the files in
        // it, where Discord's takes one only once its form is open. Written
        // unconditionally, with the permission in the predicate, as a conversation's
        // is: a board that refuses files lights nothing and accepts nothing.
        .dropDestination(for: URL.self) { urls, _ in
            guard model.canAttachFiles(in: channelID), model.permissionGate.canSend(in: channelID) else { return false }
            model.stageAttachments(urls, in: channelID)
            model.beginForumPost(in: channelID)
            return true
        } isTargeted: { targeted in
            let allowed = targeted && model.canAttachFiles(in: channelID) && model.permissionGate.canSend(in: channelID)
            if allowed != isDropTargeted { isDropTargeted = allowed }
        }
        .overlay {
            if isDropTargeted { DropHalo() }
        }
        .animation(motion.standard, value: isDropTargeted)
        .modal(
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
