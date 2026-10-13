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
/// **The bar is three rows and each one is centred on the same midline.** The
/// tab picker sits directly above the heading strip, the search field rides the
/// heading strip's own line at its trailing end, and a third row appears only
/// while there is something to filter. Both pickers are the system's
/// `NSSegmentedControl` — §1 — which brings its own material, so neither is
/// inside a `GlassEffectContainer` and neither carries a `.glassEffect`.
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
            VStack(spacing: Spacing.snug) {
                DiscoveryTabRow(tab: $tab, dismiss: dismiss)
                DiscoveryHeadingRow(query: $query) { middle }
            }
            .surfaceColumn(Self.measure)
            .padding(.bottom, Spacing.base)
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
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - The bar's first row

/// Servers ↔ Apps, on the column's midline, with the one way out at its end.
///
/// **Centred rather than parked at the leading edge**, so it sits directly over
/// the heading strip below it and the two read as one control stack rather than
/// as a toolbar with a strip under it. The close button is an overlay rather
/// than a stack member for exactly that reason: a sibling in the row would push
/// the picker off the midline by its own width.
private struct DiscoveryTabRow: View {
    @Binding var tab: DiscoveryState.Tab
    var dismiss: () -> Void

    var body: some View {
        SegmentedPicker(
            options: DiscoveryState.Tab.allCases.map {
                SegmentedPicker.Option($0, $0.title)
            },
            selection: $tab
        )
        .fixedSize()
        .frame(maxWidth: .infinity)
        .overlay(alignment: .trailing) {
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(Typeface.controlGlyph)
                    .frame(width: Metrics.control, height: Metrics.control)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Ink.secondary)
            .frame(height: Metrics.control + Spacing.base)
            .padding(.horizontal, Spacing.base)
            .glassEffect(.regular.interactive(), in: .capsule)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(Text("Close discovery"))
        }
    }
}

// MARK: - The bar's second row

/// The heading strip on the midline, the search field at the trailing end.
///
/// **Two arrangements, and the wide one is measured rather than hoped for.**
/// The app strip is 670 points across at its six headings; centring it with the
/// field beside it costs the field's width twice, so the row needs
/// `670 + 2 × (200 + 12)` = 1,094 points and `Metrics.discoveryColumn` is sized
/// to give it that. Where the window is narrower than that, `ViewThatFits`
/// takes the second arrangement: the field moves to its own line above and the
/// strip keeps the midline, which is the half of this that was asked for.
private struct DiscoveryHeadingRow<Headings: View>: View {
    @Binding var query: String
    /// The BUILT view, not the builder — an escaping `@ViewBuilder` stored on a
    /// view keeps a closure per instance and stops SwiftUI seeing the content as
    /// structurally stable across updates.
    @ViewBuilder var headings: Headings

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.snug) {
                // The counterweight. A spacer of the field's own width is what
                // puts the strip on the column's midline rather than on the
                // midline of what is left over.
                Color.clear
                    .frame(width: Metrics.discoverySearchField, height: 0)
                Spacer(minLength: Spacing.snug)
                headings
                Spacer(minLength: Spacing.snug)
                field
            }
            VStack(spacing: Spacing.base) {
                field.frame(maxWidth: .infinity, alignment: .trailing)
                headings
            }
        }
    }

    private var field: some View {
        DiscoverySearchField(query: $query)
            .frame(width: Metrics.discoverySearchField)
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
                    .foregroundStyle(Ink.tertiary)
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
private struct FilterMenuLabel: View {
    var title: String

    var body: some View {
        HStack(spacing: Spacing.tight) {
            Text(title)
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Ink.tertiary)
        }
        .padding(.horizontal, Spacing.base)
        .padding(.vertical, 5)
        .background(Palette.surfaceRaised, in: .capsule)
        .overlay { Capsule().strokeBorder(Palette.edge) }
    }
}

// MARK: - The field

/// The field, in the app's own shape.
///
/// A capsule over `Palette.surfaceRaised` with a still-life specular edge —
/// the same field the forum board and the forward sheet carry. It never moves,
/// so it catches no travelling specular highlight of its own, and without the
/// edge it is a slightly lighter region on a near-black ground rather than a
/// field.
private struct DiscoverySearchField: View {
    /// **A binding, not a value plus a setter.** A stored closure property is a
    /// non-`Sendable` function value where `TextField` wants a main-actor
    /// isolated one — the quick switcher's field has the same note. Built one
    /// level up, where the store is.
    @Binding var query: String

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Ink.tertiary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(.body))
                .focused($isFocused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(.caption))
                        .foregroundStyle(Ink.tertiary)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear the search"))
            }
        }
        .padding(.horizontal, Spacing.snug)
        .frame(height: Metrics.control + Spacing.tight)
        .background(Palette.surfaceRaised, in: .capsule)
        .overlay { Capsule().strokeBorder(Palette.edge) }
        .contentShape(.capsule)
        .onTapGesture { isFocused = true }
    }
}
