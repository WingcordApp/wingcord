import Foundation

/// One stretch of a channel's conversation that Discord has picked out and
/// titled — what its client lists as **Topics**.
///
/// **Discord's own name for the object is a conversation** (`GET
/// /channels/{id}/conversations`), which this codebase already uses for a text
/// channel's pane and for a direct message. The type takes the name the reader
/// sees instead.
///
/// Only what is drawn: the title and its summary sentence, where the stretch
/// begins and ends, and how many messages it holds. The wire object carries
/// every message id, every participant, keywords and the summary's key points
/// with their sources — most of each 3 KB entry, and nothing on screen reads
/// any of it.
public struct ConversationTopic: Identifiable, Hashable, Sendable {
    public var id: ConversationTopicID
    /// Discord's title, with its first letter raised — its client's
    /// `upperFirst`, which is why "game state concerns" reads "Game state
    /// concerns" there.
    public var title: String
    /// One sentence about what was said.
    public var summary: String?
    public var startMessageID: MessageID
    public var endMessageID: MessageID
    public var messageCount: Int

    public init(
        id: ConversationTopicID,
        title: String,
        summary: String? = nil,
        startMessageID: MessageID,
        endMessageID: MessageID,
        messageCount: Int
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.startMessageID = startMessageID
        self.endMessageID = endMessageID
        self.messageCount = messageCount
    }
}
