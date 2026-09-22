import SwiftUI

// MARK: - The settings window
//
// A source list and a detail pane, hand-split rather than a `NavigationSplitView`.
//
// WHY NOT `NavigationSplitView`, given §1 says the sidebar column's vibrancy IS
// the bleed: because that rule describes the *workspace*, where the sidebar is
// AppKit's and the detail column is opaque. Here both columns share ONE material
// — the source list is the window's own glass and the detail pane is that same
// glass with a scrim over it — and a split view insists on painting its sidebar
// column with a material of its own. The seam is immediately visible, and every
// way of suppressing it reaches under SwiftUI for the visual effect view it
// installed. Two columns and a drag handle is less machinery than that, and it
// is also what the reference does.
//
// The cost of hand-splitting is the divider's behaviour, so this file implements
// it properly: 1:1 tracking, rubber-banding past both limits, and a snap decided
// by the gesture's *projected* rest — a fast flick collapses, a slow drag to the
// same place does not.

struct SettingsView: View {
    @State private var history = SettingsHistory()
    @State private var query = ""
    @State private var sidebar = SidebarWidth()
    /// The column's width when the current drag began. Nil between drags.
    @State private var dragOrigin: CGFloat?
    @Environment(\.motion) private var motion

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: sectionBinding, query: $query)
                .frame(width: sidebar.current)
                .opacity(sidebar.current < 1 ? 0 : 1)

            SettingsDetailPane(
                history: history,
                isSidebarCollapsed: sidebar.isCollapsed,
                toggleSidebar: { withAnimation(motion.reposition) { sidebar.toggle() } }
            )
        }
        .overlay(alignment: .leading) { divider }
        .environment(\.settingsNavigate, SettingsNavigate { history.go(to: $0) })
        // The window is `fullSizeContentView`, so the titlebar is a transparent
        // strip over the content rather than a band above it — but SwiftUI still
        // insets the scene by its height. Taking the top safe area back is what
        // puts the pane's own ten points of margin at the top of the WINDOW
        // instead of thirty-two points down it, and what lets the traffic lights
        // sit over the source list the way the reference's do.
        .ignoresSafeArea(.container, edges: .top)
        .frame(
            minWidth: SettingsMetrics.minWidth,
            minHeight: SettingsMetrics.minHeight
        )
        .settingsWindowChrome()
        .toolbar(removing: .title)
        // A caller that asked for a page gets it — on the first appearance, and
        // on every raise after, since a `Window` scene does not re-appear.
        .onAppear { takePendingSection() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in takePendingSection() }
    }

    /// Moves to the page an outside caller asked for, if one did.
    ///
    /// Through the history, so the back arrow can undo it — the same rule the
    /// source list follows.
    private func takePendingSection() {
        guard let section = SettingsWindow.takePendingSection() else { return }
        guard history.current != section else { return }
        history.go(to: section)
    }

    /// The source list writes through the history rather than to a stored
    /// section, so a click on a row is a move the back arrow can undo.
    private var sectionBinding: Binding<SettingsSection> {
        Binding(get: { history.current }, set: { history.go(to: $0) })
    }

    /// The grab handle between the columns.
    ///
    /// Four points wide with a `.resizeLeftRight` cursor, sitting *over* the
    /// seam rather than taking layout width — a divider that occupies space
    /// makes the source list's width and the pane's origin disagree by its own
    /// thickness, which is exactly the kind of off-by-four that a measured
    /// layout cannot afford.
    private var divider: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(.rect)
            // Never off the window's leading edge, or a collapsed source list is
            // one that cannot be brought back by the gesture that put it away.
            .offset(x: max(0, sidebar.current - 4))
            // `pointerStyle`, not `NSCursor.push`/`pop`. The AppKit pair keeps a
            // stack, and a hover-exit that never arrives — which happens every
            // time the pointer leaves over another window — leaves the resize
            // cursor set for the whole app until something else pushes over it.
            .pointerStyle(.columnResize)
            .gesture(
                // Translation from the width the gesture STARTED at, not the
                // pointer's position in some coordinate space: the handle is
                // eight points wide and travels with the column, so its own
                // space moves under the drag and a location read in it measures
                // nothing useful.
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let origin = dragOrigin ?? sidebar.current
                        if dragOrigin == nil { dragOrigin = origin }
                        sidebar.drag(to: origin + value.translation.width)
                    }
                    .onEnded { value in
                        let origin = dragOrigin ?? sidebar.current
                        dragOrigin = nil
                        let target = sidebar.release(
                            at: origin + value.translation.width,
                            velocity: value.velocity.width
                        )
                        withAnimation(motion.handoff(
                            velocity: value.velocity.width,
                            over: target - sidebar.current
                        )) {
                            sidebar.settle(to: target)
                        }
                    }
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Sidebar width

