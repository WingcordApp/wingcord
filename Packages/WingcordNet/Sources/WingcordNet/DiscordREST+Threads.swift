import Foundation
import WingcordCore

// MARK: - Threads and forum posts
//
// Every route here was captured from the desktop client — `forums.har` and
// `threads.har` — rather than read off the documentation, and where the two
// disagree the capture is what is implemented. The two that are not documented
// anywhere at all are `post-data` and the `@me/settings` PATCH; both are noted
// where they are declared.
//
// As everywhere else in this layer, nothing here touches the store: each call
// returns a value and the caller applies it.

extension DiscordREST {

    // MARK: Listing a forum's posts

    /// One page of a channel's **archived** threads.
    ///
    /// **`archived=true` selects, it does not include** — and getting that
    /// backwards is why a board first showed nothing but posts a fortnight old.
    /// In `forums.har` every one of the twenty-five threads this returns has
    /// `thread_metadata.archived == true`, and the ten ids the client asked
    /// `post-data` about *immediately before* the search do not intersect them
    /// at all. Those ten are the live posts, which the client already had from
    /// the gateway.
    ///
    /// So this is half a board. The other half — the active threads — is in
    /// `ChannelIndex`, put there by READY, GUILD_CREATE and THREAD_LIST_SYNC,
    /// and the two are stitched together in `AppModel.forumPresentation`.
    ///
    /// Paging is by `offset`, not by a cursor: the capture's second page is
    /// `offset=25` against the same `limit=25`. That is worth stating because
    /// every other paged route in this client is snowflake-keyed, and an offset
    /// over a list ordered by last-message-time can repeat or skip a post if one
    /// is bumped between two pages. Nothing can be done about that from here —
    /// it is the route's own shape — but the caller de-duplicates on id.
    public func forumPosts(
        in channelID: ChannelID,
        query: ForumQuery,
        offset: Int = 0,
        limit: Int = 25
    ) async throws -> ForumPage {
        var items = [
            URLQueryItem(name: "archived", value: "true"),
            URLQueryItem(name: "sort_by", value: query.sortOrder.queryValue),
            URLQueryItem(name: "sort_order", value: "desc"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "tag_setting", value: query.tagMatching.rawValue),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        // Sorted, so an unchanged filter produces an unchanged URL and the
        // response cache upstream can actually hit. A `Set`'s iteration order is
        // not stable between runs.
        for tag in query.tags.sorted() {
            items.append(URLQueryItem(name: "tag", value: String(tag.rawValue)))
        }

        let page = try await get(
            "/channels/\(channelID.rawValue)/threads/search",
            route: "channels/{id}/threads/search",
            query: items,
            as: ThreadSearchDTO.self
        )
        return page.domain(parentID: channelID)
    }

    /// Threads in a channel whose name matches.
    ///
    /// **The same route, and a deliberately different query.** Captured,
    /// `threads toolbar1.har`: typing into the Threads flyout sends
    /// `?name=the+sun&tag_setting=match_some` and **nothing else** — no
    /// `archived`, no `sort_by`, no `sort_order`, no `limit`, no `offset`. So
    /// this is not the browse query with a name bolted on; it is its own shape,
    /// and sending the browse parameters alongside would be asserting an order
    /// and a page the client never asks for here.
    ///
    /// It searches the **whole channel**, not the pages already loaded: the
    /// capture's one hit is a thread from 2025, far beyond the hundred and fifty
    /// rows that had been scrolled. That is the entire reason this is a request
    /// rather than a filter.
    ///
    /// The reply carries no paging worth following — `has_more` was false
    /// against a `total_results` of 1 — so this returns one page and no cursor.
    public func searchThreads(
        in channelID: ChannelID,
        name: String
    ) async throws -> ForumPage {
        let page = try await get(
            "/channels/\(channelID.rawValue)/threads/search",
            route: "channels/{id}/threads/search",
            query: [
                URLQueryItem(name: "name", value: name),
                URLQueryItem(name: "tag_setting", value: TagMatching.some.rawValue),
            ],
            as: ThreadSearchDTO.self
        )
        return page.domain(parentID: channelID)
    }

    /// The author and opening message of each post, in one call.
    ///
    /// **Undocumented.** It appears in no published reference; the shape here is
    /// exactly what `forums.har` shows — `POST` with `{"thread_ids":[…]}` and a
    /// reply keyed by thread id. The forum list needs it because
    /// `threads/search` returns `first_messages` only for the posts on the page
    /// it just built, and a post whose row is on screen from an earlier page has
    /// no preview line without it.
    ///
    /// The capture batches: three calls of ten, five and one. Discord's client
    /// asks for exactly the rows it is about to draw, so this takes a slice
    /// rather than a whole page.
    public func forumPostData(
        in channelID: ChannelID,
        threadIDs: [ChannelID]
    ) async throws -> [ChannelID: ForumPostDetail] {
        guard !threadIDs.isEmpty else { return [:] }
        struct Body: Encodable { var thread_ids: [String] }

        let reply = try await post(
            "/channels/\(channelID.rawValue)/post-data",
            route: "channels/{id}/post-data",
            body: Body(thread_ids: threadIDs.map { String($0.rawValue) }),
            as: PostDataDTO.self
        )

        var details: [ChannelID: ForumPostDetail] = [:]
        details.reserveCapacity(reply.threads?.count ?? 0)
        for (key, value) in reply.threads ?? [:] {
            guard let id = ChannelID(key) else { continue }
            details[id] = ForumPostDetail(
                firstMessage: value.first_message?.domain,
                author: value.first_message?.author?.domain
                    ?? value.owner?.user?.domain
            )
        }
        return details
    }

    // MARK: Membership

    /// Follows a thread — Discord's "Follow Post" and "Join Thread" are the
    /// same call.
    ///
    /// **The `location` is analytics and Discord requires nothing of it**, but
    /// it is sent because every captured call carries one and a route that is
    /// only ever exercised with a field present is a route whose behaviour
    /// without it is unknown. The capture shows `Sidebar Overflow` and
    /// `Change Notification Settings`.
    ///
    /// Answers 204 with no body, so there is nothing to merge: the caller marks
    /// the thread joined and waits for `THREAD_MEMBER_UPDATE` for the flags.
    public func joinThread(_ threadID: ChannelID, location: String) async throws {
        _ = try await requestData(
            method: "POST",
            path: "/channels/\(threadID.rawValue)/thread-members/@me",
            route: "channels/{id}/thread-members/@me",
            query: [URLQueryItem(name: "location", value: location)],
            body: Optional<Never>.none
        )
    }

    public func leaveThread(_ threadID: ChannelID, location: String) async throws {
        _ = try await requestData(
            method: "DELETE",
            path: "/channels/\(threadID.rawValue)/thread-members/@me",
            route: "channels/{id}/thread-members/@me",
            query: [URLQueryItem(name: "location", value: location)],
            body: Optional<Never>.none
        )
    }

    /// Sets which messages in a thread are worth a notification.
    ///
    /// **Undocumented, and the merge behaviour is the whole point.** The capture
    /// sends a bare `{"flags":2}` against a member whose stored value was `3`,
    /// and the reply comes back `3` again — Discord ORs the notification bit in
    /// and keeps `HAS_INTERACTED`, which is its own to set. So this sends one
    /// bit and never the member's whole field; see `ThreadNotification.wireFlags`.
    public func setThreadNotification(
        _ setting: ThreadNotification,
        in threadID: ChannelID,
        userID: UserID
    ) async throws -> ThreadMember {
        struct Body: Encodable { var flags: Int }
        let dto = try await request(
            method: "PATCH",
            path: "/channels/\(threadID.rawValue)/thread-members/@me/settings",
            route: "channels/{id}/thread-members/@me/settings",
            body: Body(flags: setting.wireFlags.rawValue),
            as: ThreadMemberDTO.self
        )
        return dto.domain(threadID: threadID, userID: userID)
    }

    /// Mutes a thread, for a while or until it is turned back on.
    ///
    /// **The end time is computed here, not by the server.** The capture sends
    /// both `selected_time_window` and an `end_time` fifteen minutes ahead of
    /// the request, and the reply echoes the client's own timestamp back — so a
    /// client that omits it gets a mute with no expiry.
    public func setThreadMute(
        _ duration: MuteDuration?,
        in threadID: ChannelID,
        userID: UserID
    ) async throws -> ThreadMember {
        struct Config: Encodable {
            var selected_time_window: Int
            var end_time: String?
        }
        struct Body: Encodable {
            var muted: Bool
            var mute_config: Config?
        }

        let body: Body
        if let duration {
            body = Body(
                muted: true,
                mute_config: Config(
                    selected_time_window: duration.rawValue,
                    end_time: duration.endTime().map(
                        ISO8601DateFormatter.threadMuteEnd.string(from:)
                    )
                )
            )
        } else {
            // **Unmuting sends `muted` alone.** The capture's un-mute is a bare
            // `{"muted":false}`, and the reply nulls `mute_config` — sending a
            // config alongside it would be asserting a window on a mute that is
            // being taken off.
            body = Body(muted: false, mute_config: nil)
        }

        let dto = try await request(
            method: "PATCH",
            path: "/channels/\(threadID.rawValue)/thread-members/@me/settings",
            route: "channels/{id}/thread-members/@me/settings",
            body: body,
            as: ThreadMemberDTO.self
        )
        return dto.domain(threadID: threadID, userID: userID)
    }

    // MARK: Making one

    /// Opens a post in a forum.
    ///
    /// **A forum post is a thread whose first message is sent with it**, in one
    /// call — there is no "create then send". `POST /channels/{forum}/threads`
    /// with a nested `message` is the shape, and the reply is the thread channel
    /// with that message already in it.
    ///
    /// Not in either capture: no post was created while recording. The route is
    /// the documented one and the reply decodes as an ordinary channel, which is
    /// the part that matters here.
    public func createForumPost(
        in channelID: ChannelID,
        name: String,
        content: String,
        tags: [ForumTagID],
        autoArchiveMinutes: Int,
        nonce: String
    ) async throws -> Channel {
        struct MessageBody: Encodable { var content: String; var nonce: String }
        struct Body: Encodable {
            var name: String
            var auto_archive_duration: Int
            var applied_tags: [String]
            var message: MessageBody
        }
        let dto = try await post(
            "/channels/\(channelID.rawValue)/threads",
            route: "channels/{id}/threads",
            body: Body(
                name: name,
                auto_archive_duration: autoArchiveMinutes,
                applied_tags: tags.map { String($0.rawValue) },
                message: MessageBody(content: content, nonce: nonce)
            ),
            as: ChannelDTO.self
        )
        return dto.domain()
    }

    /// Starts a thread hanging off an existing message.
    ///
    /// The thread's id **is** the source message's id, which is why the reply is
    /// merged rather than inserted: the timeline already has a row at that id.
    public func createThread(
        from messageID: MessageID,
        in channelID: ChannelID,
        name: String,
        autoArchiveMinutes: Int
    ) async throws -> Channel {
        struct Body: Encodable {
            var name: String
            var auto_archive_duration: Int
        }
        let dto = try await post(
            "/channels/\(channelID.rawValue)/messages/\(messageID.rawValue)/threads",
            route: "channels/{id}/messages/{id}/threads",
            body: Body(name: name, auto_archive_duration: autoArchiveMinutes),
            as: ChannelDTO.self
        )
        return dto.domain()
    }

    // MARK: Editing one

    /// Archives, un-archives, locks or re-tags a post.
    ///
    /// A thread is a channel, so this is `PATCH /channels/{id}` — the same route
    /// that renames a text channel. Only the fields the caller names are sent:
    /// `INVARIANTS.md` §1, a page sends the fields it owns.
    public func updateThread(
        _ threadID: ChannelID,
        archived: Bool? = nil,
        locked: Bool? = nil,
        appliedTags: [ForumTagID]? = nil,
        autoArchiveMinutes: Int? = nil,
        name: String? = nil
    ) async throws -> Channel {
        struct Body: Encodable {
            var archived: Bool?
            var locked: Bool?
            var applied_tags: [String]?
            var auto_archive_duration: Int?
            var name: String?
        }
        let dto = try await request(
            method: "PATCH",
            path: "/channels/\(threadID.rawValue)",
            route: "channels/{id}",
            body: Body(
                archived: archived,
                locked: locked,
                applied_tags: appliedTags?.map { String($0.rawValue) },
                auto_archive_duration: autoArchiveMinutes,
                name: name
            ),
            as: ChannelDTO.self
        )
        return dto.domain()
    }
}

// MARK: - What a forum page is

/// One page of a forum's posts, with everything the rows need.
public struct ForumPage: Sendable {
    public var posts: [Channel]
    /// The current user's membership of the posts on this page. Only the ones
    /// they follow appear — most pages carry none or one.
    public var memberships: [ThreadMember]
    /// The opening message of each post, keyed by post id. Discord returns these
    /// for the page it just built; anything older needs `forumPostData`.
    public var firstMessages: [ChannelID: Message]
    /// Everybody named by a post's opening message or its owner record.
    public var authors: [UserID: User]
    /// The guild-member half of each author: the nickname and roles a post's
    /// byline is coloured from. Only owners carry one — a message author who is
    /// not the post's owner appears in `authors` alone.
    public var members: [UserID: Member]
    public var hasMore: Bool
    /// The forum's total, which the page count cannot be derived from — the last
    /// page is short and `hasMore` only says whether to ask again.
    public var totalResults: Int
}

/// The parts of a post that `post-data` fills in.
public struct ForumPostDetail: Sendable {
    public var firstMessage: Message?
    public var author: User?
}

// MARK: - Wire

struct ThreadSearchDTO: Decodable, Sendable {
    var threads: [ChannelDTO]?
    var members: [ThreadMemberDTO]?
    var first_messages: [MessageDTO]?
    var has_more: Bool?
    var total_results: Int?

