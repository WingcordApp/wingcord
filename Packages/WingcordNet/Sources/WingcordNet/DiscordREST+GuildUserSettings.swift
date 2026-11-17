import Foundation
import WingcordCore

// MARK: - The reader's own settings for one server
//
// **`PATCH /users/@me/guilds/settings` — plural, and it takes every guild at
// once.** The body names just the one that changed:
//
//     {"guilds": {"<guild>": {"muted": true, "mute_config": {…}}}}
//
// and the reply is an ARRAY of whole settings objects, one per guild the call
// touched. Captured field by field in `serveroptions + privacy.har`, one switch
// flipped per request with the Network tab open.
//
// **A partial merge, and that is the whole reason a change is one case rather
// than a record.** Sending the record back would re-assert every value the
// reader did not touch — including any that moved on their phone while the menu
// was open.

extension DiscordREST {

    /// Writes one field of one server's settings, and reads the answer back.
    ///
    /// The reply is the server's *complete* settings object, so it is taken as
    /// the new truth rather than merged into what the client had. That matters
    /// for the mute: the client sends a duration and Discord answers with the
    /// `end_time` it computed, which is the only value that can be shown.
    public func updateGuildUserSettings(
        _ change: GuildUserSettingsChange,
        in guildID: GuildID,
        existing: GuildUserSettings
    ) async throws -> GuildUserSettings {
        let data = try await requestData(
            method: "PATCH",
            path: "/users/@me/guilds/settings",
            route: "users/@me/guilds/settings",
            body: GuildUserSettingsBody(
                guilds: [String(guildID.rawValue): .init(change, existing: existing)]
            )
        )
        let settings = (try? Self.decoder.decode([GuildSettingsDTO].self, from: data)) ?? []
        guard let entry = settings.first(where: { $0.guild_id == guildID }) else {
            // The route answered something this client could not read. The
            // optimistic value is still the best answer available — it is what
            // the reader just asked for — and refusing it here would put the
            // switch back for a write that succeeded.
            return change.applied(to: existing)
        }
        return entry.domain(guildID: guildID)
    }
}

// MARK: - The body

/// One guild's half of the patch.
///
/// **Every field is optional and only the changed one is encoded.** A `nil`
/// here is "do not mention it", which is what makes this a merge; a field
/// encoded as `null` is a different instruction and `mute_config` is the one
/// place this sends one deliberately.
/// Internal rather than private so `GuildUserSettingsTests` can assert the exact
/// JSON each change produces. The bodies are the whole contract with this route
/// — a field sent that should not have been is a setting silently re-asserted —
/// and testing them through a live `PATCH` is not testing them at all.
struct GuildUserSettingsBody: Encodable {
    var guilds: [String: Guild]

    struct Guild: Encodable {
        var muted: Bool?
        /// Explicitly nullable: clearing a mute duration sends `null`, and
        /// `Optional<MuteConfig>?` is how that is said without also sending it
        /// on every other write.
        var mute_config: MuteConfig??
        var message_notifications: Int?
        var suppress_everyone: Bool?
        var suppress_roles: Bool?
        var notify_highlights: Int?
        var mute_scheduled_events: Bool?
        var mobile_push: Bool?
        var hide_muted_channels: Bool?
        var flags: Int?
        var channel_overrides: [String: ChannelOverride]?

        struct MuteConfig: Encodable {
            var selected_time_window: Int
            /// `null` for the indefinite case. The capture sends the key either
            /// way rather than omitting it.
            var end_time: String?
        }

        struct ChannelOverride: Encodable {
            var message_notifications: Int?
            var muted: Bool?
            var mute_config: MuteConfig??
            /// Sent only by the reset, which is the one write that touches the
            /// bits. Every other change leaves them alone by omitting the key.
            var flags: Int?
        }

