import AppKit
import SwiftUI
import WingcordCore

/// The channel column: the server's banner, its name pill, and its channels.
///
/// **No background.** Like the rail, this sits inside the split view's sidebar
/// column and the vibrancy behind it is the wallpaper coming through. The banner
/// is the only thing here with a colour of its own, and it is a *layer* rather
/// than the first row of the list.
///
/// That split matters. As the first row, the banner forces the scroll view to
/// give up its top safe area — the only way for artwork inside a scroll view to
/// reach the top of the column — and a scroll view with no top safe area pins
/// its content to the top of the window rather than under the toolbar. Split
/// apart, the banner reaches the chrome and the list keeps its inset, and the
/// two stay in step because both are driven by the same measured offset.
struct ChannelSidebar: View, Equatable {
    var presentation: SidebarPresentation
    /// **One value, so two rows cannot both be lit.** A channel and a server
    /// page are mutually exclusive destinations in this list, and holding them
    /// as a channel id plus a flag is how the channel you came from keeps its
    /// pill while Channels & Roles is open.
    var target: SidebarTarget

    /// The call the reader is in, if it is in this server. Part of `==` because
    /// it changes a row's glyph — a row that could not see it would keep
    /// offering "join" to a channel you are already in.
    var connectedVoiceChannelID: ChannelID?
    /// The card for an event happening now, at the head of the list.
    var liveEvent: LiveEventNotice?

    static func == (lhs: ChannelSidebar, rhs: ChannelSidebar) -> Bool {
        lhs.presentation == rhs.presentation
            && lhs.target == rhs.target
            && lhs.connectedVoiceChannelID == rhs.connectedVoiceChannelID
            && lhs.liveEvent == rhs.liveEvent
    }

    var selectChannel: (ChannelID) -> Void = { _ in }
    /// Its own closure rather than `selectChannel`: opening a thread decides
    /// between the panel and the whole column on the thread's *parent*, which is
    /// a store question — see `AppModel.openThread`.
    var openThread: (ChannelID) -> Void = { _ in }
    var joinVoice: (ChannelID) -> Void = { _ in }
    var openVoiceChat: (ChannelID) -> Void = { _ in }
    var toggleCategory: (ChannelID) -> Void = { _ in }
    var openSurface: (GuildSurface) -> Void = { _ in }
    /// The Message Requests page, from its row at the head of the conversations.
    var openMessageRequests: () -> Void = {}
    /// The Friends page, from its row above that (REDESIGN.md R12).
    var openFriends: () -> Void = {}
    /// The events panel — on its list, or on one event.
    var openEvents: (GuildID, UInt64?) -> Void = { _, _ in }
    var dismissLiveEvent: (UInt64) -> Void = { _ in }
    /// A secondary click on a conversation, with the row's own rect. Only the
    /// direct-message list passes one — see `SidebarChannelRow.openMenu`.
    var openMenu: (ChannelID, CGRect) -> Void = { _, _ in }
    /// Create Channel inside a category — its "+".
    var createChannel: (ChannelID) -> Void = { _ in }
    /// The Boost progress bar's switch, from its own menu.
    var setBoostProgressBar: (GuildID, Bool) -> Void = { _, _ in }

    @Environment(\.motion) private var motion
    /// Where the header title starts, and the header row it centres in — see
    /// `SidebarPages`, whose pages without a rail start it past the lights.
    @Environment(\.sidebarTitleLeading) private var titleLeading
    @Environment(\.sidebarHeaderBand) private var headerBand
    @Environment(\.sidebarBarsInset) private var barsInset
    /// The window's arrangement, for whether the header's toggle has folded
    /// into the + menu and given the name its room (#17).
    @Environment(\.shellLayout) private var shellLayout
    /// How far the list has been scrolled — see `SidebarScroll`.
    @State private var scroll = SidebarScroll()
    /// Whether the pointer is over the banner — see `SidebarBannerPointer`.
    @State private var bannerPointer = SidebarBannerPointer()
    /// How much room the window's chrome takes above this column.
    ///
    /// **Read from a view that RESPECTS the safe area.** The opposite is the
    /// intuition, it is what this file used to do, and it is wrong: a reader
    /// that ignores the inset has already been handed the region the inset
    /// describes, so it has nothing left to report. Measured on a live window,
    /// both readers in the same frame: **0.00 ignoring, 52.00 respecting.**
    ///
    /// The banner needs it in order to run underneath the chrome, and it is the
    /// only thing in this view that does — every other number stays in the
    /// column's own space. See `chromeInsetProbe`.
    @State private var topInset: CGFloat = 0
    /// How far below the sidebar panel's top edge this column begins, measured
    /// in `SidebarPanelSpace` — what lifts the title into the header row.
    ///
    /// **Measured, not `topInset`.** The safe-area inset reads from the
    /// window's top, not the panel's, so a floating panel's five points of
    /// top inset put a title placed by it five points above the row it
    /// belongs in (measured: centred at 20.5 against the lights' 25).
    @State private var panelTop: CGFloat?
    /// How wide this column is. Measured for one reason only: an over-wide
    /// toolbar item is dropped rather than truncated, so the title has to know
    /// what it may occupy. See `SidebarBannerLayout.toolbarTitleWidth`.
    @State private var columnWidth: CGFloat = 0

