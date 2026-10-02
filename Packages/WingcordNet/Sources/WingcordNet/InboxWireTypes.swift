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

/// `GET` and `POST /users/@me/scheduled-messages`.
///
/// **Captured, request and reply both** — `inbox,fixed23.har`, one message
/// queued from the composer and the list read back three times. Every field
/// this decoder had before was wrong, and the whole row was being dropped:
/// there is no `content`, no `channel_id` and no `scheduled_at` at the top
/// level of an element, so `domain()` answered nil for every entry Discord
/// sent and the Scheduled tab was empty on a response that decodes perfectly.
///
/// The shape, whole:
///
/// ```json
/// { "id": "1551628835722625195",
///   "scheduled_message_id": "1551628835722625195",
///   "user_id": "987654321987654321",
///   "send_at_timestamp": "2026-09-21T17:45:00+00:00",
///   "state": 0,
///   "attachment_uploads": [],
///   "create_args":       { "content": "hey", "channel_id": "…", "type": 0, … },
///   "scheduled_message": { "content": "hey", "channel_id": "…", "type": 0, … },
///   "message_preview":   { …a whole message object… } }
/// ```
///
/// **Three things about it that a reader would otherwise get wrong.**
///
///  - **The draft is nested, and it is nested TWICE.** `create_args` and
///    `scheduled_message` were byte-identical in every captured element.
///    `scheduled_message` is read first because it is named for what the row
///    *is* rather than for how it was made; `create_args` is the fallback, so
///    an edit route that revises one and not the other cannot blank the row.
///  - **The timestamp is `send_at_timestamp` on the way OUT and
///    `scheduled_timestamp` on the way IN.** Two names for one instant across
///    one round trip — see `scheduleMessage`. Neither is `scheduled_at`.
///  - **The id is spelled twice and both agreed.** `id` is read first.
///
/// **`state` is read through Discord's own table** (`551640` and `566908`'s
/// `H`): `0` is scheduled, and each of the five failures has a sentence — four
/// of them "Message could not be sent", and a missing permission saying so.
/// Every captured row carried `0`; the table is the client's, not a guess.
///
/// **`message_preview` is deliberately not decoded.** The row draws the
/// reader's own draft text — there is no sent message to lay out — and a
/// nested `MessageDTO` that failed to decode would throw the whole array away
/// rather than one row. It is named here so the next reader knows it is there.
struct ScheduledMessageDTO: Decodable, Sendable {
    var id: MessageID?
    var scheduled_message_id: MessageID?
    var send_at_timestamp: Date?
    var state: Int?
    var scheduled_message: Draft?
    var create_args: Draft?

    /// What will be sent. Discord's own message-create body, stored.
    struct Draft: Decodable, Sendable {
        var content: String?
        var channel_id: ChannelID?
        var type: Int?
        var flags: Int?
        var sticker_ids: [String]?
        var forward_only: Bool?
    }

    func domain() -> ScheduledMessage? {
        let draft = scheduled_message ?? create_args
        guard let id = id ?? scheduled_message_id,
              let channelID = draft?.channel_id,
              let at = send_at_timestamp
        else { return nil }
        return ScheduledMessage(
            id: id,
            channelID: channelID,
            // Not on the payload at all, exactly as a mention is not — the
            // caller resolves channel to guild through `ChannelIndex`.
            guildID: nil,
            content: draft?.content ?? "",
            scheduledAt: at,
            failureReason: state.flatMap(Self.failureReason)
        )
    }

    /// `ERROR_SCHEDULED_MESSAGES_DISABLED` 1, `USER_NOT_FOUND` 2,
    /// `USER_CANNOT_USE_SCHEDULED_MESSAGES` 3, `CHANNEL_NOT_FOUND` 4,
    /// `SEND_FAILED` 5.
    static func failureReason(_ state: Int) -> String? {
        switch state {
        case 3: "Message could not be sent, permission was denied"
        case 1, 2, 4, 5: "Message could not be sent"
        default: nil
        }
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
