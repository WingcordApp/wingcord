import Foundation
import WingcordCore

// The inbox's wire shapes.
//
// **Two of the three routes here have never been seen answering with data**, and
// the decoders are written accordingly. `inbox.har` carries a complete
// `/users/@me/mentions` page and an *empty* `/users/@me/scheduled-messages`;
// `/users/@me/saved-messages` is not in the capture at all and comes from
// docs.discord.food, which is behind Discord often enough to matter.
//
// So every field below that the screen does not strictly need is optional, and
// the two envelope types fail soft — a row that cannot be understood is dropped
// and the rest of the page draws. The alternative is one unexpected null
// somewhere in a hundred bookmarks taking the whole tab down, which is the
// failure this client has already paid for once in READY.

// MARK: - Saved messages

/// `GET /users/@me/saved-messages`.
///
/// An envelope rather than a bare array, which is the one thing about this
/// route worth remembering: the mentions route answers `[...]` and this one
/// answers `{ "results": [...] }`.
struct SavedMessagesResponseDTO: Decodable, Sendable {
    var results: [SavedMessageDTO]?
}

struct SavedMessageDTO: Decodable, Sendable {
    /// Null when the message is gone — deleted, or in a channel the account has
    /// lost. Documented nullable, and the row is still drawn.
    var message: MessageDTO?
    var save_data: SaveDataDTO?

    /// The save, and whoever wrote the message it points at.
    ///
    /// Returns nil only when `save_data` is missing, because without it there is
    /// nothing to address the unsave route with — a row that cannot be removed
    /// is worse than a row that is not drawn.
    func domain() -> (saved: SavedMessage, author: User?)? {
        guard let save = save_data?.domain(fallbackID: message?.id) else { return nil }
        return (SavedMessage(message: message?.domain, saveData: save), message?.author?.domain)
    }
}

struct SaveDataDTO: Decodable, Sendable {
    var channel_id: ChannelID?
    var message_id: MessageID?
    var guild_id: GuildID?
    var saved_at: Date?
    var due_at: Date?
    var author_summary: String?
    var channel_summary: String?
    var message_summary: String?
    var notes: String?

    /// - Parameter fallbackID: the message's own id, used when `message_id` is
    ///   absent. The two cannot disagree — a save is addressed by the message it
    ///   points at — so either will do, and taking both means one missing field
    ///   is not a dropped row.
    func domain(fallbackID: MessageID?) -> SaveData? {
        guard let channelID = channel_id, let messageID = message_id ?? fallbackID else {
            return nil
        }
        return SaveData(
            channelID: channelID,
            messageID: messageID,
            guildID: guild_id,
            // **The snowflake's own timestamp is the fallback, not `.now`.**
            // `saved_at` is documented required and has never been seen; if it
            // is missing or in a form the decoder does not know, sorting by
            // "now" would put every such row at the top of the list on every
            // fetch and shuffle them on the next one. The message's minting
            // time is wrong but stable, which keeps the list still.
            savedAt: saved_at ?? messageID.timestamp,
            dueAt: due_at,
            authorSummary: author_summary,
            channelSummary: channel_summary,
            messageSummary: message_summary,
            notes: notes
        )
    }
}

// MARK: - Scheduled messages

/// `GET /users/@me/scheduled-messages`.
///
/// **Every field is optional because the shape is inferred, not captured.** See
/// `ScheduledMessage` for what is known: the route exists, it is user-scoped,
/// and the one time it was recorded it answered `[]`. The names below follow
/// the conventions every neighbouring route uses, and `domain()` returns nil
/// rather than guessing when the three fields the row cannot be drawn without
/// are missing.
struct ScheduledMessageDTO: Decodable, Sendable {
    var id: MessageID?
    var channel_id: ChannelID?
    var guild_id: GuildID?
    var content: String?
    /// The two spellings a Discord route uses for "when this happens". Both are
    /// read; whichever arrives wins.
    var scheduled_at: Date?
    var send_at: Date?
    var failure_reason: String?

    func domain() -> ScheduledMessage? {
        guard let id, let channelID = channel_id, let at = scheduled_at ?? send_at else {
            return nil
        }
        return ScheduledMessage(
            id: id,
            channelID: channelID,
            guildID: guild_id,
            content: content ?? "",
            scheduledAt: at,
            failureReason: failure_reason
        )
    }
}

// MARK: - Gateway payloads

/// `RECENT_MENTION_DELETE` — one mention was acknowledged, here or elsewhere.
struct RecentMentionDeletePayload: Decodable, Sendable {
    var message_id: MessageID
}

/// `SAVED_MESSAGE_DELETE` — a bookmark or reminder was taken off.
///
/// Addressed by the pair, not by the message alone, because the unsave route is
/// `/{channel.id}/{message.id}` and the client's own table is keyed the same
/// way.
struct SavedMessageDeletePayload: Decodable, Sendable {
    var channel_id: ChannelID
    var message_id: MessageID
}
