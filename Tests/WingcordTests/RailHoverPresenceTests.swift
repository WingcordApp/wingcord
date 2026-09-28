import Foundation
import SwiftUI
import Testing
import WingcordCore
@testable import Wingcord

/// Who the rail's hover chip says is in a server.
///
/// **Only answerable at all since `READY_SUPPLEMENTAL` landed.** The voice
/// states for every guild the account is in arrive in that event and nowhere
/// else, so before it this whole surface would have drawn an empty row for every
/// server on the rail, permanently and with nothing to say why.
@Suite("The rail's hover presence")
@MainActor
struct RailHoverPresenceTests {

    private let reader = UserID(rawValue: 1)
    private let here = GuildID(rawValue: 1000)
    private let elsewhere = GuildID(rawValue: 2000)
    /// An ordinary voice room in `here`.
    private let room = ChannelID(rawValue: 1001)
    /// `here`'s AFK room.
    private let afk = ChannelID(rawValue: 1002)
    /// A voice room `@everyone` may not see.
    private let staff = ChannelID(rawValue: 1003)
    /// A stage channel, live unless a test says otherwise.
    private let stage = ChannelID(rawValue: 1004)
    /// `elsewhere`'s room.
    private let lounge = ChannelID(rawValue: 2001)

    /// Two servers shaped the way the rail meets them: a room, an AFK room, a
    /// room the reader cannot see and a live stage, with `@everyone` allowed to
    /// see and join — or the permission gate hides every room and each test
    /// fails for a reason nothing in it says.
    private func model() -> AppModel {
        let model = AppModel()
        model.currentUserID = reader
        let owner = UserID(rawValue: 9)
        model.guilds = [
            here: Guild(id: here, name: "Here", ownerID: owner, afkChannelID: afk),
            elsewhere: Guild(id: elsewhere, name: "Elsewhere", ownerID: owner),
        ]
        let hereEveryone = RoleID(rawValue: here.rawValue)
        var index = ChannelIndex()
        index.replaceChannels(
            [
                Channel(id: room, kind: .voice, guildID: here, name: "General"),
                Channel(id: afk, kind: .voice, guildID: here, name: "AFK"),
                Channel(
                    id: staff, kind: .voice, guildID: here, name: "Staff",
                    overwrites: [PermissionOverwrite(
                        id: hereEveryone.rawValue, subject: .role, allow: [], deny: [.viewChannel]
                    )]
                ),
                Channel(id: stage, kind: .stage, guildID: here, name: "Town Hall"),
            ],
            inGuild: here
        )
        index.replaceChannels(
            [Channel(id: lounge, kind: .voice, guildID: elsewhere, name: "Lounge")],
            inGuild: elsewhere
        )
        model.channelIndex = index
        for guild in [here, elsewhere] {
            let everyone = RoleID(rawValue: guild.rawValue)
            model.roles[guild] = [
                everyone: Role(
                    id: everyone, name: "@everyone", position: 0,
                    permissions: [.viewChannel, .connect, .speak]
                ),
            ]
            model.members[guild] = [reader: Member(userID: reader, roleIDs: [])]
        }
        model.stageInstances[stage] = StageInstance(
            id: 1, guildID: here, channelID: stage, topic: "Q&A"
        )
        return model
    }

    private func join(
        _ model: AppModel,
        _ id: UInt64,
        in channelID: ChannelID? = nil,
        streaming: Bool = false,
        camera: Bool = false,
        suppressed: Bool = false
    ) {
        let channelID = channelID ?? room
        let userID = UserID(rawValue: id)
        model.users[userID] = User(id: userID, username: "person\(id)")
        model.voiceStates[userID] = VoiceState(
            userID: userID,
            channelID: channelID,
            guildID: model.channelIndex[channelID]?.guildID,
            sessionID: "s",
            isStreaming: streaming,
            isCameraOn: camera,
            isSuppressed: suppressed
        )
    }

