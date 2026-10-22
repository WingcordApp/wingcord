import Foundation
import WingcordCore
import WingcordNet

// MARK: - Now Playing, published

extension SessionController {

    /// Starts reading what plays — if the reader shares it — for as long as
    /// an account is signed in, and republishes whenever its activity changes.
    func startNowPlaying() {
        nowPlaying.assets = NowPlayingPresence.Assets(
            external: { [rest] application, links in
                try await rest.externalAssetIDs(application: application, urls: links)
            },
            named: { [rest] application in
                try await rest.applicationAssetIDs(application: application)
            }
        )
        hookNowPlaying()
        nowPlaying.refresh()
    }

    /// `--demo`: the same reading and building, published nowhere — the
    /// reader's own card shows it, and nothing asks Discord anything.
    func startNowPlayingLocally() {
        nowPlaying.assets = nil
        hookNowPlaying()
        nowPlaying.refresh()
    }

    private func hookNowPlaying() {
        nowPlaying.sharesActivity = { [weak self] in self?.model.activityPrivacy.sharesCurrentGame ?? false }
        nowPlaying.isSpotifyShown = { [weak self] in self?.model.spotifyActivity != nil }
        nowPlaying.onChange = { [weak self] in
            guard let self else { return }
            model.nowPlayingActivity = nowPlaying.activity
            // Mirrored, as a game is: the presence this client publishes never
            // comes back to it.
            model.reflectOwnPresenceNow()
            publishPresence()
        }
    }

    /// Stops reading, and forgets what played — signing out leaves nothing of
    /// the last account's on the next one.
    func stopNowPlaying() {
        nowPlaying.onChange = nil
        nowPlaying.stop()
        model.nowPlayingActivity = nil
    }

    /// A Now Playing setting changed: start, stop, or build again.
    func nowPlayingSettingsChanged() {
        guard model.currentUserID != nil else { return }
        nowPlaying.refresh()
    }
}
