import Foundation

/// One stretch of a channel that Discord has titled and summed up in a
/// sentence — what its client lists as **Summaries**.
///
/// **Not a topic.** `ConversationTopic` is Discord's newer "conversations"
/// feature, gated on its own server flag and drawn as a minimap; this is the
/// older summaries feature (`GET /channels/{id}/summaries`, store `822074` in
/// Discord's bundle), drawn as a bar under the toolbar. A channel can have both.
///
/// Only what is drawn. The wire object also lists every message id in the
/// stretch, a `source`, a `type` and an `unsafe` flag, and Discord's own client
/// reads none of them.
public struct ChannelSummary: Identifiable, Hashable, Sendable {
    public var id: ChannelSummaryID
    /// Discord's title for the stretch.
    public var topic: String
    /// One sentence about what was said — `summ_short` on the wire.
    public var summary: String
    /// Who took part, each once, in the order the wire lists them.
    public var people: [UserID]
    public var startMessageID: MessageID
    public var endMessageID: MessageID
    public var messageCount: Int

    public init(
        id: ChannelSummaryID,
        topic: String,
        summary: String,
        people: [UserID],
        startMessageID: MessageID,
        endMessageID: MessageID,
        messageCount: Int
    ) {
        self.id = id
        self.topic = topic
        self.summary = summary
        self.people = people
        self.startMessageID = startMessageID
        self.endMessageID = endMessageID
        self.messageCount = messageCount
    }

    /// How many a channel keeps — Discord's own `takeRight(75)`.
    public static let limit = 75

    /// A channel's summaries as Discord's store holds them: **newest first by
    /// where each begins**, and no more than `limit` of them.
    ///
    /// The wire list is ordered by where each stretch **ends** — the most
    /// recently active first, measured on the capture's fifty — so its starts
    /// run in no order. That is why Discord sorts on arrival, and why every
    /// index into the list (the bar's place, its arrows) is an index into this
    /// order.
    public static func newestFirst(_ summaries: [ChannelSummary]) -> [ChannelSummary] {
        Array(
            summaries
                .sorted { $0.startMessageID.rawValue > $1.startMessageID.rawValue }
                .prefix(limit)
        )
    }

    /// `incoming` laid over `held`: a summary already held is replaced by its
    /// newer copy, and the rest are kept — Discord's `CONVERSATION_SUMMARY_UPDATE`
    /// and single-summary answer both merge this way.
    public static func merging(
        _ incoming: [ChannelSummary],
        into held: [ChannelSummary]
    ) -> [ChannelSummary] {
        guard !incoming.isEmpty else { return held }
        let replaced = Set(incoming.map(\.id))
        return newestFirst(incoming + held.filter { !replaced.contains($0.id) })
    }
}