/// The source list's width, and the rules that govern it.
///
/// A value type with the whole gesture in it, so the view holds one `@State` and
/// the arithmetic is testable without a window.
struct SidebarWidth: Equatable, Sendable {
    /// Narrower than this and a row is an icon and a truncated word, which is
    /// worse than no list at all — so the drag snaps past it in either direction.
    static let collapseThreshold: CGFloat = 120
    static let minimum: CGFloat = 168
    static let maximum: CGFloat = 320

    private(set) var current: CGFloat = SettingsMetrics.sidebarWidth
    /// Where the width returns to when the list is brought back.
    private var restored: CGFloat = SettingsMetrics.sidebarWidth

    var isCollapsed: Bool { current < 1 }

    /// 1:1 with the pointer inside the allowed range, resisted outside it, and
    /// free to reach zero because collapsing is a legitimate destination rather
    /// than an overshoot.
    mutating func drag(to x: CGFloat) {
        current = max(0, Motion.clampWithResistance(
            x, to: Self.minimum...Self.maximum, limit: Self.minimum
        ))
    }

    /// Where the gesture is *going*, not where it stopped.
    func release(at x: CGFloat, velocity: CGFloat) -> CGFloat {
        let projected = Motion.projectedPosition(from: x, velocity: velocity)
        if projected < Self.collapseThreshold { return 0 }
        return min(Self.maximum, max(Self.minimum, projected))
    }

    mutating func settle(to width: CGFloat) {
        current = width
        if width >= Self.minimum { restored = width }
    }

    mutating func toggle() {
        current = isCollapsed ? restored : 0
    }
}

// MARK: - The detail pane

/// The pane is ONE view type and always has been — §1. Every section is a case
/// inside it, never a branch in the caller, so macOS never re-resolves the
/// column split on a selection change.
private struct SettingsDetailPane: View {
    var history: SettingsHistory
    var isSidebarCollapsed: Bool
    var toggleSidebar: () -> Void

    @Environment(\.motion) private var motion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isScrolled = false

    private var section: SettingsSection { history.current }

    var body: some View {
        ScrollView(.vertical) {
            SettingsPaneContent(section: section)
                .padding(.horizontal, SettingsMetrics.cardInset)
                .padding(.bottom, SettingsMetrics.cardInset)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        // `safeAreaBar`, never `safeAreaInset`: only the former registers as a
        // bar, and the registration is the entire reason content passing under
        // the toolbar is treated at all. The failure is invisible at rest —
        // scrolled to the top there is nothing behind the bar to blur.
        .floatingTopBar {
            SettingsToolbar(
                history: history,
                title: isScrolled ? section.title : nil,
                isSidebarCollapsed: isSidebarCollapsed,
                toggleSidebar: toggleSidebar
            )
        }
        // The system's own scroll edge cannot draw this band, and the reason is
        // written up in `Glass.swift`: it samples the WINDOW's backdrop, not the
        // content passing under the bar. Over a translucent settings window that
        // means the band shows a blurred *desktop* — brighter than the pane it
        // crosses, with the rows underneath hidden rather than veiled. The
        // reference's band shows the rows themselves, blurred and darkened, and
        // no scroll-edge style produces that here.
        //
        // So the band is drawn: one glass surface across the top of the pane,
        // tinted, and masked by a gradient so it has no bottom edge at all. It
        // is inside the pane's clip, which is what carries the darkening around
        // the pane's two top corners the way the reference's does.
        // The scrim goes OUTSIDE the bar, so it covers the bar's row too.
        //
        // It used to sit on the scroll view, inside the bar's inset, which left
        // the 72 points under the toolbar showing the bare window — the desktop,
        // brighter than the pane by half again. The bar was then given a scrim of
        // its own to patch that, and a flat rectangle with a hard bottom edge is
        // what the reader saw. One background across the whole pane has no seam
        // to hide.
        .background(SettingsSurface.pane(reducingTransparency: reduceTransparency))
        .overlay(alignment: .top) { scrollEdgeBand }
        // Whether the page has moved at all. A threshold, not the offset: the
        // only reader is a title that is either there or not, and publishing a
        // scroll position per event would invalidate the whole pane on every
        // frame of a scroll.
        // `contentOffset` is measured from the content's origin, and the bar has
        // pushed that origin down by its own height — so at rest the offset is
        // minus the top inset, not zero. Comparing it to the inset is what makes
        // this read "has the page moved" rather than "is the page 72 points
        // down", which is a distinction that costs a title that never appears.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 6
        } action: { _, moved in
            isScrolled = moved
        }
        .clipShape(.settingsRect(SettingsMetrics.paneRadius))
        .padding(.vertical, SettingsMetrics.paneInset)
        .padding(.trailing, SettingsMetrics.paneInset)
        .animation(motion.standard, value: section)
    }
}


