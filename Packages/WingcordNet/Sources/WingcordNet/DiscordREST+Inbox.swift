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
    /// **User-scoped, not channel-scoped** — that much the capture settles, and
    /// it is the one thing about this route that would have been guessed wrong:
    /// every neighbouring "later" route in Discord's API hangs off a channel.
    /// The element shape is inferred; see `ScheduledMessageDTO`.
    ///
    /// Rows that cannot be understood are dropped rather than thrown, so a
    /// shape that turns out to be wrong costs an empty tab and not a failure.
    public func scheduledMessages() async throws -> [ScheduledMessage] {
        let page = try await get(
            "/users/@me/scheduled-messages",
            route: "users/@me/scheduled-messages",
            as: [ScheduledMessageDTO].self
        )
        return page.compactMap { $0.domain() }
    }

    /// Cancels a scheduled message.
    ///
    /// **The path is inferred along with the shape.** It mirrors the list route,
    /// which is the convention every other user-scoped collection follows. A 404
    /// here means the path is wrong rather than the message being gone, and the
    /// caller says so rather than removing the row.
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

    /// Marks many channels read in one request.
    ///
    /// **What "mark all read" has to be.** The per-channel ack is one request
    /// per channel, and an account with sixty unread channels would spend sixty
    /// of them through a rate limiter — which is a visible stall and then a 429.
    ///
    /// Two rules this route has that the single ack does not, both from the
    /// docs and both able to fail silently:
    ///
    ///  - **The message id must be greater than zero**, or the entry is ignored
    ///    with no error. Filtered here rather than at the call site.
    ///  - **It takes no `manual` flag**, so it must never be used to move a read
    ///    cursor *backwards*. Marking read only ever moves it forward, which is
    ///    the only thing this client asks of it.
    public func bulkAcknowledge(_ updates: [ReadStateUpdate]) async throws {
        struct Entry: Encodable {
            var channel_id: String
            var message_id: String
            var read_state_type: Int?
        }
        struct Body: Encodable { var read_states: [Entry] }

        let entries = updates.compactMap { update -> Entry? in
            guard update.messageID.rawValue > 0 else { return nil }
            return Entry(
                channel_id: update.channelID.description,
                message_id: update.messageID.description,
                // Omitted for an ordinary channel: `CHANNEL` is the route's own
                // default, and sending a field's default value on every entry is
                // bytes in a body that can carry hundreds of them.
                read_state_type: update.kind == .channel ? nil : update.kind.rawValue
            )
        }
        guard !entries.isEmpty else { return }
        _ = try await requestData(
            method: "POST",
            path: "/read-states/ack-bulk",
            route: "read-states/ack-bulk",
            body: Body(read_states: entries)
        )
    }
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
    static func page(from dtos: [MessageDTO], reversed: Bool) -> MessagePage {
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
            threads: dtos.compactMap { $0.thread?.domain() }
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
