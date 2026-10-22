import Foundation
import Testing
@testable import WingcordCore

/// The channel behind a video, and the cover behind a song.
struct MediaLookupsTests {

    @Test("oEmbed is asked about the video's canonical address")
    func oEmbedRequest() {
        let url = YouTubeOEmbed.request(videoID: "dQw4w9WgXcQ")
        #expect(url.absoluteString == "https://www.youtube.com/oembed?format=json&url=https://www.youtube.com/watch?v%3DdQw4w9WgXcQ")
    }

    @Test("oEmbed's author is the channel")
    func oEmbedAnswer() {
        let data = Data(#"{"title":"Video","author_name":"Andrew Tsai","author_url":"https://www.youtube.com/@AndrewTsai","type":"video"}"#.utf8)
        #expect(YouTubeOEmbed.decode(data) == .init(channelName: "Andrew Tsai", channelURL: URL(string: "https://www.youtube.com/@AndrewTsai")))
        let plain = Data(#"{"author_name":"X","author_url":"http://example.com/x"}"#.utf8)
        #expect(YouTubeOEmbed.decode(plain)?.channelURL == nil, "only an https link becomes a button")
        #expect(YouTubeOEmbed.decode(Data("Not Found".utf8)) == nil)
    }

    @Test("iTunes Search is asked for the artist and the song, in the storefront")
    func searchRequest() throws {
        let url = ITunesSearch.request(title: "Blue in Green", artist: "Miles Davis", country: "RO")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "term" }?.value == "Miles Davis Blue in Green")
        #expect(items.first { $0.name == "entity" }?.value == "song")
        #expect(items.first { $0.name == "country" }?.value == "RO")
    }

    private let answer = Data(#"""
    {"resultCount":3,"results":[
     {"trackName":"So What","artistName":"Miles Davis","collectionName":"Kind of Blue","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/a/100x100bb.jpg","trackViewUrl":"https://music.apple.com/us/album/so-what/1?i=1"},
     {"trackName":"Blue in Green (Live)","artistName":"Miles Davis Quintet","collectionName":"Live at the Plugged Nickel","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/b/100x100bb.jpg","trackViewUrl":"https://music.apple.com/us/album/blue-in-green/2?i=2"},
     {"trackName":"Blue in Green","artistName":"Miles Davis","collectionName":"Kind of Blue (Legacy Edition)","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/c/100x100bb.jpg","trackViewUrl":"https://music.apple.com/us/album/blue-in-green/3?i=3"}
    ]}
    """#.utf8)

    @Test("The song whose title and artist agree most closely — the album preferred — at 512 px")
    func matchesSong() {
        let closest = ITunesSearch.match(answer, title: "Blue in Green", artist: "Miles Davis", album: nil)
        #expect(closest?.artworkURL == URL(string: "https://is1-ssl.mzstatic.com/image/thumb/c/512x512bb.jpg"))
        let quintet = ITunesSearch.match(answer, title: "Blue in Green", artist: "Miles Davis Quintet", album: nil)
        #expect(quintet?.trackURL == URL(string: "https://music.apple.com/us/album/blue-in-green/2?i=2"))
        let album = ITunesSearch.match(answer, title: "Blue in Green", artist: "Miles Davis", album: "Kind of Blue (Legacy Edition)")
        #expect(album?.trackURL == URL(string: "https://music.apple.com/us/album/blue-in-green/3?i=3"))
        #expect(ITunesSearch.match(answer, title: "Freddie Freeloader", artist: "Miles Davis", album: nil) == nil)
        #expect(ITunesSearch.match(answer, title: "Blue in Green", artist: "Bill Evans", album: nil) == nil)
        #expect(ITunesSearch.match(Data("{}".utf8), title: "x", artist: nil, album: nil) == nil)
    }

    @Test("Titles compare without case, accents or a trailing qualifier")
    func comparable() {
        #expect(ITunesSearch.comparable("Café (Remastered 2009)") == "cafe")
        #expect(ITunesSearch.comparable("Song - Live at Wembley") == "song")
        #expect(ITunesSearch.comparable("(I Can't Get No) Satisfaction") == "(i can't get no) satisfaction")
    }
}