extension SettingsDetailPane {

    /// The band across the top of the pane.
    ///
    /// A gradient, and every number in it is measured off the reference by
    /// sampling the pane's own left margin — a column that is background at
    /// every scroll offset — at rest and scrolled six clicks:
    ///
    ///   - the darkening is a factor of 0.42 at the top edge, which is black at
    ///     57%;
    ///   - it holds full strength for the first 36% of the band — 26 points of
    ///     72 — and then ramps;
    ///   - and it is gone at the band's foot, with **no bottom edge at all**.
    ///
    /// That last point is the whole correction. What this window drew before was
    /// the pane's own scrim painted flat across a 72-point row, which put a hard
    /// horizontal seam a third of the way down the pane — visible at rest, with
    /// nothing scrolled, and the thing that reads as "too tall".
    ///
    /// It is inside the pane's clip, which is what carries the darkening around
    /// the pane's two top corners the way the reference's does.
    ///
    /// **Only while the page has moved.** At rest the reference's band is its
    /// window's bare material and reads *lighter* than the pane, not darker — so
    /// a darkening that were always on would be wrong in the one state the
    /// reader sees most.
    fileprivate var scrollEdgeBand: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(SettingsSurface.scrollEdgeTint), location: 0),
                .init(color: .black.opacity(SettingsSurface.scrollEdgeTint), location: 0.36),
                .init(color: .clear, location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: SettingsMetrics.toolbarBandHeight)
        .opacity(isScrolled ? 1 : 0)
        .animation(motion.fade, value: isScrolled)
        .allowsHitTesting(false)
    }
}

// MARK: - The toolbar

private struct SettingsToolbar: View {
    var history: SettingsHistory
    /// The pane's name, shown only once the page has moved — the reference's
    /// own behaviour, and the reason it works is that the name is already the
    /// selected row two inches to the left until the page scrolls away from it.
    var title: String?
    var isSidebarCollapsed: Bool
    var toggleSidebar: () -> Void

    @Environment(\.motion) private var motion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 12.5) {
            // The reference moves the history control to the trailing end when
            // the source list is away, because the leading end then belongs to
            // the window's own buttons and a control sitting under them reads as
            // theirs.
            if isSidebarCollapsed {
                Spacer(minLength: 0)
                // Only when the list is away. A toggle that is present whether
                // or not there is anything to bring back is a fourth control in
                // a row that has three, and the reference has none at all —
                // its source list cannot be collapsed.
                SettingsSidebarButton(action: toggleSidebar)
            }
            SettingsHistoryControl(history: history)
            if let title {
                Text(title)
                    .font(SettingsType.sectionHeader)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .transition(.opacity)
            }
            if !isSidebarCollapsed { Spacer(minLength: 0) }
            SettingsPaneAction(section: history.current)
        }
        .animation(motion.fade, value: title)
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .frame(height: SettingsMetrics.toolbarItemHeight)
        .padding(.top, 12)
        .padding(.bottom, SettingsMetrics.toolbarBandHeight - 12 - SettingsMetrics.toolbarItemHeight)
        .frame(maxWidth: .infinity)
        // Not a scrim rectangle. The bar is a floating capsule on a row,
        // and the band across the top of the pane is the SCROLL EDGE, not a
        // rectangle drawn here.
        //
        // A scrim on this view used to be the fix for a band that read lighter
        // than the pane it crossed. That was the wrong reading of the reference:
        // measured, the reference's own band is lighter than its pane by nearly
        // two to one — 62 against 33 — because its band is the window's bare
        // material with nothing but the scroll edge over it. Painting the pane's
        // scrim here instead drew a flat 72-point rectangle with a hard bottom
        // edge, which is the "too tall" band this window shipped with.
    }
}

