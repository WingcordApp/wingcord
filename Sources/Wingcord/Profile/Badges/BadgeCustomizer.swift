import SwiftUI
import WingcordCore

// MARK: - Which badges show, and in what order
//
// docs/CLIPS-PRESENCE.md, Phase 8 — Discord's "Customize your badges"
// (Alex's screenshots 2 and 3): every badge the reader owns, a hidden one
// struck through; each with a menu naming it, "View Badge Details" and "Hide
// Badge"; reordering with Nitro; "View Badges". Staff — and Nitro's own unless
// the account may hide it — can't be hidden, as Discord's can't.
//
// **No upsell.** Without Nitro the reorder line says what Nitro would do and
// stops there: this client sells nothing.

struct BadgeCustomizer: View {
    var userID: UserID
    var viewBadges: () -> Void

    @Environment(AppModel.self) private var model

    private var badges: [CatalogBadge] { model.badgeCatalogs[userID] ?? [] }
    private var management: (enabled: Bool, tenureHideable: Bool) { model.badgeManagement }
    private var canReorder: Bool { model.entitlements.premiumTier == .nitro }

    var body: some View {
        let arrangement = badges.arrangement(tenureHideable: management.tenureHideable)
        VStack(alignment: .leading, spacing: Spacing.snug) {
            Text("Customize your badges")
                .font(.system(.title3, weight: .bold))
                .foregroundStyle(InkColor.primary)
            Text("Hide any badges you don’t want others to see.")
                .font(.system(.subheadline))
                .foregroundStyle(InkColor.secondary)
            if !canReorder {
                Label("Reorder your badges with Nitro", systemImage: "arrow.left.arrow.right")
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(InkColor.secondary)
                    .padding(Spacing.snug)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(60), spacing: Spacing.base), count: 6), spacing: Spacing.base) {
                ForEach(arrangement.fixed + arrangement.ordered + arrangement.hidden) { badge in
                    tile(badge, isFixed: arrangement.fixed.contains(badge), ordered: arrangement.ordered)
                }
            }
            if !management.enabled {
                Text("Discord hasn’t turned badge settings on for this account yet.")
                    .font(.system(.caption))
                    .foregroundStyle(InkColor.secondary)
            }
            Button("View Badges", action: viewBadges)
                .buttonStyle(.glass)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        }
        .padding(Spacing.group)
        .frame(width: 440)
        .task { model.loadBadgeCatalog(of: userID) }
    }

    /// **The whole tile is the target** (Alex, 2026-10-26: the ⋯ and the eye
    /// were "very hard to click"). The ⋯ was an 18-point button hung half off
    /// the tile's corner, and the eye a picture in the same corner, over it.
    /// Now a click anywhere on the tile opens its menu, a right-click does too
    /// (Discord's `onContextMenu`), the ⋯ is a glass disc inside the corner and
    /// the eye — decoration, as Discord's is — sits in the opposite one.
    private func tile(_ badge: CatalogBadge, isFixed: Bool, ordered: [CatalogBadge]) -> some View {
        Menu {
            menuItems(badge, isFixed: isFixed, ordered: ordered)
        } label: {
            BadgeCustomizerTile(badge: badge)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .contextMenu { menuItems(badge, isFixed: isFixed, ordered: ordered) }
        .help(badge.name ?? badge.title)
        .accessibilityLabel((badge.name ?? badge.title) + (badge.isHidden ? ", hidden" : ""))
    }

    @ViewBuilder
    private func menuItems(_ badge: CatalogBadge, isFixed: Bool, ordered: [CatalogBadge]) -> some View {
        Section(badge.name ?? badge.title) {
            Button("View Badge Details", systemImage: "info.circle", action: viewBadges)
            if !isFixed, management.enabled {
                Button(badge.isHidden ? "Show Badge" : "Hide Badge",
                       systemImage: badge.isHidden ? "eye" : "eye.slash") {
                    model.setBadgeHidden(badge.badgeID, hidden: !badge.isHidden)
                }
            }
            if canReorder, management.enabled, let index = ordered.firstIndex(of: badge) {
                Button("Move Earlier", systemImage: "arrow.left") { move(ordered, from: index, by: -1) }
                    .disabled(index == 0)
                Button("Move Later", systemImage: "arrow.right") { move(ordered, from: index, by: 1) }
                    .disabled(index == ordered.count - 1)
            }
        }
    }

    private func move(_ ordered: [CatalogBadge], from index: Int, by delta: Int) {
        var ids = ordered.map(\.badgeID)
        let target = index + delta
        guard ids.indices.contains(target) else { return }
        ids.swapAt(index, target)
        model.setBadgeOrder(ids)
    }
}

/// One badge in the customizer: its mark, the ⋯ that says it has a menu, and —
/// hidden — the struck-through eye.
private struct BadgeCustomizerTile: View {
    var badge: CatalogBadge

    @Environment(\.motion) private var motion
    @State private var isHovered = false

    private static let side: CGFloat = 60

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovered ? Palette.hoverFill : Palette.skeletonPlate)
            if let url = badge.mark {
                BadgeArtwork(url: url, side: 36)
                    .opacity(badge.isHidden ? 0.35 : 1)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .overlay(alignment: .topTrailing) {
            Image(systemName: "ellipsis")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isHovered ? InkColor.primary : InkColor.secondary)
                .frame(width: 22, height: 22)
                .glassEffect(.regular, in: .circle)
                .padding(3)
        }
        .overlay(alignment: .bottomLeading) {
            if badge.isHidden {
                Image(systemName: "eye.slash")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(InkColor.primary)
                    .padding(5)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(.rect(cornerRadius: 12))
        .scaleEffect(isHovered ? 1.04 : 1)
        .animation(motion.hover, value: isHovered)
        .onHover { isHovered = $0 }
    }
}
