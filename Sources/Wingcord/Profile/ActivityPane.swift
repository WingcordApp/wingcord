import SwiftUI
import WingcordCore

/// What somebody is doing right now.
///
/// **The whole of a rich presence, which this client used to throw most of
/// away.** An app publishes a large image, a small image that rides its corner,
/// hover text for each, two lines of prose, a clock and up to two buttons —
/// Medal sends every one of them — and the old card drew a game-controller
/// glyph and the app's name.
///
/// The two images are separate assets and are resolved separately: the large one
/// is the game's art and the small one is the *publisher's* mark, which is what
/// makes "Counter-Strike 2 **with Medal**" legible as two things at once.
struct CurrentActivityCard: View {
    var activity: Activity
    /// The links behind the buttons, in the same order as their labels. Empty
    /// until the metadata route answers, and empty forever for the vast
    /// majority of activities — see `ProfilePresentation.activityButtonURLs`.
    var buttonURLs: [URL]
    var ground: ProfileGround
    /// Opens the game this activity is about. Nil where there is nothing to
    /// open, which is every activity that is not a game.
    var openGame: (() -> Void)?

    @Environment(\.openURL) private var openURL

    private static let artworkSide: CGFloat = 68
    private static let badgeSide: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            header
            HStack(alignment: .top, spacing: Spacing.snug) {
                artwork
                VStack(alignment: .leading, spacing: 2) {
                    title
                    if let details = activity.details, !details.isEmpty {
                        Text(details)
                            .font(.system(.subheadline))
                            .foregroundStyle(InkColor.secondary)
                            .lineLimit(2)
                    }
                    if let state = activity.state, !state.isEmpty {
                        Text(state)
                            .font(.system(.subheadline))
                            .foregroundStyle(InkColor.tertiary)
                            .lineLimit(2)
                    }
                    clock
                }
                Spacer(minLength: 0)
            }
            buttons
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // **A plate of its own, which this card has never had.** Discord draws
        // the whole block — verb, art, lines, clock and buttons — on a
        // translucent panel, so on a themed profile it reads as an object lying
        // on the person's colour rather than as text typed onto it. It is the
        // ground's own `panelFill`, which is Discord's `PROFILE_GRADIENT_SECTION_BOX`
        // — black at 45 % on a dark card and white at 45 % on a light one — so
        // it inverts with the card instead of needing a second rule.
        .padding(platesItself ? Spacing.snug : 0)
        .background {
            if platesItself {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(ground.panelFill)
            }
        }
    }

    /// "Playing", "Listening to Spotify" — the verb, with a live dot in front.
    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Palette.presenceOnline)
                .frame(width: 6, height: 6)
            Text(kindLabel)
                .font(Typeface.sectionHeader)
                .foregroundStyle(InkColor.tertiary)
                .textCase(.uppercase)
        }
        .accessibilityElement(children: .combine)
    }

    private var kindLabel: String {
        switch activity.kind {
        case .playing: "Playing"
        case .streaming: "Streaming"
        case .listening: "Listening"
        case .watching: "Watching"
        case .competing: "Competing"
        case .custom, .unknown: "Now"
        }
    }

    /// The large asset, with the small one riding its corner.
    ///
    /// **A plate under both**, because an activity that publishes no art at all
    /// is the common case and an empty 68-point hole is worse than a mark. The
    /// plate is the ground's own panel fill, so it belongs to the person's
    /// surface rather than being a grey box dropped on it.
    /// The app's own icon, and the request that fetches it.
    ///
    /// Passed in rather than read from the store here: this view holds no
    /// model reference, which is what lets the pane above it be compared.
    var applicationIconURL: URL?
    /// Whether this card draws its own plate.
    ///
    /// **False where a surface already puts it in one.** The full profile wraps
    /// this in a `ProfileSlab`, and adding a second plate inside the first is a
    /// card drawn inside a card — which is what happened the moment the mini
    /// profile got the plate it was missing. The mini card has no slab, so it
    /// carries the plate itself.
    var platesItself: Bool = true

    private var artwork: some View {
        ZStack(alignment: .bottomTrailing) {
            RemoteImage(
                // **The application's own icon where the presence has no
                // artwork.** Rich presence art is optional and plenty of games
                // publish none — Roblox publishes a name and nothing else —
                // which drew a grey plate with a controller in it where
                // Discord draws the app icon it has for every one of them.
                url: activity.largeArtworkURL(side: Self.artworkSide) ?? applicationIconURL,
                side: Self.artworkSide,
                bucket: .artwork
            ) {
                ZStack {
                    Rectangle().fill(ground.panelFill)
                    Image(systemName: activity.kind == .listening ? "music.note" : "gamecontroller.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(InkColor.tertiary)
                }
            }
            .aspectRatio(contentMode: .fill)
            .frame(width: Self.artworkSide, height: Self.artworkSide)
            .clipShape(.rect(cornerRadius: Radius.chip, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .strokeBorder(Ink.quaternary, lineWidth: 1)
            }

            if let small = activity.smallArtworkURL(side: Self.badgeSide) {
                RemoteImage(url: small, side: Self.badgeSide, bucket: .thumbnail) {
                    Circle().fill(Palette.surfaceRaised)
                }
                .frame(width: Self.badgeSide, height: Self.badgeSide)
                .clipShape(.circle)
                // The ring is what separates the badge from the art under it.
                // Without it a dark mark on dark box art disappears.
                .overlay { Circle().strokeBorder(Palette.canvas, lineWidth: 2) }
                .offset(x: 7, y: 7)
                .help(activity.smallText ?? "")
                .accessibilityLabel(Text(activity.smallText ?? "Publisher"))
            }
        }
        .frame(width: Self.artworkSide, height: Self.artworkSide)
        .help(activity.largeText ?? "")
    }

    /// The activity's name, and a way into the game when there is one.
    ///
    /// **A button only where it opens something.** An app with no game profile
    /// behind it stays plain text rather than becoming a control that does
    /// nothing when clicked — `INVARIANTS.md` §5.5.
    @ViewBuilder
    private var title: some View {
        if let openGame {
            Button(action: openGame) {
                Text(activity.name)
                    .font(.system(.headline))
                    .foregroundStyle(InkColor.primary)
                    .lineLimit(1)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Open \(activity.name)")
        } else {
            Text(activity.name)
                .font(.system(.headline))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
        }
    }

    /// The clock, ticking.
    ///
    /// **Two shapes, and which one is drawn is a fact about the payload.** An
    /// activity with an end — a track — counts toward it and prints the pair;
    /// one without counts up from its start. An activity with neither prints
    /// nothing, which is most of them.
    ///
    /// `SwiftUI.TimelineView` fully qualified: this app has a `TimelineView` of
    /// its own, and the unqualified name resolves to the message canvas.
    @ViewBuilder
    private var clock: some View {
        if let startedAt = activity.startedAt {
            SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                    Text(clockLabel(now: context.date, from: startedAt))
                        .font(.system(.caption).monospacedDigit())
                }
                // **`inkAccent`, not `accent`.** The second is a surface
                // colour — for a derived theme it is the avatar's own dominant
                // colour — and setting text in it drew a black clock on a dark
                // card for anybody with a dark avatar.
                .foregroundStyle(ground.inkAccent ?? InkColor.secondary)
            }
            .padding(.top, 3)
        }
    }

    private func clockLabel(now: Date, from startedAt: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(startedAt)))
        guard let endsAt = activity.endsAt else {
            return Self.clock(elapsed) + " elapsed"
        }
        let total = max(0, Int(endsAt.timeIntervalSince(startedAt)))
        return "\(Self.clock(min(elapsed, total))) / \(Self.clock(total))"
    }

    /// `mm:ss` under an hour, `h:mm:ss` over it. A two-hour session written
    /// "127:14" is a number nobody parses — the same rule the invitation card's
    /// status line already follows.
    static func clock(_ seconds: Int) -> String {
        let s = seconds % 60, m = (seconds / 60) % 60, h = seconds / 3600
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// The app's own two buttons.
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
            HStack(spacing: Spacing.base) {
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
            ForEach(Array(entry.traits.enumerated()), id: \.offset) { _, trait in
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
