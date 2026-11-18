import Foundation

/// A call's record on its `CALL` message — Discord's `call`: who was in it,
/// and when it ended.
///
/// **What turns "started a call." into Discord's line.** Its renderer (`ij` in
/// `f1ea8c8b1054ad64`) says how long a finished call lasted, and tells a
/// reader who was never in it that they missed it, in red — both read off
/// this. Without it every call was the same grey "started a call." (Alex,
/// 2026-11-18: "discord makes some icons green, when wingcord doesnt").
public struct MessageCall: Hashable, Sendable, Codable {
    /// Everyone who joined the call at any point.
    public var participantIDs: [UserID]
    /// When it ended. Nil while it is still going.
    public var endedAt: Date?

    public init(participantIDs: [UserID], endedAt: Date? = nil) {
        self.participantIDs = participantIDs
        self.endedAt = endedAt
    }
}
