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

/// How much of the screen a clip keeps.
///
/// **Fifteen seconds is the ceiling, and it is Apple's rather than a choice.**
/// `SCClipBufferingOutput` — the first-party rolling buffer new in macOS 27 —
/// documents "Maximum duration is 15 seconds" and exposes no knob anywhere on
/// `SCStream` or `SCStreamConfiguration`. Discord's shortest clip is thirty, so
/// anything longer than this means keeping our own ring of compressed samples;
/// that is a real week of work and a permanently-running encoder, and it is
/// deliberately not what this ships.
enum ClipLength: String, CaseIterable, Identifiable, Sendable, Codable {
    case fiveSeconds
    case tenSeconds
    case fifteenSeconds

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .fiveSeconds: 5
        case .tenSeconds: 10
        case .fifteenSeconds: 15
        }
    }

    var title: String { "\(Int(seconds)) seconds" }
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
