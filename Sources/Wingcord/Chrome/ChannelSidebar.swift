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
    /// The events panel — on its list, or on one event.
    var openEvents: (GuildID, UInt64?) -> Void = { _, _ in }
    var dismissLiveEvent: (UInt64) -> Void = { _ in }
    /// A secondary click on a conversation, with the row's own rect. Only the
    /// direct-message list passes one — see `SidebarChannelRow.openMenu`.
    var openMenu: (ChannelID, CGRect) -> Void = { _, _ in }
    /// Create Channel inside a category — its "+".
    var createChannel: (ChannelID) -> Void = { _ in }

    @Environment(\.motion) private var motion
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
    /// How wide this column is. Measured for one reason only: an over-wide
    /// toolbar item is dropped rather than truncated, so the title has to know
    /// what it may occupy. See `SidebarBannerLayout.toolbarTitleWidth`.
    @State private var columnWidth: CGFloat = 0

    private var hasBanner: Bool { presentation.header?.hasBanner ?? false }

    /// Everything positioned against the banner, at rest. See
    /// `SidebarBannerLayout` for the arithmetic and for the one measurement it
    /// rests on; the views that move with the list add the travel themselves.
    ///
    /// Recomputed rather than stored: it is four `CGFloat`s over values already
    /// in hand, and a stored copy is a copy that can be stale — which is exactly
    /// how an earlier version parked the pill at the *previous* server's banner
    /// height on a server that had none.
    private var layout: SidebarBannerLayout {
        SidebarBannerLayout(hasBanner: hasBanner, chromeInset: topInset, columnWidth: columnWidth)
    }

    var body: some View {
        ZStack(alignment: .top) {
            if hasBanner, let header = presentation.header {
                TravellingBanner(header: header, layout: layout, scroll: scroll, pointer: bannerPointer)
                    // Up to the window's top edge, under the toolbar, so the
                    // sidebar toggle sits on the artwork instead of on a bare
                    // strip above it. It is also what makes the banner's frame
                    // start at `-topInset`, which is the placement every other
                    // number here is measured against.
                    .ignoresSafeArea(.container, edges: .top)
            }
            list
        }
        .background(alignment: .top) { chromeInsetProbe }
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
        // The other half of the name, and the half that is REACHABLE — see
        // `showsToolbarTitle` for why the parked pill could not be.
        //
        // Placement is `.automatic`, not `.navigation`: measured on a live
        // window, `.navigation` lands the item at x=376, AFTER the split view's
        // sidebar toggle and out over the detail column. `.automatic` lands it
        // at x=96, in the sidebar's own span of the bar — the gap between the
        // traffic lights and the toggle that is otherwise flexible space — and
        // at y=830..866, which is the toggle's own row to the point.
        //
        // Declared here rather than beside the rest of the chrome because the
        // scroll position that decides it is this view's own. Routing it
        // through the store instead would publish a write on every scroll tick
        // to every surface observing it.
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if let header = presentation.header {
                    TravellingToolbarTitle(header: header, layout: layout, scroll: scroll)
                }
            }
            // **A title, not a pill.** The bar's shared glass platter made
            // "Direct Messages" and the server's name read as a capsule over
            // the list; the column's title is plain text, the way a sidebar
            // heads itself.
            .sharedBackgroundVisibility(.hidden)
            // Pushes the title to the LEADING edge of the sidebar's span.
            // Without it the section right-aligns against the toggle and the
            // name lands at x=196 — a hundred points right of where the
            // floating pill just faded out, so the hand-off reads as a jump
            // rather than as one name staying put while its material changes.
            // With it, x=96 against the resting pill's 88.
            ToolbarSpacer(.flexible)
        }
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
                openMenu: { openMenu(category.id, $0) },
                createChannel: presentation.header?.canCreateChannels == true
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
            .tag(SidebarTarget.channel(channel.id))
        case .thread(let thread):
            SidebarThreadRow(
                thread: thread,
                isSelected: target == .channel(thread.id),
                openMenu: { openMenu(thread.id, $0) }
            )
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
        for (index, row) in presentation.rows.enumerated() {
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
                            openMenu: { openMenu(category.id, $0) },
                            createChannel: presentation.header?.canCreateChannels == true
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
        // The column's own ground shows through: the theme, the wallpaper's
        // vibrancy, and the banner the list scrolls over.
        .scrollContentBackground(.hidden)
        // Collapsing or expanding a category adds or removes its channels, so
        // the row count is exactly the signal.
        .animation(motion.standard, value: presentation.rows.count)
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
            .padding(.leading, SidebarBannerLayout.pillLeading)
            .padding(.trailing, Spacing.snug)
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
/// and "Krxqz | Cfgs, Clients and more" are visibly different objects rather
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

    var body: some View {
        HStack(spacing: Spacing.base) {
            Button {
                page = ServerMenuPage()
                isMenuOpen = true
            } label: {
                label
            }
            // `.plain` + a content shape, THEN the glass. The borderless style
            // with `.fixedSize` collapses the label frame on this platform.
            .buttonStyle(.plain)
            // Hugs the label. Everything above this in the chain must leave the
            // width alone.
            .fixedSize()
            .interactiveChromeOverMedia()
            .animation(motion.glassMorph, value: name)
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

    /// Fixed ink rather than the vibrant hierarchy: this label composites
    /// against a picture nobody chose, where a hierarchical style resolves to
    /// whatever the artwork happens to be and stops being readable.
    private var label: some View {
        HStack(spacing: Spacing.tight) {
            if let mark {
                GuildMarkBadge(mark: mark)
                    .padding(.trailing, Spacing.hair)
            }
            Text(name)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(.caption2, weight: .bold))
                .foregroundStyle(InkColor.secondary)
        }
        .padding(.horizontal, Spacing.snug)
        .frame(minHeight: Metrics.control)
        .contentShape(.capsule)
    }
}

/// The server's name in the toolbar, level with the sidebar toggle, for every
/// moment the banner is not carrying it.
///
/// **It draws no glass and sets no size**, for the same reason `ChannelPill`
/// does not: a `ToolbarItem` on macOS 27 already arrives with the system's
/// material at the system's size, and a second one inside it is the
/// capsule-inside-a-platter that `INVARIANTS.md` §4 rule 2 forbids.
///
/// It is also the only version of the name that can be *pressed* up there.
/// Measured on a live window, the top 32 points belong to `NSTitlebarView` — a
/// sibling above the hosting view, which takes the mouse first — so a capsule
/// drawn level with the toggle would be visible, unclickable, and would drag
/// the window when pressed. A toolbar item is level with the toggle by
/// construction and reachable by definition.
private struct ServerTitleItem: View, Equatable {
    var name: String
    /// The widest the label may draw. See `SidebarBannerLayout.toolbarTitleWidth`
    /// — over the span, the toolbar drops the item rather than truncating it.
    var maxWidth: CGFloat
    /// Whose menu the chevron opens. **Nil is the direct-message home**, which
    /// is a destination and not a server: it has no invite, no settings and
    /// nothing to leave, and a menu offering all three is three commands that
    /// cannot mean anything. Without it this is a label rather than a control.
    var guildID: GuildID?
    /// Discord's mark, before the name — see `GuildMark`.
    var mark: GuildMark?

    @Environment(\.motion) private var motion

    /// The sidebar's body runs on **every scroll tick**, so without a place to
    /// stop, the label below would be re-measured on each one. Name and width
    /// are the only things that can change what this draws; the closure is
    /// recreated on every parent evaluation and is deliberately excluded, which
    /// is the same trade `ChannelSidebar` itself makes.
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
                } label: { title }
                    .accessibilityHint("Server options")
                    // **A real toolbar item is the one place a presentation may
                    // be inline** — `INVARIANTS.md` §1. It is one item evaluated
                    // once, and the alternative is a window-root presenter
                    // anchored to a rect the toolbar cannot report.
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
                title.accessibilityAddTraits(.isHeader)
            }
        }
        // Switching servers reflows the label rather than cutting between two
        // of them, and the system's material morphs along with the width.
        .animation(motion.glassMorph, value: name)
        .help(name)
        .accessibilityLabel(Text(name))
    }

    /// The label, sized by the toolbar wherever it can be.
    ///
    /// **A cap is imposed only on a name that needs one.** The `.frame(width:)`
    /// below exists for exactly one reason — an over-wide toolbar item is
    /// *dropped* rather than truncated, and the neighbouring controls slide into
    /// the hole — so a name that already fits the sidebar's span has nothing to
    /// be saved from, and giving it a hand-measured frame anyway is how the
    /// platter came to sit a couple of points off its own text.
    ///
    /// The measurement and SwiftUI's own layout are two different text stacks
    /// and they do not have to agree to a point. Where the cap is not needed,
    /// they are not asked to: the item is sized the way `ChannelPill` is, by the
    /// bar, which is the arrangement that has always looked right.
    ///
    /// **A width, not a maxWidth**, in the case that does need it. The bar sizes
    /// its items against an unspecified proposal, where a maximum is advisory
    /// and the label still reports its full ideal — measured, `maxWidth` left a
    /// 35-character name being dropped exactly as before, while a width drew it
    /// at 104.5 and put the toggle back at x=324.
    /// How much breathing room a **bare label** needs inside its platter.
    ///
    /// **A toolbar platter hugs a `Text` far more tightly than it hugs a
    /// control's label**, and this item is the only bare one in the app: on a
    /// server it is a `Menu`, which arrives with the system's own control
    /// insets, and on the direct-message home there is nothing to open so it is
    /// a label. The two therefore came out visibly different — the DM title sat
    /// with its first and last letters almost touching the ends of its capsule
    /// while every other item in the bar breathed.
    ///
    /// Six points a side, which is the difference measured against the `Menu`
    /// beside it. It is *not* a hand-set control size — `INVARIANTS.md` §1
    /// forbids that and means it — it is padding on a piece of text the bar has
    /// declined to treat as a control.
    private static let bareLabelInset: CGFloat = 6

    /// What the label's own frame may occupy, once its padding is taken out.
    ///
    /// The cap exists to stop the bar DROPPING an over-wide item, so the padding
    /// has to come out of it rather than be added on top — otherwise the fix for
    /// a cramped short name is what makes a long one disappear.
    private var labelWidthCap: CGFloat {
        let cap = guildID == nil ? max(20, maxWidth - Self.bareLabelInset * 2) : maxWidth
        // The mark rides in front of the name and is never the part that gives.
        return max(20, cap - markWidth)
    }

    /// The mark and its gap, which come out of the name's allowance.
    private var markWidth: CGFloat {
        mark == nil ? 0 : Self.markSide + Self.markGap
    }

    private static let markSide: CGFloat = 18
    private static let markGap = Spacing.tight + Spacing.hair

    @ViewBuilder
    private var title: some View {
        let label = Text(name)
            .fontWeight(.semibold)
            .lineLimit(1)
            .truncationMode(.tail)
            .contentTransition(.interpolate)

        HStack(spacing: Self.markGap) {
            if let mark {
                GuildMarkBadge(mark: mark, side: Self.markSide)
            }
            if naturalWidth > labelWidthCap {
                label.frame(width: labelWidthCap, alignment: .leading)
            } else {
                label
            }
        }
        .padding(.horizontal, guildID == nil ? Self.bareLabelInset : 0)
    }

    /// What the label would take if nothing stopped it.
    ///
    /// Measured through AppKit rather than asked of SwiftUI: a hidden `Text` and
    /// an `onGeometryChange` would answer the same question a layout pass later
    /// and write it into state that the next server invalidates.
    ///
    /// **The font has to be the one SwiftUI will actually draw.** `Text` in a
    /// toolbar resolves to the body text style, which tracks the reader's text
    /// size — so measuring against a fixed `systemFontSize` is right only at the
    /// default and progressively wrong above and below it, which is a cap that
    /// truncates a name that fits or drops one that would have.
    ///
    /// Rounded up with a point of slack, so a name near the cap is never
    /// truncated by a rounding difference between the two stacks.
    private var naturalWidth: CGFloat {
        let body = NSFont.preferredFont(forTextStyle: .body)
        let font = NSFontManager.shared.convert(body, toHaveTrait: .boldFontMask)
        return ceil((name as NSString).size(withAttributes: [.font: font]).width) + 1
    }
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
