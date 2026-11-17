import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// `PATCH /users/@me/guilds/settings`, against the bodies Discord's own client
/// sent and the object it answered with.
///
/// **Captured 2026-09-22** in `serveroptions + privacy.har`: every switch in the
/// server menu and its notification sheet flipped one at a time with the Network
/// tab open. The route is a partial merge, so *what is absent* from a body is as
/// much a part of the contract as what is in it — a client that also sent the
/// eight fields it was not asked to change would re-assert every one of them
/// over whatever a phone had just written.
@Suite("Guild user settings")
struct GuildUserSettingsTests {

    private static let guildID = GuildID(rawValue: 574_217_343_635_554_305)
    private static let channelID = ChannelID(rawValue: 733_717_471_666_321_637)

    /// The reply to the 15-minute mute, trimmed to two channel overrides.
    ///
    /// **Trimmed by entries, never by levels** — `INVARIANTS.md` §5.6. Its
    /// `end_time` is kept exactly as it arrived, microseconds and offset and
    /// all, because that string is the thing most likely to stop parsing.
    private static let reply = """
    [{"guild_id": "574217343635554305", "suppress_everyone": false, \
    "suppress_roles": false, "mute_scheduled_events": false, \
    "message_notifications": 2, "flags": 16384, "mobile_push": true, \
    "muted": true, "mute_config": {"end_time": "2026-09-22T04:22:36.924000+00:00", \
    "selected_time_window": 900}, "hide_muted_channels": false, \
    "channel_overrides": [{"channel_id": "648280515617501023", \
    "message_notifications": 3, "muted": false, "mute_config": null, \
    "collapsed": false, "flags": 4096}, {"channel_id": "619028510748548556", \
    "message_notifications": 3, "muted": false, "mute_config": null, \
    "collapsed": false, "flags": 4096}], "notify_highlights": 2, "version": 844}]
    """

    // MARK: Reading the answer

    private func decodedReply() throws -> GuildUserSettings {
        let data = Data(Self.reply.utf8)
        let entries = try JSONDecoder().decode([GuildSettingsDTO].self, from: data)
        let entry = try #require(entries.first)
        return entry.domain(guildID: Self.guildID)
    }

