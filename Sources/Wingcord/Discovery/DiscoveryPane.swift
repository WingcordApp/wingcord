import SwiftUI
import WingcordCore

/// Discovery — servers and apps the account is not in yet.
///
/// **A page on the reading surface with one glass bar**, which is §1's rule for
/// every full-column surface in this app and not a fresh decision: what passes
/// under the bar is a scrolling grid, so the bar floats; the cards sit on an
/// opaque ground, so they are `.structuralSurface()` with a hairline. Glass over
/// an opaque fill is §4 rule 3 and renders as a flat panel.
///
/// **The bar is the toolbar row** (Alex, 2026-11-04): Servers/Apps at its leading
/// end, the headings on the page's midline, and the inbox, search and the way out at
/// its trailing end. It used to be three rows, 140 points of them. Both pickers are
/// the system's `NSSegmentedControl` — §1 — which brings its own material, so neither
/// is inside a `GlassEffectContainer` and neither carries a `.glassEffect`.
struct DiscoveryPane: View {
    /// A binding for the same reason `query` is one: a stored closure is a
    /// non-`Sendable` function value where the control's own binding wants a
    /// main-actor-isolated one.
    @Binding var tab: DiscoveryState.Tab
    /// **A binding, built where the store is.** The setter goes through
    /// `setDiscoveryQuery`, which is what raises the request — and a stored
    /// `(String) -> Void` property is a non-`Sendable` function value where
    /// `TextField` wants a main-actor-isolated one.
    @Binding var query: String
    /// Bindings for the reason `tab` is one — the control's own selection
    /// binding wants a main-actor-isolated setter, and a stored closure is not.
    @Binding var categoryID: Int?
    var categories: [DiscoveryCategory]
    @Binding var appCategoryID: Int?
    var appCategories: [AppDirectoryCategory]
    /// The search's own category counts, or empty while there is no search.
    var facet: [DiscoveryFacetBucket]
    /// What the Show menu's label says — the selected heading, or All.
    var facetLabel: String
    @Binding var languageCode: String?
    var cards: [DiscoveryCard]
    var appCards: [DiscoveryAppCard]
    var isBusy: Bool
    var emptyLine: String?
    /// Whether there is another page under this one.
    var hasMore: Bool

    /// The app whose own page is open, one level in. Nil is the grid.
    var openAppID: ApplicationID?
    /// Its storefront, one level deeper again.
    var openStoreID: ApplicationID?
    var openCard: (DiscoveryCard) -> Void
    var openApp: (ApplicationID) -> Void
    var closeApp: () -> Void
    var addApp: (ApplicationID) -> Void
    var openStore: (ApplicationID) -> Void
    var closeStore: () -> Void
    var openSupportGuild: (GuildID) -> Void
    var loadMore: () -> Void
    var dismiss: () -> Void

    @Environment(\.motion) private var motion

    /// The column both the grid and the bar are laid out on. See
    /// `Metrics.discoveryColumn` for why it is wider than every other surface.
    private static let measure = Metrics.discoveryColumn

    var body: some View {
        // **A stack of two under one view type**, which is the same rule §1
        // states for the detail column itself: internal `_ConditionalContent`
        // under a stable outer type is not a structural swap, and the grid
        // underneath keeps its scroll and its page while a page is open over it.
        Group {
            if let openStoreID {
                ApplicationStorePage(
                    applicationID: openStoreID,
                    name: storeName,
                    layout: .page,
                    onBack: closeStore
                )
                .readingSurface()
            } else if let openAppID {
                ActivityDetailPage(
                    applicationID: openAppID,
                    // **No channel here.** The directory is reached from the
                    // rail with nothing open, so a Send would have nowhere to
                    // act — the page draws its description, its commands as a
                    // read-only list, Add App, and a Launch that runs the app in
                    // its own direct message.
                    channelID: nil,
                    layout: .page,
                    onBack: closeApp,
                    onLaunched: closeApp,
                    onOpenStore: { openStore(openAppID) },
                    onAdd: { addApp(openAppID) },
                    onOpenSimilar: openApp,
                    onOpenSupportGuild: openSupportGuild
                )
                .readingSurface()
            } else {
                browse
            }
        }
    }

