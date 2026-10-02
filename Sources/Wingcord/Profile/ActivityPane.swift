import AppKit
import SwiftUI
import WingcordCore

/// What somebody is doing right now — Discord's activity card, line for line.
///
/// **Which line says what is `ActivityCardContent`'s**, read out of Discord's
/// bundle and tested there; this view lays it out. The card Discord draws:
///
/// ```
/// Watching YouTube ▶︎                    the header, with the platform's mark
/// ┌──────┐ How to setup BL2 Mods          title
/// │ art  │ WholyMilk                      subtitle, then any third line
/// └──────┘ 🖥 0:02                         the clock, in the kind's glyph
/// [ Watch on YouTube                 ]    the app's buttons, stacked
/// ```
///
/// The two images are separate assets and are resolved separately: the large
/// one is the game's art and the small one is the *publisher's* mark, which is
/// what makes "Counter-Strike 2 **with Medal**" legible as two things at once.
struct CurrentActivityCard: View {
    var activity: Activity
    /// The links behind the buttons, in the same order as their labels. Empty
    /// until the metadata route answers, and empty forever for the vast
    /// majority of activities — see `ProfilePresentation.activityButtonURLs`.
    var buttonURLs: [URL]
    /// Where the game is sold, when it is sold anywhere this client can address.
    /// See `Game.storeOffers`.
    var storeOffers: [GameStoreOffer] = []
    var ground: ProfileGround
    /// Opens the game this activity is about. Nil where there is nothing to
    /// open, which is every activity that is not a game.
    var openGame: (() -> Void)?
    /// The app's own icon, which stands in where a presence publishes no art.
    ///
    /// Passed in rather than read from the store here: this view holds no
    /// model reference, which is what lets the pane above it be compared.
    var applicationIconURL: URL?
    /// Whether this card draws its own plate.
    ///
    /// **False where a surface already puts it in one.** The full profile wraps
    /// this in a `ProfileSlab`, and a plate inside that is a card drawn inside a
    /// card. The mini card has no slab, so it carries the plate itself.
    var platesItself: Bool = true
    /// The chips of the Recent activity entry this is the live end of — see
    /// `RecentActivity.records`. Discord draws them after the clock.
    var traits: [RecentActivity.Trait] = []
    /// Whether this is the reader's own activity. Discord offers somebody
    /// else's Spotify session to listen to; the reader's own, nothing.
    var isOwn = false
    /// Listen Along on a Spotify session — see `AppModel.listenAlongOffer`.
    /// Nil draws none.
    var listenAlong: ListenAlongOffer?

    @Environment(\.openURL) private var openURL

    /// Discord's popout art, and the badge that rides its corner.
    private static let artworkSide: CGFloat = 60
    private static let badgeSide: CGFloat = 22
    /// Concentric with the card around it: its 24-point corner less the
    /// 16-point margin the card sits in. Discord's own is 8.
    private static let corner = Radius.row

