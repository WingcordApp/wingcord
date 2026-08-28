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
    @State private var section: SettingsSection = .general
    @State private var query = ""
    @State private var sidebar = SidebarWidth()
    /// The column's width when the current drag began. Nil between drags.
    @State private var dragOrigin: CGFloat?
    @Environment(\.motion) private var motion

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $section, query: $query)
                .frame(width: sidebar.current)
                .opacity(sidebar.current < 1 ? 0 : 1)

            SettingsDetailPane(
                section: section,
                isSidebarCollapsed: sidebar.isCollapsed,
                toggleSidebar: { withAnimation(motion.reposition) { sidebar.toggle() } }
            )
        }
        .overlay(alignment: .leading) { divider }
        .environment(\.settingsNavigate, SettingsNavigate { section = $0 })
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
    var section: SettingsSection
    var isSidebarCollapsed: Bool
    var toggleSidebar: () -> Void

    @Environment(\.motion) private var motion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isScrolled = false

    var body: some View {
        ScrollView(.vertical) {
            SettingsPaneContent(section: section)
                .padding(.horizontal, SettingsMetrics.cardInset)
                .padding(.bottom, SettingsMetrics.cardInset)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        // The scrim goes HERE, on the scroll view, not outside the bar. The
        // scroll-edge band is drawn from what is behind the scroll view, so a
        // scrim applied outside leaves the band sampling the bare window
        // material — and the band then reads *lighter* than the pane it is
        // supposed to be part of. Measured: 43 against a pane of 39.
        .background(SettingsSurface.pane(reducingTransparency: reduceTransparency))
        // `safeAreaBar`, never `safeAreaInset`: only the former registers as a
        // bar, and the registration is the entire reason content passing under
        // the toolbar is treated at all. The failure is invisible at rest —
        // scrolled to the top there is nothing behind the bar to blur.
        .floatingTopBar {
            SettingsToolbar(
                section: section,
                title: isScrolled ? section.title : nil,
                isSidebarCollapsed: isSidebarCollapsed,
                toggleSidebar: toggleSidebar
            )
        }
        .hardScrollEdges(.top)
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

// MARK: - The toolbar

private struct SettingsToolbar: View {
    var section: SettingsSection
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
            if isSidebarCollapsed { Spacer(minLength: 0) }
            SettingsHistoryControl(showSidebar: toggleSidebar)
            if let title {
                Text(title)
                    .font(SettingsType.sectionHeader)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .transition(.opacity)
            }
            if !isSidebarCollapsed { Spacer(minLength: 0) }
            SettingsPaneAction(section: section)
        }
        .animation(motion.fade, value: title)
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .frame(height: SettingsMetrics.toolbarItemHeight)
        .padding(.top, 12)
        .padding(.bottom, SettingsMetrics.toolbarBandHeight - 12 - SettingsMetrics.toolbarItemHeight)
        .frame(maxWidth: .infinity)
        // The SAME scrim the pane carries, and for the same reason.
        //
        // The scroll-edge band is drawn from the window's material, not from the
        // view behind the scroll view — so without this the band is the bare
        // ground (measured: 24 against a pane of 16) and reads as a lighter
        // strip across the top of the pane, at rest, with nothing scrolled. With
        // it the band is the pane's own tone and the seam disappears, which is
        // exactly what the reference does: its band and its pane measure within
        // two of each other in both states.
        //
        // It is the bar's background rather than an overlay on the pane because
        // the band IS the bar: the system decides the blur, the bar decides what
        // colour it is.
        .background(SettingsSurface.pane(reducingTransparency: reduceTransparency))
    }
}

/// Back and forward in one capsule, with a hairline between them.
///
/// The pair is a single item rather than two, because two capsules of one glyph
/// each read as two unrelated controls and the reference's do not. Wingcord has
/// no history stack inside settings yet, so the leading half is wired to the
/// thing a reader actually wants from a control in that position when the source
/// list is gone: bring it back.
private struct SettingsHistoryControl: View {
    var showSidebar: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: showSidebar) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .medium))
                    // Quiet at rest, like the reference's — both of whose glyphs
                    // measure the same faint value whether or not they lead
                    // anywhere. The affordance is carried by the hover, which
                    // costs nothing until the pointer is on it.
                    .foregroundStyle(isHovered ? Ink.primary : Ink.quaternary)
                    .frame(width: SettingsMetrics.toolbarButtonSide,
                           height: SettingsMetrics.toolbarItemHeight)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .animation(motion.hover, value: isHovered)
            .accessibilityLabel("Show sections")

            Color.white.opacity(0.20)
                .frame(width: SettingsMetrics.hairline, height: 12)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Ink.quaternary)
                .frame(width: SettingsMetrics.toolbarButtonSide,
                       height: SettingsMetrics.toolbarItemHeight)
                .accessibilityHidden(true)
        }
        // The capsule is wider than the two hit targets inside it — measured at
        // 63 against buttons totalling 57 — which is what stops the glyphs
        // sitting on its rim.
        .padding(.horizontal, 3)
        .glassEffect(.regular, in: .capsule)
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
