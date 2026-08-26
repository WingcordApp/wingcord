import SwiftUI
import WingcordCore

/// The column of server tiles down the leading edge.
///
/// **No background of any kind.** This sits inside the split view's sidebar
/// column, which AppKit backs with behind-window vibrancy — that vibrancy is the
/// wallpaper showing through, and painting over it is how an app ends up
/// hand-rolling the effect it just covered up.
///
/// A plain `VStack`, not a `LazyVStack`, and that is deliberate. Lazy layout
/// corrects its own content-height estimate while scrolling backwards, which
/// disrupts the elastic rebound at the top boundary — and an expanded folder
/// makes rail rows variable-height, which is exactly when the estimate is
/// wrong. A hundred tiles of 44pt is nothing to lay out eagerly; the tiles
/// themselves are cheap because the artwork is fetched at the drawn size and
/// decoded off-main.
struct GuildRail: View, Equatable {
    var items: [RailItem]
    var selectedGuildID: GuildID?
    /// Whether the home (DMs) entry is the current destination.
    var isHomeSelected: Bool
    var homeMentionCount: Int
    var homeHasUnread: Bool

    /// Compares **only** the value inputs.
    ///
    /// The action closures below are recreated on every parent evaluation, so
    /// including them would make this always-false — which is the failure mode
    /// that makes an `EquatableView` look like it does nothing at all.
    static func == (lhs: GuildRail, rhs: GuildRail) -> Bool {
        lhs.items == rhs.items
            && lhs.selectedGuildID == rhs.selectedGuildID
            && lhs.isHomeSelected == rhs.isHomeSelected
            && lhs.homeMentionCount == rhs.homeMentionCount
            && lhs.homeHasUnread == rhs.homeHasUnread
    }

    var selectHome: () -> Void = {}
    var selectGuild: (GuildID) -> Void = { _ in }
    var toggleFolder: (UInt64) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.base) {
                HomeRailTile(
                    isSelected: isHomeSelected,
                    mentionCount: homeMentionCount,
                    hasUnread: homeHasUnread,
                    action: selectHome
                )

                RailDivider()

                ForEach(items) { item in
                    switch item {
                    case .guild(let guild):
                        GuildRailTile(
                            guild: guild,
                            isSelected: guild.id == selectedGuildID,
                            action: { selectGuild(guild.id) }
                        )
                    case .folder(let folder):
                        GuildRailFolder(
                            folder: folder,
                            selectedGuildID: selectedGuildID,
                            toggle: { toggleFolder(folder.id) },
                            selectGuild: selectGuild
                        )
                    }
                }
            }
            .padding(.vertical, Spacing.base)
        }
        .scrollIndicators(.hidden)
        // The rail runs to the top of the window, under the traffic lights,
        // which the split view already insets the column for.
        .frame(width: Proportions.railWidth)
        .softScrollEdgesVertical()
    }
}

/// The hairline between the home entry and the servers.
///
/// Its own view rather than a `Divider()` so the inset is stated once. A
/// `Divider` in a `VStack` spans the whole width, which on a 68pt rail reads as
/// a line across the wallpaper rather than as a separator between two groups.
private struct RailDivider: View {
    var body: some View {
        Rectangle()
            .fill(Palette.selectionFill)
            .frame(height: 1)
            .padding(.horizontal, 18)
            .accessibilityHidden(true)
    }
}
