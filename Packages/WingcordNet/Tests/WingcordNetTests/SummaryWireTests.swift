import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// Summaries and server themes on the wire.
///
/// The summary bodies are captured in `summaries.har` — the list trimmed to its
/// first three entries, and otherwise verbatim. The theme object is captured in
/// `join discoverable server.har`, on the guild the join answers with.
@Suite("Summaries and server themes on the wire")
struct SummaryWireTests {

    /// `GET /channels/983622219499953020/summaries`, first three.
    private static let list = #"""
{"summaries": [{"topic": "Discord's New Badges", "summ_short": "Discussion about the new badges on Discord and their functionality.", "message_ids": ["1551812003923655140", "1551812058506929424", "1551812093068846108", "1551812163447168842", "1551812373461829553", "1551812769431835469", "1551817720898053800", "1551820548655509010", "1551828792469355167", "1551831126731597258", "1551831357941034442", "1551855655783319783", "1551858184964655462", "1551858400895039854", "1551929873695850102", "1551929896148961498", "1551961945942535800", "1551969980038583061", "1551971295650213244", "1551973756324555935", "1551981019341484916", "1551981418716838959", "1551983147072765984", "1551985192395725173", "1551985215217206848", "1552482143086199112", "1552488656132242679", "1552488798275987505"], "people": ["93290206353948672", "199251165661691351", "215231100271802270", "223518178103354092", "277549276599330154", "316632042092996580", "360123810111147788", "513777778214291685", "667766867224226799", "858197128688659891", "1065130711899891774", "1154793294523450275", "1240982789815535723", "1360696492033048576", "1419853886980302640", "1485183378009924328", "1509707188404851196", "1513684134964615215", "1515234832002922823"], "id": "1551865480592991975", "unsafe": false, "start_id": "1551812003923655140", "end_id": "1552488798275987505", "count": 28, "source": 2, "type": 3}, {"topic": "Googlebook OS", "summ_short": "Discussion about the new Android OS and its name, Googlebook OS.", "message_ids": ["1552418893509407404", "1552419224597235424", "1552419239702215163", "1552420904525763125", "1552421595538204951", "1552428311663274486", "1552429055258148692", "1552429082074939059", "1552432489593081529", "1552433182012464885", "1552433480334141386", "1552433551001941242", "1552433658252244168", "1552433800791189383", "1552434062145179882"], "people": ["212005965988371747", "663450955099988281", "783728416556133353", "803575323070555561", "864226873697400366", "949691680797998987", "1503588019056563945"], "id": "1552429059700116079", "unsafe": false, "start_id": "1552418893509407404", "end_id": "1552434062145179882", "count": 15, "source": 2, "type": 3}, {"topic": "Googlebook OS", "summ_short": "Discussion about the new Android OS and its name, Googlebook OS.", "message_ids": ["1552419224597235424", "1552419239702215163"], "people": ["663450955099988281"], "id": "1552435802034424155", "unsafe": false, "start_id": "1552419224597235424", "end_id": "1552419239702215163", "count": 2, "source": 2, "type": 3}]}
"""#

    /// `GET /channels/983622219499953020/summaries/1551688682463957073`.
    private static let one = #"""
{"topic":"Nitro Credits Bug","summ_short":"Discussion about a bug with Nitro credits and the need for private profiles.","message_ids":["1551684919267172537","1551685844109971952","1551685879689425379","1551686467933775417","1551686521638690373","1551686591526583286","1551687134045354418","1551687634281529350","1551688056408315542","1551688075500513951","1551688172467022562","1551688188754479259","1551688300574665131","1551688390157879300","1551688466263012213","1551688523111841065","1551688611038598129","1551688634364438459","1551688636326486159"],"people":["1097101542676504657","1329817381406162207","1363394132419079785","940637019163898541","360123810111147788","1136105591269223853"],"id":"1551688682463957073","unsafe":false,"start_id":"1551684919267172537","end_id":"1551688636326486159","count":19,"source":2,"type":3}
"""#

    @Test("The list decodes, newest first by where each stretch begins")
    func list() throws {
        let dto = try DiscordREST.decoder.decode(SummaryListDTO.self, from: Data(Self.list.utf8))
        let summaries = ChannelSummary.newestFirst(dto.summaries.compactMap(\.domain))
        #expect(summaries.count == 3)
        // The wire runs by where each ends; the store by where each begins.
        #expect(summaries.map(\.topic) == ["Googlebook OS", "Googlebook OS", "Discord's New Badges"])
        let badges = try #require(summaries.last)
        #expect(badges.id == ChannelSummaryID(rawValue: 1_551_865_480_592_991_975))
        #expect(badges.startMessageID == MessageID(rawValue: 1_551_812_003_923_655_140))
        #expect(badges.endMessageID == MessageID(rawValue: 1_552_488_798_275_987_505))
        #expect(badges.messageCount == 28)
        #expect(badges.people.count == 19)
        #expect(badges.summary == "Discussion about the new badges on Discord and their functionality.")
    }

    @Test("One summary decodes from its bare object")
    func one() throws {
        let summary = try #require(
            try DiscordREST.decoder.decode(SummaryDTO.self, from: Data(Self.one.utf8)).domain
        )
        #expect(summary.topic == "Nitro Credits Bug")
        #expect(summary.messageCount == 19)
        #expect(summary.people.count == 6)
    }

    @Test("A bare array is a list too, and an entry that cannot be placed is dropped")
    func tolerance() throws {
        let bare = #"[{"id":"9","topic":"T","summ_short":"S","people":["1","1","2"],"start_id":"5","end_id":"7","count":3}, {}]"#
        let dto = try DiscordREST.decoder.decode(SummaryListDTO.self, from: Data(bare.utf8))
        let summaries = dto.summaries.compactMap(\.domain)
        #expect(summaries.count == 1)
        // Each person once, as Discord's own mapping keeps them.
        #expect(summaries.first?.people == [UserID(rawValue: 1), UserID(rawValue: 2)])
    }

    @Test("A live update decodes to its channel and its summaries")
    func liveUpdate() throws {
        let frame = #"{"op":0,"s":42,"t":"CONVERSATION_SUMMARY_UPDATE","d":{"channel_id":"983622219499953020","guild_id":"603970300668805120","summaries":[{"id":"1551688682463957073","topic":"Nitro Credits Bug","summ_short":"x","people":[],"start_id":"1551684919267172537","end_id":"1551688636326486159","count":19}]}}"#
        let payload = try JSONDecoder().decode(GatewayFrame.self, from: Data(frame.utf8)).payload
        guard case .summariesUpdated(let channelID, let summaries)? = GatewayUpdate(payload) else {
            Issue.record("not a summary update")
            return
        }
        #expect(channelID == ChannelID(rawValue: 983_622_219_499_953_020))
        #expect(summaries.map(\.topic) == ["Nitro Credits Bug"])
    }

    // MARK: Server themes

    /// The captured object, verbatim.
    private static let theme = ##"{"preset_id": null, "custom_user_theme_settings": {"colors": ["#77C579"], "gradient_color_stops": [], "gradient_angle": 0, "base_mix": 0}, "enabled": true}"##

    @Test("A guild's theme decodes from the top level and from READY's properties")
    func theme() throws {
        let top = #"{"id":"302094807046627600","name":"MINECRAFT","features":["GUILD_THEME"],"owner_configured_content_level":0,"theme":"# + Self.theme + "}"
        let guild = try DiscordREST.decoder.decode(GuildDTO.self, from: Data(top.utf8)).domain
        let theme = try #require(guild.theme)
        #expect(theme.isEnabled)
        #expect(theme.colors == [0x77_C5_79])
        #expect(!theme.hasGradientStops)
        #expect(theme.baseMix == 0)
        #expect(theme.resolved == .custom(color: 0x77_C5_79, angle: 0, baseMix: 0))
        #expect(!guild.isAgeRestricted)

        let nested = #"{"id":"1","properties":{"name":"P","owner_configured_content_level":3,"theme":"# + Self.theme + "}}"
        let ready = try DiscordREST.decoder.decode(GuildDTO.self, from: Data(nested.utf8))
        #expect(ready.domain.theme == theme)
        #expect(ready.domain.isAgeRestricted)
        #expect(ready.carriesTheme)
    }

    @Test("A theme left out is not a theme taken away; null is")
    func absentAndNull() throws {
        let absent = try DiscordREST.decoder.decode(GuildDTO.self, from: Data(#"{"id":"1"}"#.utf8))
        #expect(!absent.carriesTheme)
        let null = try DiscordREST.decoder.decode(GuildDTO.self, from: Data(#"{"id":"1","theme":null}"#.utf8))
        #expect(null.carriesTheme)
        #expect(null.domain.theme == nil)
    }

    @Test("A theme of a shape nobody has seen draws nothing and fails nothing")
    func malformed() throws {
        let odd = #"{"id":"1","theme":{"enabled":true,"custom_user_theme_settings":{"colors":[7]}}}"#
        let guild = try DiscordREST.decoder.decode(GuildDTO.self, from: Data(odd.utf8))
        #expect(guild.carriesTheme)
        #expect(guild.domain.theme == nil)
        let bad = ##"{"id":"1","theme":{"enabled":true,"custom_user_theme_settings":{"colors":["#77C579","nope"]}}}"##
        #expect(try DiscordREST.decoder.decode(GuildDTO.self, from: Data(bad.utf8)).domain.theme?.colors == [])
    }

    // MARK: The reader's preference

    /// `appearance` with a theme (field 1), the preference (14) and a switch
    /// this client never reads (15); `guilds` with one server set to its own.
    private static func blob(preference: UInt64?) -> Data {
        var appearance = ProtobufWriter()
        appearance.varint(field: 1, 2)
        if let preference { appearance.varint(field: 14, preference) }
        appearance.varint(field: 15, 1)
        var settings = ProtobufWriter()
        settings.varint(field: 13, 2)
        var entry = ProtobufWriter()
        entry.fixed64(field: 1, 603_970_300_668_805_120)
        entry.message(field: 2, settings.data)
        var guilds = ProtobufWriter()
        guilds.message(field: 1, entry.data)
        var outer = ProtobufWriter()
        outer.message(field: 3, guilds.data)
        outer.message(field: 13, appearance.data)
        return outer.data
    }

    @Test("The default and each server's own are read, and unset reads as the server's")
    func decodePreference() {
        let decoded = UserSettingsProto.decode(Self.blob(preference: 1)).serverThemes
        #expect(decoded.default == .personal)
        let previews = GuildID(rawValue: 603_970_300_668_805_120)
        #expect(decoded.overrides[previews] == .guild)
        #expect(decoded.usesServerTheme(in: previews))
        #expect(!decoded.usesServerTheme(in: GuildID(rawValue: 5)))

        let unset = UserSettingsProto.decode(Self.blob(preference: nil)).serverThemes
        #expect(unset.default == .unspecified)
        #expect(unset.usesServerTheme(in: GuildID(rawValue: 5)))
    }

    @Test("Writing the default changes field 14 and carries every other byte of appearance")
    func patchPreference() throws {
        let body = UserSettingsProto.patchDefaultServerTheme(.guild, in: Self.blob(preference: 1))
        let data = try #require(Data(base64Encoded: body))
        var reader = ProtobufReader(data)
        let first = reader.next()
        let field = try #require(first)
        #expect(field.number == 13)
        #expect(reader.next() == nil)
        var inner = reader.reader(for: field)
        var seen: [Int: UInt64] = [:]
        while let entry = inner.next() { seen[entry.number] = entry.value }
        #expect(seen == [1: 2, 14: 2, 15: 1])
    }
}
