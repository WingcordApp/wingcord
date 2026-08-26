import Foundation

/// What the reader has seen in one channel.
///
/// In `WingcordCore` rather than the app, because the gateway builds these while
/// converting READY off the main actor — and a domain value that only the UI
/// layer can name forces the network layer to invent a parallel one, which is
/// how two definitions of "unread" end up disagreeing.
public struct ReadState: Hashable, Sendable, Codable {
    /// The newest message acknowledged. The unread divider goes after this.
    public var lastAcknowledgedID: MessageID?
    /// Mentions since that point, as Discord counts them.
    public var mentionCount: Int
    public var isMuted: Bool

    public init(
        lastAcknowledgedID: MessageID? = nil,
        mentionCount: Int = 0,
        isMuted: Bool = false
    ) {
        self.lastAcknowledgedID = lastAcknowledgedID
        self.mentionCount = mentionCount
        self.isMuted = isMuted
    }

    /// Whether anything is unread, given what the channel's newest message is.
    ///
    /// Compared on the snowflake, never on a stored timestamp: ids are monotonic
    /// by minting time, and a `Date` round-tripped through JSON is not
    /// guaranteed to preserve ordering within a millisecond — so two messages
    /// sent in the same tick can compare in the wrong order and leave a channel
    /// permanently unread.
    public func isUnread(newest: MessageID?) -> Bool {
        guard let newest else { return false }
        guard let lastAcknowledgedID else { return true }
        return newest.rawValue > lastAcknowledgedID.rawValue
    }
}
