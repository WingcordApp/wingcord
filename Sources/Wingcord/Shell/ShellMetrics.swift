import CoreGraphics
import SwiftUI

// MARK: - The window shell
//
// The window is no longer a system split view with a toolbar. It is one picture
// (the ground: a theme or the reader's wallpaper) under everything, a sidebar
// panel over it, the detail column beside the panel, and two header rows we draw
// ourselves level with the traffic lights. Every number those pieces have to
// agree on lives here, so the panel, the header, the traffic lights and the
// detail's inset cannot drift apart.
//
// **Why not `NavigationSplitView` any more.** Hiding its sidebar resizes the
// detail on every frame of the animation, and the transcript re-lays out every
// row at every intermediate width — which is the lag. Here the sidebar only
// slides; the detail changes width once. And a hidden-title-bar window lets a
// SwiftUI control level with the traffic lights take clicks (measured
// 2026-10-13), so the chrome no longer has to be toolbar items.

/// Where the sidebar sits.
nonisolated enum SidebarStyle: String, CaseIterable, Identifiable, Sendable {
    /// A glass panel inset from the window's edges, the wallpaper running round
    /// it — Craft's floating sidebar, and macOS 26's own.
    case floating
    /// A column flush with the window's leading edge, top and foot.
    case docked

    var id: Self { self }

    var label: String {
        switch self {
        case .floating: "Floating"
        case .docked: "Docked"
        }
    }
}

/// One list the sidebar swipes to (REDESIGN.md R8).
nonisolated enum SidebarPage: Hashable, Sendable {
    /// The conversations — direct messages and groups — across the whole panel.
    case messages
    /// The rail beside the open server's channels: the two-page layout's second.
    case servers
    /// Every server by name, the rack expanded: the three-stop layout's middle.
    case serverList
    /// The open server's channels on their own: the three-stop layout's last.
    case channels

    var title: String {
        switch self {
        case .messages: "Messages"
        case .servers, .serverList: "Servers"
        case .channels: "Channels"
        }
    }

    var symbolName: String {
        switch self {
        case .messages: "bubble.left.and.bubble.right.fill"
        case .servers, .serverList: "square.stack.3d.up.fill"
        case .channels: "number"
        }
    }
}

/// How many pages the sidebar swipes between (REDESIGN.md R8, Q2).
nonisolated enum SidebarPageLayout: String, CaseIterable, Identifiable, Sendable {
    /// Messages | Servers — the rail beside the channels on the second page.
    case twoPages
    /// Messages | Servers | Channels — the servers named in a list of their
    /// own, and the channels a swipe past it.
    case threeStops

    var id: Self { self }

    var pages: [SidebarPage] {
        switch self {
        case .twoPages: [.messages, .servers]
        case .threeStops: [.messages, .serverList, .channels]
        }
    }

    var label: String {
        switch self {
        case .twoPages: "Two Pages"
        case .threeStops: "Three Stops"
        }
    }
}

