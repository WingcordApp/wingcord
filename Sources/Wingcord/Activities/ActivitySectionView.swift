import SwiftUI

/// One titled row of the launcher.
///
/// Three shapes behind one type, because the wire says which: Recents is a
/// strip of bare icons, a `type: 5` collection is two artwork tiles across, and
/// everything else is a list. Splitting them into three views at the call site
/// would put the wire's own distinction in the caller.
struct ActivitySectionView: View {
    var section: ActivitySection
    var onOpen: (ActivityRow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            header
            switch kind {
            case .recents: recents
            case .featured: featured
            case .list: list
            }
        }
    }

    private enum Kind { case recents, featured, list }

    private var kind: Kind {
        if section.id == "recents" { return .recents }
        return section.isFeatured ? .featured : .list
    }

    /// The title, and nothing beside it.
    ///
    /// **No "View More".** Discord's row has one; this does not, and that is a
    /// decision rather than an omission — the link opens a full-window app
    /// directory this client does not have, so a control here would be the
    /// inert control `INVARIANTS.md` §5.5 forbids. The search field above
    /// reaches every app in the directory, which is what the link was for.
    private var header: some View {
        Text(section.title)
            .font(Typeface.sectionHeader)
            .foregroundStyle(Ink.secondary)
            .textCase(.uppercase)
            .kerning(0.4)
            .padding(.leading, Spacing.tight)
    }

    // MARK: Recents

    /// Icons only, in a row.
    ///
    /// These are apps the reader has already launched — they know what they
    /// are — so a name under each would be a caption on something already
    /// recognised, and the strip would cost three rows instead of one.
    private var recents: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Spacing.base) {
                ForEach(section.rows) { row in
                    Button { onOpen(row) } label: {
                        ActivityIcon(row: row, side: Metrics.activityRecentIcon)
                    }
                    .buttonStyle(.plain)
                    .help(row.name)
                    .accessibilityLabel(row.name)
                }
            }
            .padding(.horizontal, Spacing.tight)
            .padding(.vertical, Spacing.hair)
        }
        .scrollIndicators(.never)
    }

    // MARK: Featured

    private var featured: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: Spacing.base),
                GridItem(.flexible(), spacing: Spacing.base),
            ],
            spacing: Spacing.base
        ) {
            ForEach(section.rows) { row in
                ActivityTile(row: row, onOpen: { onOpen(row) })
            }
        }
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: Spacing.hair) {
            ForEach(section.rows) { row in
                ActivityRowView(row: row, onOpen: { onOpen(row) })
            }
        }
    }
}

// MARK: - An app's icon

/// The square mark, with a monogram behind it until the artwork lands.
///
/// A rounded rectangle rather than a circle: these are application icons, and
/// every platform that has ever drawn one draws it as a squircle. A circle here
/// would read as a person.
struct ActivityIcon: View {
    var row: ActivityRow
    var side: CGFloat

    var body: some View {
        RemoteImage(url: row.iconURL, side: side) {
            Text(row.monogram)
                .font(.system(size: side * 0.42, weight: .semibold))
                .foregroundStyle(Ink.secondary)
                .frame(width: side, height: side)
                .background(Palette.surfaceRaised)
        }
        .frame(width: side, height: side)
        .clipShape(.rect(cornerRadius: side * 0.28, style: .continuous))
    }
}

// MARK: - A featured tile

/// Artwork over a name, two across.
///
/// **Not interactive glass.** A tile lives in a scroll view, and interactive
/// glass warps toward the cursor — on a surface that slides under a stationary
/// pointer the displacement is recomputed every frame and the card visibly
/// wobbles. `Glass.swift` says so in as many words. The press feedback is a
/// scale instead, which is the same instant response without the warp.
private struct ActivityTile: View {
    var row: ActivityRow
    var onOpen: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                art
                HStack(spacing: Spacing.base) {
                    ActivityIcon(row: row, side: 26)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.name)
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                        Text(row.subtitle)
                            .font(Typeface.rowSubtitle)
                            .foregroundStyle(Ink.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Spacing.base)
                .padding(.bottom, Spacing.base)
            }
            .background(Palette.surfaceRaised, in: .rect(cornerRadius: Radius.chip, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .strokeBorder(Palette.hoverFill, lineWidth: isHovered ? 1 : 0)
            }
            .contentShape(.rect(cornerRadius: Radius.chip, style: .continuous))
            .scaleEffect(isHovered ? 1.012 : 1)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(motion.hover, value: isHovered)
        .accessibilityLabel(row.name)
        .accessibilityHint(row.subtitle)
    }

    /// 16:9 — the shape every `embedded_cover` in the captured shelf is drawn
    /// at, and the reason the tile's height is derived rather than chosen.
    private var art: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                RemoteImage(
                    url: row.tileURL,
                    side: Metrics.activityTileWidth,
                    // Four tiles, large each, re-shown on every open — which
                    // is exactly what the artwork bucket is sized for. The
                    // attachment bucket would evict them behind one fling
                    // through an image channel.
                    bucket: .artwork
                ) {
                    // No artwork: the icon on the app's own ground, rather than
                    // a grey block. Every app in the captured shelf has a tile,
                    // so this is the search-result case.
                    ActivityIcon(row: row, side: Metrics.activityRowIcon)
                }
                .aspectRatio(contentMode: .fill)
            }
            .clipShape(
                .rect(
                    topLeadingRadius: Radius.chip,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: Radius.chip,
                    style: .continuous
                )
            )
    }
}

// MARK: - A list row

private struct ActivityRowView: View {
    var row: ActivityRow
    var onOpen: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Spacing.snug) {
                ActivityIcon(row: row, side: Metrics.activityRowIcon)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    Text(row.subtitle)
                        .font(Typeface.rowSubtitle)
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, Spacing.base)
            .background(
                isHovered ? Palette.hoverFill : .clear,
                in: .rect(cornerRadius: Radius.row, style: .continuous)
            )
            .contentShape(.rect(cornerRadius: Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(motion.hover, value: isHovered)
        .accessibilityLabel(row.name)
        .accessibilityHint(row.subtitle)
    }
}
