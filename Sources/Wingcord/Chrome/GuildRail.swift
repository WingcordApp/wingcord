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
    /// The server being previewed, pinned above the divider.
    ///
    /// **Not in `items`, and it must not be.** That list is built from the
    /// account's folder order — a settings payload the client writes back — and
    /// a server nobody joined has no place in it. Discord pins the preview to the
    /// top for the same reason: it is a temporary destination, not a membership.
    var previewedGuild: RailGuild?
    /// The servers the reader has applied to — `PendingApplicationsFolder`.
    /// Above the divider with the preview, which is where Discord puts it
    /// (`rf`): both are servers the reader is not in.
    var pendingApplications: PendingApplicationsRail?
    var selectedGuildID: GuildID?
    /// Whether the home (DMs) entry is the current destination.
    var isHomeSelected: Bool
    var homeMentionCount: Int
    var homeHasUnread: Bool
    /// The DM call's start, for the clock under the Home squircle.
    var homeCallSince: Date? = nil
    /// Show All Servers, at the rail's head — where the rack expands into the
    /// list (REDESIGN.md R10). Nil where there is no list to expand into.
    var showAllServers: (() -> Void)? = nil
    /// Read All (#7, WC-VACZ). Nil hides it; it is offered only while some
    /// server has something unread.
    var readAll: (() -> Void)? = nil

    /// Compares **only** the value inputs.
    ///
    /// The action closures below are recreated on every parent evaluation, so
    /// including them would make this always-false — which is the failure mode
    /// that makes an `EquatableView` look like it does nothing at all.
    static func == (lhs: GuildRail, rhs: GuildRail) -> Bool {
        lhs.items == rhs.items
            && lhs.previewedGuild == rhs.previewedGuild
            && lhs.pendingApplications == rhs.pendingApplications
            && lhs.selectedGuildID == rhs.selectedGuildID
            && lhs.isHomeSelected == rhs.isHomeSelected
            && lhs.homeMentionCount == rhs.homeMentionCount
            && lhs.homeHasUnread == rhs.homeHasUnread
            && lhs.homeCallSince == rhs.homeCallSince
            && (lhs.showAllServers == nil) == (rhs.showAllServers == nil)
            && (lhs.readAll == nil) == (rhs.readAll == nil)
    }

    var selectHome: () -> Void = {}
    var selectGuild: (GuildID) -> Void = { _ in }
    /// A right-click on a tile, with its frame. See `GuildRailTile.openMenu`.
    var openGuildMenu: (GuildID, CGRect) -> Void = { _, _ in }
    var toggleFolder: (UInt64) -> Void = { _ in }
    /// A right-click on a folder's tile, with its frame — `FolderOptionsMenu`.
    var openFolderMenu: (UInt64, CGRect) -> Void = { _, _ in }
    /// A server or folder dropped somewhere else in the rail — `RailDrop`.
    var drop: (RailDrop) -> Void = { _ in }
    var togglePendingApplications: () -> Void = {}
    /// A right-click on a pending application's tile, with its frame.
    var openJoinRequestMenu: (GuildID, CGRect) -> Void = { _, _ in }
    var dismissApplicationCoachmark: () -> Void = {}
    var addServer: () -> Void = {}
    var openDiscovery: () -> Void = {}
    /// Whether discovery is the detail column, so the tile can say so. Part of
    /// the value rather than read from the store, because this view holds no
    /// model reference — that is what `.equatable()` needs.
    var isDiscoveryShown = false

    /// The space tile frames and the pointer are measured in while a tile is
    /// carried: the scrolling content's own, so a scroll moves nothing in it.
    nonisolated static let contentSpace = "GuildRail.content"

    /// The tile being carried, if any — `RailDrag`.
    @State private var drag = RailDrag()
    @Environment(\.sidebarBarsInset) private var barsInset

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.base) {
                if let showAllServers {
                    AllServersRailButton(action: showAllServers)
                }
                HomeRailTile(
                    isSelected: isHomeSelected,
                    mentionCount: homeMentionCount,
                    hasUnread: homeHasUnread,
                    callSince: homeCallSince,
                    action: selectHome
                )

                // Between the home entry and the rule, which is where Discord
                // puts it: above the line is where you are, below it is what you
                // are in.
                if let previewedGuild {
                    GuildRailTile(
                        guild: previewedGuild,
                        isSelected: previewedGuild.id == selectedGuildID,
                        action: { selectGuild(previewedGuild.id) },
                        openMenu: { openGuildMenu(previewedGuild.id, $0) }
                    )
                }

                if let pendingApplications {
                    PendingApplicationsFolder(
                        folder: pendingApplications,
                        selectedGuildID: selectedGuildID,
                        toggle: togglePendingApplications,
                        selectGuild: selectGuild,
                        openMenu: openJoinRequestMenu,
                        dismissCoachmark: dismissApplicationCoachmark
                    )
                }

                RailDivider()

                // Above the servers, as Vencord's button sits: the one way to
                // clear every dot at once.
                if let readAll {
                    ReadAllCapsule(action: readAll)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                ForEach(items) { item in
                    switch item {
                    case .guild(let guild):
                        GuildRailTile(
                            guild: guild,
                            isSelected: guild.id == selectedGuildID,
                            action: { selectGuild(guild.id) },
                            openMenu: { openGuildMenu(guild.id, $0) },
                            dragNode: .guild(guild.id)
                        )
                        // Skipped when nothing it draws changed — see its `==`.
                        .equatable()
                    case .folder(let folder):
                        GuildRailFolder(
                            folder: folder,
                            selectedGuildID: selectedGuildID,
                            toggle: { toggleFolder(folder.id) },
                            selectGuild: selectGuild,
                            openGuildMenu: openGuildMenu,
                            openFolderMenu: { openFolderMenu(folder.id, $0) }
                        )
                    }
                }

                AddServerRailTile(action: addServer)
                DiscoverRailTile(isSelected: isDiscoveryShown, action: openDiscovery)
            }
            .padding(.vertical, Spacing.base)
            .coordinateSpace(.named(Self.contentSpace))
            .overlay(alignment: .topLeading) { RailDropMarks(drag: drag, items: items) }
            .background { RailScrollViewReader(drag: drag) }
            .environment(drag)
        }
        .scrollIndicators(.hidden)
        // The last tiles rest above the call card and the now bar, which run
        // across the rail too — `sidebarBarsInset`.
        .safeAreaPadding(.bottom, barsInset)
        // The rail runs to the top of the window, under the traffic lights,
        // which the split view already insets the column for.
        .frame(width: Proportions.railWidth)
        .softScrollEdgesVertical()
        .onChange(of: items, initial: true) { drag.items = items }
        // The act a drop performs never changes — the store's — so it is
        // handed over once rather than on every evaluation.
        .onAppear { drag.drop = drop }
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

