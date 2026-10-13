import AppKit
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
                // **The column narrows to the rail while the gate is up**, or
                // the hidden channel list leaves a two-hundred-point hole beside
                // it. A fixed width rather than a range: there is nothing in
                // there to resize, and a draggable divider over a 68-point strip
                // is a control that can only make it wrong.
                .navigationSplitViewColumnWidth(
                    min: model.isColumnTakenOver ? Proportions.railWidth : Proportions.sidebarMin,
                    ideal: model.isColumnTakenOver ? Proportions.railWidth : Proportions.sidebarIdeal,
                    max: model.isColumnTakenOver ? Proportions.railWidth : Proportions.sidebarMax
                )
        } detail: {
            WorkspacePane(presentation: model.workspacePresentation)
                // **The channel is the window's title** — the HIG's "Provide a
                // useful title for each window" — with the topic, or a
                // thread's parent, as its subtitle and the channel's acts in
                // the title's menu. It was a custom pill in the toolbar.
                //
                // Never `.toolbar(removing: .title)`: with the title removed,
                // the soft edge a scroll view gets where it runs under the
                // toolbar is installed and draws nothing (measured). A page
                // with no channel has an empty title, which keeps the edge.
                .navigationTitle(model.channelChrome.name)
                .navigationSubtitle(model.channelChrome.titleSubtitle)
                .toolbarTitleMenu { ChannelTitleMenu(chrome: model.channelChrome, model: model) }
                // The topic, which the pill used to open as a popover — a menu
                // item cannot anchor one, so it is a small sheet.
                .sheet(isPresented: Binding(
                    get: { model.channelChrome.isTopicShown },
                    set: { if !$0 { model.openTopicChannelID = nil } }
                )) {
                    ChannelTopicSheet()
                }
                .toolbar {
                    // **The closures have to be passed.** They default to `{}`,
                    // so a toolbar built without them compiles, renders, and
                    // does nothing at all when clicked — which is exactly what
                    // the member-list toggle was doing.
                    ChannelToolbar(
                        chrome: model.channelChrome,
                        toggleMemberList: { model.isMemberListShown.toggle() },
                        toggleUserProfile: { model.isDirectMessageProfileShown.toggle() },
                        toggleCall: {
                            guard let channelID = model.selectedChannelID else { return }
                            if model.connectedVoiceChannelID == channelID {
                                model.leaveVoice()
                            } else if model.channelChrome.isCallOngoing {
                                // Already running: join it, and ring nobody.
                                model.joinCall(in: channelID)
                            } else {
                                model.startCall(in: channelID)
                            }
                        },
                        toggleVoiceChat: { model.isVoiceChatShown.toggle() },
                        togglePins: {
                            guard let channelID = model.selectedChannelID else { return }
                            model.togglePinsPane(for: channelID)
                        },
                        pinsContent: {
                            // Built only when the popover is presented, which is
                            // what keeps the pins read out of the toolbar's own
                            // body — the bar is evaluated on every navigation
                            // and the pane is opened a few times a session.
                            AnyView(
                                Group {
                                    if let channelID = model.openPinsChannelID {
                                        PinnedMessagesPane(channelID: channelID)
                                    }
                                }
                            )
                        },
                        toggleThreads: {
                            guard let channelID = model.selectedChannelID else { return }
                            if model.openThreadsChannelID == channelID {
                                model.closeThreadBrowser()
                            } else {
                                model.openThreadBrowser(channelID)
                            }
                        },
                        threadsContent: {
                            AnyView(
                                Group {
                                    if let channelID = model.openThreadsChannelID {
                                        ThreadBrowserPane(channelID: channelID)
                                    }
                                }
                            )
                        },
                        toggleSummaries: { AppSettings.shared.showsSummaryBar.toggle() },
                        isServerPage: model.workspacePresentation.primary.isServerPage,
                        isInboxShown: model.isInboxShown,
                        toggleInbox: { model.toggleInbox() },
                        inboxContent: {
                            // Built only while presented, which is what keeps
                            // five lists and a relationship walk out of the
                            // toolbar's own body — the bar is evaluated on
                            // every navigation and this is opened a few times
                            // a session.
                            AnyView(InboxFlyout())
                        }
                    )
                }
        }
        .navigationSplitViewStyle(.balanced)
        .capsWindowMinimumSize()
    }
}

/// The toolbar's search item, on every surface but a server's own page.
///
/// **On the primary pane, not the column, so a page can go without it.**
/// Discord's server pages draw their title and nothing else — their headers
/// pass `hideSearch` and no `toolbar` — and `.searchable` is the only thing
/// that puts this item in the bar: `toolbar(removing: .search)` leaves it in
/// place on macOS (probed). Declared below the window's `.toolbar`, it still
/// lands last in the bar, and the branch is free: the pane underneath changes
/// type whenever it flips.
struct ToolbarSearch: ViewModifier {
    var isOffered: Bool

    @Environment(AppModel.self) private var model

    /// The toolbar's search field, put in focus by a thread's Search item —
    /// see `AppModel.searchFocusRequest`.
    @FocusState private var isFocused: Bool

    /// The search field's text.
    ///
    /// **Opening the panel is a side effect of typing**, which is what the
    /// native item implies: there is no separate "open search" control once the
    /// field is in the toolbar, so the first character is what raises the
    /// results column.
    ///
    /// **And closing it is a side effect of clearing**, which is the half that
    /// was missing. Escape in an `NSSearchField` empties it — that is AppKit's
    /// behaviour and the field never forwards the key — so a binding that only
    /// ever opened left the reader pressing Escape at a column that had no way
    /// of hearing it. There is a button on the panel too; this is the one the
    /// keyboard reaches.
    private var text: Binding<String> {
        Binding(
            get: { model.searchText },
            set: { text in
                // Emptying the field puts the transcript back, results and all:
                // there is nothing left to have asked.
                guard !text.isEmpty else {
                    if model.isSearchDrafting { model.closeSearch() }
                    return
                }
                // The first keystroke starts a DRAFT, not a search — the state
                // is where the text lives. The results column waits for Return;
                // see `MessageSearchState.isPresented`.
                if !model.isSearchDrafting { model.toggleSearch() }
                model.searchText = text
            }
        )
    }