    /// The reader's Server banners switch, read here so a server with art
    /// draws exactly as one without it when it is off.
    @State private var settings = AppSettings.shared
    /// The Messages page's search — see `visibleRows`.
    @State private var query = ""
    /// Which row the pointer is on, tracked once for the list — see
    /// `SidebarHoverRouter`.
    @State private var hoverRouter = SidebarHoverRouter()

    /// The direct-message home, whose list the search narrows.
    private var isHome: Bool { presentation.header != nil && presentation.header?.guildID == nil }

    private var isSearching: Bool {
        isHome && !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// What the list draws: everything, or — while the home is searched —
    /// every conversation whose name matches, closed folders and pins
    /// included, most recent first, as plain rows.
    private var visibleRows: [SidebarRow] {
        guard isSearching else { return presentation.rows }
        let needle = query.trimmingCharacters(in: .whitespaces)
        return presentation.conversations
            .filter { $0.name.localizedStandardContains(needle) }
            .map(SidebarRow.channel)
    }

    private var hasBanner: Bool {
        settings.showsServerBanners && (presentation.header?.hasBanner ?? false)
    }

    /// Everything positioned against the banner, at rest. See
    /// `SidebarBannerLayout` for the arithmetic and for the one measurement it
    /// rests on; the views that move with the list add the travel themselves.
    ///
    /// Recomputed rather than stored: it is four `CGFloat`s over values already
    /// in hand, and a stored copy is a copy that can be stale — which is exactly
    /// how an earlier version parked the pill at the *previous* server's banner
    /// height on a server that had none.
    private var layout: SidebarBannerLayout {
        SidebarBannerLayout(
            hasBanner: hasBanner, chromeInset: topInset, columnWidth: columnWidth, titleLeading: titleLeading,
            foldsSidebarToggle: shellLayout?.foldsSidebarToggle ?? false
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            if hasBanner, let header = presentation.header {
                TravellingBanner(header: header, layout: layout, scroll: scroll, pointer: bannerPointer)
                    // **Under the switcher, as the list's first thing**, no
                    // longer up under the toolbar where the controls sat on the
                    // picture (Alex, 2026-11-18). Carried up by the list, it
                    // fades under the chrome exactly as a row does.
                    .fadesUnderSidebarChrome()
            }
            // The rows fade out under the panel's chrome, and so does the
            // banner behind them (above); the name over them fades by its own
            // opacity as it rides off the artwork.
            VStack(spacing: 0) {
                // The conversations' search, fixed over the list as Messages
                // keeps its own — the system's field on glass.
                if isHome {
                    SearchField(prompt: "Search", text: $query)
                        .padding(.horizontal, Spacing.base + Spacing.hair)
                        .padding(.top, Spacing.tight)
                        .padding(.bottom, Spacing.tight)
                }
                list
                    .fadesUnderSidebarChrome()
                    .overlay(alignment: .top) {
                        if isSearching, visibleRows.isEmpty {
                            Text("No conversations match.")
                                .font(.subheadline)
                                .foregroundStyle(Ink.secondary)
                                .padding(.top, Spacing.group)
                        }
                    }
            }
        }
        .background(alignment: .top) { chromeInsetProbe }
        .onGeometryChange(for: CGFloat?.self) { proxy in
            proxy.bounds(of: SidebarPanelSpace.space).map { -$0.minY }
        } action: { top in
            panelTop = top
        }
        // Over both layers, so it sits ON the artwork rather than in the band
        // below it.
        //
        // Inside the scroll view it could only do one of two things: scroll away
        // at the LIST's pace, or pin and never move. What is wanted is neither —
        // it travels at the BANNER's pace, which includes the stretch the list
        // knows nothing about. That is a position rather than a layout, so it is
        // drawn on top and told where to be. Nothing here blocks the scroll: the
        // row is a menu button and a spacer, and a spacer has no hit region.
        .overlay(alignment: .topLeading) {
            if hasBanner, let header = presentation.header {
                TravellingPill(header: header, layout: layout, scroll: scroll)
            }
        }
        // The other half of the name: once the pill has ridden off the banner
        // (or on a server with none), the name sits in the panel's header row,
        // level with the traffic lights. The header is ours now rather than a
        // toolbar, so the row is drawn here — where the scroll that decides it
        // lives — and lifted into the header band above the list's safe area.
        .overlay(alignment: .topLeading) {
            if let header = presentation.header {
                // In the panel's header row: its height, from the panel's top
                // edge. Outside a panel (a preview), the chrome above it.
                let lift = panelTop ?? topInset
                TravellingToolbarTitle(header: header, layout: layout, scroll: scroll)
                    .padding(.leading, titleLeading)
                    .frame(height: max(1, panelTop == nil ? topInset : (headerBand ?? topInset)), alignment: .leading)
                    .offset(y: -lift)
            }
        }
    }

    /// The reader's Pinned Channels heading, which is no category on the server.
    private func isPinnedSection(_ category: SidebarCategory) -> Bool {
        category.id == AppModel.pinnedChannelsCategoryID
    }

    @ViewBuilder
    private func row(_ row: SidebarRow) -> some View {
        switch row {
        case .guildAction(let surface):
            SidebarActionRow(
                symbolName: surface.symbolName,
                title: surface.title,
                isSelected: target == .surface(surface)
            )
            .tag(SidebarTarget.surface(surface))
        case .messageRequests(let pending):
            SidebarActionRow(
                symbolName: "envelope.fill",
                title: "Message Requests",
                count: pending,
                isSelected: target == .messageRequests
            )
            .tag(SidebarTarget.messageRequests)
        case .friends(let pending):
            SidebarActionRow(
                symbolName: "person.2.fill",
                title: "Friends",
                count: pending,
                isSelected: target == .friends
            )
            .tag(SidebarTarget.friends)
        case .pinnedGrid(let channels):
            // Its tiles select by themselves; the row is never the list's.
            PinnedConversationsGrid(
                channels: channels,
                selectedID: { if case .channel(let id) = target { return id }; return nil }(),
                select: { selectChannel($0) },
                openMenu: { openMenu($0, $1) }
            )
            .selectionDisabled()
        case .guideProgress(let progress):
            SidebarGuideProgressRow(progress: progress) { openSurface(.serverGuide) }
                .selectionDisabled()
        case .boostGoal(let goal):
            // Opens a flyout rather than going anywhere, as the events row
            // opens a panel.
            SidebarBoostGoalRow(goal: goal) { setBoostProgressBar(goal.guildID, $0) }
                .selectionDisabled()
        case .events(let events):
            // Opens a panel rather than going anywhere, so it is a button in
            // the list and never its selection.
            SidebarEventsRowView(row: events) { openEvents(events.guildID, nil) }
                .selectionDisabled()
        case .category(let category):
            // A category only reaches here if it has no section of its own,
            // which the grouping above does not produce. Rendered anyway rather
            // than dropped: a row the model contains and the view silently skips
            // is a channel nobody can reach.
            SidebarCategoryRow(
                category: category,
                toggle: { toggleCategory(category.id) },
                // Pinned Channels is the reader's own section, not a category
                // on the server: no menu of a category, no channel made in it.
                openMenu: { if !isPinnedSection(category) { openMenu(category.id, $0) } },
                createChannel: presentation.header?.canCreateChannels == true && !isPinnedSection(category)
                    ? { createChannel(category.id) }
                    : nil
            )
            .selectionDisabled()
        case .channel(let channel):
            SidebarChannelRow(
                channel: channel,
                isSelected: target == .channel(channel.id),
                guildID: presentation.header?.guildID,
                isConnected: connectedVoiceChannelID == channel.id,
                // Nil for anything that is not a voice channel, which is what
                // removes the accessories from every text row rather than
                // drawing them disabled — §5.5.
                join: channel.kind == .voice || channel.kind == .stage
                    ? { joinVoice(channel.id) }
                    : nil,
                openChat: channel.kind == .voice || channel.kind == .stage
                    ? { openVoiceChat(channel.id) }
                    : nil,
                // A conversation has its menu and a server channel its own
                // (`ChannelOptionsMenu`); the model decides which.
                openMenu: { openMenu(channel.id, $0) }
            )
            // Skipped when nothing it draws changed — see its `==`.
            .equatable()
            .tag(SidebarTarget.channel(channel.id))
        case .thread(let thread):
            SidebarThreadRow(
                thread: thread,
                isSelected: target == .channel(thread.id),
                openMenu: { openMenu(thread.id, $0) }
            )
            .equatable()
            .tag(SidebarTarget.channel(thread.id))
        }
    }

    /// The list's selection, which IS where the reader is.
    ///
    /// Read from the model's target, so a channel opened from anywhere else —
    /// a mention, the quick switcher, a shortcut — is the one the list
    /// highlights. Written by the list, on a click or an arrow key, and routed
    /// to the same act the old rows ran: a thread opens through `openThread`,
    /// whose panel-or-column decision is the store's.
    private var selection: Binding<SidebarTarget?> {
        Binding(
            get: { target == .none ? nil : target },
            set: { chosen in
                guard let chosen, chosen != target else { return }
                switch chosen {
                case .channel(let id):
                    let isThread = presentation.rows.contains { row in
                        if case .thread(let thread) = row { return thread.id == id }
                        return false
                    }
                    if isThread { openThread(id) } else { selectChannel(id) }
                case .surface(let surface):
                    openSurface(surface)
                case .messageRequests:
                    openMessageRequests()
                case .friends:
                    openFriends()
                case .none:
                    break
                }
            }
        )
    }

    /// Reports how much room the chrome takes above this column.
    ///
    /// **It reads the inset WITHOUT ignoring it, and that one modifier is the
    /// defect this file spent six attempts on.** A reader that ignores the safe
    /// area has already been handed the region the inset describes, so there is
    /// nothing left for it to report: measured on a live window, 0.00 from an
    /// ignoring reader against 52.00 from this one, in the same view on the same
    /// frame. With zero in hand the banner was built a toolbar's height short,
    /// its lower lip landed 52 points above where every other number in this
    /// view assumed it was, and the pill — placed correctly against an edge that
    /// was not there — floated in the gap underneath the artwork.
    ///
    /// A `Color.clear` rather than a `GeometryReader`: the reader would add a
    /// layout container and a second pass to answer a question the background's
    /// own proxy already answers.
    ///
    /// The write is wrapped in a transaction with animations disabled: this is a
    /// measured value, it can change during a live resize, and animating on one
    /// makes the banner lurch every time the window is dragged.
    private var chromeInsetProbe: some View {
        Color.clear
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { inset in
                write(inset, into: $topInset)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                write(width, into: $columnWidth)
            }
            .allowsHitTesting(false)
    }

    /// Stores a measured value, guarded and unanimated.
    ///
    /// Guarded because a `@State` write of an equal value still invalidates, and
    /// both of these are read on every layout pass. Unanimated because a
    /// measurement can change mid-resize, and animating on one makes the banner
    /// lurch every time the window is dragged.
    private func write(_ value: CGFloat, into binding: Binding<CGFloat>) {
        guard abs(binding.wrappedValue - value) > 0.5 else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { binding.wrappedValue = value }
    }

    /// The rows, grouped into the list's sections.
    ///
    /// **The presentation stays flat; the grouping happens here.** `INVARIANTS`
    /// rejects a nested sidebar model, and that still holds — a nested *model*
    /// re-materialises whole sections on every rebuild and cannot be diffed
    /// per row. Each row keeps its own stable id, `ForEach` still diffs row by
    /// row, and the grouping adds only the `Section` a category heads.
    private struct Group_: Identifiable {
        var id: UInt64
        /// Nil for the rows above the first category — the guild actions.
        var header: SidebarCategory?
        var rows: [(index: Int, row: SidebarRow)]
    }

    private var groups: [Group_] {
        var result: [Group_] = []
        var loose: [(Int, SidebarRow)] = []
        for (index, row) in visibleRows.enumerated() {
            if case .category(let category) = row {
                if !loose.isEmpty {
                    result.append(Group_(id: 0, header: nil, rows: loose))
                    loose = []
                }
                result.append(Group_(id: category.id.rawValue, header: category, rows: []))
            } else if result.isEmpty || result[result.count - 1].header == nil {
                loose.append((index, row))
            } else {
                result[result.count - 1].rows.append((index, row))
            }
        }
        if !loose.isEmpty { result.append(Group_(id: 0, header: nil, rows: loose)) }
        return result
    }

    /// **The system sidebar list** — DESIGN-NOTES decision 13. The selection
    /// highlight, the row metrics (which follow the sidebar size in System
    /// Settings), the keyboard and VoiceOver are the system's, and nothing
    /// here is glass.
    private var list: some View {
        List(selection: selection) {
            if layout.listReserve > 0 {
                Color.clear
                    .frame(height: layout.listReserve - Self.listTopMargin)
                    .modifier(BannerHover(
                        pointer: bannerPointer,
                        isEnabled: presentation.header?.bannerURL.map(CDN.canAnimate) ?? false
                    ))
                    .selectionDisabled()
                    .accessibilityHidden(true)
            }

            if let liveEvent {
                LiveEventCard(
                    notice: liveEvent,
                    open: { openEvents(liveEvent.guildID, liveEvent.eventID) },
                    join: liveEvent.joinChannelID.map { channelID in
                        { liveEvent.isJoined ? selectChannel(channelID) : joinVoice(channelID) }
                    },
                    dismiss: { dismissLiveEvent(liveEvent.eventID) }
                )
                .selectionDisabled()
                .transition(.materialize)
            }

            ForEach(groups) { group in
                if let category = group.header {
                    Section {
                        ForEach(group.rows, id: \.row.id) { entry in
                            row(entry.row)
                        }
                    } header: {
                        SidebarCategoryRow(
                            category: category,
                            toggle: { toggleCategory(category.id) },
                            openMenu: { if !isPinnedSection(category) { openMenu(category.id, $0) } },
                            createChannel: presentation.header?.canCreateChannels == true && !isPinnedSection(category)
                                ? { createChannel(category.id) }
                                : nil
                        )
                    }
                } else {
                    ForEach(group.rows, id: \.row.id) { entry in
                        row(entry.row)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // One tracking area for every row's hover, behind the list and the
        // size of it; the rows find the router in the environment.
        .environment(\.sidebarHoverRouter, hoverRouter)
        .background { SidebarHoverSurface(router: hoverRouter) }
        // The reader's spacing (Settings › Appearance › Channel list). With a
        // denser setting the system's minimum row height steps aside, so rows
        // can come under it; at the default nothing changes.
        .environment(\.sidebarListSpacing, SidebarListSpacing(
            channel: settings.channelSpacing, category: settings.categorySpacing
        ))
        .environment(
            \.defaultMinListRowHeight,
            settings.channelSpacing < 0 ? 0 : Metrics.sidebarRowContent + Metrics.sidebarRowInset * 2
        )
        // The column's own ground shows through: the theme, the wallpaper's
        // vibrancy, and the banner the list scrolls over.
        .scrollContentBackground(.hidden)
        // Collapsing or expanding a category adds or removes its channels, so
        // the row count is exactly the signal.
        .animation(motion.standard, value: visibleRows.count)
        // One read, carrying the banner and the pill up together.
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            // An equal write still invalidates its readers, and this one fires
            // on every scroll tick.
            if abs(scroll.travel - offset) > 0.5 { scroll.travel = offset }
        }
        // **Top only.** The now bar is glass floating over the list's foot,
        // and a scroll edge effect under it blurs the rows before the capsule
        // can refract them — see `softScrollEdgeTopOnly`.
        .softScrollEdgeTopOnly()
        // The rows pass under the bars and the last one rests above them —
        // `sidebarBarsInset`.
        .safeAreaPadding(.bottom, barsInset)
    }

    /// The space a sidebar list leaves above its first row, which the banner's
    /// reserve already accounts for. Measured on the macOS 27 SDK, 2026-10-05.
    private static let listTopMargin: CGFloat = 10
}

/// How far the channel list has been scrolled: zero at rest, positive downward.
///
/// **An object the moving parts read, not state on the sidebar.** Held as the
/// sidebar's `@State`, every scroll tick re-ran the sidebar's whole body — the
/// grouping walk, the list, and every visible row, whose closures cannot be
/// compared — to move three things: the banner, the pill on it, and the name in
/// the toolbar. Measured on the demo server, forty ticks of scroll ran the
/// sidebar forty times and its rows three hundred and twenty. Read here, only
/// the three views that move are invalidated.
///
/// Read once from the scroll view's own geometry rather than inferred from a
/// reader inside the content, which would measure the content's frame.
@Observable
private final class SidebarScroll {
    var travel: CGFloat = 0
}

extension SidebarBannerLayout {
    /// The same layout, carried up by the list's scroll.
    fileprivate func travelled(_ scroll: SidebarScroll) -> SidebarBannerLayout {
        var layout = self
        layout.travel = max(0, scroll.travel)
        return layout
    }
}

/// Whether the pointer is over the banner.
///
/// **An object the banner reads, for `SidebarScroll`'s reason**: held as the
/// sidebar's own state, every crossing of the banner's edge would re-run the
/// whole channel list to change one picture.
@Observable
private final class SidebarBannerPointer {
    var isOver = false
}

/// The pointer, over the banner.
///
/// **On the list's own reserve, not on the banner.** The banner is a layer
/// behind the list and takes no events; the clear band the list reserves for
/// it sits exactly over it and scrolls with it — Discord's own arrangement, an
/// overlay the banner's height listening for the pointer.
///
/// **Installed only where there is a film to play** — `INVARIANTS.md` §2, guard
/// the modifier, not the closure: a tracking area on a band that scrolls is
/// re-derived on every frame of every scroll.
private struct BannerHover: ViewModifier {
    var pointer: SidebarBannerPointer
    var isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .contentShape(.rect)
                .onHover { hovering in
                    guard pointer.isOver != hovering else { return }
                    pointer.isOver = hovering
                }
                // A band removed under the pointer gets no exit, and a latch
                // left set is a banner that never stops.
                .onDisappear { pointer.isOver = false }
        } else {
            content
        }
    }
}

/// The banner, riding the scroll. See `SidebarScroll`.
private struct TravellingBanner: View {
    var header: SidebarHeader
    var layout: SidebarBannerLayout
    var scroll: SidebarScroll
    var pointer: SidebarBannerPointer

    /// The five seconds of motion a banner gets when it comes into view.
    @State private var isArriving = false
    /// The reader's battery switch. Discord gates the arrival on its GIF
    /// autoplay and lets the pointer play the banner either way.
    @State private var settings = AppSettings.shared

    /// What restarts the arrival: another server's banner, or this one coming
    /// back into view after the list scrolled it away.
    private struct Arrival: Equatable {
        var url: URL?
        var isInView: Bool
    }

    var body: some View {
        let travelled = layout.travelled(scroll)
        SidebarBanner(header: header, layout: travelled, animates: isArriving || pointer.isOver)
            .task(id: Arrival(url: header.bannerURL, isInView: travelled.isBannerInView)) {
                // Cleared before the wait, so a banner scrolled away mid-arrival
                // stops at once rather than when a stale task notices.
                isArriving = false
                guard travelled.isBannerInView,
                      settings.playsAnimatedContent,
                      let url = header.bannerURL, CDN.canAnimate(url)
                else { return }
                isArriving = true
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                isArriving = false
            }
    }
}

/// The name on the banner's lower lip, riding the scroll with it.
private struct TravellingPill: View {
    var header: SidebarHeader
    var layout: SidebarBannerLayout
    var scroll: SidebarScroll

    var body: some View {
        let layout = layout.travelled(scroll)
        ServerNamePill(
            name: header.name,
            guildID: header.guildID,
            mark: header.mark,
            // The toolbar title answers the menu bar once it has the name.
            answersMenuBar: !layout.showsToolbarTitle
        )
            // The same margin both sides, inside the banner's own inset.
            .padding(.leading, SidebarBannerLayout.pillLeading)
            .padding(.trailing, SidebarBannerLayout.pillLeading)
            .offset(y: layout.pillTop)
            .opacity(layout.pillOpacity)
            // A pill faded to nothing must not still be taking clicks out of
            // the strip it has slid into.
            .allowsHitTesting(layout.pillOpacity > 0)
    }
}

/// The name in the toolbar, once the pill has ridden off the banner.
private struct TravellingToolbarTitle: View {
    var header: SidebarHeader
    var layout: SidebarBannerLayout
    var scroll: SidebarScroll

    var body: some View {
        if layout.travelled(scroll).showsToolbarTitle {
            ServerTitleItem(
                name: header.name,
                maxWidth: layout.toolbarTitleWidth,
                // Nil for the direct-message home, which is a destination
                // rather than a server: there is nothing to invite anyone to,
                // nothing to configure, and nothing to leave.
                guildID: header.guildID,
                mark: header.mark
            )
            .equatable()
        }
    }
}

/// The server's name, floating on the banner's lower lip.
///
/// Sized down from a standalone floating control: at full size with a headline
/// inside, the name reads as a page title with a whole navigation bar's weight
/// behind it, on a column that already has the rail and the now bar competing
/// for attention.
///
/// **The pill hugs its label — its width IS the text's width**, so "Lumen Club"
/// and "Pixel Forge | Mods, Tools and more" are visibly different objects rather
/// than the same slab with different contents. `.fixedSize()` before the glass
/// is what does it: the material has to be applied to the final hugged geometry,
/// and a `.frame(maxWidth:)` anywhere above it defeats the whole effect.
///
/// Switching servers **animates that width** rather than snapping it. The name
/// is the animation's value, so the capsule reflows to the new label and the
/// glass morphs with it; without the value the two names cut, and a capsule that
/// changes size instantaneously reads as two different controls rather than as
/// one control being re-labelled.
///
/// **One material and one branch fewer than it used to carry.** This view exists
/// only where there is artwork under it — a banner is what it sits on, and the
/// only server without a menu is the direct-message home, which has no banner —
/// so the ground behind it is never in question. The pair of ink styles, the
/// four-way material modifier and the optional target all described states this
/// pill cannot be in; `ServerTitleItem` covers the ones it cannot reach.
private struct ServerNamePill: View {
    var name: String
    var guildID: GuildID?
    /// Discord's mark, before the name — see `GuildMark`.
    var mark: GuildMark?
    /// Whether a menu-bar command's page request is this pill's to open —
    /// `ServerMenuPageRequest`.
    var answersMenuBar: Bool

    @Environment(\.motion) private var motion

    @State private var isMenuOpen = false
    @State private var page = ServerMenuPage()
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Spacing.base) {
            Button {
                page = ServerMenuPage()
                isMenuOpen = true
            } label: {
                label
            }
            .buttonStyle(.plain)
            // **No `.fixedSize()`**: hugging the whole name ran a long one past
            // the banner's edge (Alex, 2026-11-18). The button takes what the
            // row has before the spacer does, and the name truncates in it.
            .layoutPriority(1)
            .onHover { isHovered = $0 }
            .animation(motion.hover, value: isHovered)
            // The whole name, for when the banner had to cut it short.
            .help(name)
            .accessibilityLabel(Text(name))
            .accessibilityHint("Server options")
            // **Inline, because this is one view rather than a list row.** §2
            // forbids a presentation on a *row*, where the modifier is paid for
            // by every one of a hundred; the name pill is drawn once per
            // sidebar and this is the only place that can point a popover at
            // the control that opened it.
            .popover(isPresented: $isMenuOpen, arrowEdge: .bottom) {
                if let guildID {
                    ServerOptionsMenu(
                        guildID: guildID,
                        startsOn: page.surface,
                        inviteChannelID: page.inviteChannelID,
                        close: { isMenuOpen = false }
                    )
                    .presentationBackground(.clear)
                }
            }
            .modifier(ServerMenuRequestAnswer(
                guildID: guildID, answers: answersMenuBar, page: $page, isMenuOpen: $isMenuOpen
            ))

            // The spacer keeps the pill leading-aligned instead of centring
            // itself across the column, and it is also what stops the overlay
            // swallowing scroll: a spacer has no hit region.
            Spacer(minLength: Spacing.base)
        }
    }

