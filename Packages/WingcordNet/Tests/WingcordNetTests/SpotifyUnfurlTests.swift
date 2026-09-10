import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// Reading a Spotify card out of Spotify's own embed page.
///
/// **The blob below is real**, taken off
/// `https://open.spotify.com/embed/track/7glld4kxYHp61zIPtSVHNk` and trimmed of
/// the arrays nothing here reads — the wrappers, the field names and every value
/// are the page's own. That matters more than usual: this is a scrape of a page
/// rather than a call to an API, so the shape is the only contract there is, and
/// a fixture written from memory would pin the wrong one.
///
/// What it exists to prove is that the fields Discord's own card draws and its
/// embed does not carry — the artist, the colour, the explicit flag, the length
/// and the preview clip — all come out of here. `spotify embed.har` is the
/// evidence for the other half: the embed Discord sends is a title, a provider
/// and a thumbnail, and nothing else.
@Suite("Spotify unfurls")
struct SpotifyUnfurlTests {

    // MARK: The page

    private static let trackPage = """
    <!DOCTYPE html><html><head><title>Spotify Embed</title></head><body>
    <div id="__next"></div>
    <script id="__NEXT_DATA__" type="application/json">\
    {"props":{"pageProps":{"state":{"data":{"entity":{"type":"track",\
    "uri":"spotify:track:7glld4kxYHp61zIPtSVHNk","id":"7glld4kxYHp61zIPtSVHNk",\
    "name":"Lounge Act","title":"Lounge Act",\
    "artists":[{"name":"Nirvana","uri":"spotify:artist:6olE6TJLqED3rqDCT0FyPh"}],\
    "duration":156426,"isExplicit":true,\
    "audioPreview":{"url":"https://p.scdn.co/mp3-preview/c4eb66f61ebc7d1f11f027c14aef7e5351f43eec"},\
    "visualIdentity":{"backgroundBase":{"alpha":255,"blue":153,"green":82,"red":0},\
    "image":[{"url":"https://i.scdn.co/image/300.jpg","maxHeight":300,"maxWidth":300},\
    {"url":"https://i.scdn.co/image/64.jpg","maxHeight":64,"maxWidth":64},\
    {"url":"https://i.scdn.co/image/640.jpg","maxHeight":640,"maxWidth":640}]}}}}}}}\
    </script></body></html>
    """

    private static func unfurl(
        _ page: String, kind: SpotifyUnfurl.Kind = .track, id: String = "x"
    ) -> SpotifyUnfurl? {
        SpotifyEmbedClient.hydrationEntity(in: Data(page.utf8))?
            .domain(fallbackKind: kind, fallbackID: id)
    }

    @Test("Everything Discord's card draws and its embed does not carry")
    func trackFields() throws {
        let card = try #require(Self.unfurl(Self.trackPage))
        #expect(card.kind == .track)
        #expect(card.id == "7glld4kxYHp61zIPtSVHNk")
        #expect(card.title == "Lounge Act")
        // The artist — the single most visible thing Discord's embed omits.
        #expect(card.subtitle == "Nirvana")
        #expect(card.isExplicit)
        #expect(card.durationMilliseconds == 156426)
        #expect(card.durationLabel == "2:36")
        #expect(card.previewURL?.host() == "p.scdn.co")
    }

    /// **Three 8-bit channels, not a hex string**, and the card's colour is the
    /// one Spotify quantised from the artwork rather than Spotify green — blue
    /// for *Nevermind*, magenta for Today's Top Hits.
    @Test("The accent is folded out of separate channels")
    func accentChannels() throws {
        let card = try #require(Self.unfurl(Self.trackPage))
        #expect(card.accentValue == 0x00_52_99)
    }

    /// The card draws a 76-point square. The 640 is four megapixels for a
    /// thumbnail and the 64 is soft on any Retina display.
    @Test("The 300-point rendition is the one taken")
    func coverRendition() throws {
        let card = try #require(Self.unfurl(Self.trackPage))
        #expect(card.coverURL?.absoluteString == "https://i.scdn.co/image/300.jpg")
    }

