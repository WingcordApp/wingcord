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
                        openChannelDetails: {},
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
                        }
                    )
                }
        }
        .navigationSplitViewStyle(.balanced)
        .clearsTitlebarMaterial()
        // The title is drawn by the toolbar, not by the window's own title bar.
        .toolbar(removing: .title)
        .capsWindowMinimumSize()
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
            ChannelSidebarContainer()
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    // The bar paints a fill of its own that no modifier can
                    // suppress, and under a theme it is a slab across the foot
                    // of the column with a hard edge. Handing it the same ground
                    // the column has puts the theme back over it — see
                    // `barGround`.
                    //
                    // **The call sits above the identity, in a panel of its
                    // own.** It used to be a line inside the now bar, which made
                    // the bar change height whenever somebody joined a channel
                    // and re-laid out the whole list under it.
                    VStack(spacing: Spacing.base) {
                        VoiceHUDContainer()
                        NowBarContainer()
                    }
                    .barGround(.sidebar)
                }
        }
    }
}

// MARK: - The titlebar's own material

/// Makes the titlebar strip transparent, so the window's ground runs through it.
///
/// **`INVARIANTS.md` §1 says the `Window` scene takes no `NSWindow`
/// configuration, and this is the one exception it now has.** The rule is about
/// the switches that change what the *window* is — `isOpaque`, a hand-rolled
/// vibrancy, a background colour of its own — because each of those puts the app
/// in the business of painting what the system was already painting. This takes
/// a mark away and paints nothing.
///
/// It is here because SwiftUI could not do it.
/// `toolbarBackgroundVisibility(.hidden, for: .windowToolbar)` is the modifier
/// for exactly this and it did not remove the slab, on the split view or on the
/// view owning the toolbar. What settled it was a red probe painted over the
/// ground: the ground reaches the full height of the strip and is simply covered
/// there, so what is on top belongs to `NSTitlebarView` rather than to anything
/// this app draws. The settings window has made the same call since it was
/// built, for the same reason and in the same one place.
///
/// The workspace window stays **opaque** — that half of §1 is untouched, and it
/// is the half that keeps a transcript readable over a photograph.
private struct TitlebarMaterialClearer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // **Both, and each removes a different slab.**
            //
            // `titlebarAppearsTransparent` is what stops `NSTitlebarView`
            // painting its own material: without it AppKit draws an
            // `NSTitlebarBackgroundView` per split column across the top 52
            // points — over the ground, over the reader's picture, and over the
            // edge treatment this window draws for itself. It reads as a dark
            // shadow ruled along the window's top edge.
            //
            // `fullSizeContentView` is what stops the strip being a hole
            // instead: transparent with the content still starting below it,
            // the app trades a slab for the desktop.
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
        }
    }
}

extension View {
    fileprivate func clearsTitlebarMaterial() -> some View {
        background(TitlebarMaterialClearer().frame(width: 0, height: 0))
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
            connectedVoiceChannelID: model.connectedVoiceChannelID,
            selectChannel: { model.selectChannel($0) },
            openThread: { model.openThread($0) },
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
        )
        .equatable()
    }
}

private struct NowBarContainer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NowBar(
            presentation: model.nowBarPresentation,
            // Through the controller, so the switch reaches the media engine
            // AND is republished over the socket — a mute that only moves a
            // local flag is a mute nobody else can see.
            toggleMute: { model.toggleVoiceMute() },
            toggleDeafen: { model.toggleVoiceDeafen() },
            openSettings: { SettingsWindow.open() },
            openSelfProfile: {
                guard let userID = model.currentUserID else { return }
                // The full profile is a sheet and anchors to nothing, so there
                // is no rect to hand it.
                model.openProfile(userID, anchor: .zero, depth: .full)
            },
            setStatus: { model.updateSelfStatus($0) },
            setCustomStatus: { model.updateSelfCustomStatus($0) }
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