    /// What the storefront's own bar is titled. Read from the page's card so
    /// the store does not have to fetch the application again to name itself.
    private var storeName: String {
        appCards.first { $0.id == openStoreID }?.name ?? ""
    }

    private var browse: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.group) {
                grid
                footer
            }
            .surfaceColumn(Self.measure)
            .padding(.top, Spacing.margin)
            .padding(.bottom, Spacing.section)
        }
        .scrollBounceBehavior(.always, axes: .vertical)
        .softScrollEdgesVertical()
        .readingSurface()
        .floatingTopBar {
            DiscoveryToolbar(tab: $tab, query: $query, dismiss: dismiss) { middle }
        }
        .animation(motion.standard, value: tab)
        .animation(motion.standard, value: showsFilters)
    }

    /// **Servers, and only while something has been typed.** The facet is the
    /// search route's answer and the language filter is the search route's
    /// parameter; neither exists on a browse, and a control that cannot change
    /// the answer is the one §5.5 forbids.
    private var showsFilters: Bool {
        tab == .servers && !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// **The middle of the bar is always the same question — how is this list
    /// narrowed — and only its instrument changes.**
    ///
    /// Browsing, that is the six-heading strip. Searching, it is the facet and
    /// the language, because a search *has* a facet: the route answers a count
    /// per category for the query — forty-five buckets, from 142 down to 19 in
    /// the capture — and neither a count nor forty-five segments fits a
    /// segmented control. They occupy the strip's own place rather than a third
    /// row under it: a bar that grew a row when somebody typed would move the
    /// grid down as they typed into it, and a middle that simply emptied read as
    /// the bar having broken.
    @ViewBuilder
    private var middle: some View {
        if showsFilters {
            DiscoveryFilters(
                buckets: facet,
                label: facetLabel,
                categoryID: $categoryID,
                languageCode: $languageCode
            )
        } else {
            headings
        }
    }

    // MARK: The headings

    /// The same control as the tabs above it, and the same one the full profile
    /// uses: `NSSegmentedControl`, capsule, `role: .tabs` — §1's rule, and what
    /// Clock, Podcasts and Freeform draw.
    ///
    /// **It holds six headings, which is what makes it the right instrument.**
    /// The route answers forty-nine and the reference client's own strip shows
    /// six; a control that sizes each segment to its label — which this one does,
    /// see `SegmentedPicker` — would be fifteen hundred points wide with all of
    /// them. `AppModel.featuredCategoryIDs` is the curation.
    ///
    /// **It stands down while there is a search**, because then the category is
    /// the facet's and the facet has forty-five buckets with counts on them. One
    /// value, one control at a time: see `DiscoveryFilterRow`.
    @ViewBuilder
    private var headings: some View {
        if tab == .servers {
            if !categories.isEmpty {
                SegmentedPicker(
                    options: [SegmentedPicker.Option(nil, "Featured")]
                        + categories.map { SegmentedPicker.Option($0.id, $0.name) },
                    selection: $categoryID
                )
                // **`fixedSize`, or the control is squeezed.** It reports its
                // `intrinsicContentSize` and SwiftUI is free to propose less;
                // `.extraLarge` is 36 points tall and the strip was rendering
                // shorter than Clock's own for that reason alone.
                .fixedSize()
                .accessibilityLabel(Text("Browse servers by category"))
            }
        } else if !appCategories.isEmpty {
            SegmentedPicker(
                // **Featured is one of these, not the absence of one.** It is
                // category `0` and it is prepended by the projection, because the
                // route does not send it — see `AppDirectoryCategory.featured`.
                options: appCategories.map { SegmentedPicker.Option($0.id, $0.name) },
                selection: $appCategoryID
            )
            .fixedSize()
            .accessibilityLabel(Text("Browse apps by category"))
        }
    }

    // MARK: The grid

    /// **Adaptive columns, not a fixed count.** The detail column is resizable
    /// and the window has a 880-point minimum, so a hard four-up is three cards
    /// of empty space on a narrow window and a wall on a wide one.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Metrics.discoveryCardWidth), spacing: Spacing.margin)]
    }

    @ViewBuilder
    private var grid: some View {
        if let emptyLine {
            // **Centred, because it stands where the grid would.** Left against
            // the column's edge under a centred bar it read as a stray caption
            // rather than as the page's answer.
            Text(emptyLine)
                .font(.system(.callout))
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Proportions.surfaceColumnMax)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, Spacing.section)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.margin) {
                if tab == .servers {
                    ForEach(cards) { card in
                        DiscoveryServerCard(card: card) { openCard(card) }
                    }
                } else {
                    ForEach(appCards) { card in
                        DiscoveryAppTile(card: card) { openApp(card.id) }
                    }
                }
            }
        }
    }

    // MARK: The foot

    /// Page two, and the only thing that asks for it.
    ///
    /// **A button, not a scroll sentinel.** An `onAppear` at the foot of a lazy
    /// grid fires while the reader is still two rows above it and again on every
    /// bounce; a control that says what it does costs one click and cannot fire
    /// twice by accident. It is also the honest shape for a route with six
    /// thousand answers.
    @ViewBuilder
    private var footer: some View {
        if isBusy {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.snug)
        } else if hasMore {
            Button("Show more", action: loadMore)
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - The toolbar row

/// Servers ↔ Apps, the headings, then the inbox, search and the way out.
///
/// **The headings drop to a row of their own only where one row can't hold them**,
/// which `HeaderBarLayout` decides with the open field's width reserved, so nothing
/// moves when the field opens.
private struct DiscoveryToolbar<Middle: View>: View {
    @Binding var tab: DiscoveryState.Tab
    @Binding var query: String
    var dismiss: () -> Void
    /// The BUILT view, not the builder — an escaping `@ViewBuilder` stored on a
    /// view keeps a closure per instance and stops SwiftUI seeing the content as
    /// structurally stable across updates.
    @ViewBuilder var middle: Middle

    /// Whether the field has the keyboard, in which case Escape is the field's.
    @State private var isSearchFocused = false

    private static var trailingAtWidest: CGFloat {
        Metrics.discoverySearchField + 2 * (SearchField.height + Spacing.base)
    }

    var body: some View {
        PageHeaderBar(wrapsCenter: true, reservedTrailing: Self.trailingAtWidest) {
            SegmentedPicker(
                options: DiscoveryState.Tab.allCases.map {
                    SegmentedPicker.Option($0, $0.title)
                },
                selection: $tab
            )
            .fixedSize()
        } center: {
            middle
        } trailing: {
            HStack(spacing: Spacing.base) {
                DiscoveryInboxButton()
                DiscoverySearch(query: $query, isFocused: $isSearchFocused)
                HeaderCircleButton(
                    systemImage: "xmark",
                    label: "Close discovery",
                    side: SearchField.height,
                    action: dismiss
                )
                .keyboardShortcut(isSearchFocused ? nil : .cancelAction)
            }
        }
    }
}

/// The inbox, as it is on every other page.
private struct DiscoveryInboxButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HeaderCircleButton(
            systemImage: "tray",
            label: "Inbox",
            isActive: model.isInboxShown,
            side: SearchField.height
        ) {
            model.toggleInbox()
        }
        .popover(isPresented: Binding(
            get: { model.isInboxShown },
            set: { if !$0, model.isInboxShown { model.toggleInbox() } }
        ), arrowEdge: .bottom) {
            InboxFlyout()
        }
    }
}

