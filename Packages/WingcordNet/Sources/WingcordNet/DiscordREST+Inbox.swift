import Foundation
import WingcordCore

// The inbox's routes.
//
// **Four lists, three routes, and one of the four has no route at all.** Worth
// stating once here, because it is the thing that shapes the whole surface:
//
//  - **Mentions** is `GET /users/@me/mentions` — captured whole in `inbox.har`.
//  - **Bookmarks and Reminders are ONE route**, `GET /users/@me/saved-messages`,
//    partitioned on whether `save_data.due_at` is set. Two tabs, one fetch.
//  - **Scheduled** is `GET /users/@me/scheduled-messages` — captured answering
//    `[]`, so the route is real and the shape is inferred. See `ScheduledMessage`.
//  - **Unreads has no route.** It is computed from READY's read states and the
//    channel index the client already holds, and each expanded channel is an
//    ordinary `/messages?around=` fetch. Nothing here serves it, and that is
//    not an omission.

extension DiscordREST {

    // MARK: Mentions

    /// Every message that mentioned the reader in the past seven days.
    ///
    /// **The window is Discord's and it is short.** Seven days, server-side —
    /// so an empty Mentions tab on an account that was pinged last month is
    /// correct, not a bug, and nothing this client does can widen it.
    ///
    /// **The payload carries no `guild_id`.** Checked against all 25 messages in
    /// `inbox.har`: not one has the field, and neither does any author object —
    /// the only `guild_id` anywhere on the page is inside `message_reference` on
    /// the seven that are replies, and that is the *quoted* message's guild. So
    /// the caller resolves channel → guild through its own `ChannelIndex`, and a
    /// mention in a channel this client has never seen has no server name to
    /// draw. That is the one gap, and it is Discord's.
    ///
    /// - Parameters:
    ///   - roles: include mentions that came from a role ping. Default true,
    ///     which is what Discord's own client sends.
    ///   - everyone: include `@everyone` and `@here`. Default true, same reason.
    public func recentMentions(
        before: MessageID? = nil,
        limit: Int = 25,
        guildID: GuildID? = nil,
        roles: Bool = true,
        everyone: Bool = true
    ) async throws -> MessagePage {
        var items = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "roles", value: roles ? "true" : "false"),
            URLQueryItem(name: "everyone", value: everyone ? "true" : "false"),
        ]
        if let before { items.append(URLQueryItem(name: "before", value: before.description)) }
        if let guildID { items.append(URLQueryItem(name: "guild_id", value: guildID.description)) }

        let page = try await get(
            "/users/@me/mentions",
            route: "users/@me/mentions",
            query: items,
            as: [MessageDTO].self
        )
        return Self.page(from: page, reversed: false)
    }

    /// Acknowledges one mention, which is what takes it off the list.
    ///
    /// `DELETE`, and the name is Discord's: this deletes the *mention record*,
    /// never the message. Fires `RECENT_MENTION_DELETE`, which is how the other
    /// clients on the account find out.
    public func deleteRecentMention(_ messageID: MessageID) async throws {
        _ = try await requestData(
            method: "DELETE",
            path: "/users/@me/mentions/\(messageID.rawValue)",
            route: "users/@me/mentions/{message}",
            body: Optional<Never>.none
        )
    }

    // MARK: Saved messages — bookmarks and reminders

    /// Everything the reader has put aside, both kinds.
    ///
    /// Returns the authors alongside, for the reason a history page does: a
    /// bookmark can point at a message from two years ago written by somebody
    /// no roster still carries, and dropping them leaves every row reading
    /// "Unknown" over a grey circle.
    public func savedMessages() async throws -> (saved: [SavedMessage], authors: [UserID: User]) {
        let response = try await get(
            "/users/@me/saved-messages",
            route: "users/@me/saved-messages",
            as: SavedMessagesResponseDTO.self
        )
        var saved: [SavedMessage] = []
        var authors: [UserID: User] = [:]
        for dto in response.results ?? [] {
            guard let resolved = dto.domain() else { continue }
            saved.append(resolved.saved)
            if let author = resolved.author { authors[author.id] = author }
        }
        return (saved, authors)
    }

    /// Bookmarks a message, or sets a reminder on it.
    ///
    /// **One route for both, and `dueAt` is the only difference.** Sending a
    /// date makes it a reminder; sending none makes it a bookmark. Discord caps
    /// the account at 200 saved messages *without* a reminder — reminders are
    /// counted separately — and answers 400 past that, which the caller surfaces
    /// as a refusal rather than retrying.
    ///
    /// **The PUT is captured, request and reply both**, and the reply is why
    /// `SaveData` is shaped the way it is: it answers with the whole message
    /// plus a `save_data` record carrying `saved_at`, `due_at`, `notes` and
    /// three summary strings that came back *empty*. That is the independent
    /// confirmation of the list route's element shape, and it is also why
    /// nothing reads those summaries — they have never been seen populated.
    ///
    /// **The DELETE is not captured.** Same path with `DELETE`, which is the
    /// convention every other paired route here follows and is still an
    /// inference until somebody watches it answer.
    ///
    /// - Parameter source: the analytics label Discord's own client sends. Kept
    ///   because the capture carried it and an analytics field that is wrong
    ///   fails silently; it is not read back.
    public func saveMessage(
        _ messageID: MessageID,
        in channelID: ChannelID,
        dueAt: Date? = nil,
        source: String = "context_menu"
    ) async throws {
        struct Body: Encodable {
            var source: String
            /// **Omitted entirely when nil, never sent as `null`.** A bookmark
            /// and a reminder-being-cleared are different acts, and this route
            /// has only ever been seen carrying the key when there is a date.
            var due_at: String?
        }
        _ = try await requestData(
            method: "PUT",
            path: "/users/@me/saved-messages/\(channelID.rawValue)/\(messageID.rawValue)",
            route: "users/@me/saved-messages/{channel}/{message}",
            body: Body(
                source: source,
                due_at: dueAt.map(ISO8601DateFormatter.withFraction.string(from:))
            )
        )
    }

    /// Takes a bookmark or a reminder off.
    ///
    /// **Captured** — `bookmarks, reminders,scheduled.har`, three bookmarks
    /// removed in a row. Same path as the `PUT`, `DELETE`, answers **204** with
    /// no body. The inference this client shipped on was right; it is a
    /// measurement now.
    public func unsaveMessage(_ messageID: MessageID, in channelID: ChannelID) async throws {
        _ = try await requestData(
            method: "DELETE",
            path: "/users/@me/saved-messages/\(channelID.rawValue)/\(messageID.rawValue)",
            route: "users/@me/saved-messages/{channel}/{message}",
            body: Optional<Never>.none
        )
    }

    // MARK: Scheduled messages

    /// Messages the reader queued to send later.
    ///
    /// **User-scoped, not channel-scoped**, which is the one thing about this
    /// route that would have been guessed wrong: every neighbouring "later"
    /// route in Discord's API hangs off a channel. The element shape is now
    /// captured rather than inferred — see `ScheduledMessageDTO`, and note
    /// that every field the old decoder looked for was absent, so this tab was
    /// empty on a response that decodes perfectly.
    ///
    /// Rows that cannot be understood are dropped rather than thrown, so a
    /// shape that turns out to be wrong costs one row and not the page.
    public func scheduledMessages() async throws -> [ScheduledMessage] {
        let page = try await get(
            "/users/@me/scheduled-messages",
            route: "users/@me/scheduled-messages",
            as: [ScheduledMessageDTO].self
        )
        return page.compactMap { $0.domain() }
    }

    /// Queues a message to be sent later.
    ///
    /// **Captured** — `inbox,fixed23.har`, one message scheduled from the
    /// composer's own control:
    ///
    /// ```json
    /// POST /users/@me/scheduled-messages
    /// { "channel_id": "1424759145021837325", "content": "hey",
    ///   "scheduled_timestamp": "2026-09-21T17:45:00.000Z",
    ///   "flags": 0, "attachments": [] }
    /// ```
    ///
    /// **The field is `scheduled_timestamp` here and `send_at_timestamp` in
    /// the answer.** One instant, two names, inside a single round trip — so a
    /// client that reused the reply's spelling on the request is sending a key
    /// Discord does not read, and a scheduled message that silently never gets
    /// a time is one that silently never sends.
    ///
    /// `flags` and `attachments` are sent even though both are empty: they are
    /// in every captured body, and §SM.1's rule is that a page sends the fields
    /// it owns whether or not they changed. A reply and a poll ride along as
    /// Discord's `151282` sends them — the message body's own fields, beside the
    /// time — and are left out when there are none, as they are in the capture.
    ///
    /// The reply is one `ScheduledMessageDTO`, the same element the list
    /// answers with, so the caller can insert the new row without refetching.
    public func scheduleMessage(
        in channelID: ChannelID,
        content: String,
        at date: Date,
        replyingTo: MessageID? = nil,
        pingsRepliedAuthor: Bool = true,
        attachments: [UploadedAttachment] = [],
        poll: PollDraft? = nil
    ) async throws -> ScheduledMessage? {
        struct Body: Encodable {
            var channel_id: String
            var content: String
            var scheduled_timestamp: String
            var flags: Int
            var message_reference: ReplyBody?
            var allowed_mentions: QuietReplyMentions?
            var poll: PollBody?
            var attachments: [AttachmentBody]
        }
        let dto = try await post(
            "/users/@me/scheduled-messages",
            route: "users/@me/scheduled-messages",
            body: Body(
                channel_id: channelID.description,
                content: content,
                scheduled_timestamp: ISO8601DateFormatter.withFraction.string(from: date),
                flags: 0,
                message_reference: replyingTo.map(ReplyBody.init),
                allowed_mentions: replyingTo != nil && !pingsRepliedAuthor ? QuietReplyMentions() : nil,
                poll: poll.map(PollBody.init),
                attachments: attachments.map(AttachmentBody.init)
            ),
            as: ScheduledMessageDTO.self
        )
        return dto.domain()
    }

    /// Edits what a scheduled message will say.
    ///
    /// **Captured** — `scheduled.har`, Edit Message:
    /// `PATCH /users/@me/scheduled-messages/{id}` with `{"content":"hey1",
    /// "flags":0}`. The reply is the whole element the list answers with.
    ///
    /// **Two edits, two bodies, one route — and neither carries the other's
    /// field.** Editing the text sends `content` and `flags`; editing the time
    /// sends `scheduled_timestamp` alone. That is §SM.1's rule again: a page
    /// sends the fields it owns. A client that merged the two into one body
    /// would rewrite a time nobody touched every time somebody fixed a typo.
    public func editScheduledMessage(
        _ id: MessageID,
        content: String
    ) async throws -> ScheduledMessage? {
        struct Body: Encodable {
            var content: String
            var flags: Int
        }
        let dto = try await request(
            method: "PATCH",
            path: "/users/@me/scheduled-messages/\(id.rawValue)",
            route: "users/@me/scheduled-messages/{message}",
            body: Body(content: content, flags: 0),
            as: ScheduledMessageDTO.self
        )
        return dto.domain()
    }

    /// Moves when a scheduled message will be sent.
    ///
    /// **Captured** — `scheduled.har`, Edit Schedule Time:
    /// `{"scheduled_timestamp":"2026-09-22T05:15:00.000Z"}`, and nothing else.
    ///
    /// **`scheduled_timestamp` on the way in, `send_at_timestamp` on the way
    /// out**, exactly as the create route does — see `scheduleMessage`.
    public func rescheduleMessage(
        _ id: MessageID,
        to date: Date
    ) async throws -> ScheduledMessage? {
        struct Body: Encodable { var scheduled_timestamp: String }
        let dto = try await request(
            method: "PATCH",
            path: "/users/@me/scheduled-messages/\(id.rawValue)",
            route: "users/@me/scheduled-messages/{message}",
            body: Body(
                scheduled_timestamp: ISO8601DateFormatter.withFraction.string(from: date)
            ),
            as: ScheduledMessageDTO.self
        )
        return dto.domain()
    }

    /// Sends a scheduled message now rather than waiting for its time.
    ///
    /// **Captured** — `scheduled.har`, Send Now:
    /// `POST /users/@me/scheduled-messages/{id}/send`, **no request body at
    /// all**, and the reply is **the sent message**, not the scheduled record:
    /// a whole `MessageDTO` with a new snowflake and a fresh timestamp.
    ///
    /// That asymmetry is the thing to know. Every other route on this
    /// collection answers with a `ScheduledMessageDTO`; this one answers with
    /// the thing the collection just stopped holding, because the row is gone
    /// and the message exists. A caller that decoded the usual element here
    /// would throw on a send that succeeded.
    ///
    /// The row is removed by the caller on a 200 — there is no scheduled
    /// message left to refetch.
    public func sendScheduledMessageNow(_ id: MessageID) async throws -> Message? {
        let dto = try await request(
            method: "POST",
            path: "/users/@me/scheduled-messages/\(id.rawValue)/send",
            route: "users/@me/scheduled-messages/{message}/send",
            body: Optional<Never>.none,
            as: MessageDTO.self
        )
        return dto.domain
    }

    /// Cancels a scheduled message.
    ///
    /// **Captured** — `scheduled.har`, Cancel Scheduled Message. `DELETE` on
    /// the element's own path, answering **204** with no body. The path this
    /// client inferred from the list route was right, and it is a measurement
    /// now rather than a convention.
    public func deleteScheduledMessage(_ id: MessageID) async throws {
        _ = try await requestData(
            method: "DELETE",
            path: "/users/@me/scheduled-messages/\(id.rawValue)",
            route: "users/@me/scheduled-messages/{message}",
            body: Optional<Never>.none
        )
    }

    // MARK: The selected tab

    /// Remembers which tab the reader was on, for every client on the account.
    ///
    /// **Proto 1, not proto 2.** The two settings blobs are different messages
    /// behind one route shape: `/settings-proto/1` is `PreloadedUserSettings`,
    /// which holds the inbox, the folders and the rail order;
    /// `/settings-proto/2` is `FrecencyUserSettings`, which holds the GIF
    /// favourites and the switcher's ranking table. Sending this to 2 would be
    /// accepted and would write field 2 of the wrong message.
    ///
    /// Failure is deliberately not surfaced: the worst case is an inbox that
    /// opens on the wrong tab next launch, and a banner about a preference that
    /// did not save is noise about something nobody asked for.
    public func setInboxTab(_ tab: InboxTab) async throws {
        struct Body: Encodable { var settings: String }
        _ = try await requestData(
            method: "PATCH",
            path: "/users/@me/settings-proto/1",
            route: "users/@me/settings-proto/:type",
            body: Body(settings: UserSettingsProto.encodeInboxTab(tab))
        )
    }

    // MARK: Read states

    /// Marks many channels read — Discord's own `BULK_ACK`, as its read-state
    /// store sends it.
    ///
    /// **Its shape, not a guess at one.** The store queues
    /// `{channel_id, message_id, read_state_type}` for every channel that
    /// actually has something unread, **always with the type** — zero for a
    /// channel — and drains the queue a hundred entries per request, a second
    /// apart. The version this replaced sent everything in one body and left
    /// the type off, and Discord answered by changing nothing.
    ///
    /// Two rules this route has that the single ack does not:
    ///
    ///  - **The message id must be greater than zero**, or the entry is ignored
    ///    with no error. Filtered here rather than at the call site.
    ///  - **It takes no `manual` flag**, so it must never be used to move a read
    ///    cursor *backwards*. Marking read only ever moves it forward.
    public func bulkAcknowledge(
        _ updates: [ReadStateUpdate],
        /// How many of how many have been sent, after each batch — Read All's
        /// progress, since a long list takes a second a hundred.
        progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
    ) async throws {
        struct Entry: Encodable {
            var channel_id: String
            var message_id: String
            var read_state_type: Int
        }
        struct Body: Encodable { var read_states: [Entry] }

        let entries = updates.compactMap { update -> Entry? in
            guard update.messageID.rawValue > 0 else { return nil }
            return Entry(
                channel_id: update.channelID.description,
                message_id: update.messageID.description,
                read_state_type: update.kind.rawValue
            )
        }
        var start = entries.startIndex
        while start < entries.endIndex {
            if start > entries.startIndex { try await Task.sleep(for: .seconds(1)) }
            let end = min(start + Self.bulkAcknowledgeBatch, entries.endIndex)
            _ = try await requestData(
                method: "POST",
                path: "/read-states/ack-bulk",
                route: "read-states/ack-bulk",
                body: Body(read_states: Array(entries[start..<end]))
            )
            progress?(end - entries.startIndex, entries.count)
            start = end
        }
    }

    /// Discord's own batch: `ef.splice(0, 100)`.
    static let bulkAcknowledgeBatch = 100
}

