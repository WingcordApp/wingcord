import SwiftUI
import WingcordCore

// MARK: - Media

/// The hero and the tray under it: a trailer where the game has one, and every
/// still it published.
///
/// **The trailer is the hero, and it is the single biggest thing this page was
/// missing.** `GameTrailer` has been decoded since the page was written and
/// drawn nowhere — a game's own moving pitch, sitting in the payload behind a
/// shelf of screenshots.
///
/// **A selected item, not an auto-advancing carousel.** A page that moves on its
/// own while somebody is reading the blurb beside it is motion nobody asked for,
/// and Reduce Motion would have to switch it off anyway. The tray is the
/// control, and it is the whole control.
struct GameMediaStage: View {
    var media: [GameMediaItem]
    /// Nil means "the first one", so the tray needs no seeding pass and the
    /// selection survives a refresh that reorders nothing.
    @Binding var selection: URL?

    @Environment(\.motion) private var motion
    /// Which run of thumbnails the tray is showing. The counter and the arrows
    /// are the same fact.
    @State private var page = 0
    /// Whether the trailer on the stage is playing — the tray's mark on it
    /// says Pause while it is, as Discord's does.
    @State private var isTrailerPlaying = false

    /// 78 in the handoff. The tray shows a page of these and names how many
    /// there are, which a bare scrolling strip does not.
    private static let thumbnailHeight: CGFloat = 62
    private static let perPage = 6

    private var current: GameMediaItem? {
        media.first { $0.id == selection } ?? media.first
    }

    private var currentIndex: Int {
        media.firstIndex { $0.id == current?.id } ?? 0
    }

    private var pageCount: Int {
        max(1, Int(ceil(Double(media.count) / Double(Self.perPage))))
    }

    private var visible: ArraySlice<GameMediaItem> {
        let start = min(page, pageCount - 1) * Self.perPage
        return media[start..<min(start + Self.perPage, media.count)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            stage
            if media.count > 1 { tray }
        }
    }

