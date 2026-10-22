import Foundation
import WingcordCore

// MARK: - A video's channel, a song's cover
//
// Each asked once per thing played and remembered for the launch; an answer
// that failed for the network is asked again next time, one the route refused
// is not.

@MainActor
final class NowPlayingLookups {
    private var channels: [String: URL] = [:]
    private var channelMisses: Set<String> = []
    private var covers: [String: ITunesSearch.Match] = [:]
    private var coverMisses: Set<String> = []

    /// A YouTube video's channel page, from oEmbed.
    func channel(of videoID: String) async -> URL? {
        if let known = channels[videoID] { return known }
        guard !channelMisses.contains(videoID) else { return nil }
        switch await Self.fetch(YouTubeOEmbed.request(videoID: videoID)) {
        case .answered(let data):
            if let url = YouTubeOEmbed.decode(data)?.channelURL {
                remember(&channels, videoID, url)
                return url
            }
            channelMisses.insert(videoID)
            return nil
        case .refused:
            channelMisses.insert(videoID)
            return nil
        case .failed:
            return nil
        }
    }

    /// A song's cover and its page on Apple Music, from iTunes Search.
    func cover(title: String, artist: String?, album: String?) async -> ITunesSearch.Match? {
        let key = [artist ?? "", title, album ?? ""].joined(separator: "\u{1F}")
        if let known = covers[key] { return known }
        guard !coverMisses.contains(key) else { return nil }
        let request = ITunesSearch.request(title: title, artist: artist, country: Locale.current.region?.identifier)
        switch await Self.fetch(request) {
        case .answered(let data):
            // No result that is this song is an answer too.
            if let match = ITunesSearch.match(data, title: title, artist: artist, album: album) {
                remember(&covers, key, match)
                return match
            }
            coverMisses.insert(key)
            return nil
        case .refused:
            coverMisses.insert(key)
            return nil
        case .failed:
            return nil
        }
    }

    private enum Fetched {
        case answered(Data)
        /// Asked and answered "no" — not asked again this launch.
        case refused
        /// The network, not the route.
        case failed
    }

    private static func fetch(_ url: URL) async -> Fetched {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode
        else { return .failed }
        switch status {
        case 200: return .answered(data)
        case 400..<500 where status != 429: return .refused
        default: return .failed
        }
    }

    /// Kept small: a long listening session should not grow it without end.
    private func remember<Value>(_ table: inout [String: Value], _ key: String, _ value: Value) {
        if table.count >= 256 { table.removeAll(keepingCapacity: true) }
        table[key] = value
    }
}
