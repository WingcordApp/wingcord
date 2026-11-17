import AppKit
import SwiftUI
import WingcordCore

/// Every server by name — the rack, expanded (REDESIGN.md R10), as Discord's
/// mobile experiment lays its server list out: the three-stop layout's middle
/// page, and the servers page while no server has been opened.
///
/// **The rail's own items**, so a folder, an order or a badge cannot disagree
/// between the two: one memo (`AppModel.railItems`), drawn twice.
struct ServerList: View, Equatable {
    var items: [RailItem]
    /// The servers the rail pins above its divider: one being previewed, and
    /// the ones the reader has applied to. Neither is a membership, so neither
    /// is in `items` — the rail's own rule.
    var previewedGuild: RailGuild? = nil
    var pendingApplications: [RailGuild] = []
    var selectedGuildID: GuildID?
    /// Read All, while some server is unread — see `ReadAllCapsule`.
    var readAll: (() -> Void)? = nil

    static func == (lhs: ServerList, rhs: ServerList) -> Bool {
        lhs.items == rhs.items
            && lhs.previewedGuild == rhs.previewedGuild
            && lhs.pendingApplications == rhs.pendingApplications
            && lhs.selectedGuildID == rhs.selectedGuildID
            && (lhs.readAll == nil) == (rhs.readAll == nil)
    }

    var selectGuild: (GuildID) -> Void = { _ in }
    var openGuildMenu: (GuildID, CGRect) -> Void = { _, _ in }
    var toggleFolder: (UInt64) -> Void = { _ in }
    var addServer: () -> Void = {}
    var openDiscovery: () -> Void = {}

