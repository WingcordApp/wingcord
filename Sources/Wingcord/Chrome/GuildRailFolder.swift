import SwiftUI
import WingcordCore

/// A folder in the rail: a tile that opens into a well of its servers.
///
/// Closed, it draws a 2×2 grid of its members' icons and carries their combined
/// unread state — a folder that hides an unread without saying so is a folder
/// people stop trusting. Open, the tile becomes a folder glyph and the servers
/// appear beneath it in a tinted well.
struct GuildRailFolder: View {
    var folder: RailFolder
    var selectedGuildID: GuildID?
    var toggle: () -> Void
    var selectGuild: (GuildID) -> Void

    @Environment(\.motion) private var motion

    private var side: CGFloat { Metrics.guildTile }

    /// Whether the folder contains the current destination. A closed folder
    /// holding the open server has to say so, or selection disappears.
    private var containsSelection: Bool {
        guard let selectedGuildID else { return false }
        return folder.guilds.contains { $0.id == selectedGuildID }
    }

    private var tint: Color? {
        folder.colorValue.map(Color.init(hex:))
    }

    var body: some View {
        VStack(spacing: Spacing.base) {
            Button(action: toggle) {
                ZStack(alignment: .leading) {
                    RailIndicator(
                        isSelected: !folder.isExpanded && containsSelection,
                        hasUnread: !folder.isExpanded && folder.hasUnread
                    )

                    folderTile
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .buttonStyle(.plain)
            .frame(width: Proportions.railWidth, height: side)
            .hoverFlyout(folder.name ?? "Folder")
            .accessibilityLabel(Text(folder.name ?? "Folder"))

            if folder.isExpanded {
                VStack(spacing: Spacing.base) {
                    ForEach(folder.guilds) { guild in
                        GuildRailTile(
                            guild: guild,
                            isSelected: guild.id == selectedGuildID,
                            action: { selectGuild(guild.id) }
                        )
                    }
                }
                .padding(.vertical, Spacing.base)
                .background {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill((tint ?? Color.white).opacity(0.10))
                        .padding(.horizontal, 8)
                }
                // The well grows from the tile above it, not from nothing.
                .transition(.materialize(from: .top))
            }
        }
        .animation(motion.glassMorph, value: folder.isExpanded)
    }

    /// The tile's face: a grid of member icons when closed, a folder glyph when
    /// open.
    ///
    /// A `ZStack` with both present and one at zero opacity, rather than an
    /// `if`, so the tile keeps one view identity and the two faces cross-fade
    /// inside a stable frame instead of the whole tile being rebuilt.
    private var folderTile: some View {
        ZStack {
            memberGrid.opacity(folder.isExpanded ? 0 : 1)

            Image(systemName: "folder.fill")
                .font(.system(size: side * 0.36))
                .foregroundStyle(tint ?? Color.white.opacity(0.8))
                .opacity(folder.isExpanded ? 1 : 0)
        }
        .frame(width: side, height: side)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill((tint ?? Color.white).opacity(0.14))
        }
        .clipShape(.rect(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if !folder.isExpanded, folder.mentionCount > 0 {
                UnreadBadge(count: folder.mentionCount, isMuted: false)
                    .offset(x: 3, y: 3)
            }
        }
    }

    /// Up to four member icons in a 2×2.
    ///
    /// Three servers make a 2×2 with a held empty slot, never a lopsided row of
    /// three — the grid is a shape, and a ragged one reads as a layout fault.
    private var memberGrid: some View {
        let cell = (side - 12) / 2
        let gap: CGFloat = 3
        return VStack(spacing: gap) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<2, id: \.self) { column in
                        let index = row * 2 + column
                        if index < folder.guilds.count {
                            let member = folder.guilds[index]
                            RemoteImage(url: member.iconURL, side: cell) {
                                Text(member.monogram.prefix(1))
                                    .font(.system(size: cell * 0.5, weight: .bold))
                                    .foregroundStyle(Ink.tertiary)
                                    .frame(width: cell, height: cell)
                                    .background(Palette.surfaceRaised)
                            }
                            .frame(width: cell, height: cell)
                            .clipShape(.rect(cornerRadius: 4, style: .continuous))
                        } else {
                            Color.clear.frame(width: cell, height: cell)
                        }
                    }
                }
            }
        }
    }
}
