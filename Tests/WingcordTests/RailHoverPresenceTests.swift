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

    private let here = GuildID(rawValue: 1000)
    private let elsewhere = GuildID(rawValue: 2000)

    private func model() -> AppModel {
        let model = AppModel()
        model.currentUserID = UserID(rawValue: 1)
        return model
    }

    private func join(
        _ model: AppModel,
        _ id: UInt64,
        guild: GuildID,
        streaming: Bool = false,
        camera: Bool = false
    ) {
        let userID = UserID(rawValue: id)
        model.users[userID] = User(id: userID, username: "person\(id)")
        model.voiceStates[userID] = VoiceState(
            userID: userID,
            channelID: ChannelID(rawValue: guild.rawValue + 1),
            guildID: guild,
            sessionID: "s",
            isStreaming: streaming,
            isCameraOn: camera
        )
    }

    @Test("Only this server's people, in join order")
    func scopedToItsOwnServer() {
        let model = model()
        join(model, 30, guild: here)
        join(model, 20, guild: here)
        join(model, 40, guild: elsewhere)

        let presence = model.railHoverPresence(for: here)
        // Ordered by id, which is join time — by name it would reshuffle
        // whenever somebody was renamed, and by nothing on every rehash.
        #expect(presence.voice.map(\.id) == [UserID(rawValue: 20), UserID(rawValue: 30)])
        #expect(presence.voiceOverflow == 0)
        #expect(presence.live.isEmpty)
        #expect(presence.rowCount == 1)
    }

    /// **A camera counts as well as a screen share**, because the row answers
    /// "is there something to watch" and both are.
    @Test("The live row is the people worth watching, and they are also in voice")
    func liveRow() {
        let model = model()
        join(model, 20, guild: here)
        join(model, 21, guild: here, streaming: true)
        join(model, 22, guild: here, camera: true)

        let presence = model.railHoverPresence(for: here)
        #expect(presence.voice.count == 3)
        #expect(presence.live.map(\.id) == [UserID(rawValue: 21), UserID(rawValue: 22)])
        #expect(presence.rowCount == 2)
    }

    /// Discord draws five faces and then a count. The count is what is *left*,
    /// not the total — "+60" beside five faces means sixty-five people.
    @Test("Past the limit the row counts the remainder")
    func overflowIsTheRemainder() {
        let model = model()
        for id in 20..<85 { join(model, UInt64(id), guild: here) }

        let presence = model.railHoverPresence(for: here)
        #expect(presence.voice.count == RailHoverPresence.faceLimit)
        #expect(presence.voiceOverflow == 65 - RailHoverPresence.faceLimit)
    }

    /// **The common case, and the one that must cost nothing.** Almost every
    /// server on a rail has nobody in voice, and the chip for one of those has
    /// to be the chip it always was — one line, one band, no rows.
    @Test("A quiet server adds nothing to the chip")
    func quietServerIsUnchanged() {
        let model = model()
        join(model, 20, guild: elsewhere)

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
        join(model, 20, guild: here)
        model.voiceStates[UserID(rawValue: 20)]?.channelID = nil

        #expect(model.railHoverPresence(for: here).isEmpty)
        #expect(model.voiceMarksByGuild.isEmpty)
    }

    /// **The correction this suite was extended for.** The first version marked
    /// a tile only when somebody was streaming, so every busy server where
    /// nobody happened to be sharing — which is most of them — carried nothing,
    /// while Discord draws a speaker on all of them.
    @Test("A server with anybody in a room is marked, streaming or not")
    func quietRoomsAreStillMarked() {
        let model = model()
        join(model, 20, guild: here)
        join(model, 21, guild: elsewhere, streaming: true)

        let marks = model.voiceMarksByGuild
        #expect(marks[here] == .voice)
        #expect(marks[elsewhere] == .live)
    }

    /// **Whichever order the table is walked in.** It is a dictionary, so the
    /// order is not stable across runs, and a rule written as "last writer wins"
    /// would draw a speaker on a server with a stream in it about half the time.
    @Test("A stream wins over a quiet room in the same server")
    func liveWinsOverVoice() {
        let model = model()
        // The streamer joins first, so a naive later write would overwrite it.
        join(model, 20, guild: here, streaming: true)
        for id in 21..<40 { join(model, UInt64(id), guild: here) }

        #expect(model.voiceMarksByGuild[here] == .live)
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

    /// A server nobody is in has no mark at all — nil rather than a `.voice`
    /// for everything, which would put a speaker on the whole rail.
    @Test("A silent server carries no mark")
    func silenceIsNoMark() {
        let model = model()
        join(model, 20, guild: elsewhere)

        #expect(model.voiceMarksByGuild[here] == nil)
    }
}
