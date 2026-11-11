import SwiftUI
import WingcordCore

/// What a search found.
///
/// **A destination in the supplementary column, not a sheet**, and that is the
/// whole reason clicking a result can jump the transcript without taking the
/// list away: the column survives the primary changing. A search is a list
/// somebody works *through* — closing it on the first hit means running it again
/// for the second.
///
/// **Every hit is the real message, drawn by the transcript's own painter.** A
/// bespoke author/time/text row draws a blank line for a forward, an embed, an
/// attachment, a poll, a sticker or a join notice — which is most of what people
/// go looking for. `MessageCard` is the transcript at a narrower width; see its
/// own note, which named this surface before it existed.
struct SearchPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var presentation = PresentationRevision.shared
    /// Moves when a picture a card draws has landed. Local, because an avatar
    /// arriving is a repaint of this pane and not of every laid-out row in the
    /// app — which is what `PresentationRevision` would be.
    @State private var artworkGeneration: UInt64 = 0

    /// What a card is laid out against: the column less its own margins.
    static var cardWidth: CGFloat {
        Proportions.searchColumnIdeal - Spacing.snug * 2 - Spacing.base * 2
    }

    var body: some View {
        // Read at the top rather than inside the branches: a read that happens
        // on one branch is a dependency only that branch registers.
        let search = model.searchPresentation
        let cards = model.searchCards(width: Self.cardWidth)

        VStack(alignment: .leading, spacing: 0) {
            if let search {
                header(search)
                Divider().overlay(Ink.quaternary)
                stage(search, cards: cards)
                    // **A registered bar, not a band under the list.**
                    // `safeAreaBar` is what reserves the clearance *and* gives
                    // the results passing beneath it the system's scroll-edge
                    // blur; an overlay would need its own inset constant and
                    // the two would drift.
                    .floatingBottomBar {
                        if search.pageCount > 1 {
                            SearchPagePill(
                                currentPage: search.currentPage,
                                pageCount: search.pageCount,
                                isLoading: search.isLoading,
                                go: { model.goToSearchPage($0) }
                            )
                            .padding(.bottom, Spacing.snug)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(motion.standard, value: search?.totalResults)
        .animation(motion.standard, value: search?.currentPage)
        // Escape, when the reader is in the results rather than in the field.
        // `onExitCommand` rather than a key equivalent: it travels the responder
        // chain from whatever has focus, so the composer and the quick switcher
        // keep their own Escape and this one never fires over them.
        .onExitCommand { model.closeSearch() }
        // **The painter only peeks the image caches**, so the pictures these
        // cards draw have to be fetched by somebody. One pass per page, behind
        // the scroll gate — exactly as the pinned pane does.
        .task(id: cards.map(\.id)) {
            await prefetch(cards)
        }
    }

    // MARK: Header

    private func header(_ search: MessageSearchPresentation) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(spacing: Spacing.base) {
                Text(resultsTitle(search))
                    .font(.system(.headline))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.numericText())

                if search.isLoading {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)

                // One glass group, the header controls' own arrangement: the
                // three things the reader can do to a list of results.
                GlassEffectContainer(spacing: Spacing.tight) {
                    HStack(spacing: Spacing.tight) {
                        SearchFiltersButton(
                            count: search.activeFilterCount,
                            open: { model.isSearchFiltersShown = true }
                        )
                        SearchSortMenu(
                            sort: search.sort,
                            order: search.order,
                            choose: { model.setSearchSort($0, order: $1) }
                        )
                        // **The panel's only visible way out.** Everything else
                        // here is opened from a control that can be pressed again
                        // to close it; this one is raised by typing in a toolbar
                        // field, so without this the column is a one-way door.
                        // Escape reaches it two other ways: clearing the field,
                        // and `onExitCommand` below when the focus is in the list.
                        SearchCloseButton { model.closeSearch() }
                    }
                }
                // **Never squeezed**: the column is narrow, and a control that
                // gives up width wraps its label ("Filt / ers"). The title
                // truncates instead.
                .fixedSize()
            }

            // What the list under it was searched with, each a ✕ away.
            let tokens = model.searchFilterTokens
            if !tokens.isEmpty {
                SearchTokenRow(tokens: tokens, remove: { model.removeSearchFilter($0) })
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Said out loud rather than left to look like a thin server: the
            // index is still being built and these results are incomplete.
            if search.isDeepIndexing {
                notice("This server is still being indexed, so some older messages are missing.",
                       symbolName: "clock.arrow.circlepath")
            }
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.vertical, Spacing.snug)
    }

    /// "842 Results", or what to do instead.
    private func resultsTitle(_ search: MessageSearchPresentation) -> String {
        guard search.hasAnswer else { return "Search \(search.scopeTitle)" }
        // **The server's count, not the page's.** The route documents that it
        // returns fewer than it counts, so the array's length is not the answer.
        return search.totalResults == 1 ? "1 Result" : "\(search.totalResults) Results"
    }

    // MARK: The list

    @ViewBuilder
    private func stage(_ search: MessageSearchPresentation, cards: [SearchResultCard]) -> some View {
        if let failure = search.failure {
            notice(failure, symbolName: "exclamationmark.triangle")
                .padding(Spacing.margin)
        } else if search.isIndexing {
            notice("Discord is building this server's search index.", symbolName: "hourglass")
                .padding(Spacing.margin)
        } else if !search.hasAnswer {
            notice(
                "Type in the search field above, then press Return.",
                symbolName: "magnifyingglass"
            )
            .padding(Spacing.margin)
        } else if cards.isEmpty {
            notice("No messages matched.", symbolName: "text.magnifyingglass")
                .padding(Spacing.margin)
        } else {
            list(cards)
        }
    }

    private func list(_ cards: [SearchResultCard]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.tight) {
                ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                    // **A header per run of one channel**, which is what Discord
                    // draws: results are ordered by time and cluster into
                    // channels, so a header on every card would be noise and a
                    // header only at the top would be a lie.
                    if index == 0 || cards[index - 1].channelID != card.channelID {
                        SearchChannelHeading(card: card)
                            .padding(.top, index == 0 ? 0 : Spacing.base)
                    }
                    SearchResultRow(
                        card: card,
                        presentationRevision: presentation.value,
                        artworkGeneration: artworkGeneration,
                        open: { model.openSearchResult(card.id, in: card.channelID) }
                    )
                }
            }
            .padding(.horizontal, Spacing.snug)
            .padding(.vertical, Spacing.snug)
        }
        .scrollBounceBehavior(.basedOnSize)
        .softScrollEdgesVertical()
    }

    private func notice(_ text: String, symbolName: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            Image(symbol: symbolName)
                .font(.system(.callout))
                .foregroundStyle(Ink.tertiary)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(.callout))
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func prefetch(_ cards: [SearchResultCard]) async {
        let requests = TimelineImageRequests.requests(
            for: cards.flatMap(\.card.messageRows),
            scale: 2,
            loadsArtwork: AppSettings.shared.loadsImagesAutomatically,
            playsAnimatedEmoji: AnimationClock.playsAnimatedEmoji
        )
        guard !requests.isEmpty else { return }
        await ScrollWorkGate.waitUntilInactive()
        guard !Task.isCancelled else { return }
        // A nudge per landing, coalesced (`ImageBatch`): the cards peek the
        // caches on their next draw, and one slow picture must not hold the
        // rest of the pane's back.
        await ImageBatch.load(requests) { _ in artworkGeneration &+= 1 }
    }
}

