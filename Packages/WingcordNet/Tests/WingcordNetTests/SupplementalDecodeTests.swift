import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// The half of the bootstrap this client had been asking for and throwing away.
///
/// **The bug these pin down was invisible in the code and obvious in the
/// documentation.** `capabilities` carries `PRIORITIZED_READY_PAYLOAD` (1 << 5)
/// and `DEDUPE_USER_OBJECTS` (1 << 4); the gateway guild object's own footnotes
/// say what those bits do — `voice_states` is *omitted* from READY and sent in
/// `READY_SUPPLEMENTAL` instead, guild members collapse into `merged_members`,
/// and every member and presence names its person with `user_id` rather than a
/// user object. A client that reads only READY therefore believes every voice
/// channel in the account is empty, for ever, and has no error anywhere to say
/// so.
///
/// The payloads below are the documented shapes with the account's own ids
/// replaced. The two things they exist to hold are the ones that fail silently:
/// **a state nested in a guild carries no `guild_id`**, and **the merged arrays
/// are positional**.
struct ReadySupplementalDecodeTests {

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    /// Two guilds, each with somebody in a room, and the members and presences
    /// that belong to them — in the parallel arrays the capability produces.
    private static let payload = """
    {
      "guilds": [
        {
          "id": "574217343635554305",
          "voice_states": [
            {
              "user_id": "987654321987654321",
              "channel_id": "1547595286728000033",
              "session_id": "a1",
              "self_mute": false,
              "self_stream": true
            },
            {
              "user_id": "1051931404149393511",
              "channel_id": "1547595286728000033",
              "session_id": "a2",
              "self_deaf": true,
              "self_mute": true
            }
          ],
          "activity_instances": []
        },
        {
          "id": "672208888016632122",
          "voice_states": [
            {
              "user_id": "852892297663134629",
              "channel_id": "850360749463584969",
              "session_id": "b1",
              "mute": true
            }
          ]
        }
      ],
      "merged_members": [
        [
          { "user_id": "987654321987654321", "nick": "Comet", "roles": ["1"] },
          { "user_id": "1051931404149393511", "roles": [] }
        ],
        [
          { "user_id": "852892297663134629", "nick": "berrin", "roles": [] }
        ]
      ],
      "merged_presences": {
        "friends": [
          { "user_id": "999999999999999999", "status": "dnd", "activities": [] }
        ],
        "guilds": [
          [
            {
              "user_id": "987654321987654321",
              "status": "online",
              "activities": [
                { "name": "Counter-Strike 2", "type": 0, "application_id": "1158877933042143272" }
              ]
            }
          ],
          [
            { "user_id": "852892297663134629", "status": "idle", "activities": [] }
          ]
        ]
      },
      "lazy_private_channels": [
        { "id": "1234567890", "type": 1, "recipient_ids": ["852892297663134629"] }
      ]
    }
    """

    @Test("Every guild's voice states arrive, and each one is stamped with its guild")
    func voiceStates() throws {
        let snapshot = ReadySupplementalSnapshot(
            payload: try Self.decode(ReadySupplementalPayload.self, Self.payload)
        )
        #expect(snapshot.voiceStates.count == 3)

        // The state is nested in its guild and says so nowhere else. Without the
        // stamp every one of these looks like a direct-message call.
        let streamer = try #require(snapshot.voiceStates[UserID(rawValue: 987654321987654321)])
        #expect(streamer.guildID == GuildID(rawValue: 574217343635554305))
        #expect(streamer.channelID == ChannelID(rawValue: 1547595286728000033))
        #expect(streamer.isStreaming)

        let elsewhere = try #require(snapshot.voiceStates[UserID(rawValue: 852892297663134629)])
        #expect(elsewhere.guildID == GuildID(rawValue: 672208888016632122))
        // A moderator's mute, not their own — the two are different facts and a
        // client that folds them cannot say which it is.
        #expect(elsewhere.isServerMuted)
        #expect(!elsewhere.isSelfMuted)
    }