    func domain(parentID: ChannelID) -> ForumPage {
        var authors: [UserID: User] = [:]
        var members: [UserID: Member] = [:]
        var firstMessages: [ChannelID: Message] = [:]

        for dto in first_messages ?? [] {
            if let author = dto.author { authors[author.id] = author.domain }
            // A post's opening message lives in the post, so its `channel_id` is
            // the post's own id and keys the map directly. There is no case
            // where it names the forum.
            firstMessages[dto.channel_id] = dto.domain
        }

        var posts: [Channel] = []
        posts.reserveCapacity(threads?.count ?? 0)
        for dto in threads ?? [] {
            // The owner arrives as a guild member wrapping a user. It is the
            // only place a post's author appears when `first_messages` does not
            // cover it, which is every page after the first.
            if let owner = dto.owner, let user = owner.user {
                authors[user.id] = user.domain
                members[user.id] = owner.domain(userID: user.id)
            }
            posts.append(dto.domain())
        }

        // A membership row is always about the account that asked — the route
        // returns the caller's own and nobody else's — so a row missing either
        // id is a row there is nothing to key on, and it is dropped rather than
        // attributed to a guess.
        let memberships = (self.members ?? []).compactMap { dto -> ThreadMember? in
            guard let threadID = dto.id, let userID = dto.user_id else { return nil }
            return dto.domain(threadID: threadID, userID: userID)
        }

        return ForumPage(
            posts: posts,
            memberships: memberships,
            firstMessages: firstMessages,
            authors: authors,
            members: members,
            hasMore: has_more ?? false,
            totalResults: total_results ?? posts.count
        )
    }
}

struct PostDataDTO: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        var first_message: MessageDTO?
        /// The post's creator as a guild member — the same shape `threads/search`
        /// puts on the channel.
        var owner: MemberDTO?
    }
    var threads: [String: Entry]?
}

extension ISO8601DateFormatter {
    /// The format a mute's end time is sent in.
    ///
    /// **Milliseconds, and a `Z` rather than `+00:00`.** The capture sends
    /// `2026-09-04T14:16:42.000Z`; the fractional option is what produces the
    /// `.000`, and Discord echoes the string back unchanged.
    nonisolated(unsafe) static let threadMuteEnd: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
