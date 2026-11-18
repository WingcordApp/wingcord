import SwiftUI

/// One titled section of the launcher, in the Showcase layout (Alex,
/// 2026-11-18, picked over a list and a gallery: "i want smth beautiful").
///
/// Four shapes behind one type, because the wire says which:
/// - **Recents**: big icons with their names, in a row.
/// - **A featured collection** (`type: 5`): a paging carousel of wide hero
///   cards (`ActivityHeroCarousel`).
/// - **Any other collection**: a two-column grid of cards — artwork above,
///   the app below (`ActivityGridCard`) — and See All opens it in place.
/// - **Search results**: rows, which scan faster than cards when you know
///   the name you typed.
struct ActivitySectionView: View {
    var section: ActivitySection
    var onOpen: (ActivityRow) -> Void
    /// Starts an app in the call straight from its card (decision 5); nil in
    /// the composer, where a card opens the app's page.
    var onStart: ((ActivityRow) -> Void)? = nil

    @Environment(\.motion) private var motion
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            // The carousel carries its own weight; a title over it would be a
            // label on the most obvious thing in the panel.
            if kind != .featured { header }
            switch kind {
            case .recents: recents
            case .featured:
                ActivityHeroCarousel(rows: section.rows, onOpen: onOpen, onStart: onStart)
            case .grid: grid
            case .list: list
            }
        }
    }

    private enum Kind { case recents, featured, grid, list }

    private var kind: Kind {
        if section.id == "recents" { return .recents }
        if section.id == "search" { return .list }
        return section.isFeatured ? .featured : .grid
    }

    /// The title in the section's own case, and See All where it has more.
    ///
    /// **See All opens the section in place.** Discord's opens a full-window
    /// app directory this client does not have; a link to nowhere would be
    /// the inert control `INVARIANTS.md` §5.5 forbids, and a grid that grows
    /// where you are looking is the shorter trip anyway.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
            Text(section.title)
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
            Spacer(minLength: Spacing.base)
            if section.hasMore {
                Button {
                    withAnimation(motion.standard) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Text(isExpanded ? "Show Less" : "See All")
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.right")
                            .font(.system(.caption, weight: .semibold))
                    }
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(Palette.accent)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.tight)
    }

    // MARK: Recents

    private static let recentSide: CGFloat = 56

    /// Big icons with their names: the games you already know, one press from
    /// playing, the way a phone's dock holds its apps.
    private var recents: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Spacing.margin) {
                ForEach(section.rows) { row in
                    Button {
                        if let onStart, row.isLaunchable { onStart(row) } else { onOpen(row) }
                    } label: {
                        VStack(spacing: 6) {
                            ActivityIcon(row: row, side: Self.recentSide)
                                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                            Text(row.name)
                                .font(.system(.caption, weight: .medium))
                                .foregroundStyle(Ink.secondary)
                                .lineLimit(1)
                                .frame(width: Self.recentSide + Spacing.snug)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(ActivityPressStyle())
                    .help(onStart == nil ? row.name : "Start \(row.name)")
                    .accessibilityLabel(row.name)
                }
            }
            .padding(.horizontal, Spacing.tight)
            .padding(.vertical, Spacing.tight)
        }
        .scrollIndicators(.never)
    }

    // MARK: Grid

    private var grid: some View {
        let shown = isExpanded ? section.rows : Array(section.rows.prefix(section.collapsedCount))
        return LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: Spacing.snug, alignment: .top),
                GridItem(.flexible(), spacing: Spacing.snug, alignment: .top),
            ],
            spacing: Spacing.margin
        ) {
            ForEach(shown) { row in
                ActivityGridCard(row: row, onOpen: { onOpen(row) }, onStart: start(row))
            }
        }
    }

    private func start(_ row: ActivityRow) -> (() -> Void)? {
        guard let onStart, row.isLaunchable else { return nil }
        return { onStart(row) }
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
        .clipShape(.rect(cornerRadius: side * 0.24, style: .continuous))
    }
}

// MARK: - A search row

private struct ActivityRowView: View {
    var row: ActivityRow
    var onOpen: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Spacing.snug) {
                ActivityIcon(row: row, side: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Spacing.base) {
                        Text(row.name)
                            .font(.system(.body, weight: .semibold))
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                        if row.isPromoted { PromotedBadge() }
                    }
                    if !row.subtitle.isEmpty {
                        Text(row.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
                    .opacity(isHovered ? 1 : 0)
            }
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, Spacing.base)
            .background(
                isHovered ? Palette.hoverFill : .clear,
                in: .rect(cornerRadius: Radius.row, style: .continuous)
            )
            .contentShape(.rect(cornerRadius: Radius.row, style: .continuous))
        }
        .buttonStyle(ActivityPressStyle())
        .onHover { isHovered = $0 }
        .animation(motion.hover, value: isHovered)
        .accessibilityLabel(row.isPromoted ? "\(row.name), promoted" : row.name)
        .accessibilityHint(row.subtitle)
    }
}
