import Foundation
import Testing
@testable import WingcordCore
@testable import WingcordNet

/// The channel Overview's write, and the two faults it used to carry.
///
/// **A rename wiped the channel.** The editor started from "no topic, slowmode
/// off, 64 kbps" and the page sends every field it owns, so the first rename
/// wrote all of those back. **And `flags` was the spoiler bit or zero**, which
/// cleared every other bit the channel had. Both are pinned against the keys
/// the captured body carries (`HANDOFF.md` §SM.14).
@Suite("Channel overview wire")
struct ChannelOverviewWireTests {

    private func keys(_ overview: ChannelOverview) throws -> [String: Any] {
        let data = try JSONEncoder().encode(ChannelOverviewBody(overview))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private let busyText = Channel(
        id: ChannelID(rawValue: 1),
        kind: .text,
        guildID: GuildID(rawValue: 9),
        name: "general",
        topic: "Be nice",
        isNSFW: false,
        rateLimitPerUser: 30,
        // Require-tag, hide-media and a bit this client has no name for.
        flags: ChannelFlags(rawValue: (1 << 4) | (1 << 15) | (1 << 30)),
        defaultAutoArchiveDuration: 1440
    )

    @Test("A draft starts from the channel, not from defaults")
    func seededFromTheChannel() {
        let overview = ChannelOverview(busyText)
        #expect(overview.topic == "Be nice")
        #expect(overview.slowmodeSeconds == 30)
        #expect(overview.visibility == .default)
        #expect(overview.autoArchiveMinutes == 1440)
        #expect(overview.flags == busyText.flags.rawValue)
    }

    @Test("An age-restricted channel opens as age-restricted")
    func ageGateIsRead() {
        var channel = busyText
        channel.isNSFW = true
        #expect(ChannelOverview(channel).visibility == .ageRestricted)
    }

    @Test("Renaming sends the channel's own values back, untouched")
    func renameKeepsEverythingElse() throws {
        var overview = ChannelOverview(busyText)
        overview.name = "lobby"
        let body = try keys(overview)
        #expect(body["name"] as? String == "lobby")
        #expect(body["topic"] as? String == "Be nice")
        #expect(body["rate_limit_per_user"] as? Int == 30)
        #expect(body["nsfw"] as? Bool == false)
        #expect(body["flags"] as? Int == busyText.flags.rawValue)
        #expect(body["default_auto_archive_duration"] as? Int == 1440)
    }

    @Test("Choosing Spoiler sets one bit and keeps every other")
    func spoilerTogglesOneBit() throws {
        var overview = ChannelOverview(busyText)
        overview.visibility = .spoiler
        let flags = try #require(try keys(overview)["flags"] as? Int)
        #expect(flags == busyText.flags.rawValue | ChannelVisibility.spoilerFlag)

        overview.visibility = .default
        #expect(try keys(overview)["flags"] as? Int == busyText.flags.rawValue)
    }

    @Test("A text channel sends the captured eight keys and no voice keys")
    func textChannelKeys() throws {
        var channel = busyText
        channel.defaultAutoArchiveDuration = nil
        let body = try keys(ChannelOverview(channel))
        #expect(Set(body.keys) == [
            "name", "type", "topic", "bitrate", "user_limit", "nsfw", "flags", "rate_limit_per_user",
        ])
    }

    @Test("A voice channel sends Automatic as an explicit null")
    func voiceChannelRegion() throws {
        let voice = Channel(
            id: ChannelID(rawValue: 2),
            kind: .voice,
            name: "Hangout",
            bitrate: 256_000,
            userLimit: 4,
            videoQualityMode: 2
        )
        let body = try keys(ChannelOverview(voice))
        #expect(body.keys.contains("rtc_region"))
        #expect(body["rtc_region"] is NSNull)
        #expect(body["video_quality_mode"] as? Int == 2)
        #expect(body["bitrate"] as? Int == 256_000)
        #expect(body["user_limit"] as? Int == 4)
    }

    @Test("A boosted bitrate survives a server that lost its boosts")
    func bitrateChoicesKeepTheCurrentValue() {
        let choices = BoostTier.bitrateChoices(maximum: 96_000, current: 256_000)
        #expect(choices.contains(256_000))
        #expect(choices.last == 256_000)
        #expect(choices.allSatisfy { $0 <= 96_000 || $0 == 256_000 })
    }

    @Test("A custom slowmode is shown rather than replaced")
    func slowmodeKeepsCustomValue() {
        let choices = SlowmodeChoices.choices(including: 45)
        #expect(choices.contains(45))
        #expect(choices == choices.sorted())
        #expect(SlowmodeChoices.choices(including: 60) == SlowmodeChoices.presets)
        #expect(SlowmodeChoices.title(21600) == "6h")
        #expect(SlowmodeChoices.title(0) == "Off")
    }
}