    /// An album names one person in `subtitle` and leaves `artists` empty, sends
    /// `duration: 0` and means nothing by it, and carries its preview on the
    /// first track rather than on itself. All three differ from a track and all
    /// three are the page's own shape.
    @Test("An album reads its byline, its count and its first preview")
    func albumShape() throws {
        let card = try #require(Self.unfurl("""
        <script id="__NEXT_DATA__" type="application/json">\
        {"props":{"pageProps":{"state":{"data":{"entity":{"type":"album",\
        "id":"2guirTSEqLizK7j9i1MTTZ","name":"Nevermind (Remastered)",\
        "subtitle":"Nirvana","artists":[],"duration":0,"isExplicit":false,\
        "trackList":[{"title":"Smells Like Teen Spirit","subtitle":"Nirvana",\
        "audioPreview":{"url":"https://p.scdn.co/mp3-preview/91219ebc"}},\
        {"title":"In Bloom","subtitle":"Nirvana"}],\
        "visualIdentity":{"backgroundBase":{"red":0,"green":82,"blue":153}}}}}}}}\
        </script>
        """, kind: .album, id: "2guirTSEqLizK7j9i1MTTZ"))
        #expect(card.kind == .album)
        #expect(card.title == "Nevermind (Remastered)")
        #expect(card.subtitle == "Nirvana")
        // Zero is not a length. Drawn, it would read "0:00".
        #expect(card.durationMilliseconds == nil)
        #expect(card.durationLabel == nil)
        #expect(card.trackCount == 2)
        #expect(card.previewURL?.absoluteString == "https://p.scdn.co/mp3-preview/91219ebc")
    }

    /// A playlist's byline is its owner, which is the same field an album puts
    /// its artist in — so one rule covers both and neither needs a case.
    @Test("A playlist's byline is whoever made it")
    func playlistShape() throws {
        let card = try #require(Self.unfurl("""
        <script id="__NEXT_DATA__" type="application/json">\
        {"props":{"pageProps":{"state":{"data":{"entity":{"type":"playlist",\
        "id":"37i9dQZF1DXcBWIGoYBM5M","name":"Today’s Top Hits","subtitle":"Spotify",\
        "duration":0,"trackList":[{"title":"Ain't In LA"}],\
        "visualIdentity":{"backgroundBase":{"red":150,"green":0,"blue":103}}}}}}}}\
        </script>
        """, kind: .playlist, id: "37i9dQZF1DXcBWIGoYBM5M"))
        #expect(card.subtitle == "Spotify")
        #expect(card.accentValue == 0x96_00_67)
    }

    // MARK: When it breaks

    /// **The whole point of the fallback.** This is a page, not a contract: when
    /// Spotify moves the blob, renames a wrapper or serves a stub, the answer has
    /// to be "no card" so the transcript keeps the embed Discord sent. A throw
    /// here, or a half-built value, would be a defect on somebody's screen.
    @Test("A page with no blob, a moved blob or a truncated one is simply no card")
    func brokenPages() {
        #expect(Self.unfurl("<html><body>nothing here</body></html>") == nil)
        #expect(Self.unfurl("""
        <script id="__NEXT_DATA__" type="application/json">{"props":{}}</script>
        """) == nil)
        // Opened and never closed — a truncated download.
        #expect(Self.unfurl("""
        <script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":
        """) == nil)
        // The wrappers are right and the entity has no name.
        #expect(Self.unfurl("""
        <script id="__NEXT_DATA__" type="application/json">\
        {"props":{"pageProps":{"state":{"data":{"entity":{"type":"track"}}}}}}</script>
        """) == nil)
    }

    // MARK: The link

    @Test("Every form of a Spotify link resolves to the same address")
    func linkForms() throws {
        let share = SpotifyLink.parse(
            "https://open.spotify.com/track/7glld4kxYHp61zIPtSVHNk?si=ea73b1734457451e"
        )
        #expect(share?.kind == .track)
        #expect(share?.id == "7glld4kxYHp61zIPtSVHNk")

        // **A share from a non-English client**, and the form a "second path
        // component is the id" parser reads as a track called `intl-de`.
        let localised = SpotifyLink.parse("https://open.spotify.com/intl-de/album/2guirTSEqLizK7j9i1MTTZ")
        #expect(localised?.kind == .album)
        #expect(localised?.id == "2guirTSEqLizK7j9i1MTTZ")

        // The desktop app's own scheme.
        #expect(SpotifyLink.parse("spotify:playlist:37i9dQZF1DXcBWIGoYBM5M")?.kind == .playlist)
    }

    @Test("Anything that is not a Spotify entity is not one")
    func rejectedLinks() {
        #expect(SpotifyLink.parse("https://example.test/track/abc") == nil)
        #expect(SpotifyLink.parse("https://open.spotify.com/") == nil)
        #expect(SpotifyLink.parse("https://open.spotify.com/track") == nil)
        // A kind this client has no card for.
        #expect(SpotifyLink.parse("https://open.spotify.com/user/someone") == nil)
        // **An id with a path separator in it**, which would otherwise be pasted
        // straight into the URL this client fetches.
        #expect(SpotifyLink.parse("https://open.spotify.com/track/..%2Fevil") == nil)
    }
}
