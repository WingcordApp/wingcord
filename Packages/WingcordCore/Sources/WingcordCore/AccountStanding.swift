import Foundation

// MARK: - Account standing
//
// `GET /safety-hub/@me` — where the account sits on Discord's own enforcement
// ladder. Captured live: `{"account_standing":{"state":100}}` beside
// `classifications`, `guild_classifications`, `is_appeal_eligible` and a few
// other fields this client does not read, because it has never seen them
// populated and a violation's own shape is not something to guess at for a
// feature whose whole job is telling someone the truth about their account.

/// Just the one fact worth showing: the rung, not the case file.
public struct AccountStanding: Hashable, Sendable {
    public var state: State

    public init(state: State) {
        self.state = state
    }

    /// The five rungs of Discord's own ladder — `100`, `200`, `300`, `400`,
    /// `500` — confirmed against published documentation rather than
    /// guessed from the one value this app's own capture ever showed.
    public enum State: Hashable, Sendable {
        case allGood
        case limited
        case veryLimited
        case atRisk
        case suspended
        /// A code newer than this table. Kept as the number it arrived as —
        /// rounding it to the nearest known rung could read a real
        /// restriction as fine, or a clean account as flagged, and both are
        /// worse than an admittedly unrecognised state.
        case unknown(Int)

        public init(wireValue: Int) {
            switch wireValue {
            case 100: self = .allGood
            case 200: self = .limited
            case 300: self = .veryLimited
            case 400: self = .atRisk
            case 500: self = .suspended
            default: self = .unknown(wireValue)
            }
        }

        /// Every rung this client can draw a step for, worst last.
        public static let known: [State] = [.allGood, .limited, .veryLimited, .atRisk, .suspended]

        /// How far along the ladder this rung is, `0...4` for a known one.
        /// Used to place it among `known` without a second switch at the
        /// call site.
        public var rank: Int? { Self.known.firstIndex(of: self) }

        /// The stepper's own label — "All good", "Limited", and so on.
        public var label: String {
            switch self {
            case .allGood: "All good"
            case .limited: "Limited"
            case .veryLimited: "Very limited"
            case .atRisk: "At risk"
            case .suspended: "Suspended"
            case .unknown: "Unknown"
            }
        }
    }
}
