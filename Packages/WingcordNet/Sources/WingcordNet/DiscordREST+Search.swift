import Foundation
import WingcordCore

// Searching messages.
//
// **Captured** — `search messages1.har`, nine queries against one guild — and
// the limits come from `docs.discord.food/resources/message#search-guild-messages`,
// which is where they are written down and nowhere else.
//
// ```
// GET /guilds/{guild.id}/messages/search?content=hey&sort_by=timestamp&sort_order=desc&offset=0
// GET /guilds/{guild.id}/messages/search?author_id=…&sort_by=timestamp&…
// GET /guilds/{guild.id}/messages/search?has=image&…
// GET /guilds/{guild.id}/messages/search?mentions=…&…
// GET /guilds/{guild.id}/messages/search?max_id=…&min_id=…
//                                       &author_type=user&author_type=bot&author_type=webhook
//                                       &pinned=true&…
// ```
//
// Three things the capture settles that the parameter list alone does not:
//
//  1. **A repeated key is how a list is sent.** `author_type` appears three
//     times in one query string rather than once comma-joined, and every
//     `array[…]` parameter is written that way.
//  2. **The date filters are snowflakes.** There is no `before`/`after` in
//     wall-clock time; `max_id` and `min_id` carry the bounds, which is why
//     `Snowflake.lowerBound(for:)` exists. See `MessageSearch.swift`.
//  3. **An empty answer is a 200, not a 404.** The last captured query returns
//     `{"analytics_id":…,"messages":[],"doing_deep_historical_index":false,
//     "total_results":0}` — so "no results" is a page to draw, not an error to
//     report.

extension DiscordREST {

    /// The index is still being built.
    ///
    /// **A 202, not an error** — and it is the one status this client would
    /// otherwise read as success and decode into an empty page, which reads as
    /// "no results" for a server that simply has not been indexed yet. Its body
    /// looks like an error and is not one:
    ///
    /// ```
    /// {"message":"Index not yet available. Try again later",
    ///  "code":110000,"documents_indexed":0,"retry_after":2}
    /// ```
    public struct SearchIndexing: Error, Sendable, Hashable {
        /// Seconds to wait. **Zero is a real answer** and means "a short delay",
        /// not "immediately" — retrying with no pause on a zero is a spin.
        public var retryAfter: TimeInterval
        public var documentsIndexed: Int?

        /// What to actually wait, with the documented floor applied.
        public var delay: Duration {
            .milliseconds(Int(max(retryAfter, 1) * 1000))
        }
    }

    /// Searches a guild's messages, or a DM's.
    ///
    /// **One method for both routes**, because they take the same grammar and
    /// answer the same shape — see `MessageSearchScope`. The only asymmetry is
    /// `channel_id`, which the documentation marks "not applicable when
    /// operating on a private channel" and which is therefore dropped there
    /// rather than sent and ignored.
    ///
    /// Throws `SearchIndexing` on a 202 so the caller can wait and repeat; every
    /// other failure is an ordinary `Failure`.
    public func searchMessages(_ query: MessageSearchQuery) async throws -> MessageSearchPage {
        let path: String
        let route: String
        switch query.scope {
        case .guild(let guildID):
            path = "/guilds/\(guildID.rawValue)/messages/search"
            // Bucketed by route, not by guild: a reader stepping through
            // servers must share one bucket or the limiter stops limiting.
            route = "guilds/{id}/messages/search"
        case .channel(let channelID):
            path = "/channels/\(channelID.rawValue)/messages/search"
            route = "channels/{id}/messages/search"
        }

        let (data, status) = try await requestRaw(
            method: "GET",
            path: path,
            route: route,
            query: Self.queryItems(for: query),
            body: Optional<Never>.none
        )

        // **Checked before the 2xx range**, because 202 is inside it. Decoding
        // this body as a page yields zero results and no error at all, which is
        // the client telling somebody their server is empty.
        if status == 202 {
            let notice = try? Self.decoder.decode(SearchIndexingDTO.self, from: data)
            throw SearchIndexing(
                retryAfter: notice?.retry_after ?? 1,
                documentsIndexed: notice?.documents_indexed
            )
        }
        guard (200..<300).contains(status) else {
            throw Self.apiFailure(status: status, data: data)
        }

        do {
            return try Self.decoder.decode(MessageSearchDTO.self, from: data).domain
        } catch {
            throw Failure.decoding(String(describing: error))
        }
    }