    @ViewBuilder
    private var stage: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                switch current {
                case .trailer(let video, let poster):
                    TrailerPlayer(
                        url: video,
                        poster: poster,
                        autoplays: !motion.reduceMotion,
                        onPlayingChange: { isTrailerPlaying = $0 }
                    )
                case .still(let url):
                    RemoteImage(url: url, side: 900, bucket: .artwork) { Palette.surfaceRaised }
                        .aspectRatio(contentMode: .fill)
                case nil:
                    Palette.surfaceRaised
                }
            }
            .clipShape(.rect(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.5), radius: 28, y: 12)
            // The stage cross-fades rather than sliding: the tray below carries
            // the sense of position, and two things moving for one click reads
            // as a transition the app is performing rather than a picture
            // changing.
            .animation(motion.fade, value: current)
            .accessibilityLabel(Text(current?.isTrailer == true ? "Trailer" : "Screenshot"))
    }

    /// "MEDIA 01 / 24", its arrows, and a page of thumbnails.
    private var tray: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            HStack(spacing: Spacing.base) {
                Text("Media")
                    .font(Typeface.sectionHeader)
                    .foregroundStyle(InkColor.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.9)
                // **It names how much there is**, which a bare strip does not:
                // a reader looking at three thumbnails cannot tell whether that
                // is all of them.
                Text("\(pad(currentIndex + 1)) / \(pad(media.count))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Ink.quaternary)
                Spacer(minLength: Spacing.base)
                if pageCount > 1 {
                    arrow("chevron.left", "Previous", enabled: page > 0) { page -= 1 }
                    arrow("chevron.right", "Next", enabled: page < pageCount - 1) { page += 1 }
                }
            }
            .padding(.horizontal, Spacing.tight)

            HStack(spacing: Spacing.base) {
                ForEach(visible) { item in
                    thumbnail(item)
                }
                // The last page is rarely full, and thumbnails that stretched to
                // fill it would be a different size from every other page's.
                if visible.count < Self.perPage {
                    ForEach(0..<(Self.perPage - visible.count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(height: Self.thumbnailHeight)
        }
        .padding(Spacing.snug)
        // Content over the game's artwork: a standard material, not glass.
        .background(.thinMaterial, in: .rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .animation(motion.standard, value: page)
    }

    /// Two digits, so the counter does not change width as it counts.
    private func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    private func thumbnail(_ item: GameMediaItem) -> some View {
        let isCurrent = item.id == current?.id
        return Button { selection = item.id } label: {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: Self.thumbnailHeight)
                .overlay {
                    // **A trailer's thumbnail is its poster**, never the video:
                    // an `.mp4` handed to the image path decodes to nothing.
                    RemoteImage(url: item.picture, side: 240, bucket: .artwork) {
                        Palette.surfaceRaised
                    }
                    .aspectRatio(contentMode: .fill)
                }
                .overlay {
                    // Discord's round overlay mark, centred: Play, or Pause on
                    // the trailer that is playing (`thumbnailPlayIcon`).
                    if item.isTrailer {
                        Image(systemName: isCurrent && isTrailerPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(.black.opacity(0.5), in: .circle)
                    }
                }
                .clipShape(.rect(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            isCurrent ? Color.white.opacity(0.85) : Color.white.opacity(0.12),
                            lineWidth: isCurrent ? 2 : 1
                        )
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(item.isTrailer ? "Trailer" : "Screenshot"))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    private func arrow(
        _ symbolName: String,
        _ label: String,
        enabled: Bool,
        _ perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Image(symbol: symbolName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(InkColor.primary)
                .frame(width: 26, height: 26)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .interactiveChromeOverMedia(in: .circle)
        .accessibilityLabel(Text(label))
    }
}

// MARK: - Announcements

/// Recent posts from the game's own server.
struct GameAnnouncementsShelf: View {
    var announcements: [GameAnnouncementCard]
    /// Opens the whole channel. **Always available now**: the reader does not
    /// have to be in the server, because opening it starts a preview — see
    /// `AppModel.openAnnouncement`.
    var openChannel: (() -> Void)?
    /// Opens one post where it was made.
    var openMessage: ((MessageID) -> Void)?

    private static let cardWidth: CGFloat = 220
    private static let cardHeight: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack {
                Text("Community Announcements")
                    .font(.system(.headline))
                    .foregroundStyle(InkColor.primary)
                Spacer(minLength: Spacing.base)
                if let openChannel {
                    Button(action: openChannel) {
                        HStack(spacing: 3) {
                            Text("View All")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .font(.system(.caption, weight: .medium))
                        .foregroundStyle(InkColor.secondary)
                        .padding(.horizontal, Spacing.base)
                        .padding(.vertical, 4)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .interactiveChrome()
                }
            }

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Spacing.snug) {
                    ForEach(announcements) { announcement in
                        AnnouncementCard(
                            announcement: announcement,
                            open: openMessage.map { open in { open(announcement.id) } }
                        )
                        .frame(width: Self.cardWidth, height: Self.cardHeight)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
        }
    }
}

private struct AnnouncementCard: View {
    var announcement: GameAnnouncementCard
    /// Nil only where the post carries no channel to open, which the digest
    /// route has never yet answered without. A card with no destination is drawn
    /// as a card, not as a dead button — §5.5.
    var open: (() -> Void)?

    var body: some View {
        if let open {
            Button(action: open) { card }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(Text("Opens this post in the game's server"))
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let url = announcement.imageURL {
                Color.clear
                    .frame(height: 96)
                    .background {
                        RemoteImage(url: url, side: 440, bucket: .artwork) {
                            Palette.surfaceRaised
                        }
                        .aspectRatio(contentMode: .fill)
                    }
                    .clipped()
            }
            VStack(alignment: .leading, spacing: Spacing.base) {
                // **No `.fixedSize`, and that is what keeps the date on the
                // card.** A fixed size takes the text's ideal height whatever it
                // was offered, so a nine-line post grew past a 240-point card
                // and pushed its own footer over the edge. Given the height it
                // actually has, a `Text` fills it and truncates.
                Text(announcement.text)
                    .font(.system(.caption))
                    .foregroundStyle(InkColor.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: Spacing.base) {
                    Text(announcement.postedAt, format: .dateTime.month(.wide).day().year())
                        .font(.system(size: 10))
                        .foregroundStyle(InkColor.tertiary)
                    if announcement.reactionCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "face.smiling")
                                .font(.system(size: 9))
                            Text(announcement.reactionCount, format: .number)
                                .font(.system(size: 10).monospacedDigit())
                        }
                        .foregroundStyle(InkColor.tertiary)
                    }
                }
            }
            .padding(Spacing.snug)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.thinMaterial, in: .rect(cornerRadius: Radius.glass))
        .clipShape(.rect(cornerRadius: Radius.glass, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Similar games

struct GameSimilarShelf: View {
    var games: [BoardGame]

    @Environment(AppModel.self) private var model

    private static let coverWidth: CGFloat = GameArt.shelfWidth

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text("Similar Games")
                .font(.system(.headline))
                .foregroundStyle(InkColor.primary)
            ScrollView(.horizontal) {
                HStack(spacing: Spacing.base) {
                    ForEach(games) { game in
                        Button { model.openGameProfile(game.gameID) } label: {
                            GameCover(game: game, width: Self.coverWidth)
                        }
                        .buttonStyle(.plain)
                        .help(game.name ?? "")
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
        }
    }
}

// MARK: - The aside

/// A heading and its content, the aside's one rhythm.
private struct AsideSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text(title)
                .font(.system(.headline))
                .foregroundStyle(InkColor.primary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Where the game is sold.
///
/// **The page's primary action, and it is named rather than glyphed.** It is
/// the one thing on this page a reader is most likely to have come for, and a
/// cart icon in the header's corner says "some kind of shop" where a labelled
/// button says "Steam".
///
/// **Discord's words, with the arrow that says where they go.** The label is
/// the store's name — Riot's is "Play" — and the trailing arrow is what says
/// the button opens a page in the browser rather than launching anything,
/// which this client cannot do. See `GameStore.profileLabel`.
struct GameStoreButton: View {
    var offer: GameStoreOffer

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { openURL(offer.url) } label: {
            HStack(spacing: Spacing.base) {
                ConnectionMark(service: offer.store.brandService, side: 18)
                Text(offer.store.profileLabel)
                    .font(.system(.subheadline, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(InkColor.tertiary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.control + 14)
            .contentShape(.rect(cornerRadius: Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(InkColor.primary)
        .interactiveChrome(in: .rect(cornerRadius: Radius.chip, style: .continuous))
        .accessibilityLabel(Text(offer.store.profileAccessibilityLabel))
        .help("Open the \(offer.store.title) page in your browser")
    }
}

/// Where to get or play the game, laid out as Discord lays it out (its `lY`).
///
/// **One store is one wide button and two sit side by side; three or more
/// fold behind Get Now**, which opens the list — with Xbox Game Pass, when it
/// is one of them, kept beside Get Now. The offers are `Game.launchOffers`:
/// every store Discord gives a button, which is how Roblox gets its own and
/// Valorant its Riot Play.
struct GameLaunchButtons: View {
    var offers: [GameStoreOffer]

    @State private var isPickerOpen = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch offers.count {
        case 0:
            EmptyView()
        case 1:
            GameStoreButton(offer: offers[0])
        case 2:
            HStack(spacing: Spacing.base) {
                GameStoreButton(offer: offers[0])
                GameStoreButton(offer: offers[1])
            }
        default:
            HStack(spacing: Spacing.base) {
                if let pass = offers.first(where: { $0.store == .xboxGamePass }) {
                    GameStoreButton(offer: pass)
                }
                getNow
            }
        }
    }

    private var getNow: some View {
        Button { isPickerOpen = true } label: {
            Text("Get Now")
                .font(.system(.subheadline, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: Metrics.control + 14)
                .contentShape(.rect(cornerRadius: Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(InkColor.primary)
        .interactiveChrome(in: .rect(cornerRadius: Radius.chip, style: .continuous))
        .accessibilityLabel(Text("Select a platform to get the game"))
        .popover(isPresented: $isPickerOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Select a platform to get the game")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
                    .padding(.horizontal, Spacing.base)
                    .padding(.vertical, Spacing.tight)
                ForEach(offers) { offer in
                    FlyoutRow(title: offer.store.profileLabel, brandService: offer.store.brandService) {
                        isPickerOpen = false
                        openURL(offer.url)
                    }
                    .accessibilityLabel(Text(offer.store.profileAccessibilityLabel))
                }
            }
            .padding(.vertical, Spacing.tight)
            .frame(width: 260)
        }
    }
}

/// The offer to connect an in-game account.
///
/// Drawn for a game whose own application — or a widget application linked to
/// it — publishes an entrypoint: Valorant's official application does, and so
/// do Arknights' and Wuthering Waves' widgets. The address is the game's, so it opens
/// in the browser: linking is an OAuth dance on the publisher's own site and
/// there is nothing for this client to do in the middle of it.
struct GameAccountLinkCard: View {
    var link: GameAccountLink

    @Environment(\.openURL) private var openURL

    var body: some View {
        AsideSection(title: "Link Account") {
            VStack(alignment: .leading, spacing: Spacing.snug) {
                HStack(spacing: Spacing.base) {
                    RemoteImage(url: link.iconURL, side: 32) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Palette.surfaceRaised)
                    }
                    .frame(width: 32, height: 32)
                    .clipShape(.rect(cornerRadius: 8, style: .continuous))

                    // Discord's words (`hUbQT2`, `JKqu+4`, `jynBQ5`).
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Link your account with \(link.applicationName)")
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(InkColor.primary)
                        Text("Show your in-game stats, send game invites easily, and more!")
                            .font(.system(.caption))
                            .foregroundStyle(InkColor.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Button { openURL(link.url) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 11))
                        Text("Link your account!")
                            .font(.system(.subheadline, weight: .medium))
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(InkColor.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: Metrics.control + 4)
                    .contentShape(.rect(cornerRadius: Radius.chip, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(InkColor.primary)
                .interactiveChrome(in: .rect(cornerRadius: Radius.chip, style: .continuous))
            }
            .padding(Spacing.snug)
            // **No material of its own.** The aside is the glass; this is a
            // region inside it, and a second `.glassEffect` here is glass on
            // glass — §4 rule 2, and what made the column read as five plates
            // instead of one pane.
            .background(Color.white.opacity(0.05), in: .rect(cornerRadius: Radius.glass, style: .continuous))
        }
    }
}

/// The game's own Discord.
struct GameCommunitySection: View {
    var community: GameCommunityCard

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        AsideSection(title: "Community") {
            VStack(alignment: .leading, spacing: Spacing.snug) {
                HStack(alignment: .top, spacing: Spacing.base) {
                    RemoteImage(url: community.iconURL, side: 40) {
                        ZStack {
                            Palette.surfaceRaised
                            Text(community.monogram)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(InkColor.secondary)
                        }
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(.circle)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            if let mark = community.mark {
                                GuildMarkBadge(mark: mark, side: 14)
                            }
                            Text(community.name)
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundStyle(InkColor.primary)
                                .lineLimit(1)
                        }
                        if let description = community.description {
                            Text(description)
                                .font(.system(.caption))
                                .foregroundStyle(InkColor.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        counts
                    }
                }

                Button(action: act) {
                    Text(community.isJoined ? "Open" : "Join")
                        .font(.system(.subheadline, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: Metrics.control + 4)
                        .contentShape(.rect(cornerRadius: Radius.chip, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(InkColor.primary)
                .interactiveChrome(in: .rect(cornerRadius: Radius.chip, style: .continuous))
            }
            .padding(Spacing.snug)
            // A region inside the aside's own pane, not a pane of its own —
            // §4 rule 2. See `GameAccountLinkCard`.
            .background(
                Color.white.opacity(0.05),
                in: .rect(cornerRadius: Radius.glass, style: .continuous)
            )
        }
    }

    /// Two dots and two numbers, which is the whole of what a reader wants from
    /// a server they are deciding whether to join.
    private var counts: some View {
        HStack(spacing: Spacing.snug) {
            if let online = community.onlineCount {
                countLabel(
                    color: Palette.presenceOnline,
                    value: online,
                    noun: "Online"
                )
            }
            if let members = community.memberCount {
                countLabel(
                    color: Palette.presenceOffline,
                    value: members,
                    noun: "Members"
                )
            }
        }
    }

    private func countLabel(color: Color, value: Int, noun: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(value.formatted(.number)) \(noun)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(InkColor.secondary)
        }
    }

    /// **Open, or hand the invite to the browser.**
    ///
    /// Joining a server from an invite code is a route this client does not
    /// have, so the button that says "Join" opens the invite where the reader
    /// can accept it — which is a real action, unlike a button that posts
    /// nothing. When they are already in the server it selects it instead, and
    /// the label says so.
    private func act() {
        if community.isJoined {
            model.dismissGameProfile()
            model.selectGuild(community.guildID)
            return
        }
        guard let url = URL(string: "https://discord.gg/\(community.inviteCode)") else { return }
        openURL(url)
    }
}

/// Steam's and OpenCritic's verdicts — Discord's Reviews card (`lP`, chunk
/// `464cd197…`): one card of 56-point lines, each of them a link to its page.
///
/// **Two Steam lines at most** — Recent, then English or All — each with
/// Steam's mark, its window, the verdict in Discord's colour for it and the
/// count; **then OpenCritic** with the tier's badge and the top critics'
/// average in a ring part-filled to the score. No bars and no "Overall":
/// `GameReviews.steamRows(hasStorePage:)` decides which lines exist.
struct GameReviewsSection: View {
    var reviews: GameReviews
    /// The game's Steam page — the lines open it, so without one there are none.
    var steamURL: URL?
    var openCriticURL: URL?

    private var steamRows: [GameReviews.SteamRow] {
        reviews.steamRows(hasStorePage: steamURL != nil)
    }

    private var openCritic: GameReviews.OpenCriticReviews? {
        openCriticURL == nil ? nil : reviews.openCritic
    }

    var body: some View {
        let rows = steamRows
        if !rows.isEmpty || openCritic != nil {
            AsideSection(title: "Reviews") {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { divider }
                        if let steamURL {
                            GameReviewLine(url: steamURL, label: "Open Steam page") { steamLine(row) }
                                .help(row.sentence)
                        }
                    }
                    if let openCritic, let openCriticURL {
                        if !rows.isEmpty { divider }
                        GameReviewLine(url: openCriticURL, label: "Open OpenCritic page") {
                            openCriticLine(openCritic)
                        }
                    }
                }
                // The page's own card, as the Details table under it is.
                .background(
                    Color.white.opacity(0.05),
                    in: .rect(cornerRadius: Radius.glass, style: .continuous)
                )
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Ink.quaternary)
            .frame(height: 0.5)
    }

    private func steamLine(_ row: GameReviews.SteamRow) -> some View {
        HStack(spacing: Spacing.tight) {
            BrandGlyph(service: "steam")
                .fill(InkColor.primary)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            Text(row.title)
                .font(.system(.body, weight: .medium))
                .foregroundStyle(InkColor.primary)
            Spacer(minLength: Spacing.base)
            Text(row.verdict.title)
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(SteamVerdictInk(tone: row.verdict.tone))
            if let count = row.count, row.verdict != .noUserReviews {
                Text("(\(count.formatted(.number)))")
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(InkColor.tertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Steam, \(row.title): \(row.verdict.title). \(row.sentence)"))
    }

    private func openCriticLine(_ critic: GameReviews.OpenCriticReviews) -> some View {
        HStack(spacing: Spacing.snug) {
            Text("OpenCritic")
                .font(.system(.body, weight: .medium))
                .foregroundStyle(InkColor.primary)
            Spacer(minLength: Spacing.base)
            if let tier = critic.tier {
                RemoteImage(url: tier.badgeURL, side: 32, bucket: .artwork) { Color.clear }
                    .frame(width: 32, height: 32)
                    .help(tier.title)
                    .accessibilityLabel(Text(tier.title))
            }
            if critic.showsRing, let tier = critic.tier, let score = critic.score {
                OpenCriticRing(score: score, rating: critic.topCriticRating ?? 0, tier: tier)
            }
            if critic.lacksCritics {
                Text("Not Enough Top Critic Reviews")
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(InkColor.tertiary)
            }
        }
    }
}

/// One line of the Reviews card: a link to its page, lit under the pointer
/// (`link`'s `--background-surface-higher`).
private struct GameReviewLine<Content: View>: View {
    var url: URL
    var label: String
    @ViewBuilder var content: Content

    @Environment(\.openURL) private var openURL
    @State private var isHovering = false

    var body: some View {
        Button { openURL(url) } label: {
            content
                .padding(.horizontal, 12)
                .frame(height: 56)
                .frame(maxWidth: .infinity)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(isHovering ? Palette.hoverFill : .clear)
        .onHover { hovering in
            if isHovering != hovering { isHovering = hovering }
        }
        .accessibilityHint(Text(label))
    }
}

/// Discord's `steam-review-text-*` colours: its `theme-dark` values in a dark
/// room and its `theme-light` ones in a light room (`--blue-new-26` and
/// `-53`, `--yellow-new-29` and `-75`, `--red-new-24` and `-50`), the subtle
/// ink for "No User Reviews".
private struct SteamVerdictInk: ShapeStyle {
    var tone: SteamVerdict.Tone

    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        let isDark = environment.colorScheme == .dark
        return switch tone {
        case .positive: AnyShapeStyle(Color(hex: isDark ? 0x7A_B2_F7 : 0x00_6D_D4))
        case .mixed: AnyShapeStyle(Color(hex: isDark ? 0xFF_C2_52 : 0x88_48_00))
        case .negative: AnyShapeStyle(Color(hex: isDark ? 0xFD_8C_87 : 0xD2_2D_39))
        case .none: AnyShapeStyle(InkColor.tertiary)
        }
    }
}

/// The top critics' average in its tier's ring — Discord's `lO`: a 32-point
/// disc of `#2e2e2e`, the score floored in white, and a 30-point ring
/// stroked to the score's share, turned so the gap sits centred on the right.
private struct OpenCriticRing: View {
    var score: Int
    /// The unfloored average, which is what the ring is filled to.
    var rating: Double
    var tier: OpenCriticTier

    var body: some View {
        let share = min(max(rating, 0), 100) / 100
        ZStack {
            Circle().fill(Color(hex: 0x2E_2E_2E))
            // Discord's `<circle r=16>` in a 36-unit box drawn at 30 points,
            // stroked 2.4 units: two points here.
            Circle()
                .inset(by: 2)
                .trim(from: 0, to: share)
                .stroke(Color(hex: tier.ringColorValue), lineWidth: 2)
                .rotationEffect(.degrees((1 - share) * 180))
                .frame(width: 30, height: 30)
            Text(score, format: .number)
                .font(.system(.subheadline, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .frame(width: 32, height: 32)
        .help("Top Critic Average")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Top Critic Average \(score)"))
    }
}

/// The facts table, and the row of marks under it.
struct GameDetailsSection: View {
    var rows: [GameDetailRow]
    var links: [GameWebsite]

    @Environment(\.openURL) private var openURL

    var body: some View {
        AsideSection(title: "Details") {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { divider }
                    detailRow(row)
                }
                if !links.isEmpty {
                    if !rows.isEmpty { divider }
                    linksRow
                }
                divider
                metadataCredit
            }
            // A region inside the aside's own pane, not a pane of its own —
            // §4 rule 2. See `GameAccountLinkCard`.
            .background(
                Color.white.opacity(0.05),
                in: .rect(cornerRadius: Radius.glass, style: .continuous)
            )
        }
    }

    /// Who the facts above came from.
    ///
    /// **A credit, and it is owed.** Every genre, company, release date,
    /// screenshot and cover on this page is IGDB's — the `third_party_skus`
    /// array names the igdb id on all three captured games — and Discord's own
    /// page carries the same line. It is a link because the credit is only
    /// useful if it goes somewhere.
    private var metadataCredit: some View {
        HStack(spacing: Spacing.base) {
            Text("Game metadata by")
                .font(.system(.caption))
                .foregroundStyle(InkColor.tertiary)
            Spacer(minLength: Spacing.base)
            Button { openURL(URL(string: "https://www.igdb.com")!) } label: {
                Text("IGDB")
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(Palette.accent)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens IGDB in your browser"))
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, Spacing.base)
    }

    private var divider: some View {
        Rectangle()
            .fill(Ink.quaternary)
            .frame(height: 0.5)
            .padding(.horizontal, Spacing.snug)
    }

    private func detailRow(_ row: GameDetailRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.snug) {
            Text(row.title)
                .font(.system(.subheadline))
                .foregroundStyle(InkColor.secondary)
            Spacer(minLength: Spacing.base)
            switch row.content {
            case .text(let value):
                Text(value)
                    .font(.system(.subheadline))
                    .foregroundStyle(InkColor.primary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            case .platforms(let groups):
                HStack(spacing: Spacing.base) {
                    ForEach(groups, id: \.self) { group in
                        Image(symbol: group.symbolName)
                            .font(.system(size: 12))
                            .foregroundStyle(InkColor.primary)
                            .help(group.title)
                            .accessibilityLabel(Text(group.title))
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, Spacing.base)
    }

    /// The game's own accounts, as brand marks.
    ///
    /// **The same object a profile's connections are**, drawn by the same view:
    /// these are the identical set of brands, and giving them a second treatment
    /// is what makes Twitch purple in one pane and grey in another.
    private var linksRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.snug) {
            Text("Links")
                .font(.system(.subheadline))
                .foregroundStyle(InkColor.secondary)
            Spacer(minLength: Spacing.base)
            HStack(spacing: 5) {
                ForEach(links) { link in
                    Button { openURL(link.url) } label: {
                        ConnectionMark(service: link.category.brandService ?? "link", side: 18)
                    }
                    .buttonStyle(.plain)
                    .help(link.category.title)
                    .accessibilityLabel(Text(link.category.title))
                }
            }
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, Spacing.base)
    }
}
