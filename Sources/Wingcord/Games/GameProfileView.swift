import SwiftUI
import WingcordCore

/// A game's own page: what it is, who made it, what people think of it, and
/// where its players are.
///
/// **Two columns, split by kind rather than by length** — the same split the
/// full profile makes. The wide column is the game *presenting itself*: its
/// pictures, its blurb, what its own server has been posting. The narrow one is
/// everything a reader would act on or check: where to buy it, where its
/// community is, how it reviewed, and the facts table.
///
/// **Every section is conditional and most games have most of them missing.**
/// Beat Saber has no rank badge, no Discord server, no announcements and one
/// platform; Arknights has no store button and offers to link an account
/// instead. There is no "empty state" for any of these — a section with nothing
/// behind it does not exist, which is what keeps the page honest at both ends of
/// that range.
struct GameProfileView: View {
    var game: GamePresentation
    var dismiss: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.motion) private var motion
    @State private var selectedMedia: URL?
    @State private var didCopyLink = false
    @State private var copyReset: Task<Void, Never>?
    /// Whether the header has given its artwork up for room.
    ///
    /// **Driven by the main column alone, not by both.** The two columns scroll
    /// independently — the same split the full profile makes — and the aside is
    /// short enough to fit without scrolling on most games. Collapsing on either
    /// one would mean the header jumping when somebody nudges a list of four
    /// details.
    @State private var isHeaderCollapsed = false
    /// How far the main column has travelled, for the ambient field's parallax.
    @State private var scrollOffset: CGFloat = 0

    /// The header artwork's height. Enough for the icon to sit in it with the
    /// title beside, and no more: the artwork is a backdrop, and a page that
    /// opens on a picture buries what it is a page *about*.
    private static let headerHeight: CGFloat = 168
    /// What it shrinks to once the reader has started reading: the identity in
    /// one bar, so the page never stops saying which game it is about.
    private static let collapsedHeaderHeight: CGFloat = 46
    /// How far the main column travels before the header gives way. Roughly the
    /// artwork's own height — collapsing sooner reads as the header flinching.
    private static let collapseThreshold: CGFloat = 110
    private static let asideWidth: CGFloat = 320
    /// The poster, and how far it hangs below the header.
    private static let posterWidth: CGFloat = 128
    private static let posterOverhang: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            header
            columns
        }
        // **The game's own artwork, bleeding under the whole page.** The same
        // field the profile stage uses: without it the aside's cards were flat
        // grey and the page could have been about any game. Fed the header
        // artwork, so the light in the page and the picture at the top of it are
        // the same image.
        .ambientArtwork(game.artworkURL, tint: nil, strength: 0.42, offset: scrollOffset)
        .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Ink.quaternary, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 36, y: 14)
        .onDisappear { copyReset?.cancel() }
    }

    // MARK: The header

    private var header: some View {
        // `Color.clear` under the artwork for the same reason every other
        // banner in this app uses one: a filling image reports its own size
        // upward and would set this sheet's width to the picture's.
        Color.clear
            .frame(height: isHeaderCollapsed ? Self.collapsedHeaderHeight : Self.headerHeight)
            .background { headerArtwork }
            .overlay(alignment: isHeaderCollapsed ? .leading : .bottomLeading) { headerIdentity }
            .overlay(alignment: .topTrailing) { headerControls }
            // **The poster hangs past the header's foot**, like a sleeve on a
            // shelf, and that overhang is the whole reason the page reads as
            // being *about* something rather than as a panel with a picture in
            // it. `zIndex` because an overlay on the header would otherwise be
            // cut by the body that follows it.
            .zIndex(1)
            .animation(motion.standard, value: isHeaderCollapsed)
    }

    @ViewBuilder
    private var headerArtwork: some View {
        ZStack {
            Palette.surfaceRaised
            if let url = game.artworkURL {
                RemoteImage(url: url, side: 1024, bucket: .artwork) { Color.clear }
                    .aspectRatio(contentMode: .fill)
                    // Faded rather than removed: the bar keeps a trace of the
                    // artwork's colour, so the collapse reads as the same
                    // surface thinning rather than as a different one arriving.
                    .opacity(isHeaderCollapsed ? 0.35 : 1)
            }
            // **A much lighter wash than this used to carry.** It was
            // `.85 → .35 → .5`, which turned The Sims' bright header into fog.
            // The title gets its legibility from its own shadow and from the
            // ambient field it sits over, not from a curtain across the picture.
            LinearGradient(
                colors: [.black.opacity(0.6), .black.opacity(0.12), .clear],
                startPoint: .bottom,
                endPoint: .top
            )
        }
        .clipped()
    }

    /// The game's identity, in whichever of the two arrangements the header is
    /// currently in.
    ///
    /// **The rank badge moves from above the title to beside it**, which is the
    /// only way it survives a bar 46 points tall — stacked, it would be the half
    /// that gets clipped.
    @ViewBuilder
    private var headerIdentity: some View {
        if isHeaderCollapsed {
            HStack(spacing: Spacing.base) {
                mark
                Text(game.name)
                    .font(.system(.headline))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let rank = game.globalRank {
                    RankBadge(rank: rank)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.snug)
            .padding(.trailing, Metrics.control * 3)
        } else {
            HStack(alignment: .bottom, spacing: Spacing.margin) {
                cover(width: Self.posterWidth)
                    // Past the header's own foot.
                    .offset(y: Self.posterOverhang)
                    .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
                VStack(alignment: .leading, spacing: 2) {
                    if let rank = game.globalRank {
                        RankBadge(rank: rank)
                    }
                    Text(game.name)
                        .font(.system(.title2, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if !game.genreLine.isEmpty {
                        Text(game.genreLine)
                            .font(.system(.subheadline))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.margin)
            .padding(.bottom, Spacing.snug)
        }
    }

    /// The poster: real box art at last, rather than a square icon stretched
    /// into a portrait frame.
    private func cover(width: CGFloat) -> some View {
        GameCover(
            game: BoardGame(
                gameID: game.gameID,
                name: game.name,
                coverURL: game.coverURL,
                isCoverArt: game.hasCoverArt,
                tags: []
            ),
            width: width
        )
    }

    /// The square mark the condensed bar wears.
    private var mark: some View {
        GameMark(
            game: BoardGame(gameID: game.gameID, name: game.name, coverURL: game.markURL, tags: []),
            side: 26
        )
    }

    /// The one control this client can honour, and the close.
    ///
    /// **No "Add to Profile".** Discord's own header offers it, and it would
    /// need a board editor to write into — `PUT /users/@me/widgets` is
    /// implemented and there is no editor yet. A button that opens nothing is
    /// the inert control `INVARIANTS.md` §5.5 forbids, so it is not drawn until
    /// there is something behind it.
    ///
    /// The store button is not here either, and that is a placement rather than
    /// an omission: it is the page's primary action and it belongs at the top of
    /// the aside, labelled, beside Join — not as a nameless glyph in a corner.
    private var headerControls: some View {
        HStack(spacing: Spacing.base) {
            Button(action: copyLink) {
                Image(systemName: didCopyLink ? "checkmark" : "link")
                    .font(Typeface.controlGlyph)
                    .frame(width: Metrics.control, height: Metrics.control)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .interactiveChromeOverMedia(in: .circle)
            .help(didCopyLink ? "Copied" : "Copy the game's id")
            .accessibilityLabel(Text("Copy game id"))

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(Typeface.controlGlyph)
                    .frame(width: Metrics.control, height: Metrics.control)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .interactiveChromeOverMedia(in: .circle)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(Text("Close"))
        }
        .padding(Spacing.snug)
        .animation(motion.standard, value: didCopyLink)
    }

    private func copyLink() {
        AppModel.copy(game.gameID.description)
        didCopyLink = true
        copyReset?.cancel()
        copyReset = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            didCopyLink = false
        }
    }

    // MARK: The body

    private var columns: some View {
        HStack(alignment: .top, spacing: 0) {
            mainColumn
            aside
        }
    }

    private var mainColumn: some View {
        ScrollView {
            mainContent
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.margin)
                // Clear of the poster, which now hangs into this column.
                .padding(.top, isHeaderCollapsed ? 0 : Self.posterOverhang)
        }
        .scrollIndicators(.never)
        .softScrollEdgesVertical()
        .frame(maxWidth: .infinity)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            max(geometry.contentOffset.y, 0)
        } action: { _, offset in
            scrollOffset = offset
            let collapsed = offset > Self.collapseThreshold
            guard isHeaderCollapsed != collapsed else { return }
            isHeaderCollapsed = collapsed
        }
    }

    // **Split out of the `ScrollView`'s trailing closure, and not for
    // tidiness.** Five conditional children of five different types inside a
    // builder inside a builder is an expression the type-checker gives up on —
    // and what it reports when it does is "ambiguous use of `init`" on the
    // `ScrollView`, which names neither the cause nor the line. Naming the stack
    // gives it one small problem instead of one large one. See `HANDOFF.md`.
    @ViewBuilder
    private var mainContent: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            if !game.media.isEmpty {
                GameMediaCarousel(media: game.media, selection: $selectedMedia)
            }
            if let summary = game.summary {
                Text(summary)
                    .font(.system(.subheadline))
                    .foregroundStyle(InkColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            announcements
            if !game.similar.isEmpty {
                GameSimilarShelf(games: game.similar)
            }
            if game.isLoading { loadingRow }
        }
    }

    @ViewBuilder
    private var announcements: some View {
        if !game.announcements.isEmpty {
            GameAnnouncementsShelf(
                announcements: game.announcements,
                openChannel: viewAllAction
            )
        }
    }

    /// Nil where the reader is not in the game's server, and the shelf then
    /// draws its heading without a "View All".
    ///
    /// Written out with an explicit type rather than as a ternary in the call:
    /// a conditional whose branches are `nil` and an unapplied method reference
    /// gives the type-checker two inferences to make at once, and it answers
    /// "failed to produce diagnostic for expression".
    private var viewAllAction: (() -> Void)? {
        guard game.announcementsChannel != nil else { return nil }
        return openAnnouncementsChannel
    }

    private var aside: some View {
        ScrollView {
            asideContent
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.margin)
        }
        .scrollIndicators(.never)
        .softScrollEdgesVertical()
        .frame(width: Self.asideWidth)
    }

    @ViewBuilder
    private var asideContent: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            if let store = game.storeLink {
                GameStoreButton(store: store)
            }
            if let link = game.accountLink {
                GameAccountLinkCard(link: link)
            }
            if let community = game.community {
                GameCommunitySection(community: community)
            }
            if let reviews = game.reviews, !reviews.isEmpty {
                GameReviewsSection(reviews: reviews, openCriticURL: game.openCriticURL)
            }
            if !game.details.isEmpty || !game.links.isEmpty {
                GameDetailsSection(rows: game.details, links: game.links)
            }
        }
    }

    private var loadingRow: some View {
        HStack(spacing: Spacing.base) {
            ProgressView().controlSize(.small)
            Text("Loading the rest…")
                .font(Typeface.rowSubtitle)
                .foregroundStyle(InkColor.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openAnnouncementsChannel() {
        guard let channel = game.announcementsChannel else { return }
        model.dismissGameProfile()
        model.openChannelFromSurface(channel.channelID)
    }
}

/// "#43 Global Rank" — the one badge a game wears.
///
/// **Drawn only where Discord ranks the game**, which is a minority: of the
/// three captured games, The Sims is 43rd and Arknights 79th, and Beat Saber
/// carries no `l30_rank` at all. A badge reading "#—" would be a client
/// inventing a fact.
private struct RankBadge: View {
    var rank: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "trophy.fill")
                .font(.system(size: 8, weight: .bold))
            Text("#\(rank) Global Rank")
                .font(.system(size: 10, weight: .bold))
                .textCase(.uppercase)
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(.white.opacity(0.92)))
        .accessibilityLabel(Text("Ranked number \(rank) globally"))
    }
}