    var body: some View {
        let content = ActivityCardContent(activity)
        VStack(alignment: .leading, spacing: Spacing.base) {
            if let header = content.header {
                headerRow(header, platform: content.platform)
            }
            HStack(alignment: .center, spacing: Spacing.base) {
                artwork(placeholder: content.clockGlyph)
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    title(content)
                    if let subtitle = content.subtitle {
                        line(subtitle, url: content.subtitleURL)
                    }
                    if let detail = content.detail {
                        line(detail, url: content.detailURL)
                    }
                    entries(content)
                    if content.showsProgress, let start = activity.startedAt, let end = activity.endsAt {
                        ActivityProgressBar(start: start, end: end)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            buttons
            spotifyControls
            store
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(platesItself ? Spacing.base : 0)
        .background {
            if platesItself { plate }
        }
    }

    // MARK: The parts

    /// "Watching YouTube", and the platform's mark in the quiet ink Discord
    /// masks it in — a brand's own colour would shout over the words.
    private func headerRow(_ text: String, platform: String?) -> some View {
        HStack(spacing: Spacing.tight) {
            Text(text)
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
            if let platform, BrandMark.mark(for: platform) != nil {
                BrandGlyph(service: platform)
                    .fill(InkColor.tertiary)
                    .frame(width: 12, height: 12)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The large asset, with the small one riding its corner.
    ///
    /// **A plate under both**, because an activity that publishes no art at all
    /// is the common case and an empty hole is worse than a mark. The plate is
    /// the ground's own panel fill, so it belongs to the person's surface rather
    /// than being a grey box dropped on it.
    @ViewBuilder
    private func artwork(placeholder: ActivityStatusLine.Glyph) -> some View {
        // A Spotify session's cover opens what is playing, as Discord's does.
        if let track = activity.spotifyTrackURL {
            Button { openInSpotify(track) } label: { artworkStack(placeholder: placeholder) }
                .buttonStyle(.plain)
                .help("Open in Spotify")
        } else {
            artworkStack(placeholder: placeholder)
        }
    }

    private func artworkStack(placeholder: ActivityStatusLine.Glyph) -> some View {
        ZStack(alignment: .bottomTrailing) {
            RemoteImage(
                // **The application's own icon where the presence has no
                // artwork.** Rich presence art is optional and plenty of games
                // publish none — Roblox publishes a name and nothing else.
                url: activity.largeArtworkURL(side: Self.artworkSide) ?? applicationIconURL,
                side: Self.artworkSide,
                bucket: .artwork
            ) {
                ZStack {
                    Rectangle().fill(ground.panelFill)
                    Image(systemName: placeholder.symbolName)
                        .font(.system(size: 20))
                        .foregroundStyle(InkColor.tertiary)
                }
            }
            .aspectRatio(contentMode: .fill)
            .frame(width: Self.artworkSide, height: Self.artworkSide)
            .clipShape(.rect(cornerRadius: Self.corner, style: .continuous))

            if let small = activity.smallArtworkURL(side: Self.badgeSide) {
                RemoteImage(url: small, side: Self.badgeSide, bucket: .thumbnail) {
                    Circle().fill(Palette.surfaceRaised)
                }
                .frame(width: Self.badgeSide, height: Self.badgeSide)
                .clipShape(.circle)
                // The ring is what separates the badge from the art under it.
                // Without it a dark mark on dark box art disappears.
                .overlay { Circle().strokeBorder(Palette.canvas, lineWidth: 2) }
                .offset(x: 6, y: 6)
                .help(activity.smallText ?? "")
                .accessibilityLabel(Text(activity.smallText ?? "Publisher"))
            }
        }
        .frame(width: Self.artworkSide, height: Self.artworkSide)
        .help(activity.largeText ?? "")
    }

    /// The card's title, and a way in when there is one.
    ///
    /// **A button only where it opens something** — the game's profile, or
    /// the page the app linked the line to. Anything else stays plain text
    /// rather than becoming a control that does nothing — `INVARIANTS.md` §5.5.
    @ViewBuilder
    private func title(_ content: ActivityCardContent) -> some View {
        let label = Text(content.title)
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(InkColor.primary)
            .lineLimit(1)
        if let openGame {
            Button(action: openGame) { label.contentShape(.rect) }
                .buttonStyle(.plain)
                .help("Open \(activity.name)")
        } else if let url = content.titleURL {
            link(label, to: url)
        } else {
            label
        }
    }

    @ViewBuilder
    private func line(_ text: String, url: URL?) -> some View {
        let label = Text(text)
            .font(.system(.caption))
            .foregroundStyle(InkColor.secondary)
            .lineLimit(1)
        if let url { link(label, to: url) } else { label }
    }

    private func link(_ label: some View, to url: URL) -> some View {
        Button { openURL(url) } label: { label.contentShape(.rect) }
            .buttonStyle(.plain)
            .help(url.host ?? url.absoluteString)
            .accessibilityHint(Text("Opens \(url.host ?? "a website") in your browser"))
    }

    /// The row under the lines: a game's party, the clock, a show's episode.
    @ViewBuilder
    private func entries(_ content: ActivityCardContent) -> some View {
        if content.party != nil || content.clockStart != nil || content.episode != nil
            || traits.contains(where: { $0.label != nil })
        {
            HStack(spacing: Spacing.base) {
                if let party = content.party {
                    entry(symbol: "person.2.fill", text: party)
                }
                if let start = content.clockStart {
                    ActivityClock(start: start, glyph: content.clockGlyph)
                }
                if let episode = content.episode {
                    entry(symbol: "scroll.fill", text: episode)
                }
                ActivityTraitChips(traits: traits)
            }
        }
    }

    private func entry(symbol: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(.caption))
                .lineLimit(1)
        }
        .foregroundStyle(InkColor.secondary)
        .accessibilityElement(children: .combine)
    }

    /// The app's own buttons, **stacked and full width** — Discord's popout
    /// puts each on a row of its own rather than squeezing two labels into
    /// one.
    ///
    /// **Paired by index, and a label with no address is not drawn.** The labels
    /// arrive over the gateway and the links come from a separate route, so
    /// between the presence landing and the metadata answering there is a beat
    /// where the labels exist alone — and a button drawn in that beat opens
    /// nothing.
    @ViewBuilder
    private var buttons: some View {
        let pairs = zip(activity.buttons, buttonURLs).map { ($0, $1) }
        if !pairs.isEmpty {
            VStack(spacing: Spacing.base) {
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                    Button { openURL(pair.1) } label: {
                        Text(pair.0)
                            .font(.system(.subheadline, weight: .medium))
                            .foregroundStyle(InkColor.primary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .interactiveChromeOverMedia()
                    .accessibilityHint(Text("Opens \(pair.1.host ?? "a website") in your browser"))
                }
            }
        }
    }

    /// Discord's two Spotify controls (module `402857`'s `H`): Listen Along,
    /// then Play on Spotify, side by side — on somebody else's session, and
    /// only where it offers them (`PLAY`, `SYNC`).
    ///
    /// **Listen Along follows them on the reader's own Spotify** — see
    /// `SessionController+ListenAlong` — and says, in Discord's words, why it
    /// is dimmed when it is. Play on Spotify hands the track to Spotify.
    @ViewBuilder
    private var spotifyControls: some View {
        if !isOwn, let track = activity.spotifyTrackURL, activity.offersPlay || activity.offersSync {
            HStack(spacing: Spacing.base) {
                if activity.offersSync, let listenAlong {
                    spotifyControl("Listen Along", action: listenAlong.join)
                        .disabled(!listenAlong.isEnabled)
                        .help(listenAlong.help)
                }
                if activity.offersPlay {
                    spotifyControl("Play on Spotify") { openInSpotify(track) }
                }
            }
        }
    }

    private func spotifyControl(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .interactiveChromeOverMedia()
    }

    /// The Spotify app, where one is installed to take `spotify:` addresses,
    /// and Spotify's site otherwise.
    private func openInSpotify(_ track: URL) {
        if let uri = URL(string: "spotify:track:\(track.lastPathComponent)"),
           NSWorkspace.shared.urlForApplication(toOpen: uri) != nil {
            NSWorkspace.shared.open(uri)
        } else {
            openURL(track)
        }
    }

    /// Where to get the game.
    ///
    /// **Under the app's own buttons, never instead of them.** Discord composes
    /// it the same way — its store call to action comes after whatever primary
    /// control the activity already has, in the same column — because the
    /// app's Join or Listen is what somebody came to the card for and the store
    /// is what they do if they cannot.
    ///
    /// **One store is a button; two are a menu.** Two full-width buttons
    /// stacked under a small card make the card mostly chrome, and the second
    /// store is a choice rather than a second action. The menu's word is
    /// *Play*, which is what Discord puts on it.
    @ViewBuilder
    private var store: some View {
        if storeOffers.count == 1, let offer = storeOffers.first {
            Button { openURL(offer.url) } label: {
                storeLabel(offer.store, text: offer.store.callToAction)
            }
            .buttonStyle(.plain)
            .interactiveChromeOverMedia()
            .help("Open \(offer.store.title) in your browser")
            .accessibilityHint(Text("Opens \(offer.store.title) in your browser"))
        } else if storeOffers.count > 1 {
            // The frame, the hit region and the material go on the MENU, after
            // the style — a borderless menu lays its own label out. §1, "A
            // borderless menu ignores a frame set on its label".
            Menu {
                ForEach(storeOffers) { offer in
                    Button(offer.store.title) { openURL(offer.url) }
                }
            } label: {
                storeLabel(nil, text: "Play")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(maxWidth: .infinity)
            .contentShape(.capsule)
            .interactiveChromeOverMedia()
            .accessibilityLabel(Text("Play"))
            .accessibilityHint(Text("Choose a store to open in your browser"))
        }
    }

    /// The full-width row both shapes wear. Its own `maxWidth` is what sizes the
    /// button; inside the menu it is inert and the menu carries the frame.
    private func storeLabel(_ store: GameStore?, text: String) -> some View {
        HStack(spacing: 6) {
            if let store {
                ConnectionMark(service: store.brandService, side: 16)
            }
            Text(text)
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .contentShape(.capsule)
    }

    private var plate: some View {
        ProfilePanelPlate(ground: ground)
    }
}

/// The clock, ticking, in the activity's own glyph.
///
/// **Green, as Discord draws it** — the one live thing on the card — in the
/// system's own green, which holds its contrast in either room. Its own view so
/// the second-by-second redraw is the clock and nothing else on the card.
///
/// `SwiftUI.TimelineView` fully qualified: this app has a `TimelineView` of its
/// own, and the unqualified name resolves to the message canvas.
private struct ActivityClock: View {
    var start: Date
    var glyph: ActivityStatusLine.Glyph

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: glyph.symbolName)
                .font(.system(size: 10, weight: .semibold))
            SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(ActivityCardContent.clock(Int(context.date.timeIntervalSince(start))))
                    .font(.system(.caption).monospacedDigit())
            }
        }
        .foregroundStyle(Palette.affirmative)
        .accessibilityElement(children: .combine)
    }
}

/// Music or a video with both ends known: elapsed, a bar, and the whole.
///
/// **Measured inside the overlay that draws it**, and consumed in the same
/// pass — the one place a proportion has to be drawn against a box's own
/// width (§1, "A surface sizes to its content with a nil proposal").
private struct ActivityProgressBar: View {
    var start: Date
    var end: Date

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
            let total = max(0, end.timeIntervalSince(start))
            let elapsed = min(total, max(0, context.date.timeIntervalSince(start)))
            HStack(spacing: Spacing.base) {
                Text(ActivityCardContent.clock(Int(elapsed)))
                Capsule()
                    .fill(Palette.edge)
                    .frame(height: 2)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(InkColor.primary)
                                // Discord's floor: a bar that has started is
                                // never an empty track.
                                .frame(width: max(4, proxy.size.width * (total > 0 ? elapsed / total : 0)))
                        }
                    }
                Text(ActivityCardContent.clock(Int(total)))
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(InkColor.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Playback progress"))
            .accessibilityValue(Text(
                "\(ActivityCardContent.clock(Int(elapsed))) of \(ActivityCardContent.clock(Int(total)))"
            ))
        }
    }
}

/// One row of somebody's recent activity.
///
/// **A record, not a presence.** What it says is what the content inventory
/// sent: what was played, when it stopped, and the traits that came with it —
/// a streak, a marathon sitting, a first time, a game that is trending. Nothing
/// is summed and nothing is inferred, which is why there is no "hours played"
/// anywhere on it.
struct RecentActivityRow: View {
    var entry: RecentActivity
    var ground: ProfileGround
    /// The game's own box art, once `/games` has answered for it. Nil for a
    /// music row and for a game that has not landed yet.
    var coverURL: URL?
    /// The application's own icon, which is what an activity that is not a
    /// tracked game has instead of box art.
    var applicationIconURL: URL?
    /// Opens the game profile. Nil for a row with no game behind it.
    var openGame: (() -> Void)?

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    private static let iconSide: CGFloat = Metrics.activityRecentIcon