    private func ids(_ row: RailHoverPresence.Row) -> [UserID] {
        row.faces.map(\.id)
    }

    // MARK: Who the chip names

    @Test("Only this server's people, in id order")
    func scopedToItsOwnServer() {
        let model = model()
        join(model, 30)
        join(model, 20)
        join(model, 40, in: lounge)

        let presence = model.railHoverPresence(for: here)
        // Ordered by id: by name it would reshuffle whenever somebody was
        // renamed, and by nothing on every rehash.
        #expect(ids(presence.voice) == [UserID(rawValue: 20), UserID(rawValue: 30)])
        #expect(presence.voice.overflow == 0)
        #expect(presence.streams.isEmpty)
        #expect(presence.rowCount == 1)
    }

    /// **The count that was wrong**: Discord draws a screen share in its own
    /// row and not again in voice, and a camera is somebody in voice.
    @Test("A screen share is drawn once, in its own row; a camera stays in voice")
    func streamsAreApartFromVoice() {
        let model = model()
        join(model, 20)
        join(model, 21, streaming: true)
        join(model, 22, camera: true)

        let presence = model.railHoverPresence(for: here)
        #expect(ids(presence.voice) == [UserID(rawValue: 20), UserID(rawValue: 22)])
        #expect(ids(presence.streams) == [UserID(rawValue: 21)])
        #expect(presence.rowCount == 2)
    }

    /// The other three differences, each one somebody Discord does not count:
    /// parked for being idle, in a room the reader cannot see, or blocked.
    @Test("The AFK room, hidden rooms and blocked people are not in voice")
    func discordsExclusions() {
        let model = model()
        join(model, 20)
        join(model, 21, in: afk)
        join(model, 22, in: staff)
        join(model, 23)
        join(model, 24)
        model.blockedUserIDs = [UserID(rawValue: 23)]
        model.ignoredUserIDs = [UserID(rawValue: 24)]

        let presence = model.railHoverPresence(for: here)
        #expect(ids(presence.voice) == [UserID(rawValue: 20)])
    }

    /// A stage is not a voice room: its speakers get a row of three and its
    /// audience is a count, and neither lands in voice.
    @Test("A live stage draws its speakers and counts its listeners")
    func stageRow() {
        let model = model()
        join(model, 20)
        join(model, 30, in: stage)
        join(model, 31, in: stage)
        for id in 40..<45 { join(model, UInt64(id), in: stage, suppressed: true) }

        let presence = model.railHoverPresence(for: here)
        #expect(ids(presence.stage) == [UserID(rawValue: 30), UserID(rawValue: 31)])
        #expect(presence.stageListeners == 5)
        #expect(ids(presence.voice) == [UserID(rawValue: 20)])
        #expect(presence.rowCount == 2)
    }

    @Test("A stage that is not live is not a row")
    func darkStageIsNoRow() {
        let model = model()
        model.stageInstances = [:]
        join(model, 30, in: stage)

        #expect(model.railHoverPresence(for: here).isEmpty)
    }

    /// **Discord's facepile, exactly.** A full row draws everybody; an
    /// overflowing one gives its last slot to the count, which is what is
    /// *left* — five faces and "+62" is sixty-seven people.
    @Test("A row draws all it can hold, then five faces and the remainder", arguments: [
        (count: 5, faces: 5, overflow: 0),
        (count: 6, faces: 6, overflow: 0),
        (count: 7, faces: 5, overflow: 2),
        (count: 67, faces: 5, overflow: 62),
        (count: 400, faces: 5, overflow: 99),
    ])
    func facepile(count: Int, faces: Int, overflow: Int) {
        let pile = RailHoverPresence.pile(count: count, slots: RailHoverPresence.faceSlots)
        #expect(pile.faces == faces)
        #expect(pile.overflow == overflow)
    }

