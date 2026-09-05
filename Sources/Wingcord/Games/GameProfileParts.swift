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
                case .trailer(let url):
                    // Muted and looping, like every store page's own hero. The
                    // page is opened to look at a game, not to be played at.
                    LoopingVideo(url: url)
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
        .glassEffect(
            .clear.tint(Palette.flyoutTint),
            in: .rect(cornerRadius: 22, style: .continuous)
        )
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
                    // **A trailer's thumbnail is not the trailer.** An `.mp4`
                    // handed to the image path decodes to nothing and the slot
                    // stays grey for the life of the page, so a trailer wears a
                    // plate with a play mark on it instead.
                    if item.isTrailer {
                        ZStack {
                            Palette.surfaceRaised
                            Image(systemName: "play.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(InkColor.primary)
                        }
                    } else {
                        RemoteImage(url: item.id, side: 240, bucket: .artwork) {
                            Palette.surfaceRaised
                        }
                        .aspectRatio(contentMode: .fill)
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
            Image(systemName: symbolName)
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
    /// Nil where the reader is not in that server, and the heading then carries
    /// no action.
    var openChannel: (() -> Void)?

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
                        AnnouncementCard(announcement: announcement)
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

    var body: some View {
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
                Text(announcement.text)
                    .font(.system(.caption))
                    .foregroundStyle(InkColor.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
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
        .glassEffect(.clear.tint(Palette.flyoutTint), in: .rect(cornerRadius: Radius.glass, style: .continuous))
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
struct GameStoreButton: View {
    var store: GameWebsite

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { openURL(store.url) } label: {
            HStack(spacing: Spacing.base) {
                ConnectionMark(service: store.category.brandService ?? "link", side: 18)
                // **"View on Steam", not "Launch on Steam".** The handoff says
                // Launch and this client cannot launch anything — the button
                // opens the store page in a browser, and it has to say the thing
                // it actually does.
                Text("View on \(store.category.title)")
                    .font(.system(.subheadline, weight: .semibold))
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
        .help("Open the \(store.category.title) page in your browser")
    }
}

/// The offer to connect an in-game account.
///
/// Drawn only for a game whose widget application publishes an entrypoint —
/// Arknights and Wuthering Waves do, and it is why their profiles show this
/// where The Sims shows a store button. The address is the game's, so it opens
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

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Link your account")
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(InkColor.primary)
                        Text("Show your in-game stats on your profile.")
                            .font(.system(.caption))
                            .foregroundStyle(InkColor.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Button { openURL(link.url) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 11))
                        Text("Link on \(link.applicationName)")
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
                            if community.isVerified {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.affirmative)
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

/// Steam's and OpenCritic's verdicts.
struct GameReviewsSection: View {
    var reviews: GameReviews
    var openCriticURL: URL?

    @Environment(\.openURL) private var openURL

    var body: some View {
        AsideSection(title: "Reviews") {
            VStack(alignment: .leading, spacing: Spacing.margin) {
                ForEach(reviews.steam?.rows ?? []) { row in
                    steamRow(row)
                }
                if let critic = reviews.openCritic, let score = critic.score {
                    HStack(spacing: Spacing.base) {
                        Text("OpenCritic")
                            .font(.system(.subheadline))
                            .foregroundStyle(InkColor.secondary)
                        Spacer(minLength: Spacing.base)
                        OpenCriticScore(score: score, tier: critic.tier)
                    }
                    .contentShape(.rect)
                    .onTapGesture { if let openCriticURL { openURL(openCriticURL) } }
                }
            }
        }
    }

    /// One aggregate: its name, its verdict and count, and the share as a bar.
    ///
    /// **The bar is the one number on this page that is genuinely a
    /// proportion.** Everything the mockup put beside it — hours played,
    /// achievements, friends who play — was invented; `rating` is a real
    /// positive share on the wire and drawing it as a real bar is what the
    /// mockup got right.
    private func steamRow(_ row: GameReviews.SteamReviews.Row) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
                Text(row.title)
                    .font(.system(.subheadline))
                    .foregroundStyle(InkColor.secondary)
                Spacer(minLength: Spacing.base)
                Text(row.verdict.title)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Color(hex: row.verdict.colorValue))
                Text("(\(row.count.formatted(.number)))")
                    .font(.system(.caption).monospacedDigit())
                    .foregroundStyle(InkColor.tertiary)
            }
            bar(share: row.rating / 100, tint: Color(hex: row.verdict.colorValue))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text("\(row.title): \(row.verdict.title), \(Int(row.rating)) per cent of \(row.count)")
        )
    }

    /// **A reader over the track, and `containerRelativeFrame` was wrong here.**
    /// That modifier resolves against the nearest *container* — the aside's
    /// whole scroll view — not against the capsule it is inside, so every bar
    /// came out 320 points long, clipped to the track, and all three read as a
    /// hundred per cent whatever the share was. A `GeometryReader` inside the
    /// overlay is the right instrument: it is handed the track's own width and
    /// the value is consumed in the same pass that produced it, so there is no
    /// extra layout pass and no measurement written into `@State` that could
    /// outlive what it measured.
    private func bar(share: Double, tint: Color) -> some View {
        Capsule()
            .fill(Color.white.opacity(0.1))
            .frame(height: 5)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [tint.mix(with: .white, by: 0.3), tint],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: proxy.size.width * min(max(share, 0), 1))
                }
            }
    }
}

/// OpenCritic's number in its tier's ring.
private struct OpenCriticScore: View {
    var score: Int
    var tier: OpenCriticTier?

    private var color: Color {
        tier.map { Color(hex: $0.colorValue) } ?? InkColor.secondary
    }

    var body: some View {
        HStack(spacing: Spacing.base) {
            if let tier {
                Text(tier.title.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(color)
            }
            Text(score, format: .number)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(InkColor.primary)
                .frame(width: 28, height: 28)
                .overlay { Circle().strokeBorder(color, lineWidth: 2) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("OpenCritic \(score)\(tier.map { ", \($0.title)" } ?? "")"))
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
                        Image(systemName: group.symbolName)
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
