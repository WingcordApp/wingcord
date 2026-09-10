import Foundation
import WingcordCore

// MARK: - Reading Spotify's own embed page
//
// **Deliberately not on `DiscordREST`, and that is a security boundary rather
// than tidiness.** Every request that type makes carries the account's token and
// its identity headers; this one goes to a host that is not Discord, so it takes
// its own `URLSession` and sends no credential at all — the same rule
// `soundboardClip` follows for the CDN.
//
// **It is a page, not an API, and that is stated rather than hidden.** Spotify
// publishes an oEmbed route, but oEmbed answers with a title, a thumbnail and an
// iframe URL — which is what Discord's own embed already gave us. Everything the
// card actually needs beyond that lives in the `__NEXT_DATA__` blob the embed
// page ships to hydrate its player: the artist, the colour Spotify quantised
// from the artwork, the explicit flag, the length, and the preview clip.
//
// So this is a scrape, it can break, and the caller is built for that: a failure
// leaves the store without an entry and the transcript draws the embed Discord
// sent, which is a correct if quieter card. Nothing here throws into a surface.

/// Spotify's embed page, read for the card behind a link.
public struct SpotifyEmbedClient: Sendable {

    public init() {}

    /// **Its own session, with no cookies and no credential.** `.ephemeral`
    /// rather than `.shared`: the shared session is where the account's Discord
    /// cookies live, and there is no reason for a third party to be handed any
    /// of them.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 10
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: configuration)
    }()

    /// A page past this size is not the one we asked for. Measured: a track is
    /// 11 KB, an album 28 KB, a fifty-track playlist 84 KB.
    private static let sizeCeiling = 2 * 1024 * 1024

    /// Resolves one Spotify link.
    ///
    /// Returns nil rather than throwing for anything that is not a transport
    /// failure — an unknown entity shape, a page that has stopped carrying the
    /// blob, a private playlist. The caller files nil as "no card" and the
    /// transcript keeps Discord's own embed.
    public func unfurl(kind: SpotifyUnfurl.Kind, id: String) async throws -> SpotifyUnfurl? {
        guard let url = URL(
            string: "https://open.spotify.com/embed/\(kind.rawValue)/\(id)"
        ) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        // A browser user-agent, sent because this is a browser's page and an
        // unusual client string is the kind of thing a page can decide to serve
        // differently. **Measured, not assumed: the blob comes back either
        // way** — with this string and with `curl`'s own default — so if the
        // scrape ever stops working, the agent is not the first thing to try.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw DiscordREST.Failure.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { return nil }
        guard http.statusCode == 200, data.count <= Self.sizeCeiling else { return nil }

        guard let entity = Self.hydrationEntity(in: data) else { return nil }
        return entity.domain(fallbackKind: kind, fallbackID: id)
    }

    /// Pulls the hydration blob out of the page.
    ///
    /// **Bounded by the script tag on both sides**, and searched over bytes
    /// rather than a decoded `String`: the page is UTF-8 with a lot of escaped
    /// content in it, and building an 84 KB `String` to find a substring is a
    /// copy this does not need.
    static func hydrationEntity(in data: Data) -> SpotifyEntityDTO? {
        let open = Data("<script id=\"__NEXT_DATA__\" type=\"application/json\">".utf8)
        let close = Data("</script>".utf8)
        guard let start = data.range(of: open) else { return nil }
        guard let end = data.range(of: close, in: start.upperBound..<data.endIndex) else {
            return nil
        }
        let json = data[start.upperBound..<end.lowerBound]
        return try? JSONDecoder().decode(SpotifyHydration.self, from: json)
            .props.pageProps.state.data.entity
    }
}

// MARK: - The blob

/// The path to the entity, and nothing else off it.
///
/// **Four wrappers deep and every one of them named, rather than a dictionary
/// walk.** A decoder that reached through `[String: Any]` would fail the same
/// way for a moved key and a changed shape, and this at least says which layer
/// went missing when it does.
struct SpotifyHydration: Decodable, Sendable {
    var props: Props

