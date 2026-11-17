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
    /// Starts an app in the call straight from its card (decision 5); nil in
    /// the composer, where a card opens the app's page.
    var onStart: ((ActivityRow) -> Void)? = nil

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
            HStack(alignment: .top, spacing: Spacing.snug) {
                ForEach(section.rows) { row in
                    Button {
                        if let onStart, row.isLaunchable { onStart(row) } else { onOpen(row) }
                    } label: {
                        VStack(spacing: 4) {
                            ActivityIcon(row: row, side: Self.recentSide)
                            // A name under each now that the strip is the
                            // launcher's second row and a game's icon alone
                            // isn't always its name (decision 5).
                            Text(row.name)
                                .font(.system(.caption, weight: .medium))
                                .foregroundStyle(Ink.secondary)
                                .lineLimit(1)
                                .frame(width: Self.recentSide + Spacing.snug)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(onStart == nil ? row.name : "Start \(row.name)")
                    .accessibilityLabel(row.name)
                }
            }
            .padding(.horizontal, Spacing.tight)
            .padding(.vertical, Spacing.hair)
        }
        .scrollIndicators(.never)
    }

    // MARK: Featured

    private static let recentSide: CGFloat = 52

    /// Discord's featured shelf as cover cards (decision 5): the first across
    /// the panel, the rest two by two, each playing its preview on hover.
    private var featured: some View {
        VStack(spacing: Spacing.snug) {
            if let hero = section.rows.first {
                ActivityFeatureCard(
                    row: hero, isHero: true, onOpen: { onOpen(hero) },
                    onStart: start(hero)
                )
            }
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: Spacing.snug),
                    GridItem(.flexible(), spacing: Spacing.snug),
                ],
                spacing: Spacing.snug
            ) {
                ForEach(section.rows.dropFirst()) { row in
                    ActivityFeatureCard(row: row, onOpen: { onOpen(row) }, onStart: start(row))
                }
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
        .clipShape(.rect(cornerRadius: side * 0.28, style: .continuous))
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
