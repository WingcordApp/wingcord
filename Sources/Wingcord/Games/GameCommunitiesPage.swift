import SwiftUI
import WingcordCore

/// A game profile's Communities tab — Discord's "Browse Similar Communities"
/// (`c82450…`'s `t3`): the servers the game lists, as cards in a grid or rows in
/// a list, with a language filter once they span more than one.
///
/// **The layout choice is the reader's and it is remembered**, as Discord's own
/// store keeps it across games; the excluded languages are per game, because a
/// language filter for one game's servers says nothing about another's.
struct GameCommunitiesPage: View {
    var gameID: ApplicationID

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @AppStorage("gameCommunitiesLayout") private var layout: CommunitiesLayout = .grid
    @State private var excludedLocales: Set<String> = []

    var body: some View {
        let tiles = model.communityTiles(for: gameID)
        let locales = Self.locales(in: tiles ?? [])
        let shown = (tiles ?? []).filter { tile in
            tile.preferredLocale.map { !excludedLocales.contains($0) } ?? true
        }
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.margin) {
                HStack(spacing: Spacing.snug) {
                    Text("Browse Similar Communities")
                        .font(.system(.title2, weight: .bold))
                        .foregroundStyle(InkColor.primary)
                    Spacer(minLength: Spacing.base)
                    // Discord offers the filter only where it would filter
                    // something: two languages or more.
                    if locales.count >= 2 {
                        languageMenu(locales)
                    }
                    SegmentedPicker(
                        options: [
                            .init(CommunitiesLayout.grid, "Grid", symbolName: "square.grid.2x2.fill"),
                            .init(CommunitiesLayout.list, "List", symbolName: "list.bullet"),
                        ],
                        selection: $layout
                    )
                }
                if let tiles {
                    if tiles.isEmpty {
                        ContentUnavailableView(
                            "No communities to show",
                            systemImage: "person.3.fill",
                            description: Text("Discord didn't send this game's servers. Try again in a moment.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 240)
                    } else {
                        cards(shown)
                    }
                } else {
                    skeletons
                }
            }
            .padding(.horizontal, Spacing.margin + 2)
            .padding(.bottom, Spacing.group)
        }
        .scrollIndicators(.never)
        .animation(motion.standard, value: layout)
        .animation(motion.standard, value: excludedLocales)
        .task { model.loadCommunities(for: gameID) }
    }

    @ViewBuilder
    private func cards(_ tiles: [GameCommunityTile]) -> some View {
        switch layout {
        case .grid:
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 260, maximum: 420), spacing: Spacing.snug)],
                alignment: .leading,
                spacing: Spacing.snug
            ) {
                ForEach(tiles) { tile in
                    CommunityServerCard(tile: tile, isRow: false) { model.openCommunity(tile.guildID, from: gameID) }
                }
            }
        case .list:
            LazyVStack(alignment: .leading, spacing: Spacing.base) {
                ForEach(tiles) { tile in
                    CommunityServerCard(tile: tile, isRow: true) { model.openCommunity(tile.guildID, from: gameID) }
                }
            }
        }
    }

    /// Eight plates while the cards are out — Discord's count.
    private var skeletons: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 260, maximum: 420), spacing: Spacing.snug)],
            spacing: Spacing.snug
        ) {
            ForEach(0..<8, id: \.self) { _ in
                RoundedRectangle(cornerRadius: Radius.glass, style: .continuous)
                    .fill(Palette.hoverFill)
                    .frame(height: 112)
            }
        }
        .accessibilityLabel(Text("Loading communities"))
    }

    private func languageMenu(_ locales: [String]) -> some View {
        Menu {
            ForEach(locales, id: \.self) { locale in
                Toggle(isOn: Binding(
                    get: { !excludedLocales.contains(locale) },
                    set: { shown in
                        if shown { excludedLocales.remove(locale) } else { excludedLocales.insert(locale) }
                    }
                )) {
                    Text(Self.languageName(locale))
                }
            }
        } label: {
            Label("Languages", systemImage: "globe")
                .labelStyle(.iconOnly)
                .font(Typeface.controlGlyph)
                .foregroundStyle(InkColor.primary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // **On the menu, after its style** — a borderless menu lays its label
        // out itself and ignores a frame set there (INVARIANTS §1), which drew
        // a bare globe beside the strip. One height with the strip beside it.
        .frame(width: SegmentedPicker<CommunitiesLayout>.stripHeight,
               height: SegmentedPicker<CommunitiesLayout>.stripHeight)
        .contentShape(.circle)
        .glassEffect(.regular.interactive(), in: .circle)
        .help("Filter by language")
    }

    /// The languages the servers speak, most common first.
    static func locales(in tiles: [GameCommunityTile]) -> [String] {
        var counts: [String: Int] = [:]
        for tile in tiles { if let locale = tile.preferredLocale { counts[locale, default: 0] += 1 } }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }

    static func languageName(_ locale: String) -> String {
        Locale.current.localizedString(forIdentifier: locale) ?? locale
    }
}

/// How the Communities tab lays its servers out.
enum CommunitiesLayout: String, Hashable, Sendable {
    case grid
    case list
}

/// One community: its icon, its mark and name, what it says about itself, and
/// how many are there. A press opens it — or previews it, for a server the
/// reader is not in.
private struct CommunityServerCard: View {
    var tile: GameCommunityTile
    var isRow: Bool
    var open: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    private var iconSide: CGFloat { isRow ? 40 : 56 }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: Spacing.snug) {
                RemoteImage(url: tile.iconURL, side: iconSide) {
                    Text(tile.monogram)
                        .font(.system(size: iconSide * 0.36, weight: .semibold))
                        .foregroundStyle(InkColor.primary)
                        .frame(width: iconSide, height: iconSide)
                        .background(Palette.hoverFill)
                }
                .frame(width: iconSide, height: iconSide)
                .clipShape(.rect(cornerRadius: iconSide * 0.28, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        if let mark = tile.mark { GuildMarkBadge(mark: mark, side: 16) }
                        Text(tile.name)
                            .font(.system(.headline))
                            .foregroundStyle(InkColor.primary)
                            .lineLimit(1)
                    }
                    if let description = tile.description {
                        Text(description)
                            .font(.system(.subheadline))
                            .foregroundStyle(InkColor.secondary)
                            .lineLimit(isRow ? 1 : 2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: Spacing.snug) {
                        count(tile.onlineCount, "Online", dot: Palette.presenceOnline)
                        count(tile.memberCount, "Members", dot: InkColor.tertiary)
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(isRow ? Spacing.snug : Spacing.margin)
            .frame(maxWidth: .infinity, minHeight: isRow ? 0 : 112, alignment: .topLeading)
            .plainChip(in: .rect(cornerRadius: Radius.glass))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.glass, style: .continuous)
                    .strokeBorder(isHovering ? Palette.edgeStrong : Palette.edge)
            }
            .contentShape(.rect(cornerRadius: Radius.glass))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        // Discord's own labels for the two outcomes.
        .accessibilityLabel(Text(tile.isJoined ? "Go to \(tile.name)" : "Preview \(tile.name)"))
        .help(tile.isJoined ? "Go to \(tile.name)" : "Preview \(tile.name)")
    }

    private func count(_ value: Int, _ noun: String, dot: some ShapeStyle) -> some View {
        HStack(spacing: 5) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text("\(value.formatted(.number)) \(noun)")
                .font(.system(.caption))
                .foregroundStyle(InkColor.secondary)
        }
    }
}
