/// One Spotify card in a message: the link's kind and id, as the store keeps
/// what Spotify said about it (`AppModel.spotifyUnfurls`).
nonisolated struct SpotifyCardKey: Hashable, Sendable {
    var unfurlKey: String
}
