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
                            SearchPageBar(
                                currentPage: search.currentPage,
                                pageCount: search.pageCount,
                                isLoading: search.isLoading,
                                go: { model.goToSearchPage($0) }
                            )
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
                    .contentTransition(.numericText())

                if search.isLoading {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)

                SearchFiltersButton(
                    count: search.activeFilterCount,
                    open: { model.isSearchFiltersShown = true }
                )

                SearchSortMenu(
                    sort: search.sort,
                    order: search.order,
                    choose: { model.setSearchSort($0, order: $1) }
                )

                // **The panel's only visible way out.** Everything else here is
                // opened from a control that can be pressed again to close it;
                // this one is raised by typing in a toolbar field, so without
                // this the column is a one-way door — which is exactly how it
                // read. Escape reaches it two other ways: clearing the field,
                // and `onExitCommand` below when the focus is in the list.
                SearchCloseButton { model.closeSearch() }
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
        await withTaskGroup(of: Void.self) { group in
            for request in requests {
                group.addTask { _ = await request.load() }
            }
        }
        guard !Task.isCancelled else { return }
        // One nudge for the batch: the cards peek the caches on their next
        // draw, and a repaint per picture would repaint the pane per avatar.
        artworkGeneration &+= 1
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
                    .font(.system(.caption, weight: .medium))
            }
            .foregroundStyle(Ink.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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

/// `‹ Back  1 2 … 400  Next ›`, floating.
///
/// **Glass, because it is the one thing here with content moving under it** —
/// the results scroll beneath the bar, which is the composition `INVARIANTS.md`
/// §4 reserves the material for. One body per control group, merged in a
/// `GlassEffectContainer`, exactly as the Channels & Roles bar is built.
///
/// **The current page is a region inside the numbers' own material, not a second
/// glass body** — §4 rule 2 — and it travels with `matchedGeometryEffect`, the
/// same idiom the segmented control uses.
///
/// **`…` is a control, not punctuation.** With four hundred pages the elision is
/// most of the range, so the thing it hides is exactly what somebody wants: it
/// opens a flyout that takes a page number. Discord draws the same `…` and makes
/// page 200 a hundred and ninety-eight clicks away.
private struct SearchPageBar: View {
    var currentPage: Int
    var pageCount: Int
    var isLoading: Bool
    var go: (Int) -> Void

    @Environment(\.motion) private var motion
    @Namespace private var pill
    @State private var isJumpShown = false

    var body: some View {
        GlassEffectContainer(spacing: Spacing.base) {
            HStack(spacing: Spacing.base) {
                step("Back", symbol: "chevron.left", to: currentPage - 1, isEnabled: currentPage > 1)
                numbers
                step("Next", symbol: "chevron.right", to: currentPage + 1, isEnabled: currentPage < pageCount)
            }
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.bottom, Spacing.snug)
        .disabled(isLoading)
        .opacity(isLoading ? 0.55 : 1)
        .animation(motion.standard, value: currentPage)
    }

    /// One glass body holding every number, so the pages read as one control
    /// rather than as a row of separate buttons.
    private var numbers: some View {
        HStack(spacing: 2) {
            ForEach(Array(pageNumbers.enumerated()), id: \.offset) { _, slot in
                switch slot {
                case .page(let page):
                    numberButton(page)
                case .gap:
                    gapButton
                }
            }
        }
        .padding(.horizontal, Spacing.tight)
        .frame(height: Metrics.control + Spacing.base)
        .interactiveChrome(in: .capsule)
    }

    private func numberButton(_ page: Int) -> some View {
        let isCurrent = page == currentPage
        return Button { go(page) } label: {
            Text(String(page))
                .font(.system(.caption, weight: isCurrent ? .semibold : .medium))
                .foregroundStyle(isCurrent ? AnyShapeStyle(.white) : AnyShapeStyle(Ink.secondary))
                .monospacedDigit()
                .padding(.horizontal, Spacing.base)
                .frame(minWidth: 26, minHeight: Metrics.control)
                .background {
                    // A tinted region inside the capsule's material, travelling
                    // between numbers — never a second glass body.
                    if isCurrent {
                        Capsule()
                            .fill(Palette.accent)
                            .matchedGeometryEffect(id: "page", in: pill)
                    }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Page \(page)")
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    /// The elision, which is where a page number is typed.
    private var gapButton: some View {
        Button { isJumpShown = true } label: {
            Image(systemName: "ellipsis")
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(Ink.tertiary)
                .frame(minWidth: 26, minHeight: Metrics.control)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Jump to a page")
        .popover(isPresented: $isJumpShown, arrowEdge: .top) {
            SearchPageJump(pageCount: pageCount) { page in
                isJumpShown = false
                go(page)
            }
        }
    }

    private func step(
        _ title: String,
        symbol: String,
        to page: Int,
        isEnabled: Bool
    ) -> some View {
        Button { go(page) } label: {
            HStack(spacing: Spacing.tight) {
                if symbol == "chevron.left" { Image(symbol: symbol) }
                Text(title)
                if symbol == "chevron.right" { Image(symbol: symbol) }
            }
            .font(.system(.caption, weight: .medium))
            .foregroundStyle(isEnabled ? AnyShapeStyle(Ink.primary) : AnyShapeStyle(Ink.quaternary))
            .padding(.horizontal, Spacing.snug)
            .frame(height: Metrics.control + Spacing.base)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .interactiveChrome(in: .capsule)
        .disabled(!isEnabled)
        // Kept in place rather than removed at the ends: a bar whose controls
        // move as you page is a bar you have to re-aim at every time.
        .opacity(isEnabled ? 1 : 0.5)
    }

    private enum Slot: Hashable { case page(Int), gap }

    /// `1 2 … 400` — the first, the last, and a window around where you are.
    ///
    /// **Always at least one gap when there is anything hidden**, because the
    /// gap is the control that reaches what the window leaves out.
    private var pageNumbers: [Slot] {
        guard pageCount > 1 else { return [] }
        guard pageCount > 6 else { return (1...pageCount).map(Slot.page) }

        var slots: [Slot] = [.page(1)]
        let lower = max(2, currentPage - 1)
        let upper = min(pageCount - 1, currentPage + 1)
        if lower > 2 { slots.append(.gap) }
        for page in lower...upper { slots.append(.page(page)) }
        if upper < pageCount - 1 { slots.append(.gap) }
        slots.append(.page(pageCount))
        return slots
    }
}

/// The flyout behind `…`.
private struct SearchPageJump: View {
    var pageCount: Int
    var go: (Int) -> Void

    @State private var typed = ""
    @FocusState private var isFocused: Bool

    private var page: Int? {
        guard let value = Int(typed), value >= 1, value <= pageCount else { return nil }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text("Go to page")
                .font(.system(.callout, weight: .semibold))
                .foregroundStyle(Ink.primary)

            HStack(spacing: Spacing.base) {
                TextField("", text: $typed, prompt: Text("1–\(pageCount)"))
                    .textFieldStyle(.plain)
                    .font(.system(.body))
                    .monospacedDigit()
                    .focused($isFocused)
                    .frame(width: 92)
                    .padding(.horizontal, Spacing.base)
                    .frame(height: Metrics.control + Spacing.tight)
                    .background(
                        Palette.surfaceRaised,
                        in: .rect(cornerRadius: Radius.chip, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                            .strokeBorder(Ink.quaternary, lineWidth: 1)
                    }
                    // Digits only: the field takes a page number, and rejecting
                    // the keystroke is clearer than accepting it and refusing
                    // the jump.
                    .onChange(of: typed) { _, value in
                        let digits = value.filter(\.isNumber).prefix(4)
                        if digits != value { typed = String(digits) }
                    }
                    .onSubmit { if let page { go(page) } }

                SurfaceFilledButton(title: "Go", systemImage: nil) {
                    if let page { go(page) }
                }
                .disabled(page == nil)
            }
        }
        .padding(Spacing.snug)
        .frame(width: 240)
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
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(Ink.secondary)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
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
                Text(count > 0 ? "Filters (\(count))" : "Filters")
                    .font(.system(.caption, weight: .medium))
            }
            .foregroundStyle(count > 0 ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Ink.secondary))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count > 0 ? "Filters, \(count) set" : "Filters")
    }
}
