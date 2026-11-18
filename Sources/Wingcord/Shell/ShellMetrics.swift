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
        case .threeStops: "Three Pages"
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

    /// Where a header row's content begins in full screen, where the lights
    /// are not on the window: the row's own margin and nothing else.
    static func fullScreenClearance(_ style: SidebarStyle) -> CGFloat {
        (style == .floating ? floatingInset : 0) + Spacing.snug
    }

    /// The narrowest the sidebar header's server name may get before the
    /// sidebar toggle folds into the + menu to make room (#17): about ten
    /// characters, with the server's mark and the chevron.
    static let minimumHeaderTitleWidth: CGFloat = 130

    /// What the sidebar header's trailing controls take: the toggle, the
    /// create menu, the gaps between them and the row's own trailing padding.
    static let headerTrailingReserve: CGFloat = headerControl + 56 + Spacing.base * 2 + 10

    /// What folding the toggle away gives back: its width and one gap.
    static let foldedToggleSaving: CGFloat = headerControl + Spacing.base

    // MARK: The sidebar

    /// How far a floating panel sits in from the window's edges — the same on
    /// every side.
    ///
    /// **One inset, so the corners can be concentric** (Alex, 2026-11-16: "the
    /// whole top part has to be fixed"). The sides used to stand at 8 and the
    /// top at 5 — the traffic lights cannot go below 25 without leaving the
    /// 32-point title bar, and a 34-point control centred there has to clear
    /// the panel's top edge — and no single rounded corner is concentric with
    /// the window's across two different gaps. Now the sides come in to the
    /// top's 5, and the corner is the window's own less that (`SidebarPanel`).
    ///
    /// **Eight was tried and taken back** (Alex, 2026-11-18): Craft's gap needs
    /// the header controls down to 30, and at 30 the icons on both header rows
    /// read as too small. The controls' size wins over the gap.
    static let floatingInset: CGFloat = 5

    /// How far a floating panel sits below the window's top edge.
    static let floatingTopInset: CGFloat = floatingInset

    static let sidebarMinWidth: CGFloat = 260
    static let sidebarIdealWidth: CGFloat = 320
    static let sidebarMaxWidth: CGFloat = 440

    /// The panel while a takeover has the detail column: the rail and the
    /// traffic lights, nothing else.
    static let takeoverWidth: CGFloat = 92

    /// The smallest corner a floating panel may have, where the system cannot
    /// say what the window's is. The panel's corner is otherwise the window's
    /// own less the inset (`ConcentricRectangle`): the window's corner is 16
    /// on macOS 27.3 and was rounder before — a fixed 18, measured against
    /// the older one, came out rounder than the window it sits in, with a
    /// wedge of gap at every corner (Image 24).
    static let floatingPanelMinimumRadius: CGFloat = 8

    static func clampedSidebarWidth(_ width: CGFloat) -> CGFloat {
        min(sidebarMaxWidth, max(sidebarMinWidth, width.rounded()))
    }

    /// The header controls' diameter. Two points under the system toolbar
    /// item's 36, so a control centred on the traffic lights stays inside a
    /// floating panel's top edge. (30, with an 8-point inset, made the icons
    /// too small — Alex, 2026-11-18.)
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
    /// The window is in full screen, where the traffic lights are not on it
    /// and their room goes to the header's own controls.
    var isFullScreen: Bool = false

    /// How far from the window's leading edge a header row's content may
    /// begin: past the lights, or — in full screen, with no lights — at the
    /// row's own margin.
    var lightsClearance: CGFloat {
        isFullScreen
            ? ShellMetrics.fullScreenClearance(style)
            : ShellMetrics.trafficLightsClearance(style)
    }

    /// Whether the sidebar toggle folds into the + menu, so the server's name
    /// has room for about ten characters (#17). A 270-point sidebar left the
    /// name 62 points: its mark, one letter and the chevron.
    var foldsSidebarToggle: Bool {
        let room = panelWidth - pageTitleLeading - ShellMetrics.headerTrailingReserve
        return room < ShellMetrics.minimumHeaderTitleWidth
    }

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
        isSidebarShown ? 0 : lightsClearance
    }

    /// Where a page's header title starts when no rail stands between it and
    /// the traffic lights: just past them, in the panel's own space — or, in
    /// full screen, where the lights are not, at the row's own margin.
    var pageTitleLeading: CGFloat {
        isFullScreen
            ? Spacing.snug
            : ShellMetrics.trafficLightsClearance(style) - panelInset + Spacing.tight
    }
}