    struct Props: Decodable, Sendable {
        var pageProps: PageProps
    }

    struct PageProps: Decodable, Sendable {
        var state: State
    }

    struct State: Decodable, Sendable {
        var data: Container
    }

    struct Container: Decodable, Sendable {
        var entity: SpotifyEntityDTO
    }
}

struct SpotifyEntityDTO: Decodable, Sendable {
    var type: String?
    var uri: String?
    var id: String?
    var name: String?
    var title: String?
    /// **Where a track names its people**, as objects. An album and a playlist
    /// leave this empty and put one string in `subtitle` instead.
    var artists: [Artist]?
    /// The artist for an album, the owner for a playlist. Absent on a track.
    var subtitle: String?
    var isExplicit: Bool?
    /// Milliseconds. **Sent as zero on an album and a playlist**, which is not a
    /// length — it is dropped on the way into the domain value.
    var duration: Int?
    var audioPreview: AudioPreview?
    var visualIdentity: VisualIdentity?
    /// An album's or a playlist's tracks. Only the count and the first preview
    /// are taken: a card is a card, not a table of contents.
    var trackList: [Track]?

    struct Artist: Decodable, Sendable { var name: String? }
    struct AudioPreview: Decodable, Sendable { var url: String? }
    struct Track: Decodable, Sendable {
        var title: String?
        var subtitle: String?
        var audioPreview: AudioPreview?
    }

    struct VisualIdentity: Decodable, Sendable {
        var backgroundBase: Channels?
        var image: [Image]?

        /// **Separate 8-bit channels, not a hex string.** Folded into the
        /// 24-bit value every colour in this app is carried as.
        struct Channels: Decodable, Sendable {
            var red: Int?
            var green: Int?
            var blue: Int?

            var value: UInt32? {
                guard let red, let green, let blue else { return nil }
                let clamp = { (component: Int) in UInt32(min(255, max(0, component))) }
                return clamp(red) << 16 | clamp(green) << 8 | clamp(blue)
            }
        }

        struct Image: Decodable, Sendable {
            var url: String?
            var maxWidth: Int?
            var maxHeight: Int?
        }
    }

    /// The card, or nil where the page answered with something unrecognisable.
    func domain(fallbackKind: SpotifyUnfurl.Kind, fallbackID: String) -> SpotifyUnfurl? {
        let heading = (title?.isEmpty == false ? title : nil) ?? name
        guard let heading, !heading.isEmpty else { return nil }

        let people = (artists ?? []).compactMap(\.name).filter { !$0.isEmpty }
        let byline = people.isEmpty
            ? subtitle.flatMap { $0.isEmpty ? nil : $0 }
            : people.joined(separator: ", ")

        // **The 300-point rendition, not the largest.** The card draws a
        // 76-point square; the 640 is four megapixels for a thumbnail, and the
        // 64 is soft the moment anybody is on a Retina display.
        let images = visualIdentity?.image ?? []
        let cover = images.first { ($0.maxWidth ?? 0) == 300 }
            ?? images.max { ($0.maxWidth ?? 0) < ($1.maxWidth ?? 0) }

        // An album's or a playlist's own preview is the first track's — which is
        // what Spotify's player starts on when you press its button.
        let preview = audioPreview?.url ?? trackList?.first?.audioPreview?.url

        return SpotifyUnfurl(
            kind: type.flatMap(SpotifyUnfurl.Kind.init(rawValue:)) ?? fallbackKind,
            id: id?.isEmpty == false ? id! : fallbackID,
            title: heading,
            subtitle: byline,
            coverURL: cover?.url.flatMap(URL.init(string:)),
            accentValue: visualIdentity?.backgroundBase?.value,
            isExplicit: isExplicit ?? false,
            durationMilliseconds: (duration ?? 0) > 0 ? duration : nil,
            previewURL: preview.flatMap(URL.init(string:)),
            trackCount: trackList.map(\.count)
        )
    }
}
