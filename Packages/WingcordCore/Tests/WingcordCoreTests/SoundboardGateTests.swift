import Foundation
import Testing
@testable import WingcordCore

/// Discord's soundboard rule (its module 813564, `W` and `j`), as a table.
@Suite("Soundboard gate")
struct SoundboardGateTests {

    private let here = GuildID(rawValue: 1)
    private let elsewhere = GuildID(rawValue: 2)

    private func sound(from guild: GuildID?, available: Bool = true) -> SoundboardSound {
        SoundboardSound(id: "9", name: "bonk", guildID: guild, isAvailable: available)
    }

    @Test("Discord's own play everywhere, a server's own in that server")
    func freeSounds() {
        for nitro in [true, false] {
            for guild in [here, elsewhere, nil] {
                #expect(SoundboardGate.canPlay(
                    sound(from: nil), playsEverywhere: nitro, inGuild: guild, mayUseExternalSounds: false
                ))
            }
        }
        #expect(SoundboardGate.canPlay(sound(from: here), playsEverywhere: false, inGuild: here, mayUseExternalSounds: false))
    }

    /// Another server's sound: Nitro, and in a server Use External Sounds too;
    /// a direct message's call asks only the subscription.
    @Test("Another server's sound needs Nitro, and Use External Sounds in a server")
    func externalSounds() {
        let other = sound(from: elsewhere)
        #expect(!SoundboardGate.canPlay(other, playsEverywhere: false, inGuild: here, mayUseExternalSounds: true))
        #expect(!SoundboardGate.canPlay(other, playsEverywhere: true, inGuild: here, mayUseExternalSounds: false))
        #expect(SoundboardGate.canPlay(other, playsEverywhere: true, inGuild: here, mayUseExternalSounds: true))
        #expect(SoundboardGate.canPlay(other, playsEverywhere: true, inGuild: nil, mayUseExternalSounds: false))
        #expect(!SoundboardGate.canPlay(other, playsEverywhere: false, inGuild: nil, mayUseExternalSounds: true))
    }

    @Test("A sound its server cannot play is played by nobody")
    func unavailable() {
        #expect(!SoundboardGate.canPlay(sound(from: here, available: false), playsEverywhere: true, inGuild: here, mayUseExternalSounds: true))
    }

    /// Discord's words only where the subscription is the lock.
    @Test("The refusal is Discord's, and only for the subscription")
    func refusal() {
        #expect(SoundboardGate.refusal(sound(from: elsewhere), playsEverywhere: false, inGuild: here)
            == "Subscribe to Nitro to send sounds across servers.")
        #expect(SoundboardGate.refusal(sound(from: elsewhere), playsEverywhere: true, inGuild: here) == nil)
        #expect(SoundboardGate.refusal(sound(from: here), playsEverywhere: false, inGuild: here) == nil)
        #expect(SoundboardGate.refusal(sound(from: nil), playsEverywhere: false, inGuild: here) == nil)
    }
}

/// Discord's favourites writer: both lists, the order kept, 250 at most.
@Suite("Soundboard favourites")
struct SoundboardFavoritesTests {

    @Test("A star goes on the end of both lists, once")
    func add() {
        var favorites = SoundboardFavorites(soundIDs: [5], orderedSoundIDs: [5])
        let first = favorites.add(9)
        let again = favorites.add(9)
        #expect(first && again)
        #expect(favorites.soundIDs == [5, 9])
        #expect(favorites.orderedSoundIDs == [5, 9])
    }

    /// An older client wrote only `sound_ids`: the order falls back to it for
    /// whatever `ordered_sound_ids` does not hold.
    @Test("The order is the arranged one, then the rest")
    func order() {
        let favorites = SoundboardFavorites(soundIDs: [1, 2, 3], orderedSoundIDs: [3, 1])
        #expect(favorites.inOrder == [3, 1, 2])
        #expect(favorites.contains(2) && !favorites.contains(4))
    }

    @Test("Unstarring leaves neither list holding it")
    func remove() {
        var favorites = SoundboardFavorites(soundIDs: [1, 2], orderedSoundIDs: [2, 1])
        favorites.remove(1)
        #expect(favorites.soundIDs == [2])
        #expect(favorites.orderedSoundIDs == [2])
    }

    @Test("At 250 in either list Discord refuses, and nothing changes")
    func limit() {
        var favorites = SoundboardFavorites(
            soundIDs: Array(1...250).map(UInt64.init), orderedSoundIDs: []
        )
        let before = favorites
        let added = favorites.add(999)
        #expect(!added)
        #expect(favorites == before)
    }
}
