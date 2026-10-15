import AppKit
import SwiftUI
import WingcordCore

/// The sidebar's lists inside the panel: its pages, and under them the call
/// card and the now bar.
///
/// **No ground of its own.** The panel behind it is glass over the window's one
/// ground (`WindowShell`); this draws only rows.
struct SidebarColumnContent: View {
    /// A takeover (the join gate, discovery) keeps the rail and drops the list.
    var isTakenOver: Bool

    var body: some View {
        Group {
            if isTakenOver {
                // **The gate takes the lists too.** It is a takeover: a list of
                // channels beside a page that says the reader may not use them
                // yet is an invitation to click one and find out. The rail
                // stays, deliberately — stepping away to another server and
                // coming back to the gate where you left it is the point of it
                // being a destination rather than a modal.
                GuildRailContainer()
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                SidebarPages()
                    // **The call card and the now bar float over the lists**,
                    // as a registered bar: every page reserves their height and
                    // its rows pass underneath. Across the whole panel and
                    // still while the pages slide — they are the account's,
                    // not a page's. The now bar is clear glass that refracts
                    // the rows (Alex, 2026-10-06); the call card is opaque,
                    // because rows reading through the call was the fault he
                    // reported in it.
                    //
                    // **Nothing is painted behind these bars**: an opaque
                    // ground under the now bar's glass leaves it nothing to
                    // refract, and it reads as a flat plate.
                    .safeAreaBar(edge: .bottom, spacing: 0) {
                        VStack(spacing: Spacing.base) {
                            VoiceHUDContainer()
                            NowBarContainer()
                        }
                        .padding(.horizontal, Spacing.base)
                    }
            }
        }
        // Drawn HERE, outside the rail's own `ScrollView` — which clips — and on
        // the one view wide enough to hold a chip beside the 68-point column.
        .railHoverLabelHost()
    }
}

// MARK: - Containers
//
// Each container reads the store and hands **plain values** down. The view below
// it holds no model reference, so a message arriving cannot invalidate the rail
// and a presence flush cannot invalidate the channel list.
//
// This is not ceremony. Without it, every publication on the store re-evaluates
// every surface's body, and `.equatable()` below cannot help because the closures
// the surface is handed are recreated each time and compare unequal.

struct GuildRailContainer: View {
    /// Whether the rail carries Show All Servers — on the servers page, where
    /// the rack expands over the channels.
    var showsAllServersButton = false

    @Environment(AppModel.self) private var model

    var body: some View {
        GuildRail(
            items: model.railItems,
            previewedGuild: model.previewRailGuild,
            pendingApplications: model.pendingApplicationsRail,
            selectedGuildID: model.selectedGuildID,
            isHomeSelected: model.selectedGuildID == nil,
            homeMentionCount: 0,
            homeHasUnread: false,
            showAllServers: showsAllServersButton ? { SidebarPager.shared.toggleAllServers() } : nil,
            selectHome: { model.selectGuild(nil) },
            selectGuild: { model.selectGuild($0) },
            openGuildMenu: { model.openServerOptions($0, anchor: $1) },
            toggleFolder: { model.toggleFolder($0) },
            openFolderMenu: { model.openFolderMenu($0, anchor: $1) },
            drop: { model.dropOnRail($0) },
            togglePendingApplications: { model.togglePendingApplications() },
            openJoinRequestMenu: { model.openJoinRequestMenu($0, anchor: $1) },
            dismissApplicationCoachmark: { model.dismissApplicationCoachmark() },
            addServer: { model.joinServerSheet = JoinServerSheetState() },
            openDiscovery: { model.toggleDiscovery() },
            isDiscoveryShown: model.isDiscoveryShown
        )
        .equatable()
    }
}

struct ChannelSidebarContainer: View {
    /// The server whose channels to list, or nil for the conversations.
    var guildID: GuildID?

    @Environment(AppModel.self) private var model
    @State private var settings = AppSettings.shared

    var body: some View {
        list
            // The conversations' preview lines, asked for once the list and
            // the connection are both there — and again only for
            // conversations that arrive later.
            .task(id: PreviewTrigger(
                isHome: guildID == nil,
                isReady: model.connectionState == .ready,
                count: guildID == nil ? model.channelIndex.privateChannelIDs().count : 0,
                isOn: settings.loadsMessagePreviews
            )) {
                guard guildID == nil else { return }
                model.sessionController.loadDirectMessagePreviews()
            }
    }