    @Test("A member with only a user_id is still a member")
    func dedupedMembers() throws {
        let snapshot = ReadySupplementalSnapshot(
            payload: try Self.decode(ReadySupplementalPayload.self, Self.payload)
        )
        let first = GuildID(rawValue: 574217343635554305)
        #expect(snapshot.membersByGuild[first]?.count == 2)
        #expect(
            snapshot.membersByGuild[first]?[UserID(rawValue: 987654321987654321)]?.nickname
                == "Comet"
        )
        // The second guild's, which proves the arrays were walked in step
        // rather than the first one being read twice.
        let second = GuildID(rawValue: 672208888016632122)
        #expect(
            snapshot.membersByGuild[second]?[UserID(rawValue: 852892297663134629)]?.nickname
                == "berrin"
        )
    }

    @Test("Guild presences land against their own guild's people, and friends land too")
    func presences() throws {
        let snapshot = ReadySupplementalSnapshot(
            payload: try Self.decode(ReadySupplementalPayload.self, Self.payload)
        )
        #expect(snapshot.presences.count == 3)
        let playing = try #require(snapshot.presences[UserID(rawValue: 987654321987654321)])
        #expect(playing.status == .online)
        #expect(playing.primaryActivity?.name == "Counter-Strike 2")
        #expect(
            playing.primaryActivity?.applicationID
                == ApplicationID(rawValue: 1158877933042143272)
        )
        // A friend, who belongs to no guild in the array.
        #expect(snapshot.presences[UserID(rawValue: 999999999999999999)]?.status == .doNotDisturb)
    }

    @Test("The conversations READY held back are carried")
    func lazyPrivateChannels() throws {
        let snapshot = ReadySupplementalSnapshot(
            payload: try Self.decode(ReadySupplementalPayload.self, Self.payload)
        )
        #expect(snapshot.privateChannels.count == 1)
        #expect(snapshot.privateChannels.first?.kind == .directMessage)
    }

    /// **The failure this guard exists for is silent and wrong**, not loud: a
    /// merged array shorter than the guild list would file one server's members
    /// under another and every nickname in the sidebar would belong to somebody
    /// else. Dropping them leaves names to the routes that answer with them.
    @Test("A merged array out of step with the guilds is dropped, and voice survives it")
    func misalignedArraysAreDropped() throws {
        let snapshot = ReadySupplementalSnapshot(payload: try Self.decode(
            ReadySupplementalPayload.self,
            """
            {
              "guilds": [
                { "id": "1", "voice_states": [
                  { "user_id": "10", "channel_id": "100", "session_id": "x" }
                ] },
                { "id": "2", "voice_states": [] }
              ],
              "merged_members": [[{ "user_id": "10", "nick": "wrong" }]],
              "merged_presences": { "guilds": [[{ "user_id": "10", "status": "online" }]] }
            }
            """
        ))
        #expect(snapshot.voiceStates.count == 1)
        #expect(snapshot.membersByGuild.isEmpty)
        #expect(snapshot.presences.isEmpty)
    }

    /// A state with a null channel is a departure, and a bootstrap has no
    /// departures in it — carrying one would put somebody in "no channel",
    /// which reads as being in every list and none.
    @Test("A state with no channel is not a person in a room")
    func nullChannelIsNotCarried() throws {
        let snapshot = ReadySupplementalSnapshot(payload: try Self.decode(
            ReadySupplementalPayload.self,
            """
            { "guilds": [{ "id": "1", "voice_states": [
              { "user_id": "10", "channel_id": null, "session_id": "x" }
            ] }] }
            """
        ))
        #expect(snapshot.voiceStates.isEmpty)
    }

    /// A voice state may carry its member inline, and that copy is fresher than
    /// the one `merged_members` sent a field earlier in the same payload.
    @Test("A member on the voice state wins over the merged one")
    func inlineMemberWins() throws {
        let snapshot = ReadySupplementalSnapshot(payload: try Self.decode(
            ReadySupplementalPayload.self,
            """
            {
              "guilds": [{ "id": "1", "voice_states": [
                { "user_id": "10", "channel_id": "100", "session_id": "x",
                  "member": { "user_id": "10", "nick": "newer" } }
              ] }],
              "merged_members": [[{ "user_id": "10", "nick": "older" }]]
            }
            """
        ))
        #expect(
            snapshot.membersByGuild[GuildID(rawValue: 1)]?[UserID(rawValue: 10)]?.nickname
                == "newer"
        )
    }
}