    var body: some View {
        content
            .padding(Spacing.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Radius.glass, style: .continuous)
                    .fill(isHovering && openGame != nil ? Palette.hoverFill : .clear)
            }
            .contentShape(.rect(cornerRadius: Radius.glass, style: .continuous))
            .onHover { hovering in
                guard isHovering != hovering else { return }
                isHovering = hovering
            }
            .animation(motion.hover, value: isHovering)
    }

    @ViewBuilder
    private var content: some View {
        if let openGame {
            // The whole row is the target, which is what Discord's is: the
            // artwork and the name are the two things anybody aims at, and
            // giving each its own hit region leaves dead space between them.
            Button(action: openGame) { row }
                .buttonStyle(.plain)
                .help("Open \(entry.subject.title)")
        } else {
            row
        }
    }

    private var row: some View {
        HStack(alignment: .center, spacing: Spacing.snug) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.subject.title)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(InkColor.primary)
                    .lineLimit(1)
                if let subtitle = entry.subject.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(.caption))
                        .foregroundStyle(InkColor.secondary)
                        .lineLimit(1)
                }
                facts
            }
            Spacer(minLength: 0)
        }
    }

    private var icon: some View {
        Group {
            if let url = artworkURL {
                RemoteImage(url: url, side: Self.iconSide, bucket: .thumbnail) {
                    Rectangle().fill(ground.panelFill)
                }
                .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(ground.panelFill)
                    Image(systemName: entry.subject.symbolName)
                        .font(.system(size: 15))
                        .foregroundStyle(InkColor.tertiary)
                }
            }
        }
        .frame(width: Self.iconSide, height: Self.iconSide)
        .clipShape(.rect(cornerRadius: Radius.row, style: .continuous))
    }

    private var artworkURL: URL? {
        if case .listening(_, _, let url) = entry.subject { return url }
        // Box art first, then the application's own icon. `/games` answers
        // only for titles Discord tracks as games, so an activity like Wordle
        // has no cover and every one of its rows drew the placeholder.
        return coverURL ?? applicationIconURL
    }

    /// The kind glyph, when it happened, and its chips — on one line, because
    /// every one of them is two or three words and stacking them would make a
    /// row of small facts taller than the name above it.
    private var facts: some View {
        HStack(spacing: Spacing.snug) {
            if let when = timestampLabel {
                HStack(spacing: 4) {
                    Image(systemName: entry.subject.symbolName)
                        .font(.system(size: 9))
                    Text(when)
                        .font(.system(.caption))
                }
                .foregroundStyle(entry.isLive ? Palette.presenceOnline : InkColor.tertiary)
            }
            ActivityTraitChips(traits: entry.traits)
        }
        .accessibilityElement(children: .combine)
    }

    /// "Playing now", "1d ago", "3h ago".
    ///
    /// **Relative, and coarse on purpose.** These entries are days and weeks
    /// old; a wall-clock date on every one of them is a column of numbers
    /// nobody reads, and it is not how Discord's own list is written.
    private var timestampLabel: String? {
        if entry.isLive { return "Playing now" }
        guard let when = entry.occurredAt else { return nil }
        return when.formatted(
            .relative(presentation: .numeric, unitsStyle: .narrow)
        )
    }
}

/// An entry's chips — "21x Streak", "Trending" — in a row, as Discord writes
/// them after the clock on a live card and after the date on a recent one.
/// Traits with no words (a duration, the live flag) draw nothing.
struct ActivityTraitChips: View {
    var traits: [RecentActivity.Trait]

    var body: some View {
        ForEach(Array(traits.enumerated()), id: \.offset) { _, trait in
            if let label = trait.label {
                HStack(spacing: 4) {
                    if let symbolName = trait.symbolName {
                        Image(systemName: symbolName)
                            .font(.system(size: 9))
                    }
                    Text(label)
                        .font(.system(.caption))
                }
                .foregroundStyle(InkColor.tertiary)
            }
        }
    }
}