nonisolated enum ShellMetrics {
    // MARK: The top band

    /// How tall the band holding the traffic lights and both header rows is:
    /// twice the centre line, so a row this tall centres on `headerCenterY`.
    static let headerHeight: CGFloat = headerCenterY * 2

    /// The traffic lights' centre, from the window's top — moved down from the
    /// system's 16 so they sit inside a floating panel the way they sit in
    /// Craft's and in macOS 26's own sidebars. The title-bar view is 32 points
    /// tall, so 25 keeps a 14-point button inside it.
    static let trafficLightsCenterY: CGFloat = 25

    /// Where both header rows centre their controls.
    static let headerCenterY: CGFloat = trafficLightsCenterY

    /// The close button's leading edge, by style.
    static func trafficLightsLeading(_ style: SidebarStyle) -> CGFloat {
        style == .floating ? floatingInset + 14 : 20
    }

    /// Between one traffic light's leading edge and the next one's.
    static let trafficLightSpacing: CGFloat = 20

    /// What the three lights span, from the first one's leading edge.
    static let trafficLightsSpan: CGFloat = trafficLightSpacing * 2 + 14

    /// How far from the window's leading edge a header row's own content may
    /// begin without touching the lights.
    static func trafficLightsClearance(_ style: SidebarStyle) -> CGFloat {
        trafficLightsLeading(style) + trafficLightsSpan + 14
    }

    // MARK: The sidebar

    /// How far a floating panel sits in from the window's leading edge and
    /// its foot.
    static let floatingInset: CGFloat = 8

    /// How far a floating panel sits below the window's top edge. **Less than
    /// the sides**: the traffic lights cannot go below 25 without leaving the
    /// 32-point title bar, and a 34-point control centred there has to clear
    /// the panel's top edge — Craft's panel sits closer to the top than to the
    /// sides for the same reason.
    static let floatingTopInset: CGFloat = 5

    static let sidebarMinWidth: CGFloat = 260
    static let sidebarIdealWidth: CGFloat = 320
    static let sidebarMaxWidth: CGFloat = 440

    /// The panel while a takeover has the detail column: the rail and the
    /// traffic lights, nothing else.
    static let takeoverWidth: CGFloat = 92

    /// A floating panel's corner. Measured against the window's own on macOS
    /// 27 and settled by eye in the running app; see REDESIGN.md.
    static let floatingPanelRadius: CGFloat = 18

    static func clampedSidebarWidth(_ width: CGFloat) -> CGFloat {
        min(sidebarMaxWidth, max(sidebarMinWidth, width.rounded()))
    }

    /// The header controls' diameter. Two points under the system toolbar
    /// item's 36, so a control centred on the traffic lights stays inside a
    /// floating panel's top edge.
    static let headerControl: CGFloat = 34

    /// The face in the detail header's title capsule.
    static let titleAvatar: CGFloat = 22

    /// The glyph inside a header control.
    static let headerGlyph: CGFloat = 15

    /// The hit strip on the panel's trailing edge that resizes it.
    static let resizeHandleWidth: CGFloat = 8
}

/// The shell's geometry for one state of the window. A value, so the panel, the
/// detail column and the traffic lights all read the same answer.
nonisolated struct ShellLayout: Equatable, Sendable {
    var style: SidebarStyle
    var sidebarWidth: CGFloat
    var isSidebarShown: Bool
    /// A takeover (the join gate, discovery) narrows the panel to the rail.
    var isTakenOver: Bool = false

    /// How far the panel sits in from the window's leading edge and foot.
    var panelInset: CGFloat { style == .floating ? ShellMetrics.floatingInset : 0 }

    /// How far the panel sits below the window's top edge.
    var panelTopInset: CGFloat { style == .floating ? ShellMetrics.floatingTopInset : 0 }

    /// The sidebar header's height inside the panel: twice the distance from
    /// the panel's top edge to the lights' centre, so its row centres on them.
    ///
    /// **Not the band less the inset.** That was 45 for a floating panel —
    /// from 5 to 50 — which centred the row's controls at 27.5, two and a
    /// half points under the lights (measured: 28.25 against 24.75).
    var sidebarHeaderHeight: CGFloat { (ShellMetrics.headerCenterY - panelTopInset) * 2 }

    /// The panel's own width.
    var panelWidth: CGFloat { isTakenOver ? ShellMetrics.takeoverWidth : sidebarWidth }

    /// Where the detail column begins, from the window's leading edge.
    var detailLeading: CGFloat {
        guard isSidebarShown else { return 0 }
        return panelInset + panelWidth
    }

    /// How far the panel travels to be out of sight — its own width, its inset,
    /// and the shadow a floating one throws.
    var hiddenOffset: CGFloat { -(panelInset + panelWidth + 32) }

    /// How much room the detail header keeps at its leading edge for the traffic
    /// lights, which stay put when the sidebar goes.
    var detailHeaderLeadingClearance: CGFloat {
        isSidebarShown ? 0 : ShellMetrics.trafficLightsClearance(style)
    }

    /// Where a page's header title starts when no rail stands between it and
    /// the traffic lights: just past them, in the panel's own space.
    var pageTitleLeading: CGFloat {
        ShellMetrics.trafficLightsClearance(style) - panelInset + Spacing.tight
    }
}
