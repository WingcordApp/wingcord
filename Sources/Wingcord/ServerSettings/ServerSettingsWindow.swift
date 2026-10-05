import AppKit
import SwiftUI
import WingcordCore

// MARK: - Opening the window
//
// **The second window in Wingcord that configures an `NSWindow`, and it does so
// by reusing the first one's configuration rather than writing a second copy.**
//
// `INVARIANTS.md` §1 says the settings window is "the ONE exception, and it is
// scoped", and that "a second window wanting the same treatment is a new
// decision, not a precedent". This is that decision, taken deliberately:
//
//   - Every argument §1 makes for the settings window holds here word for word.
//     Nothing on these pages is read for minutes at a time over a photograph,
//     every surface is one this module owns, and the source list being the bare
//     material *is* the design.
//   - The alternative was twenty pages in the workspace's detail column, where
//     they would sit on the opaque reading surface and need a second-level index
//     to be reachable at all — a settings source list wearing a channel
//     sidebar's clothes.
//   - It reuses `settingsWindowChrome()`, `SettingsMetrics` and the row
//     vocabulary rather than restating them. Two windows built from one set of
//     measurements cannot drift; two sets of measurements will.
//
// The rules stay exactly as written for `Window("Wingcord")`.

/// Which server's settings a window is showing.
///
/// The scene's value, so macOS can restore the window and so two servers can
/// have their settings open at once — which is not a hypothetical: comparing two
/// servers' permission sets is the most ordinary reason to open this twice.
struct ServerSettingsTarget: Hashable, Codable, Identifiable {
    var guildID: GuildID
    /// Which page to open on.
    ///
    /// Part of the scene's value rather than state inside the window, because
    /// "Invite People" and "Server Settings" are two menu items that open the
    /// *same* window at two different pages — and a window already open for
    /// this server has to move to the page the second one asked for.
    var section: ServerSettingsSection?
    /// A channel whose own settings should open — the main window's Edit
    /// Channel. The window shows that channel's sidebar instead of the
    /// server's, as Discord's channel settings replace its server settings.
    var channelID: ChannelID?

    /// **Identity is the guild alone.** Two menu items asking for two pages of
    /// one server must reach one window, not two.
    var id: GuildID { guildID }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.guildID == rhs.guildID }
    func hash(into hasher: inout Hasher) { hasher.combine(guildID) }
}

@MainActor
enum ServerSettingsWindow {
    static let sceneID = "server-settings"

    private static var opener: ((ServerSettingsTarget) -> Void)?

    /// Called once by the root view, exactly as `SettingsWindow.register` is.
    static func register(_ open: @escaping (ServerSettingsTarget) -> Void) {
        opener = open
    }

    static func open(_ guildID: GuildID, section: ServerSettingsSection? = nil) {
        NSApp.activate()
        opener?(ServerSettingsTarget(guildID: guildID, section: section))
    }

    /// Opens a channel's own settings — Overview, Permissions, Invites,
    /// Integrations.
    static func open(_ guildID: GuildID, channel channelID: ChannelID) {
        NSApp.activate()
        opener?(ServerSettingsTarget(guildID: guildID, channelID: channelID))
    }
}

extension View {
    /// Applied once, at the root of the main window.
    func providesServerSettingsWindow() -> some View {
        modifier(ServerSettingsWindowOpenerModifier())
    }
}

private struct ServerSettingsWindowOpenerModifier: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            ServerSettingsWindow.register { openWindow(id: ServerSettingsWindow.sceneID, value: $0) }
        }
    }
}

// MARK: - The window

struct ServerSettingsView: View {
    var target: ServerSettingsTarget
    var model: AppModel
    var controller: SessionController

    @State private var store: ServerSettingsStore?
    @State private var selection: ServerSettingsSection = .profile
    @State private var channelTab: ChannelSettingsTab = .overview
    @State private var isDeletingServer = false
    @State private var query = ""
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var sidebar = SidebarWidth()
    @State private var dragOrigin: CGFloat?
    @Environment(\.motion) private var motion

