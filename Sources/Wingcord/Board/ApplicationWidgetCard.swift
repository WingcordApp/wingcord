import SwiftUI
import WingcordCore

/// An application's own widget: a linked game's stats, or something a developer
/// authored.
///
/// **Two halves, and either can be absent.** The `widget_top` surface is a
/// header — a title, a line under it and artwork behind them — and
/// `widget_bottom` is a grid of stats. A config may define one, the other or
/// both, so this draws a divider only where there is something on each side of
/// it.
///
/// The card takes no padding of its own on the header: the artwork is authored
/// to run to the tile's edges, which is what makes a linked game's character
/// stand at the card's right rather than inside a box.
struct ApplicationWidgetCard: View {
    var tile: BoardApplicationTile
    var ground: ProfileGround

    private static let headerHeight: CGFloat = 118
    /// Three across, which is what makes six stats two rows — the shape both
    /// captured linked games publish.
    private static let statColumns = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let bottom = tile.bottom, !bottom.stats.isEmpty {
                if tile.top != nil {
                    Rectangle()
                        .fill(ground.borderStyle)
                        .frame(height: 1)
                        .opacity(0.6)
                }
                statGrid(bottom.stats)
            }
        }
    }

    // MARK: The header

    @ViewBuilder
    private var header: some View {
        // **`Color.clear` with the artwork as an overlay, never the artwork as a
        // sibling.** A filling image reports the image's own size to the layout,
        // so a stack holding one grows past the card and takes the stats grid
        // with it. Clear takes whatever width it is offered and the picture stays
        // decorative — the same arrangement the profile banner uses.
        Color.clear
            .frame(height: Self.headerHeight)
            .background { artwork }
            .overlay(alignment: .topLeading) { applicationLabel }
            .overlay(alignment: .bottomLeading) { titleBlock }
    }

    @ViewBuilder
    private var artwork: some View {
        if let url = tile.top?.heroImageURL ?? tile.characterImageURL {
            // **Trailing-aligned, and that is the whole of why this is not a
            // plain fill.** The art both captured games publish is a portrait
            // character on transparency, authored to stand at the card's right
            // with the text clear of them. Filling the box centres them behind
            // the title instead.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                RemoteImage(url: url, side: Self.headerHeight * 2, bucket: .artwork) {
                    Color.clear
                }
                .aspectRatio(contentMode: .fit)
            }
            .frame(height: Self.headerHeight)
            // A wash from the leading edge so the title always has ground under
            // it, whatever the artwork happens to be there. Over the picture
            // rather than under it — a scrim behind transparent art does
            // nothing.
            .overlay {
                LinearGradient(
                    colors: [.black.opacity(0.55), .black.opacity(0.15), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        }
    }

    /// The application's name and mark, over the artwork's top corner.
    private var applicationLabel: some View {
        HStack(spacing: 6) {
            RemoteImage(url: tile.iconURL, side: 16) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Palette.surfaceRaised)
            }
            .frame(width: 16, height: 16)
            .clipShape(.rect(cornerRadius: 4, style: .continuous))

            Text(tile.name)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)

            if tile.isVerified {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.affirmative)
            }
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.top, Spacing.snug)
        // Room for the tile's own "…", which floats over this corner.
        .padding(.trailing, Metrics.control)
    }

    @ViewBuilder
    private var titleBlock: some View {
        if let top = tile.top, !top.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if let title = top.title {
                    Text(title)
                        .font(.system(.title3, weight: .bold))
                        .foregroundStyle(InkColor.primary)
                        .lineLimit(1)
                }
                ForEach(Array(top.subtitles.enumerated()), id: \.offset) { _, subtitle in
                    Text(subtitle)
                        .font(.system(.subheadline))
                        .foregroundStyle(InkColor.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Spacing.snug)
            .padding(.bottom, Spacing.snug)
            // The artwork occupies the trailing half of the header, so the text
            // is held clear of it rather than drawn over the character's face.
            .padding(.trailing, Self.headerHeight)
        }
    }

    // MARK: The stats

    /// A fixed three columns.
    ///
    /// **Not a flow and not adaptive.** Both captured widgets publish exactly six
    /// stats and Discord lays them out three across; a flow layout would put four
    /// short labels on one row and two long ones on the next, which is what makes
    /// a stats block read as a paragraph instead of a table. Empty cells keep the
    /// last row's columns aligned with the first's.
    private func statGrid(_ stats: [ResolvedStat]) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: Spacing.snug, verticalSpacing: Spacing.snug) {
            ForEach(Array(rows(of: stats).enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(row) { stat in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(stat.value)
                                .font(.system(.subheadline, weight: .semibold).monospacedDigit())
                                .foregroundStyle(InkColor.primary)
                                .lineLimit(1)
                            Text(stat.label)
                                .font(.system(size: 10))
                                .foregroundStyle(InkColor.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(0..<(Self.statColumns - row.count), id: \.self) { _ in
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
            }
        }
        .padding(Spacing.snug)
    }

    private func rows(of stats: [ResolvedStat]) -> [[ResolvedStat]] {
        stride(from: 0, to: stats.count, by: Self.statColumns).map { start in
            Array(stats[start..<min(start + Self.statColumns, stats.count)])
        }
    }
}