    @Test("Six people in voice are six faces and no count")
    func sixIsAFullRow() {
        let model = model()
        for id in 20..<26 { join(model, UInt64(id)) }

        let presence = model.railHoverPresence(for: here)
        #expect(presence.voice.faces.count == 6)
        #expect(presence.voice.overflow == 0)
    }

    /// **The common case, and the one that must cost nothing.** Almost every
    /// server on a rail has nobody in voice, and the chip for one of those has
    /// to be the chip it always was — one line, one band, no rows.
    @Test("A quiet server adds nothing to the chip")
    func quietServerIsUnchanged() {
        let model = model()
        join(model, 20, in: lounge)

        let presence = model.railHoverPresence(for: here)
        #expect(presence.isEmpty)
        #expect(presence.rowCount == 0)
    }

    /// A departure is a state with a null channel — Discord sends no leave
    /// event — and one left in the table would keep somebody's face on the chip
    /// for ever.
    @Test("Somebody who has left is not in the room")
    func departedIsNotDrawn() {
        let model = model()
        model.stageInstances = [:]
        join(model, 20)
        model.voiceStates[UserID(rawValue: 20)]?.channelID = nil

        #expect(model.railHoverPresence(for: here).isEmpty)
        #expect(model.voiceMarksByGuild.isEmpty)
    }

    // MARK: The mark on the tile

    @Test("A server with anybody talking in a room is marked")
    func quietRoomsAreStillMarked() {
        let model = model()
        model.stageInstances = [:]
        join(model, 20)
        join(model, 21, in: lounge, streaming: true)

        let marks = model.voiceMarksByGuild
        #expect(marks[here] == .voice)
        #expect(marks[elsewhere] == .screenShare)
    }

    /// Discord's ranking, and whichever order the table is walked in: it is a
    /// dictionary, so a rule written as "last writer wins" would draw a
    /// speaker on a server with a stream in it about half the time.
    @Test("Stage over screen over camera over voice")
    func ranking() {
        let model = model()
        model.stageInstances = [:]
        join(model, 20, streaming: true)
        for id in 21..<40 { join(model, UInt64(id)) }
        #expect(model.voiceMarksByGuild[here] == .screenShare)

        model.voiceStates[UserID(rawValue: 20)]?.isStreaming = false
        model.voiceStates[UserID(rawValue: 30)]?.isCameraOn = true
        #expect(model.voiceMarksByGuild[here] == .video)

        model.stageInstances[stage] = StageInstance(
            id: 1, guildID: here, channelID: stage, topic: "Q&A"
        )
        #expect(model.voiceMarksByGuild[here] == .stage)
    }

    @Test("Rooms the chip leaves out do not mark the tile either")
    func markUsesTheChipsRooms() {
        let model = model()
        model.stageInstances = [:]
        join(model, 20, in: afk)
        join(model, 21, in: staff)
        #expect(model.voiceMarksByGuild[here] == nil)
    }

    @Test("A muted server carries no mark")
    func mutedServerIsUnmarked() {
        let model = model()
        model.stageInstances = [:]
        join(model, 20)
        model.mutedGuildIDs = [here]
        #expect(model.voiceMarksByGuild[here] == nil)
    }

    /// **The server the reader is in a call in describes their own room**, and
    /// a mute does not take that away: the reader is in it.
    @Test("The reader's own call decides its server's mark")
    func ownRoomDecides() {
        let model = model()
        model.mutedGuildIDs = [here]
        join(model, 20, in: lounge)
        join(model, 21, in: room, streaming: true)
        join(model, 1)
        model.connectedVoiceChannelID = room

        // A live stage elsewhere in the server, and somebody streaming in the
        // reader's own room: neither is what the reader is doing.
        #expect(model.voiceMarksByGuild[here] == .voice)

        model.voiceStates[UserID(rawValue: 21)]?.isCameraOn = true
        #expect(model.voiceMarksByGuild[here] == .video)
    }

