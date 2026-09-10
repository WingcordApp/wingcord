import Foundation
import WingcordCore

// MARK: - Stages
//
// Six routes, and they divide cleanly in two: four that own the *live stage*
// and two that decide who on it may speak.
//
// **The stage is addressed by its CHANNEL, not by its own id.** `GET`, `PATCH`
// and `DELETE` all take `{channel.id}` even though the object has an `id` of
// its own — there is at most one live stage per channel, so the channel is the
// key and the instance's id is only ever an identity to compare.

struct StageInstanceDTO: Decodable, Sendable {
    var id: UInt64?
    var guild_id: GuildID?
    var channel_id: ChannelID?
    var topic: String?
    var privacy_level: Int?
    var invite_code: String?
    var discoverable_disabled: Bool?
    var guild_scheduled_event_id: UInt64?

    var domain: StageInstance? {
        guard let guild_id, let channel_id else { return nil }
        return StageInstance(
            // The instance's own id is not load-bearing — everything keys on
            // the channel — so a payload without one is still a live stage.
            id: id ?? channel_id.rawValue,
            guildID: guild_id,
            channelID: channel_id,
            topic: topic ?? "",
            privacyLevel: StagePrivacyLevel(rawValue: privacy_level ?? 2),
            inviteCode: invite_code.flatMap { $0.isEmpty ? nil : $0 },
            isDiscoverableDisabled: discoverable_disabled ?? false,
            scheduledEventID: guild_scheduled_event_id
        )
    }
}

extension DiscordREST {

    /// The live stage in one channel, or nil when the lights are off.
    ///
    /// **404 is a real answer here and not a failure.** A stage channel with
    /// no live stage in it answers 404, which is the normal resting state of
    /// every stage channel in a server — so this reports "nothing running"
    /// rather than throwing, and a caller cannot mistake a quiet room for a
    /// broken request.
    public func stageInstance(inChannel channelID: ChannelID) async throws -> StageInstance? {
        do {
            return try await get(
                "/stage-instances/\(channelID.rawValue)",
                route: "stage-instances/{id}",
                as: StageInstanceDTO.self
            ).domain
        } catch Failure.notFound {
            return nil
        }
    }

    /// Starts a stage.
    ///
    /// **`POST /stage-instances`, and the channel is in the body** — the one
    /// route of the four that is not addressed by the channel, because there
    /// is nothing there yet to address.
    ///
    /// A topic is required: Discord refuses a stage with none, which is the
    /// difference between starting a stage and simply being in the channel.
    /// `send_start_notification` pings `@everyone` and is **off unless the
    /// caller says otherwise** — it is the one field here that reaches people
    /// who are not in the room.
    public func startStage(
        inChannel channelID: ChannelID,
        topic: String,
        privacyLevel: StagePrivacyLevel = .guildOnly,
        notifyEveryone: Bool = false
    ) async throws -> StageInstance? {
        struct Body: Encodable {
            var channel_id: String
            var topic: String
            var privacy_level: Int
            var send_start_notification: Bool
        }
        return try await request(
            method: "POST",
            path: "/stage-instances",
            route: "stage-instances",
            body: Body(
                channel_id: String(channelID.rawValue),
                topic: topic,
                privacy_level: privacyLevel.rawValue,
                send_start_notification: notifyEveryone
            ),
            as: StageInstanceDTO.self
        ).domain
    }

    /// Renames a running stage.
    public func setStageTopic(
        _ topic: String,
        inChannel channelID: ChannelID
    ) async throws -> StageInstance? {
        struct Body: Encodable { var topic: String }
        return try await request(
            method: "PATCH",
            path: "/stage-instances/\(channelID.rawValue)",
            route: "stage-instances/{id}",
            body: Body(topic: topic),
            as: StageInstanceDTO.self
        ).domain
    }

    /// Ends a stage.
    ///
    /// **It does not empty the channel.** Everybody stays where they are; the
    /// stage stops being live and the audience stops being an audience. Which
    /// is why this is not spelled "leave".
    public func endStage(inChannel channelID: ChannelID) async throws {
        _ = try await requestData(
            method: "DELETE",
            path: "/stage-instances/\(channelID.rawValue)",
            route: "stage-instances/{id}",
            body: Optional<String>.none
        )
    }

