import Foundation

/// What a server listened to on Spotify this past week — the Popular Music
/// widget: top songs, top artists and top listeners.
public struct GuildSpacePopularMusic: Hashable, Sendable {
    public var songs: [Song]
    public var artists: [Artist]
    public var listeners: [Listener]
    public var distinctSongs: Int
    public var distinctArtists: Int
    public var distinctListeners: Int

    public struct Song: Hashable, Sendable, Identifiable {
        /// Spotify's track id.
        public var trackID: String
        public var title: String
        public var artistName: String?
        /// Spotify's image id, under `https://i.scdn.co/image/`.
        public var coverArtHash: String?
        public var plays: Int
        /// A few of the members who played it.
        public var userIDs: [UserID]

        public var id: String { trackID }

        public init(trackID: String, title: String, artistName: String?, coverArtHash: String?, plays: Int, userIDs: [UserID]) {
            self.trackID = trackID
            self.title = title
            self.artistName = artistName
            self.coverArtHash = coverArtHash
            self.plays = plays
            self.userIDs = userIDs
        }
    }

    public struct Artist: Hashable, Sendable, Identifiable {
        public var artistID: String
        public var name: String
        public var imageHash: String?
        public var plays: Int

        public var id: String { artistID }

        public init(artistID: String, name: String, imageHash: String?, plays: Int) {
            self.artistID = artistID
            self.name = name
            self.imageHash = imageHash
            self.plays = plays
        }
    }

    public struct Listener: Hashable, Sendable, Identifiable {
        public var userID: UserID
        public var plays: Int
        /// What they last listened to, when Discord says.
        public var lastTrackTitle: String?
        public var lastArtistName: String?

        public var id: UserID { userID }

        public init(userID: UserID, plays: Int, lastTrackTitle: String? = nil, lastArtistName: String? = nil) {
            self.userID = userID
            self.plays = plays
            self.lastTrackTitle = lastTrackTitle
            self.lastArtistName = lastArtistName
        }
    }

    public init(
        songs: [Song],
        artists: [Artist],
        listeners: [Listener],
        distinctSongs: Int = 0,
        distinctArtists: Int = 0,
        distinctListeners: Int = 0
    ) {
        self.songs = songs
        self.artists = artists
        self.listeners = listeners
        self.distinctSongs = distinctSongs
        self.distinctArtists = distinctArtists
        self.distinctListeners = distinctListeners
    }

    /// Discord's empty rule (`lE`): no plays at all.
    public var hasPlays: Bool { songs.contains { $0.plays > 0 } }

    /// A Spotify picture by its id.
    public static func imageURL(_ hash: String) -> URL? {
        guard let encoded = hash.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://i.scdn.co/image/\(encoded)")
    }
}
