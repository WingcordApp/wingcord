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

    static func == (lhs: ChannelSidebar, rhs: ChannelSidebar) -> Bool {
        lhs.presentation == rhs.presentation
            && lhs.target == rhs.target
            && lhs.connectedVoiceChannelID == rhs.connectedVoiceChannelID
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
    /// A secondary click on a conversation, with the row's own rect. Only the
    /// direct-message list passes one — see `SidebarChannelRow.openMenu`.
    var openMenu: (ChannelID, CGRect) -> Void = { _, _ in }

    @Environment(\.motion) private var motion
    /// Shared namespace so the selection pill *flows* from row to row rather
    /// than fading in at the new position.
    @Namespace private var selectionNamespace
    /// How far the list has been scrolled: zero at rest, positive downward.
    ///
    /// Read once from the scroll view's own geometry rather than inferred from a
    /// reader inside the content — a reader in there measures the *content's*
    /// frame, which the stretchy banner is already deforming.
    @State private var scrollOffset: CGFloat = 0
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

    /// Everything positioned against the banner, from the four numbers that
    /// decide it. See `SidebarBannerLayout` for the arithmetic and for the one
    /// measurement it rests on.
    ///
    /// Recomputed rather than stored: it is four `CGFloat`s over values already
    /// in hand, and a stored copy is a copy that can be stale — which is exactly
    /// how an earlier version parked the pill at the *previous* server's banner
    /// height on a server that had none.
    private var layout: SidebarBannerLayout {
        SidebarBannerLayout(
            hasBanner: hasBanner,
            chromeInset: topInset,
            travel: max(0, scrollOffset),
            columnWidth: columnWidth
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            if hasBanner, let header = presentation.header {
                SidebarBanner(header: header, layout: layout)
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
                ServerNamePill(name: header.name, guildID: header.guildID)
                    .padding(.leading, SidebarBannerLayout.pillLeading)
                    .padding(.trailing, Spacing.snug)
                    .offset(y: layout.pillTop)
                    .opacity(layout.pillOpacity)
                    // A pill faded to nothing must not still be taking clicks
                    // out of the strip it has slid into.
                    .allowsHitTesting(layout.pillOpacity > 0)
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
        // scroll position that decides it is this view's own `@State`. Routing
        // it through the store instead would publish a write on every scroll
        // tick to every surface observing it.
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if layout.showsToolbarTitle, let header = presentation.header {
                    ServerTitleItem(
                        name: header.name,
                        maxWidth: layout.toolbarTitleWidth,
                        // Nil for the direct-message home, which is a
                        // destination rather than a server: there is nothing to
                        // invite anyone to, nothing to configure, and nothing
                        // to leave.
                        guildID: header.guildID
                    )
                    .equatable()
                }
            }
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
                surface: surface,
                isSelected: target == .surface(surface),
                namespace: selectionNamespace,
                action: { openSurface(surface) }
            )
        case .category(let category):
            // A category only reaches here if it has no section of its own,
            // which the grouping above does not produce. Rendered anyway rather
            // than dropped: a row the model contains and the view silently skips
            // is a channel nobody can reach.
            SidebarCategoryRow(category: category, toggle: { toggleCategory(category.id) })
        case .channel(let channel):
            SidebarChannelRow(
                channel: channel,
                isSelected: target == .channel(channel.id),
                guildID: presentation.header?.guildID,
                isConnected: connectedVoiceChannelID == channel.id,
                namespace: selectionNamespace,
                action: { selectChannel(channel.id) },
                // Nil for anything that is not a voice channel, which is what
                // removes the accessories from every text row rather than
                // drawing them disabled — §5.5.
                join: channel.kind == .voice || channel.kind == .stage
                    ? { joinVoice(channel.id) }
                    : nil,
                openChat: channel.kind == .voice || channel.kind == .stage
                    ? { openVoiceChat(channel.id) }
                    : nil,
                // A conversation has a menu; a server's channel does not, and
                // handing it nil is what keeps the catcher out of a
                // hundred-row list.
                openMenu: channel.isPerson ? { openMenu(channel.id, $0) } : nil
            )
        case .thread(let thread):
            SidebarThreadRow(
                thread: thread,
                isSelected: target == .channel(thread.id),
                namespace: selectionNamespace,
                action: { openThread(thread.id) }
            )
        }
    }

    /// How a row arrives when the whole list is replaced.
    ///
    /// The list unfolds from the top rather than appearing all at once: each row
    /// drops a few points into place a beat after the one above it, which reads
    /// as one list settling instead of as a hard cut between two servers.
    ///
    /// **The stagger is capped.** Left proportional to the index, a fifty-row
    /// server would still be arriving a second after the click — and past
    /// roughly 200ms a response animation stops reading as motion and starts
    /// reading as latency. Ten steps of 18ms is the whole budget; every row
    /// below the tenth arrives with it.
    ///
    /// Reduce Motion is handled by `motion.panel` itself, which drops the travel
    /// and leaves the fade — so the cascade degrades to a plain cross-fade
    /// rather than having to be branched around here.
    private func rowEntrance(at index: Int) -> AnyTransition {
        let delay = Double(min(index, 10)) * 0.018
        return .asymmetric(
            insertion: .move(edge: .top)
                .combined(with: .opacity)
                .animation(motion.panel.delay(delay)),
            // The outgoing list must not linger under the incoming one — two
            // channel lists overlapping mid-swap is the one thing that would
            // make this read as a glitch rather than as a transition.
            removal: .opacity.animation(motion.fadeQuick)
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

    /// The rows, grouped for pinning.
    ///
    /// **The presentation stays flat; the grouping happens here.** `INVARIANTS`
    /// rejects a nested sidebar model, and that still holds — a nested *model*
    /// re-materialises whole sections on every rebuild and cannot be diffed
    /// per row. What it was protecting against is not this: each row keeps its
    /// own stable id, `ForEach` still diffs row by row, and the only thing the
    /// grouping adds is a `Section` boundary for `pinnedViews` to hold on to.
    ///
    /// That boundary is the entire reason a category heading can stay under the
    /// server pill while its channels scroll past it, which is not expressible
    /// over a flat `LazyVStack` at all.
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

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 1, pinnedViews: [.sectionHeaders]) {
                if layout.listReserve > 0 {
                    Color.clear
                        .frame(height: layout.listReserve)
                        .accessibilityHidden(true)
                }

                ForEach(groups) { group in
                    Section {
                        ForEach(group.rows, id: \.row.id) { entry in
                            row(entry.row)
                                .transition(rowEntrance(at: entry.index))
                        }
                    } header: {
                        if let category = group.header {
                            SidebarCategoryRow(
                                category: category,
                                toggle: { toggleCategory(category.id) }
                            )
                            // The header travels with the list until it reaches
                            // the top, then stays — so it needs a ground of its
                            // own, or the channels it is pinned over scroll
                            // through it. The pill's glass is that ground; the
                            // padding is what stops the row beneath touching it.
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.base)
            .padding(.bottom, Spacing.base)
        }
        // Switching servers replaces every row id at once, so every row is an
        // INSERTION and the transitions above fire together. Declared here, on
        // the container, rather than by wrapping the change in `withAnimation`:
        // a global transaction animates every view in the window that happens to
        // re-lay-out while it runs.
        .animation(motion.panel, value: presentation.header?.guildID)
        // Collapsing or expanding a category adds or removes its channels, so
        // the row count is exactly the signal — and the same per-row entrance
        // transition then cascades them in or out rather than cutting.
        .animation(motion.standard, value: presentation.rows.count)
        .scrollIndicators(.never)
        // One read, carrying the banner and the pill up together.
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            // A `@State` write of an equal value still invalidates, and this one
            // fires on every scroll tick.
            if abs(scrollOffset - offset) > 0.5 { scrollOffset = offset }
        }
        // **Top only.** The now bar is glass, and a scroll edge effect under it
        // blurs the rows before the capsule can refract them — see
        // `softScrollEdgeTopOnly`, which carries the measurement. The bar still
        // registers through `safeAreaBar`; only the blur it was drawing is
        // gone.
        .softScrollEdgeTopOnly()
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

    @Environment(\.motion) private var motion

    @State private var isMenuOpen = false

    var body: some View {
        HStack(spacing: Spacing.base) {
            Button { isMenuOpen = true } label: {
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
                    ServerOptionsMenu(guildID: guildID, close: { isMenuOpen = false })
                        .presentationBackground(.clear)
                }
            }

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
    }

    @State private var isMenuOpen = false

    var body: some View {
        Group {
            if let guildID {
                Button { isMenuOpen = true } label: { title }
                    .accessibilityHint("Server options")
                    // **A real toolbar item is the one place a presentation may
                    // be inline** — `INVARIANTS.md` §1. It is one item evaluated
                    // once, and the alternative is a window-root presenter
                    // anchored to a rect the toolbar cannot report.
                    .popover(isPresented: $isMenuOpen, arrowEdge: .bottom) {
                        ServerOptionsMenu(guildID: guildID, close: { isMenuOpen = false })
                            .presentationBackground(.clear)
                    }
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
        guildID == nil ? max(20, maxWidth - Self.bareLabelInset * 2) : maxWidth
    }

    @ViewBuilder
    private var title: some View {
        let label = Text(name)
            .fontWeight(.semibold)
            .lineLimit(1)
            .truncationMode(.tail)
            .contentTransition(.interpolate)

        Group {
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