    @Test("Every field of the answer reaches the record")
    func replyDecodes() throws {
        let settings = try decodedReply()
        #expect(settings.isMuted)
        #expect(settings.messageNotifications == .nothing)
        #expect(settings.flags == 16384)
        #expect(settings.mobilePush)
        #expect(settings.hideMutedChannels == false)
        #expect(settings.highlights == .enabled)
        #expect(settings.highlights.suppressesHighlights == false)
        #expect(settings.channelOverrides.count == 2)
        #expect(settings.muteConfig?.selectedTimeWindow == 900)
        // Asked at a moment inside the mute's own window. The capture's mute
        // lapsed fifteen minutes after it was made, so a `.now` here would be a
        // test that passed on the day it was written and never again.
        #expect(
            settings.muteDuration(at: Date(timeIntervalSince1970: 1_790_050_000))
                == .fifteenMinutes
        )
        #expect(settings.muteDuration(at: Date(timeIntervalSince1970: 2_000_000_000)) == nil)
    }

    /// **Microseconds and a `+00:00`, not milliseconds and a `Z`.** Discord
    /// sends the mute it has just computed in one shape and echoes a stored one
    /// in another; a single strict parser answers nil for the second, which
    /// reads as "indefinite" and leaves a lapsed mute on for ever.
    @Test("The end time parses in both of the shapes Discord sends")
    func endTimeParses() throws {
        let settings = try decodedReply()
        let end = try #require(settings.muteConfig?.endTime)
        #expect(abs(end.timeIntervalSince1970 - 1_790_050_956.924) < 1)

        let whole = GuildSettingsDTO.MuteConfig(
            end_time: "2026-09-22T04:22:36+00:00", selected_time_window: 900
        )
        #expect(whole.domain.endTime != nil)
    }

    @Test("A mute that has run out is not muted, whatever the flag says")
    func lapsedMuteIsOff() throws {
        let settings = try decodedReply()
        // The capture's mute ended in 2026; at a moment after it, the flag is
        // still true on the wire and the server is not muted.
        #expect(settings.isMuted(at: Date(timeIntervalSince1970: 2_000_000_000)) == false)
        #expect(settings.isMuted(at: Date(timeIntervalSince1970: 1_790_050_000)))
    }

    // MARK: Show All Channels

    /// **The switch is the inverse of the bit.** `OPT_IN_CHANNELS_ON` set means
    /// the reader sees only the channels they opted into, so Show All Channels
    /// is OFF. Discord's own reader is `isOptInEnabled = hasFlag(…)` and its
    /// channel list draws a channel when `!optInEnabled || optedIn.contains(id)`.
    @Test("Show All Channels is ON exactly when the opt-in bit is CLEAR")
    func showAllChannelsPolarity() throws {
        let settings = try decodedReply()
        #expect(settings.flags & GuildUserSettingsFlags.optInChannelsOn != 0)
        #expect(settings.showsAllChannels == false)

        let shown = GuildUserSettingsChange.showAllChannels(true).applied(to: settings)
        #expect(shown.flags == 0)
        #expect(shown.showsAllChannels)

        let hidden = GuildUserSettingsChange.showAllChannels(false).applied(to: shown)
        #expect(hidden.flags == 16384)
    }

    /// **The whole word is sent, not the bit** — §1, "a bitfield written back
    /// must carry the bits this client cannot draw". The unread bits live in the
    /// same field and nothing in this app offers them.
    @Test("Toggling Show All Channels keeps the unread bits")
    func showAllChannelsKeepsOtherBits() throws {
        var settings = try decodedReply()
        settings.flags |= GuildUserSettingsFlags.unreadsOnlyMentions
        let shown = GuildUserSettingsChange.showAllChannels(true).applied(to: settings)
        #expect(shown.flags == GuildUserSettingsFlags.unreadsOnlyMentions)
        #expect(body(.showAllChannels(true), existing: settings)
            == #"{"flags":4096}"#)
    }

    // MARK: The bodies

    private func body(
        _ change: GuildUserSettingsChange,
        existing: GuildUserSettings = GuildUserSettings(guildID: guildID)
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = GuildUserSettingsBody.Guild(change, existing: existing)
        let data = (try? encoder.encode(payload)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    @Test("Each switch sends its own field and nothing else")
    func switchesSendOneField() {
        #expect(body(.messageNotifications(.onlyMentions))
            == #"{"message_notifications":1}"#)
        #expect(body(.messageNotifications(.allMessages))
            == #"{"message_notifications":0}"#)
        #expect(body(.messageNotifications(.nothing))
            == #"{"message_notifications":2}"#)
        #expect(body(.suppressEveryone(true)) == #"{"suppress_everyone":true}"#)
        #expect(body(.suppressRoles(true)) == #"{"suppress_roles":true}"#)
        #expect(body(.muteScheduledEvents(true)) == #"{"mute_scheduled_events":true}"#)
        #expect(body(.mobilePush(false)) == #"{"mobile_push":false}"#)
        #expect(body(.hideMutedChannels(true)) == #"{"hide_muted_channels":true}"#)
        #expect(body(.hideMutedChannels(false)) == #"{"hide_muted_channels":false}"#)
    }

    /// The field is `notify_highlights` and the switch says *Suppress*, so the
    /// two are opposites. Captured: the switch turned on sent `1`.
    @Test("Suppress Highlights sends the level, not the switch")
    func suppressHighlightsPolarity() {
        #expect(body(.suppressHighlights(true)) == #"{"notify_highlights":1}"#)
        #expect(body(.suppressHighlights(false)) == #"{"notify_highlights":2}"#)
    }

    /// **The capture's unmute is a bare `{"muted": false}`.** Sending a null
    /// config alongside it would be describing a second change nobody asked for.
    @Test("Muting carries a window and an end time; unmuting carries neither")
    func muteBodies() {
        #expect(body(.mute(nil)) == #"{"muted":false}"#)

        let encoded = body(.mute(.fifteenMinutes))
        #expect(encoded.hasPrefix(#"{"mute_config":{"end_time":"#))
        #expect(encoded.contains(#""selected_time_window":900"#))
        #expect(encoded.hasSuffix(#""muted":true}"#))

        // The indefinite case is the one duration with no end time. Discord's
        // own sentinel is a window of -1 and a null `end_time`.
        let forever = body(.mute(.untilTurnedBackOn))
        #expect(forever == #"{"mute_config":{"selected_time_window":-1},"muted":true}"#)
    }

    /// Captured on the request that adds a channel to the sheet's list: Discord
    /// sends the level **and** the mute state together, and `3` is `inherit` —
    /// a value on the wire, not a deletion.
    @Test("A channel override carries its level and its mute together")
    func channelOverrideBody() {
        #expect(
            body(.channelLevel(Self.channelID, .inherit))
                == #"{"channel_overrides":{"733717471666321637":"#
                    + #"{"message_notifications":3,"muted":false}}}"#
        )
        #expect(
            body(.channelLevel(Self.channelID, .nothing))
                == #"{"channel_overrides":{"733717471666321637":"#
                    + #"{"message_notifications":2,"muted":false}}}"#
        )
    }

    // MARK: Pin Channel to Top

    /// Discord's `jA`: the favorited bit over the override's other bits, and
    /// the opt-in bit with it when pinning, so a pinned channel is followed.
    @Test("Pinning a channel sets favorited and followed, keeping the other bits")
    func pinChannelBody() {
        var existing = GuildUserSettings(guildID: Self.guildID)
        existing.channelOverrides[Self.channelID] = ChannelUserSettings(flags: ChannelSettingsFlags.unreadsOnlyMentions)
        #expect(
            body(.channelPinned(Self.channelID, true), existing: existing)
                == #"{"channel_overrides":{"733717471666321637":{"flags":6656}}}"#
        )
    }

    @Test("Unpinning clears favorited alone")
    func unpinChannelBody() {
        var existing = GuildUserSettings(guildID: Self.guildID)
        existing.channelOverrides[Self.channelID] = ChannelUserSettings(
            flags: ChannelSettingsFlags.favorited | ChannelSettingsFlags.followed
        )
        #expect(
            body(.channelPinned(Self.channelID, false), existing: existing)
                == #"{"channel_overrides":{"733717471666321637":{"flags":4096}}}"#
        )
    }

    // MARK: Taking an override off

    /// **There is no route that deletes one override.** Discord's own "use
    /// server default" writes the inherit value with the two unread bits
    /// cleared, read out of its bundle — the entry stays on the wire carrying
    /// nothing, which is why the sheet lists an override by what it says rather
    /// than by its existence.
    @Test("Removing an override resets it rather than deleting it")
    func clearOverrideBody() {
        var existing = GuildUserSettings(guildID: Self.guildID)
        existing.channelOverrides[Self.channelID] = ChannelUserSettings(
            messageNotifications: .nothing,
            isMuted: true,
            flags: ChannelSettingsFlags.followed | ChannelSettingsFlags.unreadsOnlyMentions
        )
        #expect(
            body(.clearChannelOverride(Self.channelID), existing: existing)
                == #"{"channel_overrides":{"733717471666321637":"#
                    + #"{"flags":4096,"message_notifications":3,"muted":false}}}"#
        )
    }

    /// **Only the two unread bits go.** Every other bit is somebody's opt-in,
    /// their pin or their forum follow, and a reset that dropped those would be
    /// three settings undone by one — §1, "a bitfield written back must carry
    /// the bits this client cannot draw".
    @Test("A reset keeps every flag but the unread preference")
    func clearOverrideKeepsOtherFlags() {
        let kept = ChannelSettingsFlags.followed
            | ChannelSettingsFlags.favorited
            | ChannelSettingsFlags.newForumThreadsOn
        let flags = kept
            | ChannelSettingsFlags.unreadsAllMessages
            | ChannelSettingsFlags.unreadsOnlyMentions
        #expect(ChannelSettingsFlags.clearingUnreadPreference(flags) == kept)
    }

    @Test("Applying a removal locally empties the row the sheet lists")
    func clearOverrideAppliesLocally() {
        var existing = GuildUserSettings(guildID: Self.guildID)
        existing.channelOverrides[Self.channelID] = ChannelUserSettings(
            messageNotifications: .allMessages,
            isMuted: true,
            muteConfig: ThreadMuteConfig(selectedTimeWindow: -1),
            flags: ChannelSettingsFlags.followed
        )
        let cleared = GuildUserSettingsChange
            .clearChannelOverride(Self.channelID)
            .applied(to: existing)
        let override = cleared.channelOverrides[Self.channelID]
        #expect(override?.messageNotifications == .inherit)
        #expect(override?.isMuted == false)
        #expect(override?.muteConfig == nil)
        // The entry survives, carrying only the opt-in bit — which is exactly
        // what every untouched channel in an opt-in server already looks like.
        #expect(override?.flags == ChannelSettingsFlags.followed)
    }

    /// A channel with no entry at all has nothing to reset, and a write for it
    /// would create an override in order to say there is none.
    @Test("Removing an override that is not there writes nothing local")
    func clearMissingOverrideIsANoOp() {
        let existing = GuildUserSettings(guildID: Self.guildID)
        let cleared = GuildUserSettingsChange
            .clearChannelOverride(Self.channelID)
            .applied(to: existing)
        #expect(cleared.channelOverrides.isEmpty)
    }

    /// A channel already muted keeps its mute when only its level is changed.
    @Test("Changing a level does not silently unmute the channel")
    func channelLevelKeepsMute() {
        var existing = GuildUserSettings(guildID: Self.guildID)
        existing.channelOverrides[Self.channelID] = ChannelUserSettings(isMuted: true)
        #expect(body(.channelLevel(Self.channelID, .nothing), existing: existing)
            .contains(#""muted":true"#))
    }

    // MARK: Optimistic updates

    @Test("Applying a change locally lands on what the wire would answer")
    func optimisticMatchesTheWire() throws {
        let settings = try decodedReply()
        #expect(GuildUserSettingsChange.mute(nil).applied(to: settings).isMuted() == false)
        #expect(
            GuildUserSettingsChange.suppressHighlights(true)
                .applied(to: settings).highlights == .disabled
        )
        let level = GuildUserSettingsChange.channelLevel(Self.channelID, .allMessages)
            .applied(to: settings)
        #expect(level.channelOverrides[Self.channelID]?.messageNotifications == .allMessages)
        #expect(level.channelOverrides.count == 3)
    }
}
