import Foundation
import WingcordCore

// MARK: - Topics
//
// Discord's "conversations": stretches of a channel it has picked out, titled
// and summarised. Every shape here is captured, in `conversations + slowmode +
// jump to recent.har`; what the client does with them is module `623562` (the
// fetches), `958720` (the store) and `185522` (the pager) of Discord's bundle.

extension DiscordREST {

    /// Discord's page of topics, and the limit its client always asks with.
    public static let topicPageSize = 25

    /// Which topics to ask for.
    public enum TopicPage: Equatable, Sendable {
        /// The channel's newest.
        case newest
        /// Those either side of a message — about half the page each way.
        case around(MessageID)
        /// Those newer than a topic already held.
        case after(ConversationTopicID)
    }

    /// A page of a channel's topics, oldest first.
    ///
    /// `GET /channels/{id}/conversations?limit=25` with `around` or `after`.
    /// The envelope's four edge fields (`before_short_circuited` and the rest)
    /// were false and null in every captured answer, so the page's own size is
    /// what says an end was reached — the rule `hasMoreHistory` follows.
    public func conversationTopics(
        in channelID: ChannelID,
        _ page: TopicPage
    ) async throws -> [ConversationTopic] {
        var query = [URLQueryItem(name: "limit", value: String(Self.topicPageSize))]
        switch page {
        case .newest: break
        case .around(let messageID):
            query.append(URLQueryItem(name: "around", value: messageID.description))
        case .after(let topicID):
            query.append(URLQueryItem(name: "after", value: topicID.description))
        }
        let list = try await get(
            "/channels/\(channelID.rawValue)/conversations",
            route: "channels/\(channelID.rawValue)/conversations",
            query: query,
            as: ConversationListDTO.self
        )
        // Newest first on the wire, like a page of messages; oldest first here,
        // for the reason `messages(in:)` gives.
        return list.conversations.reversed().compactMap(\.domain)
    }

    /// One topic's messages, oldest first, with every reply able to draw its
    /// header.
    ///
    /// `GET /channels/{id}/conversations/{topic}/messages`. A preview asks for
    /// `limit=4`; the whole topic asks for everything, with Discord's own
    /// `include_message_references` and `include_reactions`.
    ///
    /// **A reply here carries no `referenced_message`.** The quoted messages
    /// travel beside the page instead — those outside the topic in
    /// `reference_messages`, those inside it as ordinary members of the page —
    /// so every reference is resolved against both before a row can draw it.
    /// Unresolved, each header would read as a message that no longer exists.
    public func conversationTopicMessages(
        in channelID: ChannelID,
        topic: ConversationTopicID,
        previewLimit: Int?
    ) async throws -> MessagePage {
        let query = if let previewLimit {
            [URLQueryItem(name: "limit", value: String(previewLimit))]
        } else {
            [
                URLQueryItem(name: "include_message_references", value: "true"),
                URLQueryItem(name: "include_reactions", value: "true"),
            ]
        }
        let answer = try await get(
            "/channels/\(channelID.rawValue)/conversations/\(topic.rawValue)/messages",
            route: "channels/\(channelID.rawValue)/conversations/{id}/messages",
            query: query,
            as: ConversationMessagesDTO.self
        )
        var page = Self.page(from: answer.messages, reversed: false)
        let quoted = Self.page(from: answer.reference_messages ?? [], reversed: false)
        page.authors.merge(quoted.authors) { own, _ in own }
        page.messages = Self.resolvingReplies(
            in: page.messages,
            among: page.messages + quoted.messages,
            authors: page.authors
        )
        return page
    }

    /// Fills each reply's header from the message it quotes, where that
    /// message is in hand.
    static func resolvingReplies(
        in messages: [Message],
        among known: [Message],
        authors: [UserID: User]
    ) -> [Message] {
        let byID = Dictionary(known.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return messages.map { message in
            guard let payload = message.payload, let reference = payload.reference,
                  reference.isUnavailable, let targetID = reference.messageID,
                  let target = byID[targetID]
            else { return message }
            var resolved = message
            resolved.payload = payload.replacingReference(MessageReference(
                messageID: targetID,
                channelID: reference.channelID,
                authorID: target.authorID,
                isAuthorBot: authors[target.authorID]?.isBot ?? false,
                excerpt: MessageReference.excerpt(of: target.content),
                hasAttachment: !(target.payload?.attachments.isEmpty ?? true)
                    || !(target.payload?.stickers.isEmpty ?? true)
            ))
            return resolved
        }
    }
}

/// `{"conversations": [...], "before_short_circuited": …}` — only the list is
/// read. See `conversationTopics(in:_:)` for why the edge fields are not.
struct ConversationListDTO: Decodable {
    var conversations: [ConversationDTO]
}

/// One conversation, decoded down to what `ConversationTopic` holds.
struct ConversationDTO: Decodable {
    var id: ConversationTopicID
    var start_message_id: MessageID
    var end_message_id: MessageID
    var message_count: Int?
    var summary_map: SummaryMap?

    struct SummaryMap: Decodable {
        var entries: [Entry]?

        struct Entry: Decodable {
            var summary_type: String?
            /// **A JSON document inside a string**, with the title in it.
            var content_json: String?
        }
    }

    /// What the summary's document says; its key points, sources and scores
    /// are not read.
    private struct Summary: Decodable {
        var title: String?
        var brief_summary: String?
    }

    /// Discord's own parse (module `161204`): the topic-extraction entry, a
    /// string title and a string summary, or no topic at all — the list is
    /// `compactMap`ped over this, as Discord's is filtered.
    var domain: ConversationTopic? {
        guard let json = summary_map?.entries?
                  .first(where: { $0.summary_type == "TOPIC_EXTRACTION_SUMMARY" })?
                  .content_json,
              let summary = try? JSONDecoder().decode(Summary.self, from: Data(json.utf8)),
              let title = summary.title, !title.isEmpty,
              let brief = summary.brief_summary
        else { return nil }
        return ConversationTopic(
            id: id,
            title: title.prefix(1).uppercased() + title.dropFirst(),
            summary: brief.isEmpty ? nil : brief,
            startMessageID: start_message_id,
            endMessageID: end_message_id,
            messageCount: message_count ?? 0
        )
    }
}

/// A topic's messages and the replies' targets outside it. `ancestors` and
/// `has_more_messages` were empty and redundant in every captured answer.
struct ConversationMessagesDTO: Decodable {
    var messages: [MessageDTO]
    var reference_messages: [MessageDTO]?
}