/// The periodic delta for a guild nobody is looking at.
///
/// **The bit that turns these on is already in this client's IDENTIFY.**
/// `PASSIVE_GUILD_UPDATE_V2` (1 << 14) tells Discord to *stop* sending
/// `VOICE_STATE_UPDATE` and `CHANNEL_UNREAD_UPDATE` for unsubscribed guilds and
/// send this instead — so a client that enables it and does not read it has
/// asked to be told nothing about every server it is not currently in.
struct PassiveUpdateDecodeTests {

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private static func update(_ json: String) throws -> GatewayUpdate? {
        GatewayUpdate(.passiveUpdate(try decode(PassiveUpdateDTO.self, json)))
    }

    @Test("Arrivals, departures, the members behind them and the unreads all come out")
    func fullDelta() throws {
        let update = try Self.update("""
        {
          "guild_id": "574217343635554305",
          "updated_channels": [
            { "id": "672208888016632122", "last_message_id": "1547602533569583309" }
          ],
          "updated_voice_states": [
            { "user_id": "10", "channel_id": "100", "session_id": "s" }
          ],
          "removed_voice_states": ["11", "12"],
          "updated_members": [{ "user_id": "10", "nick": "here" }]
        }
        """)
        guard case .passiveGuildUpdate(
            let guildID, let states, let departed, let members, _, let unreads
        ) = update else {
            Issue.record("expected a passive update, got \(String(describing: update))")
            return
        }
        #expect(guildID == GuildID(rawValue: 574217343635554305))
        // The guild is on the event and not on the states nested in it.
        #expect(states.first?.guildID == guildID)
        #expect(departed == [UserID(rawValue: 11), UserID(rawValue: 12)])
        #expect(members[UserID(rawValue: 10)]?.nickname == "here")
        #expect(unreads.first?.channelID == ChannelID(rawValue: 672208888016632122))
    }

    /// **A departure here is a bare id**, which is the one place Discord's two
    /// ways of saying "they left" differ — everywhere else it is a state with a
    /// null channel. A client that reads only the states leaves everybody in the
    /// room for ever.
    @Test("A delta that is only departures is still an event")
    func departuresAlone() throws {
        let update = try Self.update("""
        { "guild_id": "1", "removed_voice_states": ["11"] }
        """)
        guard case .passiveGuildUpdate(_, let states, let departed, _, _, _) = update else {
            Issue.record("expected a passive update")
            return
        }
        #expect(states.isEmpty)
        #expect(departed == [UserID(rawValue: 11)])
    }

    /// Discord sends these on a timer whether or not anything moved. An empty
    /// one that still produced an event would bump the sidebar's revision every
    /// few seconds, per guild, for nothing.
    @Test("A delta with nothing in it produces no event at all")
    func emptyDeltaIsDropped() throws {
        #expect(try Self.update(#"{ "guild_id": "1" }"#) == nil)
    }
}

/// What a voice channel says about itself, across the three events that say it.
struct VoiceChannelInfoDecodeTests {

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private static func patches(_ payload: GatewayFrame.Payload) throws -> [ChannelID: VoiceChannelPatch] {
        guard case .voiceChannelInfoChanged(_, let patches) = GatewayUpdate(payload) else {
            throw Failure.missing
        }
        return patches
    }

    private enum Failure: Error { case missing }

    /// **A status update mentions no clock, and must not stop one.** The outer
    /// optional is what carries that: nil is "this event said nothing", and
    /// `.some(nil)` is "it said the value is gone".
    @Test("A status change patches the status and leaves the clock alone")
    func statusOnly() throws {
        let patches = try Self.patches(.voiceChannelStatusUpdate(
            try Self.decode(VoiceChannelStatusDTO.self, """
            { "id": "100", "guild_id": "1", "status": "9k+ eu prem" }
            """)
        ))
        let patch = try #require(patches[ChannelID(rawValue: 100)])
        #expect(patch.status == .some("9k+ eu prem"))
        #expect(patch.sessionStartedAt == nil)

        var info = VoiceChannelInfo(status: "old", sessionStartedAt: .distantPast)
        info.apply(patch)
        #expect(info.status == "9k+ eu prem")
        #expect(info.sessionStartedAt == .distantPast)
    }