/// Back and forward in one capsule, with a hairline between them.
///
/// The pair is a single item rather than two, because two capsules of one glyph
/// each read as two unrelated controls and the reference's do not. Both halves
/// move through `SettingsHistory`, which every way into a section already goes
/// through — the source list, a navigation row and the search results alike.
///
/// **A half that leads nowhere is disabled, not hidden.** The reference keeps
/// both glyphs at the same faint value whether or not they lead anywhere, and a
/// capsule that changed width as the history filled would move the title beside
/// it on every navigation.
private struct SettingsHistoryControl: View {
    var history: SettingsHistory

    var body: some View {
        HStack(spacing: 0) {
            Half(
                symbol: "chevron.left",
                label: "Back",
                isEnabled: history.canGoBack,
                action: history.goBack
            )
            Color.white.opacity(0.20)
                .frame(width: SettingsMetrics.hairline, height: 12)
            Half(
                symbol: "chevron.right",
                label: "Forward",
                isEnabled: history.canGoForward,
                action: history.goForward
            )
        }
        // The capsule is wider than the two hit targets inside it — measured at
        // 63 against buttons totalling 57 — which is what stops the glyphs
        // sitting on its rim.
        .padding(.horizontal, 3)
        .glassEffect(.regular, in: .capsule)
    }

    private struct Half: View {
        var symbol: String
        var label: String
        var isEnabled: Bool
        var action: () -> Void

        @Environment(\.motion) private var motion
        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    // Quiet at rest, like the reference's. The affordance is
                    // carried by the hover, which costs nothing until the
                    // pointer is on it — and a half with nowhere to go never
                    // takes it.
                    .foregroundStyle(isHovered && isEnabled ? Ink.primary : Ink.quaternary)
                    .frame(width: SettingsMetrics.toolbarButtonSide,
                           height: SettingsMetrics.toolbarItemHeight)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .onHover { isHovered = $0 }
            .animation(motion.hover, value: isHovered)
            .accessibilityLabel(label)
        }
    }
}

/// Brings the source list back. Shown only while it is away.
struct SettingsSidebarButton: View {
    var action: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isHovered ? Ink.primary : Ink.quaternary)
                .frame(width: SettingsMetrics.toolbarButtonSide + 6,
                       height: SettingsMetrics.toolbarItemHeight)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(motion.hover, value: isHovered)
        .glassEffect(.regular, in: .capsule)
        .accessibilityLabel("Show sections")
    }
}

/// The one action a pane offers, in the toolbar's trailing slot.
private struct SettingsPaneAction: View {
    var section: SettingsSection
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch section {
        case .account:
            action("Sign Out", symbolName: "rectangle.portrait.and.arrow.right") {
                model.signOut()
            }
        case .diagnostics:
            action("Reveal Logs", symbolName: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([CrashReporter.reportDirectory])
            }
        case .connectedApps:
            action("Refresh", symbolName: "arrow.clockwise") {
                model.sessionController.refreshConnectedApps()
            }
        case .about:
            action("Release Notes", symbolName: "doc.text") {
                if let url = URL(string: "https://github.com/wingcord/wingcord/releases") {
                    openURL(url)
                }
            }
        default:
            // Every pane keeps the slot's *height* so the band does not change
            // depth as the selection moves, but nothing is drawn in it.
            Color.clear.frame(width: 0, height: SettingsMetrics.toolbarItemHeight)
        }
    }

    private func action(
        _ title: String,
        symbolName: String,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            HStack(spacing: Spacing.tight + 2) {
                Image(systemName: symbolName)
                    .font(.system(size: 12, weight: .medium))
                Text(title).font(SettingsType.toolbarLabel)
            }
            .foregroundStyle(Ink.primary)
            .padding(.horizontal, 14)
            .frame(height: SettingsMetrics.toolbarItemHeight)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}
