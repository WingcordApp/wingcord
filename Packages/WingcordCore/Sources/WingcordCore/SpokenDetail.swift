import Foundation

/// A detail VoiceOver reads out beside a message's words.
///
/// **Each of these is a real string a spoken label already carries**, not a
/// switch invented for a settings page. Turning one off shortens what is said
/// about every message in the channel, which on a busy one is the difference
/// between a readable transcript and a wall of metadata.
public enum SpokenDetail: String, Hashable, Sendable, CaseIterable, Identifiable {
    case timestamps
    case editedStatus
    case reactionCounts
    case attachmentTypes

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .timestamps: "Timestamps"
        case .editedStatus: "Edited status"
        case .reactionCounts: "Reaction counts"
        case .attachmentTypes: "Attachment types"
        }
    }

    /// The muted set.
    ///
    /// **An opt-OUT set**, so a build that adds a detail speaks it for everybody
    /// rather than leaving it out of a stored list of opt-ins nobody will go back
    /// and tick. The page draws each row as spoken-unless-muted.
    public struct Set: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let timestamps = Self(rawValue: 1 << 0)
        public static let editedStatus = Self(rawValue: 1 << 1)
        public static let reactionCounts = Self(rawValue: 1 << 2)
        public static let attachmentTypes = Self(rawValue: 1 << 3)

        public static func mask(for detail: SpokenDetail) -> Self {
            switch detail {
            case .timestamps: .timestamps
            case .editedStatus: .editedStatus
            case .reactionCounts: .reactionCounts
            case .attachmentTypes: .attachmentTypes
            }
        }
    }
}

/// Where a role's colour is allowed to land.
///
/// **Two answers, not three, and the missing one is named rather than faked.**
/// Discord offers "next to names" as well — a dot in the role's colour beside
/// the name instead of in it — and it is the better answer for a reader who
/// finds coloured type hard to read but still wants to know who is who. It is
/// not here because it is not a colour decision at all: it is a swatch, a gap
/// and a shifted name rect in two hand-drawn AppKit canvases, and a case in this
/// enum that resolved to "in names" would be §1's forbidden shape — a setting
/// that persists and changes nothing.
public enum RoleColorPlacement: String, Hashable, Sendable, CaseIterable, Identifiable {
    case inNames
    case hidden

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .inNames: "In names"
        case .hidden: "Don't show"
        }
    }

    public var symbolName: String {
        switch self {
        case .inNames: "textformat"
        case .hidden: "circle.slash"
        }
    }

    /// Whether a name is drawn in its role's colour.
    public var tintsNames: Bool { self == .inNames }
}