    /// The query string, built once so the two routes cannot drift.
    ///
    /// `URLQueryItem`s rather than a joined string: `content` is free text that
    /// routinely carries `&`, `#` and `+`, and `URLComponents` is what escapes
    /// them correctly.
    static func queryItems(for query: MessageSearchQuery) -> [URLQueryItem] {
        var items: [URLQueryItem] = []

        let content = query.content.trimmingCharacters(in: .whitespacesAndNewlines)
        // **Capped at the documented 1024 rather than sent long.** A longer
        // string is a 400, and truncating asks the question they typed most of.
        if !content.isEmpty {
            items.append(URLQueryItem(name: "content", value: String(content.prefix(1024))))
        }

        // Every list is repeated keys — see the note at the top of this file.
        for id in query.authorIDs.prefix(100) {
            items.append(URLQueryItem(name: "author_id", value: id.description))
        }
        // Meaningless on a DM: there is one channel and the route rejects it.
        if query.scope.guildID != nil {
            for id in query.channelIDs.prefix(500) {
                items.append(URLQueryItem(name: "channel_id", value: id.description))
            }
        }
        for id in query.mentionIDs.prefix(100) {
            items.append(URLQueryItem(name: "mentions", value: id.description))
        }
        // Sorted so one query produces one URL — an unordered `Set` would make
        // the same search a different cache key and a different rate-limit
        // fingerprint on every evaluation.
        for value in query.has.map(\.rawValue).sorted() {
            items.append(URLQueryItem(name: "has", value: value))
        }
        for value in query.authorKinds.map(\.rawValue).sorted() {
            items.append(URLQueryItem(name: "author_type", value: value))
        }
        if let isPinned = query.isPinned {
            items.append(URLQueryItem(name: "pinned", value: isPinned ? "true" : "false"))
        }
        // Dates go as snowflake bounds, and **both use the same conversion** —
        // see `Snowflake.bound(for:)` for why a ceiling with its low bits set
        // is the plausible answer the capture rules out.
        let bounds = query.dateBounds
        if let before = bounds.before {
            items.append(URLQueryItem(name: "max_id", value: MessageID.bound(for: before).description))
        }
        if let after = bounds.after {
            items.append(URLQueryItem(name: "min_id", value: MessageID.bound(for: after).description))
        }

        items.append(URLQueryItem(name: "sort_by", value: query.sort.rawValue))
        // Sent even for relevance, where the route ignores it, because the
        // capture sends it there — `sort_by=relevance&sort_order=desc`.
        items.append(URLQueryItem(name: "sort_order", value: query.order.rawValue))
        items.append(URLQueryItem(name: "offset", value: String(query.offset)))
        return items
    }
}

/// The 202's body.
struct SearchIndexingDTO: Decodable, Sendable {
    var retry_after: TimeInterval?
    var documents_indexed: Int?
}

/// The 200's body.
struct MessageSearchDTO: Decodable, Sendable {
    /// **An array of arrays**, and the nesting is vestigial: it carried the
    /// messages either side of each hit until Discord stopped returning
    /// surrounding context. Every group in the capture holds exactly one
    /// message, and the documentation says so outright.
    var messages: [[MessageDTO]]?
    var total_results: Int?
    var doing_deep_historical_index: Bool?

    var domain: MessageSearchPage {
        var results: [Message] = []
        var authors: [UserID: User] = [:]
        let groups = messages ?? []
        results.reserveCapacity(groups.count)
        for group in groups {
            // `hit` marks the match within a group. With context gone every
            // group is one message and the flag is redundant — but reading it
            // where it exists costs nothing and is right if context returns.
            guard let dto = group.first(where: { $0.hit == true }) ?? group.first else { continue }
            results.append(dto.domain)
            if let author = dto.author { authors[author.id] = author.domain }
            if let quoted = dto.quotedAuthor, authors[quoted.id] == nil {
                authors[quoted.id] = quoted.domain
            }
        }
        return MessageSearchPage(
            messages: results,
            // **Never the array's length.** The route documents that it "may
            // return slightly fewer results than the limit specified" and that
            // "clients should not rely on the length of the messages array to
            // paginate results" — so the count comes from the field or the page
            // count is wrong on exactly the servers that are slow to search.
            totalResults: max(total_results ?? 0, 0),
            isDeepIndexing: doing_deep_historical_index ?? false,
            authors: authors
        )
    }
}
