import SwiftUI
import WingcordCore

/// The window.
///
/// Three things about this view are the whole pane model, and each is load
/// bearing:
///
///  1. **The sidebar column is `HStack { rail; channels }` with no background.**
///     AppKit paints that column with behind-window vibrancy, and that is where
///     the wallpaper and the menu-bar accent come through. There is nothing to
///     implement and nothing to paint.
///  2. **The detail is one view type.** `WorkspacePane` takes a presentation
///     value; every branch happens inside it. A structural swap here makes macOS
///     re-resolve the column widths on every server click and steal width from
///     the sidebar until the rail slides under the detail.
///  3. **Every chrome control is a real `ToolbarItem`.** That is what gives the
///     scroll-edge blur something to key off, what makes `.glass` controls
///     resolve against the toolbar's material instead of the scrolling
///     transcript, and what removes every hand-reserved clearance under the
///     chrome — the safe area does that.
struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarColumn()
                .navigationSplitViewColumnWidth(
                    min: Proportions.sidebarMin,
                    ideal: Proportions.sidebarIdeal,
                    max: Proportions.sidebarMax
                )
        } detail: {
            WorkspacePane(presentation: model.workspacePresentation)
                .toolbar {
                    // **The closures have to be passed.** They default to `{}`,
                    // so a toolbar built without them compiles, renders, and
                    // does nothing at all when clicked — which is exactly what
                    // the member-list toggle was doing.
                    ChannelToolbar(
                        chrome: model.channelChrome,
                        toggleMemberList: { model.isMemberListShown.toggle() },
                        toggleUserProfile: { model.isDirectMessageProfileShown.toggle() },
                        openChannelDetails: {}
                    )
                }
        }
        .navigationSplitViewStyle(.balanced)
        // The title is drawn by the toolbar, not by the window's own title bar.
        .toolbar(removing: .title)
        .capsWindowMinimumSize()
    }
}

/// The rail and the channel list, side by side, painted with nothing.
///
/// Its own view so the split view's sidebar builder holds one child, and so the
/// two containers below can be invalidated independently.
private struct SidebarColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            GuildRailContainer()

            // **The bar belongs to the channel column, not to the whole
            // sidebar.** Attached to the `HStack`, it spanned the rail as well
            // and cut the last server tiles off behind it — and the rail is a
            // different surface with a different scroll, so a bar that reserves
            // space in it is reserving space in the wrong list. Scoped here it
            // insets exactly the list it floats over, and the rail runs to the
            // window's foot the way it runs to its top.
            ChannelSidebarContainer()
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    NowBarContainer()
                }
        }
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

private struct GuildRailContainer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GuildRail(
            items: model.railItems,
            selectedGuildID: model.selectedGuildID,
            isHomeSelected: model.selectedGuildID == nil,
            homeMentionCount: 0,
            homeHasUnread: false,
            selectHome: { model.selectGuild(nil) },
            selectGuild: { model.selectGuild($0) },
            toggleFolder: { model.toggleFolder($0) }
        )
        .equatable()
    }
}

private struct ChannelSidebarContainer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ChannelSidebar(
            presentation: model.sidebarPresentation,
            target: model.sidebarTarget,
            selectChannel: { model.selectChannel($0) },
            toggleCategory: { model.toggleCategory($0) },
            openSurface: { model.openSurface($0) },
            openGuildMenu: {}
        )
        .equatable()
    }
}

private struct NowBarContainer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NowBar(
            presentation: model.nowBarPresentation,
            toggleMute: { model.isSelfMuted.toggle() },
            toggleDeafen: {
                model.isSelfDeafened.toggle()
                // Deafening implies muting, and undeafening does not imply
                // unmuting — someone who was muted before they deafened stays
                // muted, which is what every voice client does and what people
                // expect.
                if model.isSelfDeafened { model.isSelfMuted = true }
            },
            openSettings: { SettingsWindow.open() },
            openSelfProfile: {
                guard let userID = model.currentUserID else { return }
                // The full profile is a sheet and anchors to nothing, so there
                // is no rect to hand it.
                model.openProfile(userID, anchor: .zero, depth: .full)
            },
            setStatus: { model.updateSelfStatus($0) },
            setCustomStatus: { model.updateSelfCustomStatus($0) },
            disconnectVoice: { model.connectedVoiceChannelID = nil }
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
