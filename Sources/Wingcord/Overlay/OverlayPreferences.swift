import CoreGraphics
import Foundation

// MARK: - The overlay's own vocabulary
//
// Small closed sets, stored by name rather than by ordinal so reordering a case
// cannot silently change what an existing preference means — the rule the rest
// of `AppSettings` already follows.

/// When a name is drawn beside an avatar in the voice widget.
///
/// The three Discord offers, and they are the right three: a roster of twelve
/// names covers a game, a roster of none is unreadable when two people talk at
/// once, and the middle answer is the one most people want.
enum OverlayNameDisplay: String, CaseIterable, Identifiable, Sendable, Codable {
    case always
    case whileSpeaking
    case never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .always: "Always"
        case .whileSpeaking: "While speaking"
        case .never: "Never"
        }
    }

    var symbolName: String {
        switch self {
        case .always: "textformat"
        case .whileSpeaking: "waveform"
        case .never: "textformat.slash"
        }
    }
}

/// How big a face is in the voice widget.
enum OverlayAvatarSize: String, CaseIterable, Identifiable, Sendable, Codable {
    case small
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: "Small"
        case .large: "Large"
        }
    }

    var points: CGFloat {
        switch self {
        case .small: 22
        case .large: 30
        }
    }

    var symbolName: String {
        switch self {
        case .small: "person.crop.circle"
        case .large: "person.crop.circle.fill"
        }
    }
}

/// Which corner the toasts stack in.
///
/// Discord calls this **Notification Position** and offers the four corners
/// plus off. Off is not a corner here — it is `overlayShowsNotifications`,
/// because a position of "nowhere" is a different kind of answer and hiding it
/// inside the position control is what makes a setting hard to find.
enum OverlayCorner: String, CaseIterable, Identifiable, Sendable, Codable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeading: "Top left"
        case .topTrailing: "Top right"
        case .bottomLeading: "Bottom left"
        case .bottomTrailing: "Bottom right"
        }
    }

    var symbolName: String {
        switch self {
        case .topLeading: "arrow.up.left"
        case .topTrailing: "arrow.up.right"
        case .bottomLeading: "arrow.down.left"
        case .bottomTrailing: "arrow.down.right"
        }
    }

    /// The normalised centre a widget sitting in this corner gets.
    var centre: CGPoint {
        switch self {
        case .topLeading: CGPoint(x: 0.14, y: 0.08)
        case .topTrailing: CGPoint(x: 0.86, y: 0.08)
        case .bottomLeading: CGPoint(x: 0.14, y: 0.88)
        case .bottomTrailing: CGPoint(x: 0.86, y: 0.88)
        }
    }
}

/// How much of what just happened a clip keeps — Discord's three lengths
/// (`SECONDS_30`, `MINUTES_1`, `MINUTES_2`), with its default of thirty.
///
/// **Wingcord's own replay buffer since Phase 3** (docs/CLIPS-PRESENCE.md,
/// D10): `SCClipBufferingOutput` stops at fifteen seconds, so the picture is
/// kept by our own encoder and ring instead, and the length is what the ring
/// is sized to — two minutes costs about four times what thirty seconds does.
enum ClipLength: String, CaseIterable, Identifiable, Sendable, Codable {
    case thirtySeconds
    case oneMinute
    case twoMinutes

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .thirtySeconds: 30
        case .oneMinute: 60
        case .twoMinutes: 120
        }
    }

    var title: String {
        switch self {
        case .thirtySeconds: "30 seconds"
        case .oneMinute: "1 minute"
        case .twoMinutes: "2 minutes"
        }
    }
}

/// What a clip is recorded at.
enum ClipResolution: String, CaseIterable, Identifiable, Sendable, Codable {
    case p720
    case p1080
    case p1440

    var id: String { rawValue }

    var height: Int {
        switch self {
        case .p720: 720
        case .p1080: 1080
        case .p1440: 1440
        }
    }

    var title: String { "\(height)p" }
}

enum ClipFrameRate: String, CaseIterable, Identifiable, Sendable, Codable {
    case fps30
    case fps60

    var id: String { rawValue }

    var rate: Int {
        switch self {
        case .fps30: 30
        case .fps60: 60
        }
    }

    var title: String { "\(rate) fps" }
}