    private struct PreviewTrigger: Hashable {
        var isHome: Bool
        var isReady: Bool
        var count: Int
        var isOn: Bool
    }

    private var list: some View {
        ChannelSidebar(
            presentation: model.sidebarPresentation(for: guildID),
            target: model.sidebarTarget,
            connectedVoiceChannelID: model.connectedVoiceChannelID,
            liveEvent: guildID.flatMap(model.liveEventNotice(for:)),
            selectChannel: { model.selectChannel($0) },
            // The channel list's own row opens the thread as the page, as
            // Discord's does — split view is for a thread reached from where
            // it hangs.
            openThread: { model.openThread($0, as: .fullView) },
            joinVoice: { channelID in
                // The same control leaves the call it is already in. Pin and
                // Unpin are one bit resolved two ways, and so is this — two rows
                // that can both be offered is how a "join" ends up disconnecting
                // somebody.
                if model.connectedVoiceChannelID == channelID {
                    model.leaveVoice()
                } else {
                    model.joinVoice(channelID)
                }
            },
            openVoiceChat: { channelID in
                model.selectChannel(channelID)
                model.isVoiceChatShown = true
            },
            toggleCategory: { model.toggleCategory($0) },
            openSurface: { model.openSurface($0) },
            openMessageRequests: { model.openMessageRequests() },
            openFriends: { model.openFriends() },
            openEvents: { model.openEvents(inGuild: $0, event: $1) },
            dismissLiveEvent: { model.dismissedEventNotices.insert($0) },
            openMenu: { id, anchor in
                // A conversation folder's header has a menu of its own; the
                // heading over the unfiled ones has none.
                if let folderID = DirectMessageFolders.folderID(from: id) {
                    if folderID != 0 { DirectMessageFolderMenu.show(for: folderID) }
                } else {
                    model.openChannelMenu(for: id, anchor: anchor)
                }
            },
            createChannel: { model.openChannelCreation(inCategory: $0) },
        )
        .equatable()
    }
}

/// The rack, expanded: every server by name.
struct ServerListContainer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ServerList(
            items: model.railItems,
            previewedGuild: model.previewRailGuild,
            pendingApplications: model.pendingApplicationsRail?.guilds ?? [],
            selectedGuildID: model.selectedGuildID,
            selectGuild: { guildID in
                model.selectGuild(guildID)
                // Picking the server already open is going back to it too.
                SidebarPager.shared.setRackExpanded(false)
            },
            openGuildMenu: { model.openServerOptions($0, anchor: $1) },
            toggleFolder: { model.toggleFolder($0) },
            addServer: { model.joinServerSheet = JoinServerSheetState() },
            openDiscovery: { model.toggleDiscovery() }
        )
        .equatable()
    }
}

private struct NowBarContainer: View {
    @Environment(AppModel.self) private var model
    /// Read here rather than inside the bar, so the bar stays a pure value view
    /// and `.equatable()` still has something to compare.
    @State private var settings = AppSettings.shared

    var body: some View {
        NowBar(
            presentation: model.nowBarPresentation,
            shape: settings.chromeShape,
            openSettings: { SettingsWindow.open() },
            openProfile: { model.openOwnCard() },
            reportAnchor: { model.ownCardAnchor = $0 }
        )
        .equatable()
    }
}

// MARK: - The Dock badge

/// Mirrors the rail's mention total onto the Dock icon.
///
/// A modifier on the window root rather than a subscription in the model: the
/// count is a *projection*, and the only thing that can tell you it moved is a
/// view that reads it. `onChange` fires when the memoized value actually
/// differs, so a presence flush that moved nobody costs one integer comparison.
///
/// `nil`, not `""` — an empty string still draws the red oval.
private struct DockBadgeModifier: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .onChange(of: model.totalMentionCount, initial: true) { _, count in
                NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
            }
    }
}

extension View {
    /// Applied once, at the window root.
    func mirrorsUnreadCountOnDock() -> some View {
        modifier(DockBadgeModifier())
    }
}
