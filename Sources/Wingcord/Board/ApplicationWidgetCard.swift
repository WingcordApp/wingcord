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

    /// **Discord's own height, measured off their card at the same scale.**
    /// This was 118, and at 118 a 300 × 450 character is a figure in a
    /// letterbox with her boots sliced off at the divider.
    ///
    /// Fixed, where Discord's is not: their two captured cards come out at 167
    /// and 147.5 with their text at identical offsets from the top, so the
    /// height there follows the artwork's natural size. Nothing here can know
    /// that size — `RemoteImage` draws a `resizable` image and reports no
    /// intrinsic size — without reading a decode into `@State`, which is a
    /// measurement that outlives what it measured and a card whose height jumps
    /// when the picture lands. So: their taller card's number, for every card.
    private static let headerHeight: CGFloat = 167
    /// How far the name clears the divider.
    ///
    /// Measured the same way: Discord's "Server:" line sits 54 points above it,
    /// not the 12 the application's own label uses at the top. The room under it
    /// is where the character's body shows, and pinning the block at 12 instead
    /// would put the whole of the new height in one void above the name.
    private static let titleClearance: CGFloat = 52
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
                // **Filled into a square of the header's height, anchored to its
                // top, and that is the correction.** Fitted, a portrait
                // character shrinks to the header's height and stands as a strip
                // at the edge — 78 points wide at Arknights' 300 × 450. Discord
                // fills a box the header's own height instead, so what arrives
                // is the head and torso at a size worth drawing and the legs go
                // past the bottom. Measured on their card: 165 points of
                // character across a 432-point widget, against ours at 78.
                RemoteImage(url: url, side: Self.headerHeight * 1.5, bucket: .artwork) {
                    Color.clear
                }
                .aspectRatio(contentMode: .fill)
                .frame(width: Self.headerHeight, height: Self.headerHeight, alignment: .top)
                .clipped()
                // **And the crop is dissolved, not cut.** A figure sliced flat
                // along the divider reads as a clipping defect whatever is above
                // it; the same crop under a fade reads as the card ending. The
                // ramp is over the last quarter, so it starts below the torso
                // whatever the character is doing with their arms.
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.75),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
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
            .padding(.bottom, Self.titleClearance)
            // The artwork occupies a square of the header's height at the
            // trailing edge, so the text is held clear of it rather than drawn
            // over the character's face.
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