    /// **Written on the picture, not on a pill** (Alex, 2026-11-18): white
    /// and bold with a soft shadow, as a name over artwork is set — fixed
    /// white rather than the ink hierarchy, because it composites against a
    /// picture nobody chose. A soft dark glow behind it keeps it readable
    /// where the artwork is bright or has already faded into a light panel,
    /// and a faint plate under the pointer says it is a button.
    private var label: some View {
        HStack(spacing: Spacing.tight) {
            if let mark {
                GuildMarkBadge(mark: mark)
                    .padding(.trailing, Spacing.hair)
            }
            Text(name)
                .font(.system(.headline, weight: .bold))
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.down")
                .font(.system(.caption, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.85))
        }
        .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
        .padding(.horizontal, Spacing.snug)
        .frame(minHeight: Metrics.control)
        .background {
            Capsule().fill(Color.white.opacity(isHovered ? 0.16 : 0))
        }
        .background {
            Capsule()
                .fill(Color.black.opacity(0.3))
                .blur(radius: 12)
                .allowsHitTesting(false)
        }
        .contentShape(.capsule)
    }
}

/// The server's name in the panel's header, level with the sidebar toggle, for
/// every moment the banner is not carrying it.
///
/// **The header's own capsule, drawn here.** This used to be a toolbar item,
/// and the toolbar drew its platter; the header is the app's own now
/// (REDESIGN.md R2), and a `Button` left to the default style there came out
/// as AppKit's grey push-button bezel. So it is the detail header's title
/// capsule — `.regular` glass at the header control's height — carrying the
/// banner pill's label: the server's mark, its name and a chevron. When the
/// name changes the capsule's width springs with it (`glassMorph`), the morph
/// the banner pill has always had.
///
/// The direct-message home has nothing to open, so its name is a heading, not
/// a capsule.
private struct ServerTitleItem: View, Equatable {
    var name: String
    /// The widest the capsule may draw — `SidebarBannerLayout.toolbarTitleWidth`,
    /// what the header leaves between the lights and its own controls.
    var maxWidth: CGFloat
    /// Whose menu it opens. **Nil is the direct-message home**, which is a
    /// destination and not a server: it has no invite, no settings and nothing
    /// to leave.
    var guildID: GuildID?
    /// Discord's mark, before the name — see `GuildMark`.
    var mark: GuildMark?