        /// The one field this change is about, and nothing else.
        init(_ change: GuildUserSettingsChange, existing: GuildUserSettings) {
            switch change {
            case .mute(let duration):
                muted = duration != nil
                // **Sent only when muting.** The capture unmutes with
                // `{"muted": false}` alone — a client that also nulled the
                // config would be describing a second change it was not asked
                // for.
                if let duration {
                    mute_config = .some(
                        MuteConfig(
                            selected_time_window: duration.rawValue,
                            end_time: duration.endTime().map(Self.timestamp)
                        )
                    )
                }
            case .messageNotifications(let level):
                message_notifications = level.rawValue
            case .suppressEveryone(let on): suppress_everyone = on
            case .suppressRoles(let on): suppress_roles = on
            case .suppressHighlights(let on):
                notify_highlights = HighlightLevel(suppressed: on).rawValue
            case .muteScheduledEvents(let on): mute_scheduled_events = on
            case .mobilePush(let on): mobile_push = on
            case .hideMutedChannels(let on): hide_muted_channels = on
            case .showAllChannels:
                // **The whole word is sent, not the bit**, so the unread bits
                // the reader set elsewhere survive — `INVARIANTS.md` §1, "a
                // bitfield written back must carry the bits this client cannot
                // draw". `applied(to:)` owns the polarity.
                flags = change.applied(to: existing).flags
            case .channelLevel(let channelID, let level):
                channel_overrides = [
                    String(channelID.rawValue): ChannelOverride(
                        message_notifications: level.rawValue,
                        // Captured alongside the level, on the request that
                        // adds a channel to the list. Discord's own client
                        // sends both.
                        muted: existing.channelOverrides[channelID]?.isMuted ?? false
                    )
                ]
            case .channelMuted(let channelID, let duration):
                channel_overrides = [
                    String(channelID.rawValue): ChannelOverride(
                        muted: duration != nil,
                        mute_config: duration.map {
                            MuteConfig(
                                selected_time_window: $0.rawValue,
                                end_time: $0.endTime().map(Self.timestamp)
                            )
                        }
                    )
                ]
            case .channelPinned(let channelID, let isPinned):
                // Discord's `jA`: the whole flags word, the pin's bit set or
                // cleared over whatever else the override carries.
                let existingFlags = existing.channelOverrides[channelID]?.flags ?? 0
                channel_overrides = [
                    String(channelID.rawValue): ChannelOverride(
                        flags: GuildUserSettingsChange.pinnedFlags(isPinned, over: existingFlags)
                    )
                ]
            case .clearChannelOverride(let channelID):
                // **Discord's own reset, field for field**, read out of its
                // bundle: `message_notifications` to the inherit value and the
                // flags with the two unread bits cleared. The mute is sent off
                // as well, which its own control does separately — the sheet
                // offers one remove and it has to undo the whole row.
                //
                // `mute_config` is deliberately absent, exactly as it is on a
                // plain unmute: the capture's unmute is a bare `muted: false`.
                let existingFlags = existing.channelOverrides[channelID]?.flags ?? 0
                channel_overrides = [
                    String(channelID.rawValue): ChannelOverride(
                        message_notifications: MessageNotificationLevel.inherit.rawValue,
                        muted: false,
                        flags: ChannelSettingsFlags.clearingUnreadPreference(existingFlags)
                    )
                ]
            }
        }

        /// The format the capture uses: ISO-8601, UTC, milliseconds.
        ///
        /// The same formatter a thread's mute already sends — it is the same
        /// field on the same route family, and two of them would be two things
        /// to get wrong.
        private static func timestamp(_ date: Date) -> String {
            ISO8601DateFormatter.threadMuteEnd.string(from: date)
        }
    }
}

// MARK: - Reading one back

extension GuildSettingsDTO {

    /// The whole record, as the reader's menu needs it.
    func domain(guildID: GuildID) -> GuildUserSettings {
        var overrides: [ChannelID: ChannelUserSettings] = [:]
        for override in channel_overrides ?? [] {
            guard let id = override.channel_id else { continue }
            overrides[id] = ChannelUserSettings(
                messageNotifications: MessageNotificationLevel(
                    rawValue: override.message_notifications ?? 3
                ),
                isMuted: override.muted ?? false,
                muteConfig: override.mute_config?.domain,
                flags: override.flags ?? 0
            )
        }
        return GuildUserSettings(
            guildID: guildID,
            isMuted: muted ?? false,
            muteConfig: mute_config?.domain,
            messageNotifications: MessageNotificationLevel(rawValue: message_notifications ?? 3),
            suppressEveryone: suppress_everyone ?? false,
            suppressRoles: suppress_roles ?? false,
            highlights: HighlightLevel(rawValue: notify_highlights ?? 0),
            muteScheduledEvents: mute_scheduled_events ?? false,
            mobilePush: mobile_push ?? true,
            hideMutedChannels: hide_muted_channels ?? false,
            flags: flags ?? 0,
            channelOverrides: overrides
        )
    }
}

extension GuildSettingsDTO.MuteConfig {
    var domain: ThreadMuteConfig {
        ThreadMuteConfig(
            endTime: end_time.flatMap(Self.parse),
            selectedTimeWindow: selected_time_window
        )
    }

    /// **Both shapes, because Discord sends both.** The mute it has just
    /// computed carries fractional seconds (`2026-09-22T04:22:36.924Z`); one
    /// echoed back later can arrive without them, and a single strict parser
    /// answers nil for the second — which reads as "indefinite" and leaves a
    /// lapsed mute on for ever. The pair the REST decoder already keeps.
    private static func parse(_ value: String) -> Date? {
        ISO8601DateFormatter.withFraction.date(from: value)
            ?? ISO8601DateFormatter.plain.date(from: value)
    }
}
