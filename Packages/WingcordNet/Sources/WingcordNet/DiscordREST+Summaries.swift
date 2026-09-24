import Foundation
import WingcordCore

// MARK: - Summaries
//
// Discord's older summaries feature, drawn as the bar under the toolbar. Both
// reads are captured in `summaries.har`, bodies and all; what the client does
// with them is module `863922` (the fetches) and `822074` (the store) of
// Discord's bundle. The moderator's `DELETE` on the single route is in the
// bundle and has never been captured, so it is not here.

extension DiscordREST {

    /// A channel's summaries, newest first by where each begins — see
    /// `ChannelSummary.newestFirst`.
    ///
    /// `GET /channels/{id}/summaries`, answered `{"summaries": [...]}`: fifty
    /// in the capture, the most recently active first.
    public func channelSummaries(in channelID: ChannelID) async throws -> [ChannelSummary] {
        let list = try await get(
            "/channels/\(channelID.rawValue)/summaries",
            route: "channels/\(channelID.rawValue)/summaries",
            as: SummaryListDTO.self
        )
        return ChannelSummary.newestFirst(list.summaries.compactMap(\.domain))
    }

    /// One summary, as it stands now — asked for when the reader goes to it,
    /// as Discord's client does (`setSelectedSummary`), so a stretch that has
    /// grown since the list arrived carries its new count and people.
    ///
    /// `GET /channels/{id}/summaries/{summary}`, answered with the bare object.
    public func channelSummary(
        _ summaryID: ChannelSummaryID,
        in channelID: ChannelID
    ) async throws -> ChannelSummary? {
        try await get(
            "/channels/\(channelID.rawValue)/summaries/\(summaryID.rawValue)",
            route: "channels/\(channelID.rawValue)/summaries/{id}",
            as: SummaryDTO.self
        ).domain
    }
}

/// `{"summaries": [...]}`.
///
/// **Discord's client also takes a bare array here** (`body.summaries
/// instanceof Array ? body.summaries : body`), so this does too: a change of
/// envelope would otherwise read as a channel with no summaries.
struct SummaryListDTO: Decodable {
    var summaries: [SummaryDTO]

    private enum Keys: String, CodingKey { case summaries }

    init(from decoder: any Decoder) throws {
        if let list = try? [SummaryDTO](from: decoder) {
            summaries = list
            return
        }
        summaries = try decoder.container(keyedBy: Keys.self)
            .decodeIfPresent([SummaryDTO].self, forKey: .summaries) ?? []
    }
}

/// One summary. Captured whole:
///
/// ```
/// {"topic": "Nitro Credits Bug",
///  "summ_short": "Discussion about a bug with Nitro credits and …",
///  "message_ids": ["1551684919267172537", …],   // 19 of them
///  "people": ["1097101542676504657", …],
///  "id": "1551688682463957073", "unsafe": false,
///  "start_id": "1551684919267172537", "end_id": "1551688636326486159",
///  "count": 19, "source": 2, "type": 3}
/// ```
///
/// `message_ids`, `unsafe`, `source` and `type` are not decoded: Discord's own
/// client reads none of them. Everything is optional because Discord's store
/// drops an entry that arrives empty (`Object.keys(e).length > 0`) rather than
/// failing the list over it.
struct SummaryDTO: Decodable, Sendable {
    var id: ChannelSummaryID?
    var topic: String?
    var summ_short: String?
    var people: [UserID]?
    var start_id: MessageID?
    var end_id: MessageID?
    var count: Int?

    /// Nil for an entry that cannot be placed in the channel: without an id
    /// and both ends there is nothing to mark and nowhere to go.
    var domain: ChannelSummary? {
        guard let id, let start_id, let end_id else { return nil }
        // Discord's own mapping keeps each person once (`new Set(e.people)`).
        var seen = Set<UserID>()
        return ChannelSummary(
            id: id,
            topic: topic ?? "",
            summary: summ_short ?? "",
            people: (people ?? []).filter { seen.insert($0).inserted },
            startMessageID: start_id,
            endMessageID: end_id,
            messageCount: count ?? 0
        )
    }
}