    func body(content: Content) -> some View {
        if isOffered {
            content
                // **The system's own search item, which is Finder's control.**
                // `.searchable` in a window with a real toolbar becomes an
                // `NSSearchToolbarItem`: a circular button that expands into a
                // field, set apart from the other items by the toolbar itself.
                //
                // There is no `.searchToolbarBehavior(.minimize)` here on
                // purpose — that value is `@available(macOS, unavailable)`, iOS
                // only. On macOS the collapse-and-expand *is* the default, and
                // asking for it explicitly does not compile.
                .searchable(
                    text: text,
                    placement: .toolbar,
                    prompt: Text("Search \(model.searchScopeTitle)")
                )
                .searchSuggestions {
                    // Built from the store's own scope, so moving between
                    // servers or conversations changes the list with no
                    // invalidation of its own — see `searchSuggestions(for:)`.
                    ForEach(model.searchSuggestions(for: model.searchText)) { suggestion in
                        SearchSuggestionRow(suggestion: suggestion)
                            // The whole field text, computed where the tokenizer
                            // is. `.searchCompletion` takes a string, and
                            // building it in the view would put the grammar in
                            // two places.
                            .searchCompletion(suggestion.completion)
                    }
                }
                // Return runs it; typing alone does not. A request per keystroke
                // against a route that indexes whole servers is a request per
                // keystroke, and the field is where a filter grammar is typed.
                //
                // **And Return is also where the column appears.** It used to
                // appear on the first keystroke — see
                // `MessageSearchState.isPresented`.
                .onSubmit(of: .search) { model.submitSearch() }
                .searchFocused($isFocused)
                .onChange(of: model.searchFocusRequest) { isFocused = true }
        } else {
            content
        }
    }
}

/// The rail and the channel list, side by side, painted with nothing.
///
/// Its own view so the split view's sidebar builder holds one child, and so the
/// two containers below can be invalidated independently.
///
/// **`sidebarGround()` is not a background**, and the distinction is the whole
/// of §1's rule: with the house theme and no picture it paints *nothing at all*,
/// so AppKit's behind-window vibrancy — the wallpaper and the menu-bar accent
/// coming through this column — is untouched. A theme that carries a hue veils
/// it thinly enough that the bleed survives tinted, and a backdrop replaces it
/// with the reader's own picture. All three cases are in `ThemeGround.swift`.
private struct SidebarColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // **The ground is a sibling that ignores the safe area, not a
        // background on the columns.**
        //
        // A `.background` is laid out inside the modified view's safe area, and
        // `.ignoresSafeArea()` on the background's own content did not get it
        // past the titlebar here: measured, the rail's strip came out at
        // #1D1B1E and the channel column's at #4C4C4F — the desktop through
        // AppKit's vibrancy — while the detail column beside them reached the
        // top of the window. A sibling in a `ZStack` has no safe area to be
        // laid out inside, so it fills the column and the ground is *its*
        // background.
        ZStack {
            Color.clear
                .sidebarGround()
                .ignoresSafeArea()

            columns
        }
    }

    private var columns: some View {
        HStack(spacing: 0) {
            GuildRailContainer()

            // **The bar belongs to the channel column, not to the whole
            // sidebar.** Attached to the `HStack`, it spanned the rail as well
            // and cut the last server tiles off behind it — and the rail is a
            // different surface with a different scroll, so a bar that reserves
            // space in it is reserving space in the wrong list. Scoped here it
            // insets exactly the list it floats over, and the rail runs to the
            // window's foot the way it runs to its top.
            // **The gate takes the channel list too.** It is a takeover: a
            // list of channels beside a page that says the reader may not use
            // them yet is an invitation to click one and find out. The rail
            // stays, deliberately — stepping away to another server and coming
            // back to the gate where you left it is the point of it being a
            // destination rather than a modal.
            if !model.isColumnTakenOver {
                ChannelSidebarContainer()
                    // **The call card and the now bar float over the list**,
                    // as a registered bar: the list reserves their height and
                    // its rows pass underneath. The now bar is clear glass that
                    // refracts them (Alex, 2026-10-06); the call card is opaque,
                    // because rows reading through the call was the fault he
                    // reported in it.
                    //
                    // **Nothing is painted behind these bars**: an opaque
                    // ground under the now bar's glass leaves it nothing to
                    // refract, and it reads as a flat plate. The sidebar's own
                    // ground already covers this strip.
                    .safeAreaBar(edge: .bottom, spacing: 0) {
                        VStack(spacing: Spacing.base) {
                            VoiceHUDContainer()
                            NowBarContainer()
                        }
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

private struct GuildRailContainer: View {
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

private struct ChannelSidebarContainer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ChannelSidebar(
            presentation: model.sidebarPresentation,
            target: model.sidebarTarget,
            connectedVoiceChannelID: model.connectedVoiceChannelID,
            liveEvent: model.selectedGuildID.flatMap(model.liveEventNotice(for:)),
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
            openEvents: { model.openEvents(inGuild: $0, event: $1) },
            dismissLiveEvent: { model.dismissedEventNotices.insert($0) },
            openMenu: { model.openChannelMenu(for: $0, anchor: $1) },
            createChannel: { model.openChannelCreation(inCategory: $0) },
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