    var body: some View {
        Group {
            if let store {
                columns(store)
            } else {
                // The window can only be opened from a server the reader is in,
                // so this is the one frame between the scene appearing and the
                // store being built — not a state anybody waits in.
                Color.clear
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(
            minWidth: SettingsMetrics.minWidth,
            minHeight: SettingsMetrics.minHeight
        )
        .settingsWindowChrome()
        .toolbar(removing: .title)
        .task(id: target.guildID) { build() }
        // The page a menu item asked for. Applied on every change of the scene
        // value, so a second "Invite People" on an already-open window moves it
        // rather than doing nothing.
        .task(id: target.section) {
            if let requested = target.section { selection = requested }
        }
        .task(id: target.channelID) {
            guard let channelID = target.channelID else { return }
            store?.openChannelID = channelID
        }
        // Not `deinit` — see `ServerSettingsStore.cancelAll`.
        .onDisappear { store?.cancelAll() }
    }

    private func columns(_ store: ServerSettingsStore) -> some View {
        let guildName = model.guilds[target.guildID]?.name ?? "Server"
        let channel = store.openChannelID.flatMap { model.channelIndex[$0] }
        return HStack(spacing: 0) {
            Group {
                if let channel {
                    ChannelSettingsSidebar(
                        store: store,
                        model: model,
                        channel: channel,
                        guildName: guildName,
                        selection: $channelTab,
                        close: { store.openChannelID = nil }
                    )
                } else {
                    ServerSettingsSidebar(
                        store: store,
                        guildName: guildName,
                        guildIconURL: guildIconURL,
                        isOwner: model.guilds[target.guildID]?.ownerID == model.currentUserID,
                        selection: $selection,
                        query: $query,
                        act: act
                    )
                }
            }
            .frame(width: sidebar.current)
            .opacity(sidebar.current < 1 ? 0 : 1)

            ServerSettingsDetailPane(
                store: store,
                model: model,
                page: channel.map { .channel($0.id, channelTab) } ?? .server(selection),
                isSidebarCollapsed: sidebar.isCollapsed,
                toggleSidebar: { withAnimation(motion.reposition) { sidebar.toggle() } }
            )
        }
        .overlay(alignment: .leading) { divider }
        // A channel opened onto starts on its first page.
        .onChange(of: store.openChannelID) { channelTab = .overview }
        .sheet(isPresented: $isDeletingServer) {
            DeleteServerSheet(store: store, guildName: guildName) {
                dismissWindow()
            }
        }
    }

    /// The rows that leave or ask — Discord's `onClick` sections. Members and
    /// App Directory hand the reader to the main window and close settings, as
    /// Discord's close its layer; Delete Server asks first.
    private func act(_ section: ServerSettingsSection) {
        switch section {
        case .members:
            model.openMembersPage(in: target.guildID)
            dismissWindow()
        case .appDirectory:
            model.openAppDirectory()
            MainWindow.raise()
            dismissWindow()
        case .deleteServer:
            isDeletingServer = true
        default:
            selection = section
        }
    }

    private var guildIconURL: URL? {
        guard let guild = model.guilds[target.guildID], let hash = guild.iconHash else { return nil }
        return CDN.guildIcon(guildID: guild.id, hash: hash, side: 40)
    }

    /// Builds the store, and picks a first section the reader can actually open.
    ///
    /// **Server Profile is not always available**, so the default cannot be a
    /// constant: a reader with `MANAGE_EXPRESSIONS` alone lands on Emoji.
    private func build() {
        guard store?.guildID != target.guildID else { return }
        let permissions = model.permissionGate.permissions(inGuild: target.guildID)
        store = ServerSettingsStore.make(for: target.guildID, model: model)
        // Opened onto a channel: the first build may land after the task
        // that would have set it.
        if let channelID = target.channelID {
            store?.openChannelID = channelID
        }
        // The catalog needs a `GuildSettings` to filter on and it has not been
        // fetched yet, so the first pass filters on permissions alone and the
        // sidebar re-filters when the fetch lands — it also fixes up a selection
        // that disappears underneath itself.
        let pages = ServerSettingsSection.reachable(with: permissions).filter { !$0.isAction }
        if !pages.contains(selection) { selection = pages.first ?? .profile }
    }

    /// The grab handle, identical in behaviour to the settings window's — same
    /// `SidebarWidth` value type, same projected-rest snap, same pointer style.
    private var divider: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(.rect)
            .offset(x: max(0, sidebar.current - 4))
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let origin = dragOrigin ?? sidebar.current
                        if dragOrigin == nil { dragOrigin = origin }
                        sidebar.drag(to: origin + value.translation.width)
                    }
                    .onEnded { value in
                        let origin = dragOrigin ?? sidebar.current
                        dragOrigin = nil
                        let destination = sidebar.release(
                            at: origin + value.translation.width,
                            velocity: value.velocity.width
                        )
                        withAnimation(motion.handoff(
                            velocity: value.velocity.width,
                            over: destination - sidebar.current
                        )) {
                            sidebar.settle(to: destination)
                        }
                    }
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Building a store

extension ServerSettingsStore {
    /// A store for one server, from what the main window already holds — for
    /// this window, and for the editors the main window raises on their own
    /// (an event's).
    static func make(for guildID: GuildID, model: AppModel) -> ServerSettingsStore {
        ServerSettingsStore(
            guildID: guildID,
            permissions: model.permissionGate.permissions(inGuild: guildID),
            channels: channelSummaries(of: guildID, model: model),
            rest: model.sessionController.rest
        )
    }

    /// The channel list every picker on every page uses, built once.
    ///
    /// From the resident store rather than fetched: the window opens on a server
    /// the reader is already in, whose channels the sidebar is already drawing.
    private static func channelSummaries(of guildID: GuildID, model: AppModel) -> [ChannelSummary] {
        let channels = model.channelIndex
            .channelIDs(inGuild: guildID)
            .compactMap { model.channelIndex[$0] }
        var categories: [ChannelID: String] = [:]
        for channel in channels where channel.kind == .category {
            categories[channel.id] = channel.name
        }
        let everyone = model.roles[guildID]?[RoleID(rawValue: guildID.rawValue)]
        return channels
            .filter { $0.kind != .category }
            .map { channel in
                ChannelSummary(
                    id: channel.id,
                    name: channel.name,
                    kind: channel.kind,
                    categoryName: channel.parentID.flatMap { categories[$0] },
                    isPublic: everyoneCanView(channel, everyone: everyone, guildID: guildID)
                )
            }
    }

    /// Whether `@everyone` can see a channel.
    ///
    /// **Not `PermissionGate`'s job.** That class answers what *the reader* may
    /// do and caches per channel on the hottest path in the app; this is a
    /// question about a different subject entirely, asked once when a window
    /// opens. Putting it there would mean a second cache keyed on a second
    /// subject for one caller.
    ///
    /// `@everyone`'s role id equals the guild's, which is Discord's own
    /// convention — and the only overwrite that matters is the one naming it,
    /// because a channel hidden from `@everyone` and allowed back for one role
    /// is still not public.
    private static func everyoneCanView(
        _ channel: Channel,
        everyone: Role?,
        guildID: GuildID
    ) -> Bool {
        var allowed = everyone?.permissions.contains(.viewChannel) ?? true
        for overwrite in channel.overwrites
        where overwrite.subject == .role && overwrite.id == guildID.rawValue {
            if overwrite.deny.contains(.viewChannel) { allowed = false }
            if overwrite.allow.contains(.viewChannel) { allowed = true }
        }
        return allowed
    }

}