    @Environment(\.motion) private var motion

    /// The sidebar's body runs on every scroll tick; name, width, server and
    /// mark are the only things that change what this draws.
    static func == (lhs: ServerTitleItem, rhs: ServerTitleItem) -> Bool {
        lhs.name == rhs.name
            && lhs.maxWidth == rhs.maxWidth
            && lhs.guildID == rhs.guildID
            && lhs.mark == rhs.mark
    }

    @State private var isMenuOpen = false
    @State private var page = ServerMenuPage()

    var body: some View {
        Group {
            if let guildID {
                Button {
                    page = ServerMenuPage()
                    isMenuOpen = true
                } label: {
                    label(opensMenu: true)
                }
                // `.plain`, then the glass: the default style is AppKit's
                // push-button bezel, and glass over it is glass on a slab.
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .accessibilityHint("Server options")
                .popover(isPresented: $isMenuOpen, arrowEdge: .bottom) {
                    ServerOptionsMenu(
                        guildID: guildID,
                        startsOn: page.surface,
                        inviteChannelID: page.inviteChannelID,
                        close: { isMenuOpen = false }
                    )
                    .presentationBackground(.clear)
                }
                // It exists only while it has the name, so it always answers.
                .modifier(ServerMenuRequestAnswer(
                    guildID: guildID, answers: true, page: $page, isMenuOpen: $isMenuOpen
                ))
            } else {
                label(opensMenu: false)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        // A cap, not a size: the capsule hugs a short name, and a long one
        // truncates before it reaches the toggle.
        .frame(maxWidth: maxWidth, alignment: .leading)
        .animation(motion.glassMorph, value: name)
        .help(name)
        .accessibilityLabel(Text(name))
    }

    /// Whether the server's mark is drawn. **It goes before the name is cut**
    /// (#17): the mark repeats what the rail already says, the name is the
    /// only thing that says which server this is.
    private var showsMark: Bool {
        mark != nil && maxWidth >= Self.roomForMark
    }

    /// The width under which the mark gives its room to the name.
    private static let roomForMark: CGFloat = 170

    /// The banner pill's label, at the header's size.
    private func label(opensMenu: Bool) -> some View {
        HStack(spacing: Spacing.tight) {
            if let mark, showsMark {
                GuildMarkBadge(mark: mark, side: Self.markSide)
                    .padding(.trailing, Spacing.hair)
            }
            Text(name)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.interpolate)
            if opensMenu {
                Image(systemName: "chevron.down")
                    .font(.system(.caption2, weight: .bold))
                    .foregroundStyle(InkColor.secondary)
            }
        }
        // The capsule's ends are half its height away; a heading has none.
        .padding(.leading, opensMenu ? (showsMark ? 10 : 14) : 0)
        .padding(.trailing, opensMenu ? 12 : 0)
        .frame(height: ShellMetrics.headerControl)
        .contentShape(.capsule)
    }

    private static let markSide: CGFloat = 18
}

/// The server's own menu, under the name.
///

// MARK: - The menu bar's asks of the server's name

/// Which page the server menu opens on, and the channel an invite is for: the
/// root from a click, whatever a menu-bar command asked for otherwise.
private struct ServerMenuPage {
    var surface: ServerOptionsMenu.Surface = .root
    var inviteChannelID: ChannelID?
}

/// Opens a server-name control's own menu on the page a menu-bar command asked
/// for — `ServerMenuPageRequest` — when the request is this control's: its
/// server, and it is the one showing the name.
private struct ServerMenuRequestAnswer: ViewModifier {
    var guildID: GuildID?
    var answers: Bool
    @Binding var page: ServerMenuPage
    @Binding var isMenuOpen: Bool

    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.onChange(of: model.serverMenuPageRequest) { _, request in
            guard answers, let request, request.guildID == guildID else { return }
            model.serverMenuPageRequest = nil
            page = ServerMenuPage(surface: request.page, inviteChannelID: request.inviteChannelID)
            isMenuOpen = true
        }
    }
}