// MARK: - The search

/// A circle that opens into the native field, as search does in servers and
/// conversations: the same morph, with this page's own list behind it.
///
/// **Stays open while it holds words**, whatever has the keyboard, since a field
/// that hid a live search would leave the grid filtered by something nobody can see.
private struct DiscoverySearch: View {
    /// **A binding, not a value plus a setter.** A stored closure property is a
    /// non-`Sendable` function value where the field wants a main-actor isolated
    /// one. Built one level up, where the store is.
    @Binding var query: String
    @Binding var isFocused: Bool

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isOpen = false

    private var showsField: Bool { isOpen || !query.isEmpty }

    var body: some View {
        Group {
            if showsField {
                SearchField(
                    text: $query,
                    takesFocus: true,
                    onCancel: close,
                    onEndEditing: endEditing
                )
                .frame(width: Metrics.discoverySearchField)
                .transition(.materialize(from: .trailing, blurring: false))
                .onAppear { isFocused = true }
            } else {
                HeaderCircleButton(systemImage: "magnifyingglass", label: "Search", side: SearchField.height) {
                    isOpen = true
                }
                .transition(.materialize(from: .trailing, blurring: false))
            }
        }
        .animation(motion.glassMorph, value: showsField)
        // ⌘F.
        .onChange(of: model.searchFocusRequest) { isOpen = true }
    }

