import Foundation
import WingcordCore

// MARK: - What the direct-message list can be told
//
// Three writes, and two of them go through the same route: the reader's own
// settings for the **private-channel pseudo-guild**.
//
// `PATCH /users/@me/guilds/@me/settings` — `@me` where a guild id would be. It
// is the *singular* route, and it is not the one `setChannelFollowed` uses: that
// one is `/users/@me/guilds/settings`, plural, and takes every guild at once
// under a `guilds` key. The two answer differently as well — the plural route
// replies with an **array** of settings objects and this one with **one**.
//
// **The body's `channel_overrides` is an object; the reply's is an array.** The
// same key, two shapes, one round trip: the request is keyed by channel id and
// the answer is a list carrying `channel_id` inside each entry. Both halves are
// captured (`settings.har`) and neither is a simplification of the other.

extension DiscordREST {

    /// Pins a direct message to the top of the list, or unpins it.
    ///
    /// **Discord's wire calls this FAVORITED and its UI calls it Pin** — see
    /// `ChannelSettingsFlags.favorited`. Captured both ways:
    ///
    /// ```
    /// PATCH /users/@me/guilds/@me/settings
    /// {"channel_overrides":{"1424759145021837325":{"flags":2048}}}   ← pin
    /// {"channel_overrides":{"1424759145021837325":{"flags":0}}}      ← unpin
    /// ```
    ///
    /// **The answer is the complete set, not a delta**, and an override with
    /// nothing left on it is *dropped* — the unpin reply comes back one entry
    /// shorter with no `flags: 0` in it. So the reply is read as the whole
    /// truth about which conversations are pinned, which is also what makes it
    /// safe to apply over an optimistic write.
    ///
    /// The bit is set alongside whatever else the override carries: the pinned
    /// entry in the capture came back with `message_notifications: 3` and
    /// `muted: false` beside it, filled in by the server. Sending only `flags`
    /// does not clear them.
    public func setDirectMessagePinned(
        _ isPinned: Bool,
        channelID: ChannelID
    ) async throws -> Set<ChannelID> {
        struct Override: Encodable { var flags: Int }
        struct Body: Encodable { var channel_overrides: [String: Override] }

        let settings = try await patchPrivateChannelSettings(
            Body(channel_overrides: [
                String(channelID.rawValue): Override(
                    flags: isPinned ? ChannelSettingsFlags.favorited : 0
                )
            ])
        )
        return Self.pinned(in: settings)
    }

    /// Mutes one conversation, for a while or until it is turned back on.
    ///
    /// The same route as the pin, and the same override object — `muted` and
    /// `mute_config` are two more fields on it, and the capture's reply carries
    /// both on other people's conversations
    /// (`{"muted":true,"mute_config":{"end_time":"…","selected_time_window":null}}`).
    ///
    /// **The end time is computed here, not by the server**, which is the rule
    /// `setThreadMute` already pays for: a client that sends a window and no
    /// end time gets a mute with no expiry.
    ///
    /// **Unmuting sends `muted` alone.** A config alongside it would be
    /// asserting a window on a mute that is being taken off.
    public func setDirectMessageMuted(
        _ duration: MuteDuration?,
        channelID: ChannelID
    ) async throws -> Set<ChannelID> {
        struct Config: Encodable {
            var selected_time_window: Int
            var end_time: String?
        }
        struct Override: Encodable {
            var muted: Bool
            var mute_config: Config?
        }
        struct Body: Encodable { var channel_overrides: [String: Override] }

        let override: Override
        if let duration {
            override = Override(
                muted: true,
                mute_config: Config(
                    selected_time_window: duration.rawValue,
                    end_time: duration.endTime().map(
                        ISO8601DateFormatter.threadMuteEnd.string(from:)
                    )
                )
            )
        } else {
            override = Override(muted: false, mute_config: nil)
        }

        let settings = try await patchPrivateChannelSettings(
            Body(channel_overrides: [String(channelID.rawValue): override])
        )
        return Self.muted(in: settings)
    }

    /// Closes a conversation — Discord's "Close DM".
    ///
    /// **It is a channel delete, and it is not destructive to the messages.**
    /// A private channel is closed for the reader alone; the transcript stays
    /// and reopens with the conversation. Which is why this is offered without
    /// a confirmation where Leave Server is not.
    public func closeDirectMessage(_ channelID: ChannelID) async throws {
        _ = try await requestData(
            method: "DELETE",
            path: "/channels/\(channelID.rawValue)",
            route: "channels/{id}",
            body: Optional<String>.none
        )
    }

    // MARK: Groups

    /// Brings a friend into a group — Discord's Add Friends to DM:
    /// `PUT /channels/{id}/recipients/{user}`. The socket's
    /// `CHANNEL_RECIPIENT_ADD` is what puts them on the roster.
    public func addGroupRecipient(_ userID: UserID, to channelID: ChannelID) async throws {
        _ = try await requestData(
            method: "PUT",
            path: "/channels/\(channelID.rawValue)/recipients/\(userID.rawValue)",
            route: "channels/{id}/recipients/{user}",
            body: Optional<String>.none
        )
    }

