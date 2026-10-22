import Foundation
import WingcordCore
import WingcordNet

// MARK: - The reader's own Spotify
//
// Discord's `SpotifyStore` (module `655116`) for this client: each linked
// Spotify account followed through Spotify's own player, what it plays kept on
// the model, and the reader's Listening activity published from it — only where
// the connection's "Display Spotify as your status" is on, which is
// `AppModel.spotifyActivity`'s rule. Nothing here looks at the Mac: Discord does
// not either; the player is Spotify's, wherever it is playing.

/// What the reader's Spotify is playing, while it plays — the `SpotifyStore`'s
/// current state. Nil on the model when nothing is.
struct SpotifyNowPlaying: Hashable, Sendable {
    var accountID: String
    var item: SpotifyPlayback.Item
    var startedAt: Date
    var contextURI: String?
}

extension SessionController {

    /// Starts following every linked Spotify account not already followed.
    /// Once a session is ready; a reconnect finds them still running.
    func followSpotify() {
        Task { [weak self] in
            guard let self else { return }
            let connections: [AccountConnection]
            if let known = model.connections {
                connections = known
            } else {
                do {
                    connections = try await rest.connections()
                    model.connections = connections
                } catch {
                    Self.trace("spotify: connections failed: \(Self.describe(error))")
                    return
                }
            }
            for account in connections
            where account.type == "spotify" && !account.isRevoked && spotifyFollowers[account.id] == nil {
                follow(spotifyAccount: account.id)
            }
        }
    }

    private func follow(spotifyAccount accountID: String) {
        let rest = rest
        spotifyFollowers[accountID] = Task { [weak self] in
            // Discord's own token for the account, asked again on every 401.
            guard let token = try? await rest.spotifyAccessToken(accountID: accountID) else {
                Self.trace("spotify: no token for \(accountID)")
                return
            }
            let client = SpotifyPlayerClient(accountID: accountID, accessToken: token) {
                try await rest.spotifyAccessToken(accountID: accountID)
            }
            self?.spotifyClients[accountID] = client
            for await event in client.events() {
                guard let self else { return }
                switch event {
                case .player(let playback): apply(playback, fromSpotify: accountID)
                case .devicesChanged: spotifyDevicesChanged(accountID)
                }
            }
        }
    }

    /// Lets go of one account — unlinked from Connected Apps.
    func stopFollowingSpotify(_ accountID: String) {
        spotifyFollowers.removeValue(forKey: accountID)?.cancel()
        spotifyClients[accountID] = nil
        apply(nil, fromSpotify: accountID)
        spotifyExpiries.removeValue(forKey: accountID)?.cancel()
    }

    /// Lets go of every account — the sign-out funnel's.
    func stopSpotify() {
        for task in spotifyFollowers.values { task.cancel() }
        for task in spotifyExpiries.values { task.cancel() }
        spotifyFollowers.removeAll()
        spotifyExpiries.removeAll()
        spotifyClients.removeAll()
        spotifyPlaying.removeAll()
        model.spotifyNowPlaying = nil
        stopListeningAlong()
    }

    /// One account's player, as it changed.
    ///
    /// **Playing or nothing**, as Discord keeps it: a paused track is not
    /// something anybody can listen along to, so it is not on the model and
    /// not on the presence. The start is kept steady across states — see
    /// `SpotifyListening.startTime`.
    private func apply(_ playback: SpotifyPlayback?, fromSpotify accountID: String) {
        spotifyExpiries.removeValue(forKey: accountID)?.cancel()
        if let playback, playback.isPlaying, let item = playback.item {
            let previous = spotifyPlaying[accountID]
            spotifyPlaying[accountID] = SpotifyNowPlaying(
                accountID: accountID,
                item: item,
                startedAt: SpotifyListening.startTime(
                    progress: playback.progress,
                    at: .now,
                    previous: previous?.item.id == item.id ? previous?.startedAt : nil
                ),
                contextURI: playback.contextURI
            )
            // **Discord's `W`**: a track that runs out with no word after it
            // has ended, five seconds past its length.
            let remaining = Double(max(0, item.duration - playback.progress) + 5000) / 1000
            spotifyExpiries[accountID] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled else { return }
                self?.apply(nil, fromSpotify: accountID)
            }
        } else {
            spotifyPlaying[accountID] = nil
        }
        // The first account playing is the one shown, as in Discord.
        let current = spotifyPlaying.values.min { $0.accountID < $1.accountID }
        listenAlongPlayerMoved(current)
        guard model.spotifyNowPlaying != current else { return }
        let before = model.spotifyActivity
        model.spotifyNowPlaying = current
        if model.spotifyActivity != before {
            nowPlaying.reconsider()
            publishPresence()
        }
    }

    /// Discord asks for the devices and the player again (`655116`'s
    /// throttled `handleDeviceStateChange`). The devices matter to listening
    /// along; the player is answered on the socket.
    private func spotifyDevicesChanged(_ accountID: String) {
        guard let client = spotifyClients[accountID] else { return }
        Task { [weak self] in
            let playback = try? await client.player()
            self?.apply(playback, fromSpotify: accountID)
        }
    }
}