/// Show All Servers: the rack opening out into every server by name, over the
/// channels (REDESIGN.md R10). Small and quiet at the rail's head — the swipe
/// right from the rack does the same, and this is the control for a pointer.
private struct AllServersRailButton: View {
    var action: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "list.bullet")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isHovering ? Ink.primary : Ink.secondary)
                .frame(width: Metrics.guildTile, height: 26)
                .background {
                    Capsule().fill(isHovering ? RailButtonInk.hover : RailButtonInk.rest)
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .frame(width: Proportions.railWidth)
        .onHover { isHovering = $0 }
        .animation(motion.hover, value: isHovering)
        .help("Show All Servers")
        .accessibilityLabel(Text("Show All Servers"))
    }
}

private nonisolated enum RailButtonInk {
    static let rest = Color.relative(dark: 0.06, light: 0.05)
    static let hover = Color.relative(dark: 0.12, light: 0.09)
}

/// Read All, in the rail and atop the Servers page: one small glass capsule,
/// there only while some server has something unread.
///
/// **It says when it's working** (Alex, 2026-11-17): Read All takes about a
/// second for every hundred channels, and a button that looked untouched in
/// the meantime invited a second press — the same requests again, through the
/// same rate limit. While it runs the capsule shows how far it has got and
/// takes no press; the toast over the window says the same in words.
struct ReadAllCapsule: View {
    var action: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        let progress = model.readAllProgress
        Button(action: action) {
            ZStack {
                Text("Read All")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(InkColor.primary)
                    .lineLimit(1)
                    .fixedSize()
                    .opacity(progress == nil ? 1 : 0)
                if let progress {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .tint(Palette.accent)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, Spacing.base)
            .frame(height: 22)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(progress != nil)
        .glassEffect(.regular.interactive(), in: .capsule)
        .scaleEffect(isHovering && progress == nil ? 1.04 : 1)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .animation(motion.standard, value: progress == nil)
        .help(progress == nil ? "Mark every server as read" : "Marking everything as read\u{2026}")
        .accessibilityLabel(Text(progress == nil ? "Mark All Servers as Read" : "Marking All Servers as Read"))
        .accessibilityValue(progress.map { Text("\($0.done) of \($0.total)") } ?? Text(""))
    }
}