    @Environment(\.motion) private var motion
    @Environment(\.sidebarTitleLeading) private var titleLeading
    @Environment(\.sidebarBarsInset) private var barsInset

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if let readAll {
                    HStack {
                        Spacer(minLength: 0)
                        ReadAllCapsule(action: readAll)
                    }
                    .padding(.horizontal, Spacing.snug)
                    .padding(.bottom, Spacing.tight)
                }
                // Above the rule, as the rail has them: where the reader is
                // looking without being a member.
                if let previewedGuild {
                    row(previewedGuild, indent: 0, status: "Previewing")
                }
                ForEach(pendingApplications) { guild in
                    row(guild, indent: 0, status: guild.applicationMark?.membershipLine ?? "Application pending")
                }
                if previewedGuild != nil || !pendingApplications.isEmpty {
                    Divider()
                        .padding(.vertical, Spacing.tight)
                        .padding(.horizontal, Spacing.snug)
                }
                ForEach(items) { item in
                    switch item {
                    case .guild(let guild):
                        row(guild, indent: 0)
                    case .folder(let folder):
                        folderHeader(folder)
                        if folder.isExpanded {
                            ForEach(folder.guilds) { guild in
                                row(guild, indent: ServerListMetrics.folderIndent)
                            }
                        }
                    }
                }
                Divider()
                    .padding(.vertical, Spacing.base)
                    .padding(.horizontal, Spacing.snug)
                ServerListAction(title: "Add a Server", symbolName: "plus", action: addServer)
                ServerListAction(title: "Explore Discoverable Servers", symbolName: "safari", action: openDiscovery)
            }
            // **The page strip's inset, and the channel list's** (Image 6):
            // at 8 the highlights ran two points past the strip above them on
            // either side.
            .padding(.horizontal, Spacing.base + Spacing.hair)
            .padding(.vertical, Spacing.base)
            .animation(motion.standard, value: items)
        }
        .scrollIndicators(.never)
        // The last server rests above the bars — `sidebarBarsInset`.
        .safeAreaPadding(.bottom, barsInset)
        .fadesUnderSidebarChrome()
    }

    private func row(_ guild: RailGuild, indent: CGFloat, status: String? = nil) -> some View {
        ServerListRow(
            guild: guild,
            status: status,
            isSelected: guild.id == selectedGuildID,
            select: { selectGuild(guild.id) },
            openMenu: { openGuildMenu(guild.id, $0) }
        )
        .padding(.leading, indent)
    }

    private func folderHeader(_ folder: RailFolder) -> some View {
        Button {
            toggleFolder(folder.id)
        } label: {
            HStack(spacing: Spacing.snug) {
                Image(systemName: folder.isExpanded ? "folder.fill" : "folder")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(hex: folder.colorValue ?? RailFolder.defaultColor))
                    .frame(width: ServerListMetrics.icon, height: ServerListMetrics.icon)
                Text(folder.displayName)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(folder.hasUnread ? Ink.primary : Ink.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if folder.mentionCount > 0, !folder.isExpanded {
                    MentionBadge(count: folder.mentionCount)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Ink.tertiary)
                    .rotationEffect(.degrees(folder.isExpanded ? 90 : 0))
            }
            .padding(.horizontal, Spacing.snug)
            .frame(height: ServerListMetrics.rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(ServerListRowStyle(isSelected: false))
        .accessibilityLabel(Text("\(folder.displayName), folder"))
        .accessibilityValue(Text(folder.isExpanded ? "Expanded" : "Collapsed"))
    }
}

nonisolated enum ServerListMetrics {
    static let icon: CGFloat = 36
    static let iconCorner: CGFloat = 11
    static let rowHeight: CGFloat = 48
    static let folderIndent: CGFloat = 14
}

/// A server's icon in the list: the picture filling one rounded square, or
/// its monogram on a tile of the same shape.
///
/// **One shape for both** (#15, Image 7). The picture used to be
/// `GuildAvatar`, clipped to a circle, laid on a dark rounded-square tile, so
/// the tile's four corners showed around every icon as a frame nobody drew.
/// The tile is the monogram's ground and nothing else now; a picture covers the
/// whole shape, and where its own artwork is transparent the row shows through.
private struct ServerListIcon: View {
    var url: URL?
    var monogram: String

    private var side: CGFloat { ServerListMetrics.icon }

    var body: some View {
        RemoteImage(url: url, side: side) {
            Text(monogram)
                .font(.system(size: side * 0.36, weight: .semibold))
                .foregroundStyle(Ink.secondary)
                .frame(width: side, height: side)
                .background(ServerListInk.monogramTile)
        }
        .frame(width: side, height: side)
        .clipShape(.rect(cornerRadius: ServerListMetrics.iconCorner, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// One server: its icon, its name, and what is waiting in it.
private struct ServerListRow: View {
    var guild: RailGuild
    /// A line that outranks what the server itself would say — "Previewing".
    var status: String? = nil
    var isSelected: Bool
    var select: () -> Void
    var openMenu: (CGRect) -> Void

    @State private var frame: CGRect = .zero

    var body: some View {
        Button(action: select) {
            HStack(spacing: Spacing.snug) {
                ServerListIcon(url: guild.iconURL, monogram: guild.monogram)
                    .overlay(alignment: .bottomTrailing) {
                        if let mark = guild.voiceMark {
                            Image(systemName: mark.symbolName)
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 16, height: 16)
                                .background(Circle().fill(Color.green))
                                .offset(x: 3, y: 3)
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(guild.name)
                        .font(.system(.body, weight: guild.hasUnread && !guild.isMuted ? .semibold : .regular))
                        .foregroundStyle(guild.isMuted ? Ink.tertiary : (guild.hasUnread ? Ink.primary : Ink.secondary))
                        .lineLimit(1)
                    if let line = statusLine {
                        Text(line)
                            .font(.system(.subheadline))
                            .foregroundStyle(Ink.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if guild.mentionCount > 0 {
                    MentionBadge(count: guild.mentionCount)
                } else if guild.hasUnread, !guild.isMuted {
                    Circle()
                        .fill(Ink.primary)
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.horizontal, Spacing.snug)
            .frame(height: ServerListMetrics.rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(ServerListRowStyle(isSelected: isSelected))
        // In the root's space, where Server Options is hung — `.global` is a
        // titlebar strip lower (`reportsPresentationAnchor`).
        .reportsPresentationAnchor { frame = $0 }
        .contextMenu {
            Button("Server Options…") { openMenu(frame) }
        }
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The line under the name: who is talking, or that the reader is there.
    private var statusLine: String? {
        if let status { return status }
        if guild.isConnectedToVoice { return "You're in voice" }
        switch guild.voiceMark {
        case .stage: return "Stage live"
        case .event: return "Event happening now"
        case .screenShare: return "Someone is streaming"
        case .video, .voice: return "People are talking"
        case nil: return guild.applicationMark?.membershipLine
        }
    }

    private var accessibilityLabel: String {
        var parts = [guild.name]
        if guild.mentionCount > 0 { parts.append("\(guild.mentionCount) mentions") } else if guild.hasUnread { parts.append("unread") }
        if guild.isMuted { parts.append("muted") }
        return parts.joined(separator: ", ")
    }
}

/// A row at the foot of the list that does something rather than goes
/// somewhere.
private struct ServerListAction: View {
    var title: String
    var symbolName: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.snug) {
                Image(systemName: symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x23A55A))
                    .frame(width: ServerListMetrics.icon, height: ServerListMetrics.icon)
                    .background(RoundedRectangle(cornerRadius: ServerListMetrics.iconCorner, style: .continuous).fill(ServerListInk.actionTile))
                Text(title)
                    .font(.system(.body))
                    .foregroundStyle(Ink.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.snug)
            .frame(height: ServerListMetrics.rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(ServerListRowStyle(isSelected: false))
    }
}

/// A row's highlight: the selection's lift, and a lighter one under the
/// pointer — the sidebar list's own vocabulary.
private struct ServerListRowStyle: ButtonStyle {
    var isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        ServerListRowBody(configuration: configuration, isSelected: isSelected)
    }
}

private struct ServerListRowBody: View {
    var configuration: ButtonStyle.Configuration
    var isSelected: Bool

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(fill)
            }
            .scaleEffect(configuration.isPressed ? Motion.pressScale : 1)
            .onHover { isHovering = $0 }
            .animation(motion.hover, value: isHovering)
            .animation(motion.hover, value: configuration.isPressed)
    }

    private var fill: Color {
        if isSelected { return ServerListInk.selection }
        return isHovering ? ServerListInk.hover : .clear
    }
}

private nonisolated enum ServerListInk {
    static let selection = SidebarHighlight.selection
    static let hover = SidebarHighlight.hover
    static let actionTile = Color.relative(dark: 0.10, light: 0.07)
    static let monogramTile = Color.adaptive(
        dark: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35),
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.6)
    )
}

/// The red count a server or folder carries for mentions of the reader.
private struct MentionBadge: View {
    var count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(minWidth: 18, minHeight: 18)
            .background(Capsule().fill(Palette.unreadBadge))
    }
}
