import Foundation

/// What a Server Hub system message (type 69) is about — `guild_space_data`:
/// a busy whiteboard, a turn in the leaderboard, or a new top in the music.
public struct GuildSpaceMessageData: Hashable, Sendable, Codable {
    public var whiteboard: Whiteboard?
    public var leaderboard: Leaderboard?
    public var music: Music?

    public struct Whiteboard: Hashable, Sendable, Codable {
        /// A couple of the people drawing.
        public var sampledUserIDs: [UserID]
        public var connectedUserCount: Int

        public init(sampledUserIDs: [UserID], connectedUserCount: Int) {
            self.sampledUserIDs = sampledUserIDs
            self.connectedUserCount = connectedUserCount
        }
    }

    public struct Leaderboard: Hashable, Sendable, Codable {
        public enum Event: Int, Hashable, Sendable, Codable {
            case ended = 1
            case started = 2
            case leaderChanged = 3
        }

        public var event: Event
        public var stat: GuildSpaceLeaderboard.Stat
        public var userID: UserID
        /// The leader who was overtaken.
        public var secondaryUserID: UserID?
        public var value: Double

        public init(event: Event, stat: GuildSpaceLeaderboard.Stat, userID: UserID, secondaryUserID: UserID?, value: Double) {
            self.event = event
            self.stat = stat
            self.userID = userID
            self.secondaryUserID = secondaryUserID
            self.value = value
        }
    }

    public struct Music: Hashable, Sendable, Codable {
        public enum Event: Int, Hashable, Sendable, Codable {
            case topSong = 1
            case topArtist = 2
            case topListener = 3
        }

        public var event: Event
        public var trackTitle: String?
        public var artistName: String?
        public var userID: UserID?

        public init(event: Event, trackTitle: String?, artistName: String?, userID: UserID?) {
            self.event = event
            self.trackTitle = trackTitle
            self.artistName = artistName
            self.userID = userID
        }
    }

    /// The person the line is about, whose name it draws in their colour: the
    /// leader, the top listener, or the first of the people drawing.
    public var subjectUserID: UserID? {
        leaderboard?.userID ?? music?.userID ?? whiteboard?.sampledUserIDs.first
    }

    /// Everyone the line names.
    public var namedUserIDs: [UserID] {
        [leaderboard?.userID, leaderboard?.secondaryUserID, music?.userID].compactMap(\.self)
            + (whiteboard?.sampledUserIDs ?? [])
    }

    public init(whiteboard: Whiteboard? = nil, leaderboard: Leaderboard? = nil, music: Music? = nil) {
        self.whiteboard = whiteboard
        self.leaderboard = leaderboard
        self.music = music
    }
}

extension GuildSpaceLeaderboard.Stat: Codable {}
