import CoreGraphics
import Foundation

// MARK: - Where the overlay's widgets sit
//
// **Stored normalised and resolved against the surface every time**, which is
// the one thing Discord's own overlay does that a Mac build needs even more
// than Windows does: the game can move between displays with different sizes
// and different scale factors in the middle of a session, and a layout stored
// in points would put the toolbar off-screen the moment it did.
//
// The normalisation is a **centre point**, not a rect, and that is a deliberate
// difference from the reference. A normalised rect stretches: a toolbar stored
// as 0.3–0.7 of the width would be 420 points wide on one display and 700 on
// another, which is a toolbar that changes size when you unplug a monitor. A
// normalised centre with a fixed point size keeps a control the size the
// pointer expects and still keeps it where the reader put it — centred stays
// centred, and hard against the right edge stays hard against the right edge.

/// One thing the overlay can draw.
///
/// The raw value is the persistence key and must not change.
///
/// **The declaration order IS the z-order**, because `visibleWidgets` returns
/// the list in `allCases` order and the scene stacks it. Discord stores a
/// `zIndex` per widget; a stored one is a number two widgets can tie on and a
/// reader can never see, where an ordering written here is settled at compile
/// time and reads as what it is. Panels first, chrome last: a chat window that
/// covered the toolbar would hide the mute button behind the thing somebody
/// opened in order to keep playing.
public enum OverlayWidgetKind: String, CaseIterable, Hashable, Sendable, Codable, Identifiable {
    /// Friends, conversations and rooms worth joining — the reading surface.
    case friends
    /// One conversation, whole: transcript, embeds and composer.
    case chat
    /// Screen shares in the call, as tiles.
    case streams
    /// Cameras in the call, as tiles, with a checkbox choosing which show.
    case videoTiles
    /// Who is in the voice channel, and who is talking.
    case voice
    /// What the reader is showing as their activity right now, and the
    /// switches that change it — Phase 6 (docs/CLIPS-PRESENCE.md, D20).
    case activity
    /// What the machine is spending — processor, graphics, memory, heat. A
    /// game's own frame rate is not readable from outside it, so it is not
    /// here.
    case performance
    /// The call's own controls — mute, deafen, camera, share, disconnect.
    case quickActions
    /// Toasts for messages that arrive while a game is in front.
    case notifications
    /// The clip that was just taken, and the keybind reminder behind it.
    case clips

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .friends: "Friends"
        case .chat: "Chat"
        case .streams: "Streams"
        case .videoTiles: "Video Tiles"
        case .voice: "Voice"
        case .activity: "Activity"
        case .performance: "Performance"
        case .quickActions: "Controls"
        case .notifications: "Notifications"
        case .clips: "Clips"
        }
    }

    /// Where it starts life, as a normalised centre.
    ///
    /// Chosen to match the arrangement Discord ships, which is the arrangement
    /// people who have used one will look for: controls top centre, voice down
    /// the left, notifications top left.
    ///
    /// **The four added later were placed by photographing them, not by
    /// reasoning about them.** Streams began at `(0.86, 0.72)` — the reference's
    /// own bottom-right — and the first capture of the two together showed it
    /// sitting across the foot of the Friends panel, because that panel is 468
    /// points tall and the reference has no sidebar open in the shot the corner
    /// came from. Eight widgets cannot all miss each other on one screen; what
    /// has to miss is the pair that are up at the same time, and Friends and
    /// Streams are that pair.
    public var defaultCentre: CGPoint {
        switch self {
        case .friends: CGPoint(x: 0.88, y: 0.50)
        case .chat: CGPoint(x: 0.38, y: 0.52)
        case .streams: CGPoint(x: 0.63, y: 0.82)
        case .videoTiles: CGPoint(x: 0.07, y: 0.76)
        case .voice: CGPoint(x: 0.08, y: 0.40)
        // Beside the controls, clear of the corner's own buttons.
        case .activity: CGPoint(x: 0.74, y: 0.08)
        // Under the corner's buttons, where a frame counter is looked for,
        // and above the top of the Friends panel.
        case .performance: CGPoint(x: 0.92, y: 0.16)
        case .quickActions: CGPoint(x: 0.5, y: 0.06)
        case .notifications: CGPoint(x: 0.14, y: 0.08)
        case .clips: CGPoint(x: 0.88, y: 0.88)
        }
    }

    /// Whether it survives into the locked state by default.
    ///
    /// **Pinning is not a favourite.** It is the declaration that a widget is
    /// visible while the overlay is asleep and the reader is playing — which is
    /// the whole point of the voice panel and the notification toast, and
    /// exactly wrong for a toolbar nobody can click.
    ///
    /// The three reading surfaces are unpinned for that reason and not as a
    /// preference: a roster, a transcript and a composer are things somebody
    /// *reads and types into*, and there is no reading a transcript that
    /// cannot take a click. The two tile widgets are pinned, because watching
    /// somebody's screen while you play is the entire point of them.
    ///
    /// The activity card is unpinned for the same reason as the controls are
    /// asleep: its point is the switches on it. The meter is pinned, because a
    /// meter you can only see with the game paused measures nothing.
    public var isPinnedByDefault: Bool {
        switch self {
        case .quickActions, .friends, .chat, .activity: false
        case .streams, .videoTiles, .voice, .notifications, .clips, .performance: true
        }
    }

    /// Whether a fresh install draws it at all.
    ///
    /// **Only the meter starts off.** It samples the machine once a second for
    /// as long as it is up, and a number nobody asked for over a game is
    /// clutter — Discord's own performance widget is a debug surface.
    public var isEnabledByDefault: Bool {
        self != .performance
    }

    /// Whether pinning this one is even offered.
    ///
    /// **Two are not, and it is not a preference.** Pinning means "draw this
    /// while the overlay is asleep", and a sleeping overlay is click-through by
    /// construction — only the click zones answer, and neither of these is one.
    /// A control that cannot work is worse than an absent one, so the switch
    /// that would produce it is not drawn at all.
    ///
    /// - The **controls** would be five buttons nobody can press.
    /// - The **chat window** is worse, because it is the largest surface here: a
    ///   transcript that cannot be scrolled and a composer that cannot be typed
    ///   into, holding five hundred points of opaque reading surface over a
    ///   match. Everything that makes it worth having needs a click.
    ///
    /// The other reading surface keeps its pin, and the difference is real
    /// rather than a line drawn somewhere: the sidebar is a **roster**. Who is
    /// online and who is in a room is legible at a glance and complete without
    /// interaction, which is the same thing the voice widget is pinned for.
    public var canBePinned: Bool {
        self != .quickActions && self != .chat
    }
}

