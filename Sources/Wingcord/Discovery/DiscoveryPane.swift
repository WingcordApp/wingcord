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
/// **The bar's controls are regions inside its material, not bodies on it.** The
/// tab picker is a capsule with a travelling pill — the same shape Channels &
/// Roles uses, and for the reason stated there: `SegmentedPicker` brings its own
/// material, and a `GlassEffectContainer` around one is glass on glass.
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
    var cards: [DiscoveryCard]
    var apps: [ActivityApp]
    var isBusy: Bool
    var emptyLine: String?
    /// Whether there is another page under this one.
    var hasMore: Bool

    /// The app whose own page is open, one level in. Nil is the grid.
    var openAppID: ApplicationID?
    var openCard: (DiscoveryCard) -> Void
    var openApp: (ActivityApp) -> Void
    var closeApp: () -> Void
    var addApp: (ApplicationID) -> Void
    var loadMore: () -> Void
    var dismiss: () -> Void

    @Environment(\.motion) private var motion

    /// Wide enough for three cards at their own minimum with the column's
    /// margins — the measure Channels & Roles already uses for the one page with
    /// something beside its content, and the same reason applies: a grid needs
    /// room a column of prose does not.
    private static let measure = Proportions.surfaceColumnWide

    var body: some View {
        // **A stack of two under one view type**, which is the same rule §1
        // states for the detail column itself: internal `_ConditionalContent`
        // under a stable outer type is not a structural swap, and the grid
        // underneath keeps its scroll and its page while a page is open over it.
        Group {
            if let openAppID {
                ActivityDetailPage(
                    applicationID: openAppID,
                    // **No channel here.** The directory is reached from the
                    // rail with nothing open, so a Launch or a Send would have
                    // nowhere to act — the page draws its description, its
                    // commands as a read-only list, and Add App.
                    channelID: nil,
                    onBack: closeApp,
                    onLaunched: closeApp,
                    onAdd: { addApp(openAppID) }
                )
                .readingSurface()
            } else {
                browse
            }
        }
    }

    private var browse: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.group) {
                heading
                headings
                grid
                footer
            }
            .surfaceColumn(Self.measure)
            .padding(.top, Spacing.margin)
            .padding(.bottom, Spacing.section)
        }
        .scrollBounceBehavior(.always, axes: .vertical)
        .readingSurface()
        .floatingTopBar {
            DiscoveryBar(tab: $tab, query: $query, dismiss: dismiss)
            .surfaceColumn(Self.measure)
            .padding(.bottom, Spacing.base)
        }
        .animation(motion.standard, value: tab)
    }

    // MARK: The heading

    /// What this grid is, in the page's own words.
    ///
    /// **The front page is named for what the route actually answers.** It is
    /// the verified-and-partnered shortlist, not "everything" — calling it All
    /// would promise the whole of discovery from a route that returns a
    /// twentieth of it.
    private var heading: some View {
        SurfaceHeading(
            title: headingTitle,
            detail: tab == .servers
                ? "Look inside a server before you join it."
                : "Apps and bots you can add to a server.",
            badge: nil
        )
    }

    private var headingTitle: String {
        guard tab == .servers else {
            return appCategories.first { $0.id == appCategoryID }?.name ?? "All apps"
        }
        guard let categoryID else { return "Featured servers" }
        return categories.first { $0.id == categoryID }?.name ?? "Servers"
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
    /// Not inside a `GlassEffectContainer` and carrying no `.glassEffect`: the
    /// control brings its own material.
    @ViewBuilder
    private var headings: some View {
        if tab == .servers {
            if !categories.isEmpty {
                SegmentedPicker(
                    options: [SegmentedPicker.Option(nil, "Featured")]
                        + categories.map { SegmentedPicker.Option($0.id, $0.name) },
                    selection: $categoryID
                )
                .accessibilityLabel(Text("Browse servers by category"))
            }
        } else if !appCategories.isEmpty {
            SegmentedPicker(
                // **"All", not "Featured".** For servers the front page is a
                // genuinely curated shortlist; for apps it is an unfiltered
                // search, and naming it Featured would be a promise the route
                // does not keep.
                options: [SegmentedPicker.Option(nil, "All")]
                    + appCategories.map { SegmentedPicker.Option($0.id, $0.name) },
                selection: $appCategoryID
            )
            .accessibilityLabel(Text("Browse apps by category"))
        }
    }

    // MARK: The grid

    /// **Adaptive columns, not a fixed count.** The detail column is resizable
    /// and the window has a 880-point minimum, so a hard three-up is two cards
    /// of empty space on a narrow window and a wall on a wide one.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Metrics.discoveryCardWidth), spacing: Spacing.margin)]
    }

    @ViewBuilder
    private var grid: some View {
        if let emptyLine {
            Text(emptyLine)
                .font(.system(.callout))
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Spacing.group)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.margin) {
                if tab == .servers {
                    ForEach(cards) { card in
                        DiscoveryServerCard(card: card) { openCard(card) }
                    }
                } else {
                    ForEach(apps) { app in
                        DiscoveryAppCard(app: app) { openApp(app) }
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
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - The bar

/// The page's floating bar.
///
/// **`SegmentedPicker` — the system's own `NSSegmentedControl`, and NOT a
/// `GlassEffectContainer` around it.** §1 says both halves of that: the control
/// Clock, Podcasts and Freeform use is the right instrument for two mutually
/// exclusive halves, and it *brings its own material*, so a container around it
/// or a `.glassEffect` on it is glass on glass. The full profile's tab strip is
/// the same call.
///
/// The container is gone rather than kept around the other two: it exists to
/// merge adjacent glass bodies, and with the picker carrying its own and the
/// field carrying a fill, there was exactly one glass element left in it.
private struct DiscoveryBar: View {
    @Binding var tab: DiscoveryState.Tab
    @Binding var query: String
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: Spacing.base) {
            SegmentedPicker(
                options: DiscoveryState.Tab.allCases.map {
                    SegmentedPicker.Option($0, $0.title)
                },
                selection: $tab
            )
            DiscoverySearchField(query: $query)
            Spacer(minLength: 0)
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
        .frame(maxWidth: 280)
        .background(Palette.surfaceRaised, in: .capsule)
        .specularEdge(in: Capsule())
        .contentShape(.capsule)
        .onTapGesture { isFocused = true }
    }
}