// MARK: - A group's heading

/// The channel a run of results was written in, with its category beside it.
private struct SearchChannelHeading: View {
    var card: SearchResultCard

    var body: some View {
        HStack(spacing: Spacing.tight) {
            Image(symbol: card.channelSymbolName)
                .font(.system(.caption))
                .foregroundStyle(Ink.tertiary)
            Text(card.channelName)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
            Spacer(minLength: Spacing.base)
            if let category = card.categoryName {
                Text(category)
                    .font(.system(.caption))
                    .foregroundStyle(Ink.quaternary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, Spacing.base)
        .padding(.vertical, Spacing.tight)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - One hit

private struct SearchResultRow: View {
    var card: SearchResultCard
    var presentationRevision: UInt64
    var artworkGeneration: UInt64
    var open: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            MessageCardCanvas(
                card: card.card,
                presentationRevision: presentationRevision,
                artworkGeneration: artworkGeneration
            )
            // The height is the layout's, so the row is placed once. A measured
            // height here would cost a second layout pass per card and would
            // settle visibly on the first frame.
            .frame(width: SearchPane.cardWidth, height: card.card.height)
            .padding(Spacing.base)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(isHovered ? Palette.hoverFill : Palette.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .strokeBorder(Ink.quaternary.opacity(isHovered ? 1 : 0.5), lineWidth: 1)
            }
            .contentShape(.rect(cornerRadius: Radius.row))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovered != hovering else { return }
            isHovered = hovering
        }
        .animation(motion.fadeQuick, value: isHovered)
        .accessibilityLabel(Text(card.card.accessibilityLabel))
        .accessibilityHint(Text("Jump to this message in #\(card.channelName)"))
    }
}

// MARK: - Sort

private struct SearchSortMenu: View {
    var sort: MessageSearchSort
    var order: MessageSearchOrder
    var choose: (MessageSearchSort, MessageSearchOrder) -> Void

    var body: some View {
        Menu {
            // **Relevance offers no direction**, because the route ignores
            // `sort_order` there — a control that changes nothing is the inert
            // control §5.5 forbids.
            Button("Newest first") { choose(.timestamp, .descending) }
            Button("Oldest first") { choose(.timestamp, .ascending) }
            Divider()
            Button("Most relevant") { choose(.relevance, .descending) }
        } label: {
            HStack(spacing: Spacing.tight) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(.caption, weight: .semibold))
                Text(label)
                    .font(.system(.subheadline, weight: .medium))
            }
            .foregroundStyle(Ink.primary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // **On the menu, after the style** — `INVARIANTS.md`, "a borderless
        // menu ignores a frame set on its label": set on the label, the pill
        // came out shorter than the two controls beside it.
        .padding(.horizontal, Spacing.snug)
        .frame(height: SearchPaneMetrics.control)
        .contentShape(.capsule)
        .interactiveChrome(in: .capsule)
        .accessibilityLabel("Sort results")
    }

    private var label: String {
        switch (sort, order) {
        case (.relevance, _): "Relevant"
        case (.timestamp, .descending): "Newest"
        case (.timestamp, .ascending): "Oldest"
        }
    }
}

// MARK: - Paging

/// The panel's controls' one height.
enum SearchPaneMetrics {
    static let control: CGFloat = 30
}

/// `‹  3 of 69  ›` — one glass capsule floating over the foot of the results.
///
/// **Replaces a row of numbered pages that could not fit its column**: at the
/// search column's width "1 2 … 69" wrapped its last number onto two lines
/// (Alex's report, 2026-11-10). A page number in words never outgrows its
/// capsule, the arrows step one page, and the number itself opens "Go to page"
/// — where four hundred pages are four keystrokes away rather than a strip of
/// buttons to aim at.
struct SearchPagePill: View {
    var currentPage: Int
    var pageCount: Int
    var isLoading: Bool
    var go: (Int) -> Void

    @Environment(\.motion) private var motion
    @State private var isJumpShown = false

    private static let height: CGFloat = 36

    var body: some View {
        HStack(spacing: 0) {
            step(forward: false)
            Button { isJumpShown = true } label: {
                HStack(spacing: 5) {
                    Text(currentPage, format: .number)
                        .font(.system(.callout, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .contentTransition(.numericText(value: Double(currentPage)))
                    Text("of \(pageCount.formatted(.number))")
                        .font(.system(.callout, weight: .medium))
                        .foregroundStyle(Ink.secondary)
                }
                .monospacedDigit()
                .padding(.horizontal, Spacing.base)
                .frame(minWidth: 76, minHeight: Self.height)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .help("Go to page…")
            .accessibilityLabel(Text("Page \(currentPage) of \(pageCount). Go to page"))
            .popover(isPresented: $isJumpShown, arrowEdge: .top) {
                SearchPageJump(pageCount: pageCount) { page in
                    isJumpShown = false
                    go(page)
                }
            }
            step(forward: true)
        }
        .padding(.horizontal, 3)
        .frame(height: Self.height)
        // How far through the pages this is: a hairline along the capsule's
        // foot, which moves as the number does. **On its own faint track**, so
        // page 1 of 69 reads as the start of a line rather than a blue speck
        // under the arrow.
        .overlay(alignment: .bottom) {
            GeometryReader { proxy in
                let fraction = CGFloat(currentPage) / CGFloat(max(1, pageCount))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Ink.quaternary)
                    Capsule()
                        .fill(Palette.accent)
                        .frame(width: max(4, proxy.size.width * fraction))
                }
                .frame(height: 2)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 3)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .interactiveChrome(in: .capsule)
        .fixedSize()
        .opacity(isLoading ? 0.6 : 1)
        .disabled(isLoading)
        .animation(motion.standard, value: currentPage)
    }

    private func step(forward: Bool) -> some View {
        let target = currentPage + (forward ? 1 : -1)
        let isEnabled = forward ? currentPage < pageCount : currentPage > 1
        return Button { go(target) } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.system(.callout, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .frame(width: Self.height - 6, height: Self.height - 6)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        // Kept in place at the ends: a control that moves as you page is one you
        // have to re-aim at every time.
        .opacity(isEnabled ? 1 : 0.3)
        .help(forward ? "Next page" : "Previous page")
        .accessibilityLabel(Text(forward ? "Next page" : "Previous page"))
    }
}

/// The filters the results were searched with, each one a token with a ✕ —
/// a horizontal strip under the header that scrolls when there are many.
private struct SearchTokenRow: View {
    var tokens: [SearchFilterToken]
    var remove: (SearchFilterToken) -> Void

    @Environment(\.motion) private var motion

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Spacing.tight) {
                ForEach(tokens) { token in
                    SearchTokenChip(token: token, remove: { remove(token) })
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.never)
        .animation(motion.standard, value: tokens)
    }
}

struct SearchTokenChip: View {
    var token: SearchFilterToken
    var remove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            if let avatarURL = token.avatarURL {
                AvatarView(url: avatarURL, monogram: token.monogram ?? "?", side: 16)
            } else if let symbolName = token.symbolName {
                Image(symbol: symbolName)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(Palette.accent)
            }
            Text(token.prefix)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(Palette.accent)
            Text(token.value)
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isHovering ? Ink.primary : Ink.secondary)
                    .frame(width: 16, height: 16)
                    .background(isHovering ? Palette.hoverFill : .clear, in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help("Remove this filter")
            .accessibilityLabel(Text("Remove \(token.prefix) \(token.value)"))
        }
        .padding(.leading, token.avatarURL == nil ? 8 : 4)
        .padding(.trailing, 3)
        .frame(height: 24)
        .background(Palette.accent.opacity(0.18), in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

/// Black or white over the accent, whichever reads: the accent is the theme's
/// and white on Wingcord's orange does not.
private struct AccentBadgeInk: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color {
        let accent = Palette.accent.resolve(in: environment)
        let luminance = 0.2126 * Double(accent.linearRed) + 0.7152 * Double(accent.linearGreen)
            + 0.0722 * Double(accent.linearBlue)
        return luminance > 0.18 ? Color.black.opacity(0.88) : .white
    }
}

/// "Go to Page", hung off the page pill's number.
///
/// **Inset for the popover's corners**: the glass is rounded far more than a
/// panel, and content set 12 points in sat in the curve — the title in the
/// corner and the row cut at both ends. The row was also wider than the
/// popover (a 92-point field beside a Go button with a 112-point floor, in
/// 240), so it spilled out of both sides. Now the field takes what the button
/// leaves, the button hugs its word, and everything is 16 points in.
struct SearchPageJump: View {
    var pageCount: Int
    var go: (Int) -> Void

    @State private var typed = ""
    @FocusState private var isFocused: Bool

    static let width: CGFloat = 260
    private static let fieldHeight: CGFloat = 36

    private var page: Int? {
        guard let value = Int(typed), value >= 1, value <= pageCount else { return nil }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Go to Page")
                    .font(.system(.headline))
                    .foregroundStyle(Ink.primary)
                Text("\(pageCount.formatted(.number)) pages of results")
                    .font(.system(.caption))
                    .foregroundStyle(Ink.secondary)
            }

            HStack(spacing: Spacing.base) {
                HStack(spacing: Spacing.tight) {
                    Image(systemName: "number")
                        .font(.system(.callout, weight: .semibold))
                        .foregroundStyle(Ink.secondary)
                        .accessibilityHidden(true)
                    TextField("Page", text: $typed, prompt: Text("1–\(pageCount.formatted(.number))"))
                        .textFieldStyle(.plain)
                        .labelsHidden()
                        .font(.system(.body, weight: .medium))
                        .monospacedDigit()
                        .focused($isFocused)
                        // Digits only: the field takes a page number, and
                        // rejecting the keystroke is clearer than accepting it
                        // and refusing the jump.
                        .onChange(of: typed) { _, value in
                            let digits = value.filter(\.isNumber).prefix(4)
                            if digits != value { typed = String(digits) }
                        }
                        .onSubmit { if let page { go(page) } }
                }
                .padding(.horizontal, Spacing.snug)
                .frame(maxWidth: .infinity, minHeight: Self.fieldHeight, maxHeight: Self.fieldHeight)
                // The modal fields' own rounded ground, not a capsule: a
                // capsule's stroked border draws a tick at each end.
                .modalFieldGround(isFocused: isFocused)
                .contentShape(.rect)
                .onTapGesture { isFocused = true }

                Button("Go") {
                    if let page { go(page) }
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .fixedSize()
                .disabled(page == nil)
            }
        }
        .padding(Spacing.margin)
        .frame(width: Self.width)
        // The material a popover paints behind its whole content is the one
        // §2 says cannot be suppressed, so nothing here adds a second.
        .presentationBackground(.clear)
        .onAppear { isFocused = true }
    }
}


// MARK: - Filters

/// The control that opens the sheet, with its badge.
/// Closes the panel.
///
/// The same weight as the two controls beside it — a header control, not a
/// window chrome button — because it is one of three things the reader can do to
/// a list of results and not a decoration on the column.
private struct SearchCloseButton: View {
    var close: () -> Void

    var body: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.system(.caption, weight: .bold))
                .foregroundStyle(Ink.primary)
                .frame(width: SearchPaneMetrics.control, height: SearchPaneMetrics.control)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .interactiveChrome(in: .circle)
        .help("Close search")
        .accessibilityLabel(Text("Close search"))
    }
}

private struct SearchFiltersButton: View {
    var count: Int
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: Spacing.tight) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(.caption, weight: .semibold))
                Text("Filters")
                    .font(.system(.subheadline, weight: .medium))
                if count > 0 {
                    // The count in a badge of the accent, as a toolbar shows
                    // what is set behind a control.
                    Text("\(count)")
                        .font(.system(.caption2, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(AccentBadgeInk())
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Palette.accent, in: .capsule)
                        .contentTransition(.numericText(value: Double(count)))
                }
            }
            .foregroundStyle(Ink.primary)
            .padding(.horizontal, Spacing.snug)
            .frame(height: SearchPaneMetrics.control)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .interactiveChrome(in: .capsule)
        .accessibilityLabel(count > 0 ? "Filters, \(count) set" : "Filters")
    }
}
