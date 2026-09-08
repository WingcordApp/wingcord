import SwiftUI
import WingcordCore

/// The detail column.
///
/// **One type, always.** Its body branches internally on the presentation value;
/// its *identity* never changes. macOS re-resolves split-view column widths on a
/// structural detail swap and repeatedly steals width from the sidebar until the
/// rail slides underneath — and internal `_ConditionalContent` under a stable
/// outer type is not a structural swap, which is the precise property everything
/// here depends on.
///
/// Anything added later — a forum, a search panel, a voice stage — arrives as a
/// case on `WorkspacePresentation`, never as a branch in the split view's
/// builder.
struct WorkspacePane: View {
    var presentation: WorkspacePresentation

    /// How far the supplementary column is lifted off the shared field.
    static let rosterLift: Double = 0.055

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    /// The window's chrome above this column.
    ///
    /// **Read on a view that RESPECTS the safe area**, which is why it is taken
    /// on the outer stack and handed down rather than measured inside the
    /// roster: a reader that ignores an inset has already been handed the region
    /// the inset describes and reports zero — §2's rule, paid for three times in
    /// this app now.
    @State private var chromeHeight: CGFloat = 0

    var body: some View {
        columns
            // **The preview banner is declared HERE, above both columns**, so it
            // spans the transcript and the roster the way Discord's does and so
            // every surface a previewed server can show — a channel, a forum, a
            // voice stage, the server guide — inherits it without a branch of
            // its own.
            //
            // `safeAreaBar`, not an overlay: the canvases underneath run to the
            // window's top and pay for the chrome as a content inset, and
            // `chromeHeight` below is read from the safe area — so the
            // transcript's inset grows by exactly this bar's height with no
            // number written down anywhere.
            .safeAreaBar(edge: .top, spacing: 0) {
                if let preview = model.guildPreviewPresentation, model.isPreviewingSelectedGuild {
                    GuildPreviewBanner(
                        preview: preview,
                        join: { model.joinPreviewedGuild() },
                        leave: { model.leavePreview() }
                    )
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { chromeHeight = $0 }
    }

    private var columns: some View {
        HStack(spacing: 0) {
            PrimaryPane(content: presentation.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let supplementary = presentation.supplementary {
                SupplementaryPane(content: supplementary, chromeHeight: chromeHeight)
                    // **A lifted panel, not a second ground.**
                    //
                    // The roster shares the window's one field — it has to, or
                    // it is a second exposure of the same photograph with the
                    // split between them, which is exactly the fault the
                    // sidebar had. What separates it is *light*: a hair of white
                    // over the field, which over a picture reads as more of the
                    // picture coming through and over a flat theme reads as a
                    // panel a step above the page. Relative, so it survives the
                    // system glass-intensity setting and Reduce Transparency —
                    // the same reasoning every fill in `Palette` is built on.
                    //
                    // It is the mirror of `ThemeColors.sidebarRecess`: contents
                    // on the left sit a step behind the page, people on the
                    // right a step in front of it.
                    .background(Color.white.opacity(Self.rosterLift))
                    // **In and out along the same edge.** The column lives at
                    // the trailing edge, so it arrives from there and leaves the
                    // same way — a panel that slides in from the right and fades
                    // out in place reads as two unrelated events. Spatial
                    // symmetry, `INVARIANTS.md` §3.
                    //
                    // Paired with `.opacity` because the transcript widens
                    // underneath it at the same time: a column travelling at
                    // full opacity over content that is already reflowing reads
                    // as two things moving past each other.
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Declared HERE rather than at the toggle, so the column's travel and
        // the transcript's reflow are one gesture. `INVARIANTS.md` §3 forbids
        // wrapping the store write in `withAnimation`: that opens a global
        // transaction and every view that re-lays-out while it runs animates.
        //
        // `reposition` is the class for larger travel that is not a gesture —
        // critically damped, because a column that has arrived somewhere should
        // not wobble about it.
        .animation(motion.reposition, value: presentation.supplementary)
        // The reading surface is opaque, and only the reading surface.
        //
        // A translucent transcript is legible over a terminal and unreadable
        // over a photograph — the desktop reads straight through the message
        // text. The bleed belongs to the CHROME: the sidebar column is vibrant
        // and this is not.
        .readingSurface()
    }
}

private struct PrimaryPane: View {
    var content: WorkspacePresentation.Primary

    var body: some View {
        switch content {
        case .empty:
            EmptyWorkspace()
        case .conversation(let channelID):
            ConversationPane(channelID: channelID)
        case .forum(let channelID):
            ForumContainer(channelID: channelID)
        case .voice(let channelID):
            VoiceChannelPane(channelID: channelID)
        case .guildSurface(_, let surface):
            // Three view types behind one `switch`, under a stable outer type.
            // That is internal `_ConditionalContent`, not the structural detail
            // swap §1 forbids — the split view has nothing to re-resolve.
            //
            // The guild is not passed down: each container reads the SELECTED
            // guild, which is the only one that can be showing. Passing it as
            // well would be a second source of truth for which server the page
            // is about.
            switch surface {
            case .serverGuide:
                ServerGuideContainer()
            case .channelsAndRoles, .browseChannels:
                ChannelsAndRolesContainer(surface: surface)
            case .gameServers:
                GameServersContainer()
            }
        case .joinGate:
            ServerJoinGateContainer()
        case .discovery:
            DiscoveryContainer()
        }
    }
}

/// The onboarding gate, fed from the store.
///
/// Reads the SELECTED guild's gate rather than taking the id from the case, for
/// the same reason the three surface containers do: the presentation already
/// decided which server this is, and a second source of truth for it is a second
/// thing to keep in step.
private struct ServerJoinGateContainer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let presentation = model.joinGatePresentation {
                ServerJoinGatePane(
                    presentation: presentation,
                    toggleOption: { model.toggleJoinGateOption($0, inPrompt: $1) },
                    back: { model.retreatJoinGate() },
                    forward: { model.advanceJoinGate() },
                    dismiss: { model.dismissJoinGate() }
                )
                .equatable()
            } else {
                SurfaceLoadingState(message: "Getting this server ready…")
            }
        }
    }
}

private struct SupplementaryPane: View {
    var content: WorkspacePresentation.Supplementary
    /// See `WorkspacePane.chromeHeight`.
    var chromeHeight: CGFloat = 0

    var body: some View {
        switch content {
        case .members:
            // **Under the chrome, and paid for as a content inset.** Left inside
            // the safe area the roster stopped at the toolbar's foot, so the
            // strip across the window's top was treated over the transcript and
            // bare over the people beside it — one row of chrome with a hard
            // vertical seam in it.
            MemberListContainer(topInset: chromeHeight)
                .frame(width: Proportions.memberColumnIdeal)
                .ignoresSafeArea(.container, edges: .top)
        case .userProfile(let userID):
            DirectMessageProfileContainer(userID: userID)
        case .thread(let channelID):
            ThreadPanelContainer(channelID: channelID)
        case .search:
            SearchPane()
                .frame(width: Proportions.searchColumnIdeal)
        case .voiceChat(let channelID):
            VoiceChatContainer(channelID: channelID)
        case .channelPreview(let channelID):
            ChannelPreviewContainer(channelID: channelID)
        }
    }
}

/// No channel open.
struct EmptyWorkspace: View {
    var body: some View {
        VStack(spacing: Spacing.snug) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Ink.quaternary)
            Text("No channel selected")
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(Ink.secondary)
            Text("Pick a server, then a channel.")
                .font(.system(.subheadline))
                .foregroundStyle(Ink.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A surface that exists in the navigation model but is not built yet.
///
/// It is a real case rather than a `fatalError` or an empty view, because the
/// presentation enum is what holds the detail column's type stable — a case that
/// cannot be rendered is a case that will be worked around with a branch in the
/// builder, which is the thing that must not happen.
struct PlaceholderPane: View {
    var symbol: String
    var title: String
    var detail: String
    var channelID: ChannelID?

    var body: some View {
        VStack(spacing: Spacing.base) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Ink.quaternary)
            Text(title)
                .font(.system(.headline))
                .foregroundStyle(Ink.secondary)
            Text(detail)
                .font(.system(.caption))
                .foregroundStyle(Ink.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Discovery, fed from the store.
///
/// The container reads and the pane draws — the same split every other surface
/// here keeps, so a grid arriving cannot invalidate the rail beside it.
private struct DiscoveryContainer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.discovery ?? DiscoveryState()
        DiscoveryPane(
            tab: Binding(
                get: { model.discovery?.tab ?? .servers },
                set: { model.selectDiscoveryTab($0) }
            ),
            query: Binding(
                get: { model.discovery?.query ?? "" },
                set: { model.setDiscoveryQuery($0) }
            ),
            categoryID: Binding(
                get: { model.discovery?.categoryID },
                set: { model.selectDiscoveryCategory($0) }
            ),
            categories: model.discoveryCategories,
            appCategoryID: Binding(
                get: { model.discovery?.appCategoryID },
                set: { model.selectAppCategory($0) }
            ),
            appCategories: model.appDirectoryCategories,
            cards: model.discoveryCards,
            apps: state.apps,
            isBusy: state.isBusy,
            emptyLine: model.discoveryEmptyLine,
            hasMore: state.tab == .servers
                ? state.page.guilds.count < state.page.total
                : state.appPage < state.appPageCount,
            openAppID: state.openAppID,
            openCard: { model.openDiscoveryCard($0) },
            openApp: { model.openDiscoveryApp($0) },
            closeApp: { model.closeDiscoveryApp() },
            addApp: { model.addDiscoveredApp($0) },
            loadMore: { model.loadMoreDiscovery() },
            dismiss: { model.closeDiscovery() }
        )
    }
}
