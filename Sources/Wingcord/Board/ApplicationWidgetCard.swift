import SwiftUI
import WingcordCore

/// An application's own widget on the board: a linked game's stats, or
/// something a developer authored — Discord's `widget_top` over its
/// `widget_bottom` (module `479299`, drawn by `794248`).
///
/// ```
/// ▣ Gramophone           ░▒▓███    the name; the picture fills the right
///                        ░▒▓███    half to the card's top and trailing
/// dargy                  ░▒▓███    edges and dissolves in from its left
/// @okdargy               ░▒▓███
/// ──────────────────────────────
/// 102K ≋     72 ♥       13 ☺       three across, each value's icon after it
/// Scrobbles  Loved…     Friends
/// ```
///
/// **The picture fades; nothing is laid over it.** It used to sit under a black
/// wash from the leading edge so the title had ground, and on a light profile
/// that wash was a dark smudge in the card's top corner. Discord keeps the text
/// in the left half and dissolves the picture instead, so there is nothing to
/// smudge in either room.
struct ApplicationWidgetCard: View {
    var tile: BoardApplicationTile
    var ground: ProfileGround

    @Environment(AppModel.self) private var model
    @State private var isHoveringName = false

    private static let columns = 3
    /// A stat's icon is one line of its value tall — Discord's `1lh`.
    private static let statIconSide: CGFloat = 14
    /// The picture's decode size: the widest the right half of a board tile
    /// gets.
    private static let pictureSide: CGFloat = 320
    /// `widget_top_contained`'s picture: square, and no larger than this.
    private static let containedSide: CGFloat = 150
    /// A progress goal's badge and a collection item's picture.
    private static let badgeSide: CGFloat = 48
    /// Discord's `--opacity-32`: the cool grey of `ProfileGround.panelFill`
    /// at twice the strength, so the empty bar reads on either ground.
    private static let barTrack = Color(red: 151 / 255, green: 151 / 255, blue: 159 / 255)
        .opacity(0.32)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            top
            if let bottom = tile.bottom, !bottom.isEmpty {
                Rectangle()
                    .fill(ground.borderStyle)
                    .frame(height: 1)
                    .opacity(0.6)
                Group {
                    if let progress = bottom.progress {
                        progressRow(progress)
                    } else if !bottom.items.isEmpty {
                        itemGrid(bottom.items)
                    } else {
                        statGrid(bottom.stats)
                    }
                }
                .padding(.top, Spacing.group)
                .padding(.horizontal, Spacing.margin)
                .padding(.bottom, Spacing.margin)
            }
        }
    }

    // MARK: The top

    /// Whether there is a band under the name at all: words, or a picture to
    /// show behind where they would be.
    private var hasBand: Bool {
        (tile.top.map { !$0.isEmpty } ?? false) || heroURL != nil
    }

    /// The name, then the title block in the left half — `widget_top_hero`'s
    /// grid, whose right column holds nothing in flow.
    private var top: some View {
        VStack(alignment: .leading, spacing: 0) {
            applicationName
            if hasBand {
                HStack(spacing: Spacing.tight) {
                    titleBlock
                        .padding(.vertical, Spacing.section)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    rightColumn
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .padding(.top, Spacing.snug)
        .padding(.horizontal, Spacing.margin)
        .padding(.bottom, hasBand ? 0 : Spacing.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { heroPicture }
    }

    /// The application's mark and name, and the way to its game when it is
    /// one — Discord's header underlines under the pointer and opens the game.
    @ViewBuilder
    private var applicationName: some View {
        let label = HStack(spacing: Spacing.tight) {
            RemoteImage(url: tile.iconURL, side: 16) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Palette.groupedFill)
            }
            .frame(width: 16, height: 16)
            .clipShape(.rect(cornerRadius: 2, style: .continuous))

            Text(tile.name)
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(InkColor.primary)
                .underline(isHoveringName)
                .lineLimit(1)
        }
        .frame(height: 24)
        // Room for the tile's "…", which floats over this corner.
        .padding(.trailing, Metrics.control)

        if let gameID = tile.gameID {
            Button { model.openGameProfile(gameID) } label: { label }
                .buttonStyle(.plain)
                .onHover { hovering in
                    guard isHoveringName != hovering else { return }
                    isHoveringName = hovering
                }
                .accessibilityHint(Text("Opens the game's profile"))
        } else {
            label
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title = tile.top?.title {
                Text(title)
                    .font(.system(.title3, weight: .medium))
                    .foregroundStyle(InkColor.primary)
                    .lineLimit(2)
                    .padding(.bottom, Spacing.tight)
            }
            ForEach(Array((tile.top?.subtitles ?? []).enumerated()), id: \.offset) { _, subtitle in
                Text(subtitle)
                    .font(.system(.subheadline))
                    .foregroundStyle(InkColor.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var heroURL: URL? {
        guard let top = tile.top else { return tile.characterImageURL }
        return top.isHero ? top.heroImageURL ?? tile.characterImageURL : nil
    }

    /// The right half, from the card's top edge to the divider, behind the
    /// text: the picture fills its width, hangs from its top, is cut at the
    /// divider and dissolves in from its left.
    ///
    /// **Its natural height, not a fill.** A portrait character runs past the
    /// divider and is cut there; a landscape picture ends above it — Discord's
    /// `width: 100%`, which a fill would instead stretch to the height by
    /// cropping its sides.
    @ViewBuilder
    private var heroPicture: some View {
        if let heroURL {
            HStack(spacing: Spacing.tight) {
                Color.clear
                Color.clear
                    .overlay(alignment: .top) {
                        RemoteImage(url: heroURL, side: Self.pictureSide, bucket: .artwork) {
                            Color.clear
                        }
                        .aspectRatio(contentMode: .fit)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .clipped()
                    .fadingInFromLeading()
            }
            .accessibilityHidden(true)
        }
    }

    /// The right half in flow: `widget_top_contained`'s picture, a square box
    /// whole rather than cropped — or nothing, a zero-height column that holds
    /// the words to the left half while a hero picture fills it from behind.
    @ViewBuilder
    private var rightColumn: some View {
        if let top = tile.top, !top.isHero, let url = top.containedImageURL {
            RemoteImage(url: url, side: Self.containedSide) { Color.clear }
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: Self.containedSide)
                .background(Palette.groupedFill)
                .clipShape(.rect(cornerRadius: Radius.chip, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .strokeBorder(Palette.hairline, lineWidth: 1)
                }
                .padding(.top, Spacing.snug)
                .padding(.bottom, Spacing.margin)
                .accessibilityHidden(true)
        } else {
            Color.clear.frame(height: 0)
        }
    }

    // MARK: The stats

    /// Three across, rows of equal columns, 24 points between everything —
    /// Discord's `statsGrid`.
    ///
    /// **Not a flow and not adaptive**: a flow puts four short labels on one
    /// row and two long ones on the next, which is what makes a stats block
    /// read as a paragraph instead of a table. A short last row keeps its empty
    /// columns so it lines up with the first.
    private func statGrid(_ stats: [ResolvedStat]) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: Spacing.group, verticalSpacing: Spacing.group) {
            ForEach(Array(rows(of: stats).enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(row) { stat in
                        statCell(stat)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(0..<(Self.columns - row.count), id: \.self) { _ in
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .gridCellUnsizedAxes(.vertical)
                    }
                }
            }
        }
    }

    private func statCell(_ stat: ResolvedStat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Text(stat.value)
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(InkColor.primary)
                    .lineLimit(2)
                if let icon = stat.iconURL {
                    RemoteImage(url: icon, side: Self.statIconSide) { Color.clear }
                        .aspectRatio(contentMode: .fit)
                        .frame(width: Self.statIconSide, height: Self.statIconSide)
                        .accessibilityHidden(true)
                }
            }
            Text(stat.label)
                .font(.system(.caption))
                .foregroundStyle(InkColor.secondary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    private func rows(of stats: [ResolvedStat]) -> [[ResolvedStat]] {
        stride(from: 0, to: stats.count, by: Self.columns).map { start in
            Array(stats[start..<min(start + Self.columns, stats.count)])
        }
    }

    // MARK: A goal

    /// `widget_bottom_progress`: the goal's badge, then the bar over its name
    /// and line, with how far along it is at the bar's end.
    private func progressRow(_ progress: ResolvedProgress) -> some View {
        HStack(spacing: Spacing.snug) {
            badge(progress.imageURL, bordered: true)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Capsule()
                    .fill(Self.barTrack)
                    .frame(height: 6)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(InkColor.primary)
                                .frame(width: proxy.size.width * CGFloat(progress.percent) / 100)
                        }
                    }
                HStack(alignment: .top, spacing: 2) {
                    twoLines(progress.name, progress.detail, spacing: 0)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let caption = progress.caption {
                        Text(caption)
                            .font(.system(.subheadline, weight: .medium))
                            .foregroundStyle(InkColor.primary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(progress.name ?? tile.name))
        .accessibilityValue(Text(progress.caption ?? ""))
    }

    // MARK: A collection

    /// `widget_bottom_collection`: two by two, each a picture and two lines.
    private func itemGrid(_ items: [ResolvedItem]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Spacing.margin, verticalSpacing: Spacing.margin) {
            ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { start in
                GridRow {
                    ForEach(items[start..<min(start + 2, items.count)]) { item in
                        HStack(spacing: Spacing.snug) {
                            badge(item.imageURL, bordered: false)
                            twoLines(item.name, item.detail, spacing: Spacing.tight)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                    if items.count - start < 2 {
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .gridCellUnsizedAxes(.vertical)
                    }
                }
            }
        }
    }

    // MARK: Parts

    private func badge(_ url: URL?, bordered: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
        return RemoteImage(url: url, side: Self.badgeSide) { Color.clear }
            .aspectRatio(contentMode: .fit)
            .frame(width: Self.badgeSide, height: Self.badgeSide)
            .background(Palette.groupedFill, in: shape)
            .clipShape(shape)
            .overlay {
                if bordered { shape.strokeBorder(Palette.hairline, lineWidth: 1) }
            }
            .accessibilityHidden(true)
    }

    /// A name over a quieter line, either of which may be missing.
    private func twoLines(_ name: String?, _ detail: String?, spacing: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            if let name {
                Text(name)
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(InkColor.primary)
                    .lineLimit(2)
            }
            if let detail {
                Text(detail)
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(InkColor.secondary)
                    .lineLimit(2)
            }
        }
    }
}
