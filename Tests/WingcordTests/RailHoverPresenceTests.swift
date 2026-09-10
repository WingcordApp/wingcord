import Foundation
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
        #expect(model.guildsWithLiveVoice.isEmpty)
    }

    /// The tile's own mark, which is resolved once for the whole rail rather
    /// than per tile — the set is the shape that makes that true.
    @Test("The live set names every server with something to watch, and no other")
    func liveSet() {
        let model = model()
        join(model, 20, guild: here)
        join(model, 21, guild: elsewhere, streaming: true)

        #expect(model.guildsWithLiveVoice == [elsewhere])
    }
}