extension DiscordREST {

    /// Turns a page of message DTOs into domain messages plus everyone who has
    /// to be known to draw them.
    ///
    /// **Shared by history and by mentions**, because the two routes answer the
    /// same array and need the same two author passes — the writers, and the
    /// authors of anything a reply quotes. A second copy would be a second place
    /// for "the quoted author must never overwrite a real record" to be
    /// remembered, and that rule is invisible until somebody's name goes thin.
    ///
    /// - Parameter reversed: history arrives newest-first and the store keeps
    ///   oldest-first, so `messages(in:)` flips it here and no surface has to
    ///   remember which way round a page came. **Mentions do not flip**: the
    ///   inbox reads newest-first, which is the order the route already sends.
    static func page(
        from dtos: [MessageDTO],
        reversed: Bool,
        wireCount: Int? = nil
    ) -> MessagePage {
        var authors: [UserID: User] = [:]
        for dto in dtos {
            if let author = dto.author { authors[author.id] = author.domain }
            // Never *over* a real author record — a quoted user object is as
            // thin as a roster one.
            if let quoted = dto.quotedAuthor, authors[quoted.id] == nil {
                authors[quoted.id] = quoted.domain
            }
        }
        return MessagePage(
            messages: (reversed ? dtos.reversed().map(\.domain) : dtos.map(\.domain)),
            authors: authors,
            threads: dtos.compactMap { $0.thread?.domain() },
            wireCount: wireCount ?? dtos.count
        )
    }
}

/// One channel to mark read, for `bulkAcknowledge`.
public struct ReadStateUpdate: Hashable, Sendable {
    public var channelID: ChannelID
    public var messageID: MessageID
    public var kind: ReadStateKind

    public init(channelID: ChannelID, messageID: MessageID, kind: ReadStateKind = .channel) {
        self.channelID = channelID
        self.messageID = messageID
        self.kind = kind
    }
}

/// Discord's read-state types. Only the first is a channel; the rest are
/// per-account features that keep a cursor of their own.
public enum ReadStateKind: Int, Hashable, Sendable {
    case channel = 0
    case guildEvent = 1
    case notificationCenter = 2
    case guildHome = 3
    case guildOnboardingQuestion = 4
    case messageRequests = 5
}