    /// A server nobody is in has no mark at all — nil rather than a `.voice`
    /// for everything, which would put a speaker on the whole rail.
    @Test("A silent server carries no mark")
    func silenceIsNoMark() {
        let model = model()
        model.stageInstances = [:]
        join(model, 20, in: lounge)

        #expect(model.voiceMarksByGuild[here] == nil)
    }

    // MARK: The hole the mark sits in

    /// **The bite is centred on the badge, and that is the whole contract.**
    /// The hole is cut by a `Shape` and filled by a `View`, which cannot see
    /// each other's numbers — so if these two ever disagree the mark sits beside
    /// its own hole, which looks like a rendering fault rather than a constant.
    @Test("The notch is centred exactly where the mark is drawn")
    func notchIsCentredOnTheMark() {
        let tile = CGRect(x: 0, y: 0, width: 44, height: 44)
        let notch = RailMarkGeometry.notch(in: tile)

        // Where the overlay actually puts the mark: top-trailing, then offset.
        let markCentre = CGPoint(
            x: tile.maxX - RailMarkGeometry.side / 2 + RailMarkGeometry.inset.x,
            y: tile.minY + RailMarkGeometry.side / 2 + RailMarkGeometry.inset.y
        )
        #expect(notch.midX == markCentre.x)
        #expect(notch.midY == markCentre.y)
    }

    /// The hole has to be bigger than the thing in it, or there is no ring of
    /// rail between them and the mark reads as printed on the icon again.
    @Test("The notch clears a ring around the mark")
    func notchClearsARing() {
        #expect(RailMarkGeometry.cutSide > RailMarkGeometry.side)
        #expect(
            RailMarkGeometry.cutSide - RailMarkGeometry.side
                == RailMarkGeometry.gap * 2
        )
    }

    /// **The defect this shape replaced, stated as behaviour.** The mask it
    /// supersedes erased the whole tile; what is wanted is that the corner under
    /// the mark stops being filled and everything else carries on being filled.
    ///
    /// Tested with `contains(_:eoFill:)` rather than against a bounding box: the
    /// ellipse deliberately hangs past the tile, so the *bounds* grow and it does
    /// not matter — a clip shape changes no layout, and the parts outside have
    /// nothing to take away. What matters is which points survive.
    @Test("The notch clears its own corner and leaves the rest of the tile")
    func notchClearsOnlyItsCorner() {
        // Selected geometry, so the corner under the mark is filled to begin
        // with — at rest the tile is a circle and that corner is already empty.
        let tile = CGRect(x: 0, y: 0, width: 44, height: 44)
        let cut = NotchedRailTile(cornerRadius: 14, isNotched: true).path(in: tile)
        let plain = NotchedRailTile(cornerRadius: 14, isNotched: false).path(in: tile)

        // A point inside both the tile and the bite.
        let inTheBite = CGPoint(x: 36, y: 8)
        #expect(plain.contains(inTheBite, eoFill: true))
        #expect(!cut.contains(inTheBite, eoFill: true))

        // And the tile itself is untouched everywhere else.
        for point in [CGPoint(x: 22, y: 22), CGPoint(x: 8, y: 8), CGPoint(x: 22, y: 40)] {
            #expect(cut.contains(point, eoFill: true))
        }
    }

    /// An unnotched tile is exactly the rounded square it always was — nothing
    /// about the shape changes for the servers with nobody in voice, which is
    /// nearly all of them.
    @Test("No mark leaves the tile exactly as it was")
    func unnotchedTileIsUnchanged() {
        let tile = CGRect(x: 0, y: 0, width: 44, height: 44)
        let plain = NotchedRailTile(cornerRadius: 14, isNotched: false).path(in: tile)
        #expect(
            plain.boundingRect
                == Path(roundedRect: tile, cornerRadius: 14, style: .continuous)
                    .boundingRect
        )
        #expect(plain.contains(CGPoint(x: 36, y: 8), eoFill: true))
    }
}
