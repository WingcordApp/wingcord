import Foundation
import WingcordCore

// MARK: - What a reader can do to a message, and to a person
//
// Every route here is one act. None of them touches the store: each returns a
// value or nothing, and the caller applies it — which is what keeps the whole
// network layer usable off the main actor.

extension DiscordREST {

    // MARK: Pins

    /// One channel's pinned messages, newest pin first.
    ///
    /// **The current route, not the deprecated one.** `GET /channels/{id}/pins`
    /// still answers and returns a bare array; `…/messages/pins` is what the
    /// client sends now and it wraps each message beside the moment it was
    /// pinned — which is the only place that timestamp exists, and the order
    /// the pane lists them in.
    public func pinnedMessages(in channelID: ChannelID) async throws -> PinnedPage {
        let page = try await get(
            "/channels/\(channelID.rawValue)/messages/pins",
            route: "channels/{id}/messages/pins",
            as: PinnedPageDTO.self
        )
        var authors: [UserID: User] = [:]
        var messages: [Message] = []
        messages.reserveCapacity(page.items?.count ?? 0)
        for item in page.items ?? [] {
            guard let dto = item.message else { continue }
            if let author = dto.author { authors[author.id] = author.domain }
            // The route answers with `pinned: false` on some entries — it is
            // describing the message, and a message on the pin list is pinned
            // whatever the field says. Forced here so the transcript and the
            // pane cannot disagree about the same message.
            var message = dto.domain
            message.isPinned = true
            messages.append(message)
        }
        return PinnedPage(messages: messages, authors: authors)
    }

    public func pin(_ messageID: MessageID, in channelID: ChannelID) async throws {
        _ = try await requestData(
            method: "PUT",
            path: "/channels/\(channelID.rawValue)/messages/pins/\(messageID.rawValue)",
            route: "channels/{id}/messages/pins/:id",
            body: Optional<Never>.none
        )
    }

    public func unpin(_ messageID: MessageID, in channelID: ChannelID) async throws {
        _ = try await requestData(
            method: "DELETE",
            path: "/channels/\(channelID.rawValue)/messages/pins/\(messageID.rawValue)",
            route: "channels/{id}/messages/pins/:id",
            body: Optional<Never>.none
        )
    }

    // MARK: Read state

    /// Rewinds the read cursor so everything after `messageID` is unread again.
    ///
    /// **`manual` is the whole difference from `acknowledge`.** Without it the
    /// server treats the call as ordinary catching-up and the client's own
    /// next ack — which the transcript sends the moment a message arrives in the
    /// open channel — silently undoes it. With it, the channel stays unread
    /// until the reader actually goes back.
    ///
    /// - Parameter messageID: the message *before* the one to leave unread, or
    ///   nil to rewind the whole channel.
    public func markUnread(
        after messageID: MessageID?,
        in channelID: ChannelID,
        mentionCount: Int
    ) async throws {
        struct Body: Encodable {
            var manual = true
            var mention_count: Int
        }
        // A nil target is "unread from the beginning", which Discord expresses
        // as an ack of message id 0 rather than as a missing path segment.
        let target = messageID?.rawValue ?? 0
        _ = try await requestData(
            method: "POST",
            path: "/channels/\(channelID.rawValue)/messages/\(target)/ack",
            route: "channels/\(channelID.rawValue)/ack",
            body: Body(mention_count: mentionCount)
        )
    }

    // MARK: Forwarding