    @Test("A cleared status is a change, not an absence")
    func clearedStatus() throws {
        let patches = try Self.patches(.voiceChannelStatusUpdate(
            try Self.decode(VoiceChannelStatusDTO.self, #"{ "id": "100", "status": null }"#)
        ))
        var info = VoiceChannelInfo(status: "was here")
        info.apply(try #require(patches[ChannelID(rawValue: 100)]))
        #expect(info.status == nil)
        #expect(info.isEmpty)
    }

    /// The documentation types this field two ways in two places — an ISO-8601
    /// timestamp on the channel metadata, an integer on the update event — and
    /// describes both as unix seconds. A decoder that assumes one throws away
    /// every payload that sends the other, and a throw here costs the whole
    /// frame rather than the timer.
    @Test("A session clock decodes from seconds and from an ISO instant")
    func bothClockShapes() throws {
        let seconds = try Self.patches(.voiceChannelStartTimeUpdate(
            try Self.decode(VoiceChannelStartTimeDTO.self, """
            { "id": "100", "guild_id": "1", "voice_start_time": 1789047652 }
            """)
        ))
        #expect(
            seconds[ChannelID(rawValue: 100)]?.sessionStartedAt
                == .some(Date(timeIntervalSince1970: 1789047652))
        )

        let iso = try Self.decode(ChannelMetadataDTO.self, """
        { "id": "100", "voice_start_time": "2026-09-10T12:00:00+00:00" }
        """)
        #expect(iso.voice_start_time?.date != nil)
    }

    @Test("A session that ended is a null clock, not a missing one")
    func endedSession() throws {
        let patches = try Self.patches(.voiceChannelStartTimeUpdate(
            try Self.decode(VoiceChannelStartTimeDTO.self, """
            { "id": "100", "voice_start_time": null }
            """)
        ))
        var info = VoiceChannelInfo(sessionStartedAt: .distantPast)
        info.apply(try #require(patches[ChannelID(rawValue: 100)]))
        #expect(info.sessionStartedAt == nil)
    }

    /// **Opcode 43's answer is authoritative, and that is what clears a label
    /// taken down while the client was away.** No event announces a status the
    /// server has forgotten, so a merge here would leave a stale line under a
    /// channel name for the life of the session.
    @Test("The channel-info answer sets both fields on every channel it lists")
    func channelInfoIsAuthoritative() throws {
        let patches = try Self.patches(.channelInfo(
            try Self.decode(ChannelInfoPayload.self, """
            {
              "guild_id": "1",
              "channels": [
                { "id": "100", "status": "NA COMP 6+", "voice_start_time": 1789047652 },
                { "id": "101" }
              ]
            }
            """)
        ))
        #expect(patches[ChannelID(rawValue: 100)]?.status == .some("NA COMP 6+"))

        var stale = VoiceChannelInfo(status: "taken down", sessionStartedAt: .distantPast)
        stale.apply(try #require(patches[ChannelID(rawValue: 101)]))
        #expect(stale.isEmpty)
    }

    /// READY is where a status *first* arrives — no REST channel route carries
    /// one — so a snapshot that dropped it would leave every label absent until
    /// somebody happened to retype it.
    @Test("READY's guild channels give up their labels")
    func readyHarvestsStatuses() throws {
        let ready = try Self.decode(ReadyPayload.self, """
        {
          "user": { "id": "1", "username": "me", "discriminator": "0" },
          "session_id": "s",
          "guilds": [{
            "id": "1",
            "properties": { "id": "1", "name": "G" },
            "name": "G",
            "channels": [
              { "id": "100", "type": 2, "name": "Team 683", "status": "NA COMP 6+" },
              { "id": "101", "type": 2, "name": "Team 694" },
              { "id": "102", "type": 0, "name": "general" }
            ]
          }]
        }
        """)
        let snapshot = ReadySnapshot(payload: ready)
        #expect(snapshot.voiceChannelInfo.count == 1)
        #expect(snapshot.voiceChannelInfo[ChannelID(rawValue: 100)]?.status == "NA COMP 6+")
    }

    /// **A guild's notification floor arrives nested, and was read flat.**
    ///
    /// This client asks for `PRIORITIZED_READY_PAYLOAD`, so READY sends a
    /// guild's own fields under `properties`. `default_message_notifications`
    /// was declared only at the top level, so it was absent on every guild in
    /// every READY and fell back to `allMessages` — which is the *loudest*
    /// answer, and the opposite of what most large servers are set to.
    ///
    /// Nothing failed: the inbox simply listed every channel with anything
    /// unread rather than the handful that would have told the reader
    /// anything, and the notification policy read the same wrong floor.
    @Test("A guild's notification default is read from its nested properties")
    func guildDefaultNotificationsComeFromProperties() throws {
        let ready = try Self.decode(ReadyPayload.self, """
        {
          "user": { "id": "1", "username": "me", "discriminator": "0" },
          "session_id": "s",
          "guilds": [
            {
              "id": "1",
              "properties": {
                "id": "1", "name": "Quiet",
                "default_message_notifications": 1
              }
            },
            {
              "id": "2",
              "properties": { "id": "2", "name": "Loud" },
              "default_message_notifications": 0
            },
            { "id": "3", "properties": { "id": "3", "name": "Unstated" } }
          ]
        }
        """)
        let snapshot = ReadySnapshot(payload: ready)
        let levels = Dictionary(
            uniqueKeysWithValues: snapshot.guilds.map {
                ($0.id, $0.defaultMessageNotifications)
            }
        )
        // Nested — the case that was silently wrong.
        #expect(levels[GuildID(rawValue: 1)] == .onlyMentions)
        // Top level still wins where Discord sends it there.
        #expect(levels[GuildID(rawValue: 2)] == .allMessages)
        // Absent from both is the documented default, and is the one answer
        // that must stay loud: a server nobody has configured must not be the
        // reason somebody stops being told.
        #expect(levels[GuildID(rawValue: 3)] == .allMessages)
    }

    /// The AFK room is read from both shapes for the same reason — §5.9: a
    /// field declared at one level is a field every READY drops.
    @Test("A guild's AFK channel is read from either level")
    func guildAFKChannelComesFromEitherLevel() throws {
        let ready = try Self.decode(ReadyPayload.self, """
        {
          "user": { "id": "1", "username": "me", "discriminator": "0" },
          "session_id": "s",
          "guilds": [
            {
              "id": "1",
              "properties": { "id": "1", "name": "Nested", "afk_channel_id": "10" }
            },
            {
              "id": "2",
              "properties": { "id": "2", "name": "Flat" },
              "afk_channel_id": "20"
            },
            { "id": "3", "properties": { "id": "3", "name": "None", "afk_channel_id": null } }
          ]
        }
        """)
        let rooms = Dictionary(
            uniqueKeysWithValues: ReadySnapshot(payload: ready).guilds.map {
                ($0.id, $0.afkChannelID)
            }
        )
        #expect(rooms[GuildID(rawValue: 1)] == ChannelID(rawValue: 10))
        #expect(rooms[GuildID(rawValue: 2)] == ChannelID(rawValue: 20))
        #expect(rooms[GuildID(rawValue: 3)] == .some(nil))
    }

    /// **A read cursor of `"0"` is "never read", not a message id.**
    ///
    /// Discord sends it for every channel the reader has no position in, and
    /// carried through as a real cursor it is the most dangerous value on this
    /// payload: every snowflake compares greater than zero, so "everything
    /// after the cursor" silently becomes the channel's entire history. The
    /// inbox's Unreads tab drew a server's founding conversation from 2025 for
    /// channels that had been busy all week, because the first message after
    /// zero is the first message ever posted.
    ///
    /// It is nil at the wire boundary so no reader downstream has to know.
    @Test("A read cursor of zero is no cursor at all")
    func zeroReadCursorIsAbsent() throws {
        let ready = try Self.decode(ReadyPayload.self, """
        {
          "user": { "id": "1", "username": "me", "discriminator": "0" },
          "session_id": "s",
          "read_state": { "entries": [
            { "id": "100", "last_message_id": "0", "mention_count": 0 },
            { "id": "101", "last_message_id": "1530121851874556743", "mention_count": 2 }
          ]}
        }
        """)
        let snapshot = ReadySnapshot(payload: ready)
        #expect(snapshot.readStates[ChannelID(rawValue: 100)]?.lastAcknowledgedID == nil)
        #expect(
            snapshot.readStates[ChannelID(rawValue: 101)]?.lastAcknowledgedID
                == MessageID(rawValue: 1_530_121_851_874_556_743)
        )
        // Both are still unread — an absent cursor means nothing has been read,
        // never that there is nothing to read.
        #expect(
            snapshot.readStates[ChannelID(rawValue: 100)]?
                .isUnread(newest: MessageID(rawValue: 5)) == true
        )
    }
}
