import CoreGraphics
import Foundation

// MARK: - Arrangements somebody can pick rather than build
//
// docs/CLIPS-PRESENCE.md, Phase 6 (D20). Discord ships one arrangement and a
// Reset; dragging ten widgets into a shape for a different kind of evening is
// work nobody should do twice. So there are four built in, each a complete
// layout rather than a diff — a preset applied over a layout somebody had
// rearranged would otherwise keep half of the old one — and the reader can
// keep their own beside them.

/// A built-in arrangement.
///
/// The raw value is the persistence key and must not change.
public enum OverlayLayoutPreset: String, CaseIterable, Identifiable, Hashable, Sendable, Codable {
    /// Discord's arrangement — what a fresh install gets.
    case standard
    /// The call and nothing else: who is talking, the controls, messages and
    /// clips.
    case minimal
    /// Nothing personal on screen: no conversations, no friends, no toasts, no
    /// activity card — for a stream somebody else is watching.
    case streaming
    /// Somebody else's game: their screen across the middle, the cameras
    /// beside it.
    case watching

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard: "Default"
        case .minimal: "Minimal"
        case .streaming: "Streaming"
        case .watching: "Watching"
        }
    }

    public var summary: String {
        switch self {
        case .standard: "Every widget where Discord puts it."
        case .minimal: "Voice, the controls, messages and clips."
        case .streaming: "Nothing personal: no chat, friends, messages or activity."
        case .watching: "Streams across the middle, cameras beside them."
        }
    }

    public var symbolName: String {
        switch self {
        case .standard: "rectangle.3.group"
        case .minimal: "rectangle.dashed"
        case .streaming: "dot.radiowaves.left.and.right"
        case .watching: "play.rectangle.on.rectangle"
        }
    }

    /// The whole layout this preset is.
    public var layout: OverlayLayout {
        var layout = OverlayLayout.default
        switch self {
        case .standard:
            break
        case .minimal:
            let kept: Set<OverlayWidgetKind> = [.voice, .quickActions, .notifications, .clips]
            for kind in OverlayWidgetKind.allCases {
                layout.setEnabled(kept.contains(kind), for: kind)
            }
        case .streaming:
            let withheld: Set<OverlayWidgetKind> = [.friends, .chat, .notifications, .activity]
            for kind in OverlayWidgetKind.allCases {
                layout.setEnabled(!withheld.contains(kind) && kind.isEnabledByDefault, for: kind)
            }
        case .watching:
            layout.move(.streams, to: CGPoint(x: 0.5, y: 0.5))
            layout.move(.videoTiles, to: CGPoint(x: 0.08, y: 0.70))
            layout.setEnabled(false, for: .chat)
            layout.setEnabled(false, for: .activity)
        }
        return layout
    }

    /// The preset `layout` is exactly, if it is one.
    public static func matching(_ layout: OverlayLayout) -> OverlayLayoutPreset? {
        allCases.first { $0.layout.isEquivalent(to: layout) }
    }
}

/// An arrangement the reader kept.
public struct OverlaySavedLayout: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var layout: OverlayLayout

    public init(id: UUID = UUID(), name: String, layout: OverlayLayout) {
        self.id = id
        self.name = name
        self.layout = layout
    }

    /// The most the reader keeps. A menu of twenty layouts is a menu nobody
    /// reads to the end.
    public static let limit = 5

    /// "Layout 3", the first number not already taken.
    public static func nextName(after saved: [OverlaySavedLayout]) -> String {
        let taken = Set(saved.map(\.name))
        var number = saved.count + 1
        while taken.contains("Layout \(number)") { number += 1 }
        return "Layout \(number)"
    }
}

extension OverlayLayout {
    /// Whether two layouts put every widget in the same state, whichever of
    /// them spelled out a placement the other left to its default.
    ///
    /// **Not `==`.** A stored layout holds only what was ever written and a
    /// preset holds everything, so two arrangements that draw identically can
    /// differ as dictionaries.
    public func isEquivalent(to other: OverlayLayout) -> Bool {
        OverlayWidgetKind.allCases.allSatisfy { kind in
            let lhs = placement(for: kind)
            let rhs = other.placement(for: kind)
            return lhs.isEnabled == rhs.isEnabled
                && lhs.isPinned == rhs.isPinned
                && abs(lhs.centre.x - rhs.centre.x) < 0.0005
                && abs(lhs.centre.y - rhs.centre.y) < 0.0005
        }
    }
}