/// One widget's place on the surface.
public struct OverlayPlacement: Hashable, Sendable, Codable {
    /// The widget's centre, in the unit square. `(0,0)` is the top left.
    public var centre: CGPoint
    /// Whether it is drawn while the overlay is locked.
    public var isPinned: Bool
    /// Whether the reader has switched it off entirely.
    public var isEnabled: Bool

    public init(centre: CGPoint, isPinned: Bool, isEnabled: Bool = true) {
        self.centre = OverlayPlacement.clamped(centre)
        self.isPinned = isPinned
        self.isEnabled = isEnabled
    }

    /// A centre is always inside the surface.
    ///
    /// **Clamped on the way in, not on the way out.** A widget dragged past the
    /// edge and released has to come back; storing the out-of-range value and
    /// correcting it at draw time means the *stored* layout is wrong, and the
    /// next resolution change resolves it from the wrong number.
    static func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), 1),
            y: min(max(point.y, 0), 1)
        )
    }
}

/// Every widget's placement, and the arithmetic that puts them on a surface.
public struct OverlayLayout: Hashable, Sendable, Codable {

    public private(set) var placements: [OverlayWidgetKind: OverlayPlacement]

    /// The arrangement a fresh install gets.
    public static var `default`: OverlayLayout {
        OverlayLayout(
            placements: Dictionary(
                uniqueKeysWithValues: OverlayWidgetKind.allCases.map { kind in
                    (kind, OverlayPlacement(
                        centre: kind.defaultCentre,
                        isPinned: kind.isPinnedByDefault,
                        isEnabled: kind.isEnabledByDefault
                    ))
                }
            )
        )
    }

