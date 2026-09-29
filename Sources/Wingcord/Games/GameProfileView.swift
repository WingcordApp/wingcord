import SwiftUI
import WingcordCore

/// A game's own page: what it is, who made it, what people think of it, and
/// where its players are.
///
/// **Glass floating over the game's own artwork**, which is the design handoff's
/// arrangement and a real correction to what was here. The old page put the
/// artwork in a 168-point band at the top and everything else on flat ground —
/// so the one picture the page had was a strip, and the cards below it were
/// clear glass over nothing, which renders as a slightly lighter rectangle. Now
/// the artwork lights the whole sheet and three glass objects float on it: the
/// header, the aside, and the media tray.
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
    /// Whether the header has given its cover and its title size up for room.
    ///
    /// **Driven by the main column alone, not by both.** The two columns scroll
    /// independently and the aside is short enough to fit without scrolling on
    /// most games. Collapsing on either one would mean the header jumping when
    /// somebody nudges a list of four details.
    @State private var isHeaderCollapsed = false
    /// How far the main column has travelled, for the ambient field's parallax.
    @State private var scrollOffset: CGFloat = 0

    /// The margin the three floating objects share. 22 in the handoff.
    private static let inset: CGFloat = 18
    /// The header bar, open and condensed. The spec's numbers, and the reason
    /// for the second one is that the page must never stop saying which game it
    /// is about.
    /// **Sized from the cover, not chosen.** Box art is 3:4, so a 60-point
    /// cover is 80 tall and the bar is that plus its own padding. Set to the
    /// spec's 92 the artwork overflowed the glass and was cut at both ends —
    /// which is what a number picked before the thing it has to contain gets
    /// you.
    private static let headerHeight: CGFloat =
        GameHeaderBar.cover / GameArt.coverAspect + GameHeaderBar.padding * 2
    private static let condensedHeaderHeight: CGFloat = 54
    /// How far the main column travels before the header gives way. Roughly the
    /// difference between the two — collapsing sooner reads as the header
    /// flinching.
    private static let collapseThreshold: CGFloat = 60
    /// 412 in the handoff, at its 1,360-point sheet.
    private static let asideWidth: CGFloat = 320

    private var headerReserve: CGFloat {
        (isHeaderCollapsed ? Self.condensedHeaderHeight : Self.headerHeight) + Self.inset * 2
    }

    var body: some View {
        ZStack(alignment: .top) {
            columns
            GameHeaderBar(
                game: game,
                isCondensed: isHeaderCollapsed,
                didCopyLink: didCopyLink,
                copyLink: copyLink,
                dismiss: dismiss
            )
            .padding(.horizontal, Self.inset)
            .padding(.top, Self.inset)
        }
        // **The game's own artwork, lighting the whole page.** Without it the
        // aside's cards are flat grey and the page could be about any game. Fed
        // the header artwork, so the light in the page and the pictures on it
        // are the same image.
        .ambientArtwork(game.artworkURL, tint: nil, strength: 0.42, offset: scrollOffset)
        .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Ink.quaternary, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 36, y: 14)
        .animation(motion.standard, value: isHeaderCollapsed)
        .onDisappear { copyReset?.cancel() }
    }

    // MARK: The body

    private var columns: some View {
        HStack(alignment: .top, spacing: Self.inset) {
            mainColumn
            aside
        }
        .padding(.horizontal, Self.inset)
        .padding(.bottom, Self.inset)
        .padding(.top, headerReserve)
    }

    private var mainColumn: some View {
        ScrollView {
            mainContent
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, Spacing.group)
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
        VStack(alignment: .leading, spacing: Self.inset) {
            if !game.media.isEmpty {
                GameMediaStage(media: game.media, selection: $selectedMedia)
            }
            if let summary = game.summary {
                Text(summary)
                    .font(.system(.subheadline))
                    .foregroundStyle(InkColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Spacing.tight)
            }
            themes
            announcements
            if !game.similar.isEmpty {
                GameSimilarShelf(games: game.similar)
            }
            if game.isLoading { loadingRow }
        }
    }

    /// What the game is *about*, as chips.
    ///
    /// **Real, decoded, and never drawn until now.** `themes` has been on the
    /// wire and in `Game` the whole time — "Action", "Fantasy", "Sandbox" — and
    /// this is the space the mockup spent on a stat trio whose three numbers
    /// were all invented.
    @ViewBuilder
    private var themes: some View {
        if !game.themes.isEmpty {
            FlowLayout(spacing: Spacing.tight) {
                ForEach(game.themes, id: \.self) { theme in
                    Text(theme)
                        .font(.system(.caption, weight: .medium))
                        .foregroundStyle(InkColor.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassEffect(.clear.tint(Palette.flyoutTint), in: .capsule)
                }
            }
            .padding(.horizontal, Spacing.tight)
        }
    }

    @ViewBuilder
    private var announcements: some View {
        if !game.announcements.isEmpty {
            GameAnnouncementsShelf(
                announcements: game.announcements,
                openChannel: viewAllAction,
                openMessage: openAnnouncementAction
            )
        }
    }

    /// Nil where the digest carried no channel, and the shelf then draws its
    /// heading without a "View All".
    ///
    /// Written out with an explicit type rather than as a ternary in the call:
    /// a conditional whose branches are `nil` and an unapplied method reference
    /// gives the type-checker two inferences to make at once, and it answers
    /// "failed to produce diagnostic for expression".
    private var viewAllAction: (() -> Void)? {
        guard game.announcementsChannel != nil else { return nil }
        return openAnnouncementsChannel
    }

    /// Opening one post. Nil only where the digest carried no channel.
    private var openAnnouncementAction: ((MessageID) -> Void)? {
        guard game.announcementsChannel != nil else { return nil }
        return { messageID in openAnnouncement(messageID) }
    }

    /// The aside: one floating glass panel, with regions cut into it.
    ///
    /// **One material, not one per section.** Every card in here used to carry
    /// its own `.glassEffect` and they sat side by side down a column — five
    /// stacked materials over the same artwork, which §4 forbids and which
    /// reads as five plates rather than one pane. The panel is the glass; the
    /// sections are regions inside it.
    private var aside: some View {
        ScrollView {
            asideContent
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.margin)
        }
        .scrollIndicators(.never)
        .softScrollEdgesVertical()
        .frame(width: Self.asideWidth)
        .glassEffect(
            .clear.tint(Palette.flyoutTint),
            in: .rect(cornerRadius: 26, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var asideContent: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            GameLaunchButtons(offers: game.launchOffers)
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

    /// **The reader is usually not in the game's server**, so this cannot be a
    /// plain channel selection: `openChannelFromSurface` looks the channel up in
    /// the index, finds nothing, and does nothing at all. Previewing is what
    /// makes the destination exist — see `AppModel.openAnnouncement`.
    private func openAnnouncementsChannel() {
        openAnnouncement(nil)
    }

    private func openAnnouncement(_ messageID: MessageID?) {
        guard let channel = game.announcementsChannel else { return }
        model.openAnnouncement(
            messageID,
            in: channel.channelID,
            guildID: channel.guildID,
            game: game.gameID
        )
    }
}

/// The page's identity, floating over its artwork.
///
/// **It condenses rather than disappearing.** Open it is the cover, the rank,
/// the genres and the title at 24 points; scrolled it is a 26-point mark and the
/// name — so the page never stops saying which game it is about, which a header
/// that scrolled away would.
///
/// **No "Add to Profile".** The handoff offers it and it would need a board
/// editor to write into: `PUT /users/@me/widgets` is implemented and typed, and
/// there is no editor. A button that opens nothing is the inert control
/// `INVARIANTS.md` §5.5 forbids, so it is not drawn — not disabled, not drawn —
/// until there is something behind it.
private struct GameHeaderBar: View {
    var game: GamePresentation
    var isCondensed: Bool
    var didCopyLink: Bool
    var copyLink: () -> Void
    var dismiss: () -> Void

    /// The cover's width; its height follows from `GameArt.coverAspect`, and the
    /// bar's height follows from that. 76 in the handoff, whose cover is square.
    static let cover: CGFloat = 60
    static let padding: CGFloat = 14
    private static let mark: CGFloat = 30

    var body: some View {
        HStack(spacing: Spacing.snug) {
            if isCondensed {
                GameMark(
                    game: BoardGame(gameID: game.gameID, name: game.name, coverURL: game.markURL, tags: []),
                    side: Self.mark
                )
                Text(game.name)
                    .font(.system(.headline))
                    .foregroundStyle(InkColor.primary)
                    .lineLimit(1)
                if let rank = game.globalRank { RankChip(rank: rank) }
            } else {
                GameCover(
                    game: BoardGame(
                        gameID: game.gameID,
                        name: game.name,
                        coverURL: game.coverURL,
                        isCoverArt: game.hasCoverArt,
                        tags: []
                    ),
                    width: Self.cover,
                    corner: 16
                )
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: Spacing.base) {
                        if let rank = game.globalRank { RankChip(rank: rank) }
                        if !game.genreLine.isEmpty {
                            Text(game.genreLine)
                                .font(.system(.caption))
                                .foregroundStyle(InkColor.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Text(game.name)
                        .font(.system(.title, weight: .bold))
                        .foregroundStyle(InkColor.primary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Spacing.snug)
            circle(didCopyLink ? "checkmark" : "link", didCopyLink ? "Copied" : "Copy the game's id", copyLink)
            circle("xmark", "Close", dismiss)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, isCondensed ? Spacing.base : Self.padding)
        .frame(height: isCondensed ? 54 : Self.cover / GameArt.coverAspect + Self.padding * 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(
            .clear.tint(Palette.flyoutTint),
            in: .rect(cornerRadius: isCondensed ? 20 : 26, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: isCondensed ? 20 : 26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.55), radius: 26, y: 12)
    }

    private func circle(
        _ symbolName: String,
        _ label: String,
        _ perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Image(systemName: symbolName)
                .font(Typeface.controlGlyph)
                .foregroundStyle(InkColor.primary)
                .frame(width: Metrics.control + 6, height: Metrics.control + 6)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .interactiveChromeOverMedia(in: .circle)
        .help(label)
        .accessibilityLabel(Text(label))
    }
}

/// "#43 GLOBAL" — the one badge a game wears.
///
/// **Drawn only where Discord ranks the game**, which is a minority: of the
/// three captured games, The Sims is 43rd and Arknights 79th, and Beat Saber
/// carries no `l30_rank` at all. A badge reading "#—" would be a client
/// inventing a fact.
private struct RankChip: View {
    var rank: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "trophy.fill")
                .font(.system(size: 8, weight: .bold))
            Text("#\(rank) GLOBAL")
                .font(.system(size: 10, weight: .bold))
                .monospacedDigit()
        }
        .foregroundStyle(.black.opacity(0.82))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            LinearGradient(
                colors: [Color(hex: 0xF6_D3_6B), Color(hex: 0xE0_A9_3A)],
                startPoint: .top,
                endPoint: .bottom
            ),
            in: .capsule
        )
        .accessibilityLabel(Text("Ranked number \(rank) globally"))
    }
}
