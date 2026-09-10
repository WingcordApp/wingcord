import Foundation

// MARK: - What Discord's Spotify card actually is
//
// **It is not Discord's.** Captured in `spotify embed.har`, the embed Discord
// attaches to a Spotify link is the whole of this:
//
// ```json
// { "type": "link", "url": "https://open.spotify.com/track/7glld4kxYHp61zIPtSVHNk",
//   "title": "Lounge Act",
//   "provider": { "name": "Spotify", "url": "https://spotify.com/" },
//   "thumbnail": { "width": 300, "height": 300, … } }
// ```
//
// No artist, no colour, no clock, no preview, no `video`, no `html`. Everything
// else on the card in Discord's own client comes from **Spotify's iframe**,
// which Discord substitutes when it recognises the provider — and the twelve
// other requests in that capture are that iframe talking to Spotify: an access
// point resolver, a library check needing the viewer's own Spotify login,
// analytics, and Spotify's Sentry.
//
// So the card is buildable and Discord is not where it comes from. This is what
// Spotify's own embed page carries, which is every field the card draws.

/// A Spotify link, resolved into the card it deserves.
public struct SpotifyUnfurl: Hashable, Sendable {

    /// What kind of thing the link points at.
    ///
    /// **The path segment verbatim**, because it is also half the address the
    /// embed page is fetched from — `open.spotify.com/embed/{kind}/{id}` — so a
    /// spelling that differs from Spotify's is a fetch that 404s.
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case track, album, playlist, artist, episode, show

        /// What the card calls it, above the title.
        public var label: String {
            switch self {
            case .track: "Song"
            case .album: "Album"
            case .playlist: "Playlist"
            case .artist: "Artist"
            case .episode: "Episode"
            case .show: "Podcast"
            }
        }
    }

    public var kind: Kind
    public var id: String
    public var title: String
    /// The artists for a track, the artist for an album, the owner for a
    /// playlist. Nil where the entity names nobody.
    public var subtitle: String?
    public var coverURL: URL?
    /// The colour Spotify itself derived from the artwork.
    ///
    /// **Not Spotify green.** The card in the reference client is blue for
    /// *Nevermind* and magenta for Today's Top Hits, because the colour is
    /// quantised from the cover — `visualIdentity.backgroundBase`, which arrives
    /// as separate 8-bit channels rather than as a hex string.
    public var accentValue: UInt32?
    public var isExplicit: Bool
    /// A track's length. Zero on an album or a playlist, where Spotify sends the
    /// field and means nothing by it — which is why this is optional and the
    /// zero is dropped on the way in.
    public var durationMilliseconds: Int?
    /// The thirty-second MP3 anybody can play without an account.
    ///
    /// **This is the whole of what the iframe would give us too.** A full track
    /// needs the viewer's own Spotify session inside that web view, and a hosted
    /// guest in this app gets a non-persistent data store by rule — so the
    /// iframe would play exactly this clip, for the cost of a `WebContent`
    /// process. Measured: 148 MB for the first embed, ~65 MB for each one after.
    public var previewURL: URL?
    /// How many tracks an album or a playlist holds. Nil for everything else.
    public var trackCount: Int?

    public init(
        kind: Kind,
        id: String,
        title: String,
        subtitle: String? = nil,
        coverURL: URL? = nil,
        accentValue: UInt32? = nil,
        isExplicit: Bool = false,
        durationMilliseconds: Int? = nil,
        previewURL: URL? = nil,
        trackCount: Int? = nil
    ) {
        self.kind = kind
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.coverURL = coverURL
        self.accentValue = accentValue
        self.isExplicit = isExplicit
        self.durationMilliseconds = durationMilliseconds
        self.previewURL = previewURL
        self.trackCount = trackCount
    }

    /// How the store files it, and how a row asks for it.
    public var key: String { "\(kind.rawValue)/\(id)" }

    /// `2:36`, or nil where there is no length to show.
    public var durationLabel: String? {
        guard let milliseconds = durationMilliseconds, milliseconds > 0 else { return nil }
        let seconds = milliseconds / 1000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// The address of a Spotify link, pulled out of whatever form it arrived in.
public enum SpotifyLink {

    /// The kind and id behind a link, or nil if it is not one.
    ///
    /// Three forms, and all three are real:
    ///
    /// - `https://open.spotify.com/track/{id}?si=…` — what a share button gives.
    /// - `https://open.spotify.com/intl-de/track/{id}` — **what a share from a
    ///   non-English client gives**, and the one a naive "second path component
    ///   is the kind" parser silently reads as a track called `intl-de`.
    /// - `spotify:track:{id}` — the desktop app's own scheme.
    ///
    /// The id is Spotify's base-62 and is validated as such rather than taken on
    /// trust: this string goes into a URL path, and a link ending in a stray
    /// segment would otherwise be fetched as one.
    public static func parse(_ text: String) -> (kind: SpotifyUnfurl.Kind, id: String)? {
        if text.hasPrefix("spotify:") {
            let parts = text.dropFirst("spotify:".count).split(separator: ":")
            guard parts.count >= 2,
                  let kind = SpotifyUnfurl.Kind(rawValue: String(parts[0])),
                  isIdentifier(parts[1])
            else { return nil }
            return (kind, String(parts[1]))
        }

        guard let url = URL(string: text), let host = url.host()?.lowercased(),
              host == "open.spotify.com" || host == "play.spotify.com"
        else { return nil }

        var segments = url.pathComponents.filter { $0 != "/" }
        // A localised share puts the locale first. Dropped rather than matched
        // against a list of locales — anything that is not a kind and is
        // followed by more path is a prefix.
        if let first = segments.first, SpotifyUnfurl.Kind(rawValue: first) == nil,
           segments.count > 2 {
            segments.removeFirst()
        }
        guard segments.count >= 2,
              let kind = SpotifyUnfurl.Kind(rawValue: segments[0]),
              isIdentifier(Substring(segments[1]))
        else { return nil }
        return (kind, segments[1])
    }

    /// Spotify's ids are base-62 and 22 characters. The length is not asserted —
    /// a podcast episode's is the same shape and Spotify has changed lengths
    /// before — but the alphabet is, because this value is pasted into a path.
    private static func isIdentifier(_ text: Substring) -> Bool {
        !text.isEmpty && text.count <= 64 && text.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber)
        }
    }
}