    /// Escape: the words go, then the field.
    private func close() {
        query = ""
        isOpen = false
        isFocused = false
    }

    private func endEditing() {
        isFocused = false
        if query.isEmpty { isOpen = false }
    }
}

// MARK: - What a search puts in the strip's place

/// Show, and the language — the two filters a search has and a browse has not.
///
/// **Menus rather than a second strip**, and the facet is the reason: the route
/// answers a count per category for the query — forty-five buckets in the
/// capture, from 142 down to 19 — and a segmented control has no room for a
/// number under a label and no way to hold forty-five segments.
///
/// **Show is absent until the facet lands, and the language is always there.**
/// The facet is an answer and the language is a parameter: one of them can be
/// offered before the route has said anything and the other cannot, and a menu
/// of buckets nobody has counted yet is the control §5.5 forbids.
private struct DiscoveryFilters: View {
    var buckets: [DiscoveryFacetBucket]
    var label: String
    @Binding var categoryID: Int?
    @Binding var languageCode: String?

    var body: some View {
        HStack(spacing: Spacing.snug) {
            if !buckets.isEmpty {
                Text("Show")
                    .font(Typeface.rowSubtitle)
                    .foregroundStyle(Ink.secondary)
                Menu {
                    ForEach(buckets) { bucket in
                        Button {
                            categoryID = bucket.id
                        } label: {
                            // The count is the whole point of the facet: it is
                            // what tells somebody that narrowing to Emoji leaves
                            // nineteen results rather than none.
                            Text("\(bucket.name)  \(bucket.count.formatted(.number))")
                        }
                    }
                } label: {
                    FilterMenuLabel(title: label)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Text("Filter by category"))
            }
            Menu {
                Button("Any language") { languageCode = nil }
                Divider()
                ForEach(GuildLocale.all) { entry in
                    Button(entry.title) { languageCode = entry.code }
                }
            } label: {
                FilterMenuLabel(
                    title: languageCode.flatMap(GuildLocale.named) ?? "Any language"
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("Filter by language"))
        }
    }
}

/// One filter menu's label: what is selected, and a mark saying it can change.
///
/// **A glass capsule as tall as the strip it stands in for**, on a row of them.
private struct FilterMenuLabel: View {
    var title: String

    var body: some View {
        HStack(spacing: Spacing.tight) {
            Text(title)
                .font(.system(.body, weight: .medium))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Ink.secondary)
        }
        .padding(.horizontal, Spacing.snug)
        .frame(height: SearchField.height)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}