    /// Sends `messageID` on to another channel, with an optional line of your
    /// own above it.
    ///
    /// **A forward is a message with a reference of type 1, not a copy of the
    /// text.** Discord resolves the snapshot server-side, so the body that
    /// arrives is the original's — including its attachments, which a client
    /// pasting the content could not carry at all.
    ///
    /// The optional message is a *separate* send, and it has to be: one payload
    /// carrying both a forward reference and content is rejected. Sent first, so
    /// the note reads above the thing it is about.
    public func forward(
        _ messageID: MessageID,
        from sourceChannelID: ChannelID,
        to targetChannelID: ChannelID,
        comment: String,
        nonce: String
    ) async throws -> Message {
        struct Body: Encodable {
            var content = ""
            var nonce: String
            var message_reference: Reference

            struct Reference: Encodable {
                var type = 1
                var message_id: String
                var channel_id: String
            }
        }
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            _ = try await sendMessage(
                in: targetChannelID,
                content: trimmed,
                nonce: nonce + "c"
            )
        }
        return try await post(
            "/channels/\(targetChannelID.rawValue)/messages",
            route: "channels/\(targetChannelID.rawValue)/messages",
            body: Body(
                nonce: nonce,
                message_reference: Body.Reference(
                    message_id: messageID.description,
                    channel_id: sourceChannelID.description
                )
            ),
            as: MessageDTO.self
        ).domain
    }

    // MARK: Relationships

    /// Blocks somebody, or takes an existing relationship away.
    ///
    /// One route for both: `PUT` with `type: 2` blocks, and `DELETE` is the only
    /// way back — there is no "unblock" verb. Passing nil is therefore unblock
    /// *and* unfriend, which is what Discord's own two menu items both call.
    public func setBlocked(_ isBlocked: Bool, userID: UserID) async throws {
        struct Body: Encodable { var type = 2 }
        _ = try await requestData(
            method: isBlocked ? "PUT" : "DELETE",
            path: "/users/@me/relationships/\(userID.rawValue)",
            route: "users/@me/relationships/:id",
            body: isBlocked ? Body() : nil
        )
    }

    /// Sends a friend request, accepts one, or takes a relationship away.
    ///
    /// **The same `PUT` sends and accepts**, which is the one part of this that
    /// reads oddly and is Discord's design: friending somebody who has already
    /// asked resolves the pending pair rather than creating a second request.
    /// `DELETE` covers withdrawing, declining and unfriending, because all three
    /// are "there is no relationship here any more".
    ///
    /// The body is an empty object, not absent — with no body the route is read
    /// as a *block* request with a missing type, which is the one mistake here
    /// that cannot be undone by pressing the button again.
    public func setFriend(_ isFriend: Bool, userID: UserID) async throws {
        struct Body: Encodable {}
        _ = try await requestData(
            method: isFriend ? "PUT" : "DELETE",
            path: "/users/@me/relationships/\(userID.rawValue)",
            route: "users/@me/relationships/:id",
            body: isFriend ? Body() : nil
        )
    }

    // MARK: Notes

    /// Writes the reader's private note about somebody.
    ///
    /// **An empty string deletes it**, which is the route's own convention and
    /// the reason this takes a `String` rather than a `String?`: a caller that
    /// had to choose between "clear" and "set to nothing" would be choosing
    /// between two spellings of the same request.
    ///
    /// There is no read route here on purpose. READY carries every note the
    /// account has, so a profile card opens with it already in hand — fetching
    /// one per card would be a round trip for an answer the client was given.
    public func setNote(_ note: String, for userID: UserID) async throws {
        struct Body: Encodable { var note: String }
        _ = try await requestData(
            method: "PUT",
            path: "/users/@me/notes/\(userID.rawValue)",
            route: "users/@me/notes/:id",
            body: Body(note: note)
        )
    }

    /// Ignores somebody, or stops.
    ///
    /// **A sub-resource of the relationship, not a relationship type.** Ignoring
    /// is orthogonal to blocking and to friendship — you can ignore a friend —
    /// so it hangs off `/ignore` and leaves whatever relationship exists alone.
    public func setIgnored(_ isIgnored: Bool, userID: UserID) async throws {
        _ = try await requestData(
            method: isIgnored ? "PUT" : "DELETE",
            path: "/users/@me/relationships/\(userID.rawValue)/ignore",
            route: "users/@me/relationships/:id/ignore",
            body: Optional<Never>.none
        )
    }

    // MARK: Invites

    /// Mints an invite to one channel.
    ///
    /// Seven days and unlimited uses — Discord's own defaults for the invite a
    /// person hands to a person, and the pair a client should not invent
    /// alternatives to.
    public func createInvite(in channelID: ChannelID) async throws -> String {
        struct Body: Encodable {
            var max_age = 604_800
            var max_uses = 0
            var temporary = false
            var unique = false
        }
        struct Reply: Decodable { var code: String }
        let reply = try await post(
            "/channels/\(channelID.rawValue)/invites",
            route: "channels/{id}/invites",
            body: Body(),
            as: Reply.self
        )
        return "https://discord.gg/\(reply.code)"
    }

    // MARK: Reporting

    /// The questionnaire for one kind of subject.
    ///
    /// Fetched rather than hard-coded: the categories *are* the flow, and they
    /// change without warning. See `ReportMenu`.
    public func reportMenu(for subject: ReportSubjectKind) async throws -> ReportMenu {
        try await get(
            "/reporting/menu/\(subject.rawValue)",
            route: "reporting/menu/:kind",
            as: ReportMenuDTO.self
        ).domain
    }

    /// Posts a walked path.
    public func submitReport(
        _ menu: ReportMenu,
        subject: ReportSubject,
        breadcrumbs: [Int],
        elements: [String: [String]],
        language: String
    ) async throws {
        var body = ReportSubmissionDTO(
            version: menu.version,
            variant: menu.variant,
            language: language,
            breadcrumbs: breadcrumbs,
            elements: elements,
            name: menu.name,
            channel_id: nil,
            message_id: nil,
            guild_id: nil,
            user_id: nil,
            widget_id: nil
        )
        switch subject {
        case .message(let messageID, let channelID):
            body.channel_id = channelID.description
            body.message_id = messageID.description
        case .user(let userID, let guildID):
            body.user_id = userID.description
            body.guild_id = guildID?.description
        case .widget(let widgetID, let userID):
            body.widget_id = widgetID
            body.user_id = userID.description
        }
        _ = try await requestData(
            method: "POST",
            path: "/reporting/\(menu.name)",
            route: "reporting/:kind",
            body: body
        )
    }
}