// MARK: - Pinned conversations

/// The pinned conversations as Messages pins them: faces in a grid over the
/// list (REDESIGN.md R9). A face is the conversation — a click opens it, a
/// secondary click its menu, where Unpin is.
private struct PinnedConversationsGrid: View {
    var channels: [SidebarChannel]
    var selectedID: ChannelID?
    var select: (ChannelID) -> Void
    var openMenu: (ChannelID, CGRect) -> Void

    var body: some View {
        // **Each row centred** (Alex, 2026-11-17), as Messages lays out its
        // pins: two faces sit in the middle of the list, not at its left.
        CenteredTileGrid(minimumWidth: 76, maximumWidth: 110, spacing: Spacing.tight, lineSpacing: Spacing.base) {
            ForEach(channels) { channel in
                PinnedConversationTile(
                    channel: channel,
                    isSelected: channel.id == selectedID,
                    select: { select(channel.id) },
                    openMenu: { openMenu(channel.id, $0) }
                )
            }
        }
        .padding(.vertical, Spacing.tight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Pinned conversations"))
    }
}

private struct PinnedConversationTile: View {
    var channel: SidebarChannel
    var isSelected: Bool
    var select: () -> Void
    var openMenu: (CGRect) -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    static let face: CGFloat = 52

    var body: some View {
        Button(action: select) {
            VStack(spacing: 5) {
                AvatarView(url: channel.avatarURL, monogram: channel.monogram ?? "?", side: Self.face)
                    .overlay {
                        // The open conversation wears a ring, as a selected
                        // row wears its highlight — in bright ink, never the
                        // accent, like the rows' own lift.
                        Circle()
                            .strokeBorder(Ink.primary, lineWidth: isSelected ? 2.5 : 0)
                            .padding(-4)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let status = channel.status {
                            if channel.isTyping {
                                TypingPill(tint: status.tint, height: 14).offset(x: 4, y: 2)
                            } else {
                                PresenceDot(status: status, side: 14).offset(x: 1, y: 1)
                            }
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if channel.mentionCount > 0 {
                            Text(channel.mentionCount > 99 ? "99+" : "\(channel.mentionCount)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(Capsule().fill(Palette.unreadBadge))
                                .offset(x: 4, y: -2)
                        }
                    }
                    .scaleEffect(isHovering ? 1.04 : 1)
                Text(channel.name)
                    .font(.system(.subheadline, weight: channel.isUnread ? .semibold : .medium))
                    .foregroundStyle(channel.isUnread || isSelected ? Ink.primary : Ink.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onSecondaryClick(perform: openMenu)
        .onHover { isHovering = $0 }
        .animation(motion.hover, value: isHovering)
        .help(channel.name)
        .accessibilityLabel(Text(channel.name + (channel.isUnread ? ", unread" : "")))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
