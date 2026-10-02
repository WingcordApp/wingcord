import Foundation

/// What one linked Spotify account is playing — the state Discord's
/// `SpotifyStore` keeps per account (module `655116`, `SPOTIFY_PLAYER_STATE`),
/// read from Spotify's own player.
public struct SpotifyPlayback: Hashable, Sendable {
    public struct Item: Hashable, Sendable {
        public var id: String
        public var name: String
        /// Milliseconds.
        public var duration: Int
        /// `track` or `episode`.
        public var type: String
        public var albumID: String
        public var albumName: String
        /// The album's first picture, which Spotify lists largest first.
        public var imageURL: URL?
        /// The album object's own `type`. Discord leaves `large_text` off a
        /// single.
        public var albumType: String
        public var artists: [Artist]
        public var isLocal: Bool

        public init(
            id: String,
            name: String,
            duration: Int,
            type: String = "track",
            albumID: String = "",
            albumName: String = "",
            imageURL: URL? = nil,
            albumType: String = "album",
            artists: [Artist] = [],
            isLocal: Bool = false
        ) {
            self.id = id
            self.name = name
            self.duration = duration
            self.type = type
            self.albumID = albumID
            self.albumName = albumName
            self.imageURL = imageURL
            self.albumType = albumType
            self.artists = artists
            self.isLocal = isLocal
        }
    }

    public struct Artist: Hashable, Sendable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public var item: Item?
    public var isPlaying: Bool
    /// Milliseconds into the item when the state was read.
    public var progress: Int
    public var repeats: Bool
    public var contextURI: String?
    public var device: SpotifyDevice?

    public init(
        item: Item?,
        isPlaying: Bool,
        progress: Int,
        repeats: Bool = false,
        contextURI: String? = nil,
        device: SpotifyDevice? = nil
    ) {
        self.item = item
        self.isPlaying = isPlaying
        self.progress = progress
        self.repeats = repeats
        self.contextURI = contextURI
        self.device = device
    }
}

/// A place Spotify can play — the reader's phone, a speaker, the Mac app.
public struct SpotifyDevice: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// `Computer`, `Smartphone`, `Speaker`…
    public var type: String
    public var isActive: Bool
    /// A device that takes no commands from the Web API.
    public var isRestricted: Bool

    public init(id: String, name: String, type: String, isActive: Bool, isRestricted: Bool = false) {
        self.id = id
        self.name = name
        self.type = type
        self.isActive = isActive
        self.isRestricted = isRestricted
    }
}

/// How Discord turns what Spotify is playing into the reader's Listening
/// activity, and back.
public enum SpotifyListening {
    /// The party a listener joins: `spotify:` and the host's user id. Discord
    /// tells a Spotify party from any other by this prefix (`272984`'s `pH`).
    public static let partyPrefix = "spotify:"
    static let imagePrefix = "https://i.scdn.co/image/"

    public static func partyID(for userID: UserID) -> String { "\(partyPrefix)\(userID.rawValue)" }

    public static func isSpotifyParty(_ id: String?) -> Bool { id?.hasPrefix(partyPrefix) == true }

    /// The picture behind a Spotify asset key — `spotify:<id>` on Spotify's
    /// image host (`970928`'s `deserialize`).
    public static func imageURL(forAsset key: String?) -> URL? {
        guard let key, key.hasPrefix(partyPrefix) else { return nil }
        return URL(string: imagePrefix + key.dropFirst(partyPrefix.count))
    }

    /// When the item started, from how far into it the player is.
    ///
    /// **Kept from the last read unless it moved by more than a second and a
    /// half** — Discord's `x` — so a state arriving a beat late does not nudge
    /// the clock everybody else is reading.
    public static func startTime(progress: Int, at now: Date, previous: Date?) -> Date {
        let start = now.addingTimeInterval(-Double(progress) / 1000)
        guard let previous, abs(start.timeIntervalSince(previous)) <= 1.5 else { return start }
        return previous
    }

    /// The Listening activity Discord publishes for what is playing
    /// (`655116`'s `getActivity`).
    ///
    /// The first five artists, joined with "; " and stripped of any ";" of
    /// their own; the track's name cut to 125 characters and an ellipsis past
    /// 128; the album's picture as `spotify:<id>`, and its name unless it is a
    /// single. A local file has nothing to sync to, so it carries no
    /// `sync_id`, flags or metadata.
    public static func activity(
        for item: SpotifyPlayback.Item,
        startedAt start: Date,
        contextURI: String?,
        partyID: String
    ) -> RichPresenceActivity {
        let artists = item.artists.prefix(5)
        let state = artists.isEmpty
            ? nil
            : artists.map { $0.name.replacingOccurrences(of: ";", with: "") }.joined(separator: "; ")
        let details = item.name.count > 128 ? String(item.name.prefix(125)) + "..." : item.name
        let startMs = Int((start.timeIntervalSince1970 * 1000).rounded())
        let image = item.imageURL.flatMap { url -> String? in
            let string = url.absoluteString
            guard string.hasPrefix(imagePrefix) else { return nil }
            return partyPrefix + string.dropFirst(imagePrefix.count)
        }
        return RichPresenceActivity(
            type: 2,
            name: "Spotify",
            details: details,
            state: state,
            assets: RichPresenceActivity.Assets(
                largeImage: image,
                largeText: item.albumType == "single" ? nil : item.albumName
            ),
            timestamps: RichPresenceActivity.Timestamps(start: startMs, end: startMs + item.duration),
            party: RichPresenceActivity.Party(id: partyID),
            syncID: item.isLocal ? nil : item.id,
            flags: item.isLocal ? 0 : 48,
            metadata: item.isLocal ? nil : RichPresenceActivity.ListeningMetadata(
                contextURI: contextURI,
                albumID: item.albumID,
                artistIDs: artists.map(\.id),
                type: item.type
            )
        )
    }
}

/// An invitation to listen along — Discord's `message.activity`, type 3 with a
/// Spotify party. The host is the message's author, and everything live on the
/// card — the track, the clock, who is listening — is read from their presence.
///
/// **Captured** — `invite to listen along.har`:
/// `{"type":3,"party_id":"spotify:987654321987654321","name_override":"Spotify",
///   "icon_override":"spotify:ab67616d0000b2734bcecb123363f1f0f869257c"}`.
public struct ListenAlongInvite: Hashable, Sendable, Codable {
    public var partyID: String
    /// "Spotify" — `name_override`.
    public var name: String
    /// The cover when it was sent — `icon_override`, a `spotify:` asset key.
    public var iconKey: String?

    public init(partyID: String, name: String = "Spotify", iconKey: String? = nil) {
        self.partyID = partyID
        self.name = name
        self.iconKey = iconKey
    }
}