/// Which questionnaire to fetch.
public enum ReportSubjectKind: String, Hashable, Sendable {
    case message
    case user
    /// One tile on somebody's profile board. Its tree is the shallowest of the
    /// three — four categories, each of which submits immediately — and its
    /// welcome node carries a `widget_preview`, which is the reported tile drawn
    /// inside the sheet.
    case widget
}

/// What is being reported, and the ids the submission needs for it.
public enum ReportSubject: Hashable, Sendable {
    case message(MessageID, channelID: ChannelID)
    case user(UserID, guildID: GuildID?)
    /// **Two ids, and both are required.** The widget id alone does not say
    /// whose board it is on, and the user id alone does not say which tile —
    /// somebody with five widgets would be reported for all of them.
    case widget(id: String, userID: UserID)

    public var kind: ReportSubjectKind {
        switch self {
        case .message: .message
        case .user: .user
        case .widget: .widget
        }
    }
}

/// A channel's pins, plus the people who wrote them.
///
/// The authors travel with the page for the same reason a history page's do:
/// this is the only place the client learns who wrote a pinned message from
/// three years ago.
public struct PinnedPage: Sendable {
    public var messages: [Message]
    public var authors: [UserID: User]
}

struct PinnedPageDTO: Decodable, Sendable {
    var items: [Item]?

    struct Item: Decodable, Sendable {
        /// The wrapper carries `pinned_at` beside the message. It is not
        /// decoded: the pane lists pins in the order the route returns them —
        /// newest first — and shows each message's own timestamp, which is the
        /// one a reader is looking for. A field decoded and never read is a
        /// field that has to keep decoding correctly for nothing.
        var message: MessageDTO?
    }
}

extension DiscordREST {
    /// Opens — or finds — the conversation with one person.
    ///
    /// The route is idempotent: called for somebody the account has written to
    /// before, it answers with the existing channel rather than making a second
    /// one. That is what makes it safe to call without checking first, and the
    /// store checks anyway because a lookup beats a round trip.
    public func openDirectMessage(with userID: UserID) async throws -> Channel {
        struct Body: Encodable { var recipient_id: String }
        return try await post(
            "/users/@me/channels",
            route: "users/@me/channels",
            body: Body(recipient_id: userID.description),
            as: ChannelDTO.self
        ).domain()
    }
}