    public init(placements: [OverlayWidgetKind: OverlayPlacement] = [:]) {
        self.placements = placements
    }

    public func placement(for kind: OverlayWidgetKind) -> OverlayPlacement {
        var placement = placements[kind]
            ?? OverlayPlacement(
                centre: kind.defaultCentre,
                isPinned: kind.isPinnedByDefault,
                isEnabled: kind.isEnabledByDefault
            )
        // **Normalised on the way out as well as refused on the way in**, so a
        // layout stored by a build that allowed it cannot resurrect a pin the
        // reader now has no control to clear.
        if !kind.canBePinned { placement.isPinned = false }
        return placement
    }

    // MARK: Resolving

    /// Where `kind` goes on a surface of `size`, given how big it wants to be.
    ///
    /// **Kept whole on the surface.** The centre is nudged so the widget's own
    /// box fits — a panel whose centre is at `x: 0.98` would otherwise hang
    /// nine tenths of itself off the right edge, and a widget you cannot reach
    /// is a widget you cannot drag back.
    public func frame(
        for kind: OverlayWidgetKind,
        size widgetSize: CGSize,
        in surface: CGSize
    ) -> CGRect {
        let centre = placement(for: kind).centre
        // A widget larger than the surface is pinned to the origin rather than
        // centred off both edges.
        let halfWidth = min(widgetSize.width, surface.width) / 2
        let halfHeight = min(widgetSize.height, surface.height) / 2
        let x = min(max(centre.x * surface.width, halfWidth), surface.width - halfWidth)
        let y = min(max(centre.y * surface.height, halfHeight), surface.height - halfHeight)
        return CGRect(
            x: x - widgetSize.width / 2,
            y: y - widgetSize.height / 2,
            width: widgetSize.width,
            height: widgetSize.height
        )
    }

    /// The normalised centre a point on the surface corresponds to.
    public static func normalised(_ point: CGPoint, in surface: CGSize) -> CGPoint {
        guard surface.width > 0, surface.height > 0 else { return .zero }
        return OverlayPlacement.clamped(
            CGPoint(x: point.x / surface.width, y: point.y / surface.height)
        )
    }

    // MARK: Editing

    public mutating func move(_ kind: OverlayWidgetKind, to centre: CGPoint) {
        var placement = placement(for: kind)
        placement.centre = OverlayPlacement.clamped(centre)
        placements[kind] = placement
    }

    public mutating func setPinned(_ pinned: Bool, for kind: OverlayWidgetKind) {
        guard kind.canBePinned else { return }
        var placement = placement(for: kind)
        placement.isPinned = pinned
        placements[kind] = placement
    }

    public mutating func setEnabled(_ enabled: Bool, for kind: OverlayWidgetKind) {
        var placement = placement(for: kind)
        placement.isEnabled = enabled
        placements[kind] = placement
    }

    /// The widgets that should be drawn right now, in a stable order.
    ///
    /// The rule that decides everything about the locked state, and it is one
    /// line: **a locked overlay draws only what is pinned.**
    ///
    /// - Parameter hidden: widgets withheld whatever the layout says —
    ///   Streamer Mode's "Hide overlay widgets". A layer over the layout rather
    ///   than an edit to it, so turning Streamer Mode off puts back exactly
    ///   what was there.
    public func visibleWidgets(
        locked: Bool, hiding hidden: Set<OverlayWidgetKind> = []
    ) -> [OverlayWidgetKind] {
        OverlayWidgetKind.allCases.filter { kind in
            guard !hidden.contains(kind) else { return false }
            let placement = placement(for: kind)
            guard placement.isEnabled else { return false }
            return locked ? placement.isPinned : true
        }
    }
}