    /// Discord's Edit Group: `PATCH /channels/{id}` with `{"name": …}`, the
    /// field sent as typed — an empty one is a group named by its members.
    public func renameGroup(_ channelID: ChannelID, to name: String) async throws {
        struct Body: Encodable { var name: String }
        _ = try await requestData(
            method: "PATCH",
            path: "/channels/\(channelID.rawValue)",
            route: "channels/{id}",
            body: Body(name: name)
        )
    }

    // MARK: Message requests

    /// Accepts a message request — Discord's Accept DM.
    ///
    /// **Captured** — `message request accepted.har`:
    /// `PUT /channels/{id}/recipients/@me` with `{"consent_status":2}`, and the
    /// reply is the conversation itself, carrying neither `is_message_request`
    /// nor `is_spam` — so decoding it IS the acceptance.
    public func acceptMessageRequest(_ channelID: ChannelID) async throws -> Channel {
        struct Body: Encodable { var consent_status = 2 }
        return try await request(
            method: "PUT",
            path: "/channels/\(channelID.rawValue)/recipients/@me",
            route: "channels/{id}/recipients/@me",
            body: Body(),
            as: ChannelDTO.self
        ).domain()
    }

    /// Turns a message request down — Discord's Ignore and Decline, which are
    /// one act (`966107`'s `UK`): a `DELETE` on the same route, leaving the
    /// conversation. Not captured; the bundle's own call.
    public func declineMessageRequest(_ channelID: ChannelID) async throws {
        _ = try await requestData(
            method: "DELETE",
            path: "/channels/\(channelID.rawValue)/recipients/@me",
            route: "channels/{id}/recipients/@me",
            body: Optional<String>.none
        )
    }

    /// Names a friend the way the reader wants to see them, or clears it.
    ///
    /// `PATCH /users/@me/relationships/{id}` with `{"nickname": "…"}`, and
    /// **`null` is how it is cleared** — an empty string is a nickname of no
    /// characters, which the route refuses. That is the same distinction
    /// `setGuildNickname` records, and the opposite of `setNote`, where empty
    /// *is* the delete. Two adjacent routes, two conventions; neither is
    /// guessable from the other.
    ///
    /// Discord offers this on friends only. The gate is the caller's — this
    /// sends what it is given.
    public func setRelationshipNickname(
        _ nickname: String?,
        for userID: UserID
    ) async throws {
        struct Body: Encodable { var nickname: String? }
        _ = try await requestData(
            method: "PATCH",
            path: "/users/@me/relationships/\(userID.rawValue)",
            route: "users/@me/relationships/:id",
            body: Body(nickname: nickname?.isEmpty == true ? nil : nickname)
        )
    }

    // MARK: The route both settings writes share

    /// `PATCH /users/@me/guilds/@me/settings`, and its one answer.
    ///
    /// **A literal `@me`, never `%40me`.** Discord's own client sends the
    /// encoded form because a browser encodes it on the way out; this client
    /// builds the URL with `appending(path:)`, which percent-encodes what it is
    /// given — so handing it `%40me` escapes the `%` and the server receives
    /// `%2540me`, decodes it once, and answers
    /// `Invalid Form Body — guild_id: Value "%40me" is not snowflake`. Measured
    /// against a live account. Every other route in this client spells the
    /// reader `@me` for the same reason.
    private func patchPrivateChannelSettings(
        _ body: some Encodable
    ) async throws -> GuildSettingsDTO {
        try await request(
            method: "PATCH",
            path: "/users/@me/guilds/@me/settings",
            route: "users/@me/guilds/{id}/settings",
            body: body,
            as: GuildSettingsDTO.self
        )
    }

    /// Every conversation the reply says is pinned.
    static func pinned(in settings: GuildSettingsDTO) -> Set<ChannelID> {
        overrides(in: settings) { ($0.flags ?? 0) & ChannelSettingsFlags.favorited != 0 }
    }

    /// Every conversation the reply says is muted.
    ///
    /// **A lapsed mute is still `muted: true` on the wire** — Discord leaves
    /// the flag set and lets the `end_time` expire — so this is the set the
    /// server holds, and whether a mute is still *in force* is
    /// `ThreadMuteConfig.isActive`'s question, asked where it is drawn.
    static func muted(in settings: GuildSettingsDTO) -> Set<ChannelID> {
        overrides(in: settings) { $0.muted == true }
    }

    private static func overrides(
        in settings: GuildSettingsDTO,
        where predicate: (GuildSettingsDTO.ChannelOverride) -> Bool
    ) -> Set<ChannelID> {
        var result: Set<ChannelID> = []
        for override in settings.channel_overrides ?? [] {
            guard let id = override.channel_id, predicate(override) else { continue }
            result.insert(id)
        }
        return result
    }
}
