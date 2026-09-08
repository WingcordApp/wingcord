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
    var tab: DiscoveryState.Tab
    /// **A binding, built where the store is.** The setter goes through
    /// `setDiscoveryQuery`, which is what raises the request — and a stored
    /// `(String) -> Void` property is a non-`Sendable` function value where
    /// `TextField` wants a main-actor-isolated one.
    @Binding var query: String
    var categoryID: Int?
    var categories: [DiscoveryCategory]
    var appCategoryID: Int?
    var appCategories: [AppDirectoryCategory]
    var cards: [DiscoveryCard]
    var apps: [ActivityApp]
    var isBusy: Bool
    var emptyLine: String?
    /// Whether there is another page under this one.
    var hasMore: Bool

    var setTab: (DiscoveryState.Tab) -> Void
    var setCategory: (Int?) -> Void
    var setAppCategory: (Int?) -> Void
    var openCard: (DiscoveryCard) -> Void
    var openApp: (ActivityApp) -> Void
    var loadMore: () -> Void
    var dismiss: () -> Void

    @Environment(\.motion) private var motion

    /// Wide enough for three cards at their own minimum with the column's
    /// margins — the measure Channels & Roles already uses for the one page with
    /// something beside its content, and the same reason applies: a grid needs
    /// room a column of prose does not.
    private static let measure = Proportions.surfaceColumnWide

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.group) {
                heading
                chips
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
            DiscoveryBar(
                tab: tab,
                query: $query,
                setTab: setTab,
                dismiss: dismiss
            )
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

    // MARK: The headings row

    /// A scrolling row of capsules, with one travelling pill.
    ///
    /// **Not a second segmented control**, though the shape is close: there are
    /// seventeen primary server headings, and `NSSegmentedControl` packs its
    /// segments to equal widths — seventeen of them is a strip of slivers. A row
    /// that scrolls holds any number of them and keeps the app's own chip shape.
    @ViewBuilder
    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Spacing.base) {
                if tab == .servers {
                    chip("Featured", isOn: categoryID == nil) { setCategory(nil) }
                    ForEach(categories) { category in
                        chip(category.name, isOn: categoryID == category.id) {
                            setCategory(category.id)
                        }
                    }
                } else {
                    chip("All", isOn: appCategoryID == nil) { setAppCategory(nil) }
                    ForEach(appCategories) { category in
                        chip(category.name, isOn: appCategoryID == category.id) {
                            setAppCategory(category.id)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.never)
        // A row of chips is chrome over the page, not content in it, so it
        // clips at the column's edge rather than running under the window's.
        .scrollClipDisabled(false)
    }

    private func chip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.subheadline, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? AnyShapeStyle(Ink.primary) : AnyShapeStyle(Ink.secondary))
                .lineLimit(1)
                .padding(.horizontal, Spacing.snug)
                .padding(.vertical, Spacing.base)
                .background(
                    isOn ? Palette.selectionFill : Palette.hoverFill,
                    in: .rect(cornerRadius: Radius.chip, style: .continuous)
                )
                .contentShape(.rect(cornerRadius: Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(motion.hover, value: isOn)
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

/// The one glass surface on this page.
private struct DiscoveryBar: View {
    var tab: DiscoveryState.Tab
    @Binding var query: String
    var setTab: (DiscoveryState.Tab) -> Void
    var dismiss: () -> Void

    @Environment(\.motion) private var motion
    @Namespace private var pill

    var body: some View {
        GlassEffectContainer(spacing: Spacing.base) {
            HStack(spacing: Spacing.base) {
                tabs
                DiscoverySearchField(query: $query)
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

    /// Two segments and one travelling pill.
    ///
    /// The pill is a tinted region *inside* the control's material rather than a
    /// second glass body — §4 rule 2 — and it travels with
    /// `matchedGeometryEffect`. The system's own `NSSegmentedControl` is the
    /// rule elsewhere and is wrong here for the reason §1 states about it: it
    /// brings its own material, and inside a `GlassEffectContainer` that is
    /// glass on glass.
    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(DiscoveryState.Tab.allCases, id: \.self) { value in
                Button { setTab(value) } label: {
                    Text(value.title)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(
                            tab == value ? AnyShapeStyle(Ink.primary) : AnyShapeStyle(Ink.secondary)
                        )
                        .padding(.horizontal, Spacing.snug)
                        .frame(height: Metrics.control)
                        .contentShape(.capsule)
                        .background {
                            if tab == value {
                                Capsule()
                                    .fill(Palette.selectionFill)
                                    .matchedGeometryEffect(id: "discovery.tab", in: pill)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == value ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(3)
        .frame(height: Metrics.control + Spacing.base)
        .glassEffect(.regular, in: .capsule)
        .animation(motion.glassMorph, value: tab)
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