    // MARK: Who may speak

    /// Changes the reader's own place on a stage.
    ///
    /// `PATCH /guilds/{id}/voice-states/@me`. Three things it can say and the
    /// permissions differ for each, which is why they are one call rather than
    /// three:
    ///
    ///  - **Stepping down to the audience** — `suppress: true`. Always allowed.
    ///    Nobody needs permission to stop talking.
    ///  - **Stepping up to speak** — `suppress: false`. Needs `MUTE_MEMBERS`,
    ///    so for everybody who is not a moderator this is refused and the way
    ///    up is a raised hand.
    ///  - **Raising a hand** — `request_to_speak_timestamp`. Needs
    ///    `REQUEST_TO_SPEAK`, and **the instant must be now or later**; a
    ///    timestamp in the past is rejected. Null lowers it.
    ///
    /// `channel_id` is sent on every call and **must be a stage channel**, and
    /// the reader must already be in it — this moves somebody who is present
    /// between two states, it does not put them in the room.
    public func setSelfStageState(
        inGuild guildID: GuildID,
        channelID: ChannelID,
        suppress: Bool? = nil,
        requestToSpeakAt: Date?? = nil
    ) async throws {
        struct Body: Encodable {
            var channel_id: String
            var suppress: Bool?
            var request_to_speak_timestamp: String?

            enum CodingKeys: String, CodingKey {
                case channel_id, suppress, request_to_speak_timestamp
            }

            /// **Written by hand so an explicit null survives.** Lowering a
            /// hand *is* sending `request_to_speak_timestamp: null`; the
            /// synthesised encoder omits a nil optional entirely, which sends
            /// nothing and leaves the hand up.
            var encodesNullRequest = false

            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(channel_id, forKey: .channel_id)
                try container.encodeIfPresent(suppress, forKey: .suppress)
                if let request_to_speak_timestamp {
                    try container.encode(
                        request_to_speak_timestamp, forKey: .request_to_speak_timestamp
                    )
                } else if encodesNullRequest {
                    try container.encodeNil(forKey: .request_to_speak_timestamp)
                }
            }
        }

        var body = Body(
            channel_id: String(channelID.rawValue),
            suppress: suppress,
            request_to_speak_timestamp: requestToSpeakAt.flatMap { $0 }.map {
                ISO8601DateFormatter.withFraction.string(from: $0)
            }
        )
        // The outer optional says "the caller mentioned the hand at all"; the
        // inner one says "and it is down". Only the second sends a null.
        if case .some(.none) = requestToSpeakAt { body.encodesNullRequest = true }

        _ = try await requestData(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)/voice-states/@me",
            route: "guilds/{id}/voice-states/@me",
            body: body
        )
    }

    /// Invites somebody to speak, or moves them back to the audience.
    ///
    /// `PATCH /guilds/{id}/voice-states/{user.id}` — needs `MUTE_MEMBERS`, and
    /// `channel_id` is **required** here where it is optional on `@me`.
    ///
    /// **Two side effects the route performs and does not announce**, both
    /// documented and both of which a client that did not know would draw
    /// wrong:
    ///
    ///  - Unsuppressing a *person* sets their `request_to_speak_timestamp` to
    ///    now. So somebody invited to speak comes back with a raised hand in
    ///    the payload, and a moderator's queue that filtered on the timestamp
    ///    alone would keep showing them. Bots are exempt.
    ///  - Suppressing somebody **clears** their request. Moving a speaker down
    ///    also takes their hand down, which is right and is not something the
    ///    client has to do itself.
    public func setStageSpeaker(
        _ userID: UserID,
        isSpeaker: Bool,
        inGuild guildID: GuildID,
        channelID: ChannelID
    ) async throws {
        struct Body: Encodable {
            var channel_id: String
            var suppress: Bool
        }
        _ = try await requestData(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)/voice-states/\(userID.rawValue)",
            route: "guilds/{id}/voice-states/{user}",
            body: Body(channel_id: String(channelID.rawValue), suppress: !isSpeaker)
        )
    }
}
