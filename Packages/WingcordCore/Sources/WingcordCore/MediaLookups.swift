import Foundation

// MARK: - What the presence looks up
//
// Two public routes, each asked once per thing played: YouTube's oEmbed for a
// video's channel (YouTubeDiscordPresence's "View Channel"), and iTunes Search
// for a song's cover — the player's own artwork has no address, and the
// gateway takes pictures only by address (docs/CLIPS-PRESENCE.md, D7).

public enum YouTubeOEmbed {

    public static func request(videoID: String) -> URL {
        var components = URLComponents(string: "https://www.youtube.com/oembed")!
        components.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(videoID)"),
        ]
        return components.url!
    }

    public struct Answer: Hashable, Sendable {
        public var channelName: String?
        public var channelURL: URL?
    }

    public static func decode(_ data: Data) -> Answer? {
        struct Body: Decodable {
            var author_name: String?
            var author_url: String?
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { return nil }
        let url = body.author_url.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        return Answer(channelName: body.author_name, channelURL: url)
    }
}

public enum ITunesSearch {

    /// A search for one song, in the reader's storefront.
    public static func request(title: String, artist: String?, country: String?) -> URL {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: [artist, title].compactMap(\.self).joined(separator: " ")),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10"),
        ] + (country.map { [URLQueryItem(name: "country", value: $0)] } ?? [])
        return components.url!
    }

    public struct Match: Hashable, Sendable {
        /// The cover at 512 px.
        public var artworkURL: URL?
        /// The song on Apple Music.
        public var trackURL: URL?
    }

    /// The result that is this song — its title and artist agreeing, the one
    /// agreeing most closely (the same words over one containing the other, the
    /// album too) first. Nil when none does: another song's cover is worse than
    /// the player's own icon.
    public static func match(_ data: Data, title: String, artist: String?, album: String?) -> Match? {
        struct Body: Decodable {
            var results: [Result]
        }
        struct Result: Decodable {
            var trackName: String?
            var artistName: String?
            var collectionName: String?
            var artworkUrl100: String?
            var trackViewUrl: String?
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { return nil }
        let wanted = (title: comparable(title), artist: artist.map(comparable), album: album.map(comparable))
        func score(_ result: Result) -> Int? {
            guard let name = result.trackName.map(comparable), agrees(name, wanted.title) else { return nil }
            var score = name == wanted.title ? 2 : 1
            if let artist = wanted.artist {
                guard let found = result.artistName.map(comparable), agrees(found, artist) else { return nil }
                score += found == artist ? 2 : 1
            }
            if let album = wanted.album, result.collectionName.map(comparable) == album { score += 4 }
            return score
        }
        let scored = body.results.compactMap { result in score(result).map { (result, $0) } }
        guard let best = scored.max(by: { $0.1 < $1.1 })?.0 else { return nil }
        return Match(
            artworkURL: best.artworkUrl100
                .map { $0.replacingOccurrences(of: "100x100bb", with: "512x512bb") }
                .flatMap(URL.init(string:)),
            trackURL: best.trackViewUrl.flatMap(URL.init(string:))
        )
    }

    /// Case and accents folded, a trailing "(Remastered)" or "- Live" cut —
    /// players and the store disagree about those.
    static func comparable(_ text: String) -> String {
        var folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        for opener in [" (", " [", " - "] {
            if let range = folded.range(of: opener), range.lowerBound > folded.startIndex {
                folded = String(folded[..<range.lowerBound])
            }
        }
        return folded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One names the other — "Artist" against "Artist & Guest".
    static func agrees(_ a: String, _ b: String) -> Bool {
        !a.isEmpty && !b.isEmpty && (a == b || a.contains(b) || b.contains(a))
    }
}
