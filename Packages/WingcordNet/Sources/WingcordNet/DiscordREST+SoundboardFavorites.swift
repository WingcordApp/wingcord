import Foundation
import WingcordCore

extension DiscordREST {
    /// The soundboard's half of the frecency blob: the starred sounds, and the
    /// account's plays, scored as Discord scores them.
    public func soundboardFrecency(now: Date = .now) async throws -> (favorites: SoundboardFavorites, played: SoundFrecency) {
        let blob = try await frecencySettings()
        let data = Data(base64Encoded: blob, options: .ignoreUnknownCharacters) ?? Data()
        let played = SoundFrecency(history: FrecencyProto.playedSoundHistory(base64: blob), now: now)
        return (FrecencyProto.favoriteSounds(in: data), played)
    }

    /// This client's plays, added to the table as it stands now and written
    /// back — Discord's `overwriteHistory(stored, pending)`, then its write of
    /// `playedSoundFrecency`. Read just before, so another client's plays since
    /// are kept.
    public func recordPlayedSounds(
        _ plays: [(soundID: String, at: Date)], now: Date = .now
    ) async throws -> SoundFrecency {
        let blob = try await fetchFrecencySettings()
        frecencyBlob = nil // a write starts fresh and leaves no stale copy
        var played = SoundFrecency(history: FrecencyProto.playedSoundHistory(base64: blob), now: now)
        for play in plays { played.track(play.soundID, at: play.at) }
        struct Body: Encodable { var settings: String }
        _ = try await requestData(
            method: "PATCH",
            path: "/users/@me/settings-proto/2",
            route: "users/@me/settings-proto/:type",
            body: Body(settings: FrecencyProto.playedSoundsPatch(played.written))
        )
        return played
    }

    /// Stars or unstars one sound, applied to the blob as it stands now — so a
    /// favourite another client made since this one last read is kept.
    ///
    /// - Returns: the favourites as written, or nil when Discord's limit of
    ///   250 refused the star and nothing was written.
    public func setFavoriteSound(_ soundID: UInt64, favorite: Bool) async throws -> SoundboardFavorites? {
        let blob = try await fetchFrecencySettings()
        frecencyBlob = nil // a write starts fresh and leaves no stale copy
        let data = Data(base64Encoded: blob, options: .ignoreUnknownCharacters) ?? Data()
        var favorites = FrecencyProto.favoriteSounds(in: data)
        if favorite {
            guard favorites.add(soundID) else { return nil }
        } else {
            favorites.remove(soundID)
        }
        struct Body: Encodable { var settings: String }
        _ = try await requestData(
            method: "PATCH",
            path: "/users/@me/settings-proto/2",
            route: "users/@me/settings-proto/:type",
            body: Body(settings: FrecencyProto.favoriteSoundsPatch(favorites, in: data))
        )
        return favorites
    }
}
