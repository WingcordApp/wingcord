import Foundation
import Testing
@testable import WingcordCore

/// What mediaremote-adapter's stream says is playing, and who is playing it.
struct NowPlayingTests {
    /// Safari playing a YouTube video, paused — the adapter's `get` output on
    /// macOS 27.2, 2026-10-20, verbatim.
    static let safariYouTube = #"""
    {"playbackRate":0,"album":"","elapsedTime":74.330928993000001,"timestamp":"2026-10-20T14:41:13Z","bundleIdentifier":"com.apple.WebKit.GPU","processIdentifier":70364,"parentApplicationBundleIdentifier":"com.apple.Safari","title":"Nintendo Games Are Now Running Natively on Mac","uniqueIdentifier":1498796,"duration":514.28099999999995,"artist":"Andrew Tsai","contentItemIdentifier":"1498796","playing":false}
    """#

    /// The same payload as one line of `stream --no-diff`.
    static var safariYouTubeLine: Data {
        Data(#"{"type":"data","diff":false,"payload":\#(safariYouTube)}"#.utf8)
    }

    @Test("A browser's media is its helper process's, under the browser")
    func decodesSafari() throws {
        guard case .playing(let snapshot) = NowPlayingStream.decode(Self.safariYouTubeLine) else {
            Issue.record("expected a snapshot")
            return
        }
        #expect(snapshot.bundleIdentifier == "com.apple.WebKit.GPU")
        #expect(snapshot.appBundleIdentifier == "com.apple.Safari")
        #expect(snapshot.title == "Nintendo Games Are Now Running Natively on Mac")
        #expect(snapshot.artist == "Andrew Tsai")
        #expect(snapshot.album == nil, "an empty album is no album")
        #expect(snapshot.duration == 514.281)
        #expect(snapshot.elapsedTime == 74.330928993)
        #expect(snapshot.isPlaying == false)
        #expect(snapshot.processIdentifier == 70364)
        #expect(snapshot.contentItemIdentifier == "1498796")
        let timestamp = try #require(snapshot.timestamp)
        #expect(timestamp == Date(timeIntervalSince1970: 1_792_507_273))
    }

    @Test("`get` prints the payload alone")
    func decodesGet() {
        #expect(NowPlayingStream.decodeGet(Data(Self.safariYouTube.utf8)) != .nothing)
        #expect(NowPlayingStream.decodeGet(Data("null".utf8)) == .nothing)
        #expect(NowPlayingStream.decodeGet(Data("{}".utf8)) == .nothing)
    }

    @Test("An empty payload is nothing playing; any other line is not an update")
    func decodesNothing() {
        #expect(NowPlayingStream.decode(Data(#"{"type":"data","diff":false,"payload":{}}"#.utf8)) == .nothing)
        #expect(NowPlayingStream.decode(Data(#"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.apple.Music","title":""}}"#.utf8)) == .nothing)
        #expect(NowPlayingStream.decode(Data(#"{"type":"error","message":"x"}"#.utf8)) == nil)
        #expect(NowPlayingStream.decode(Data("not json".utf8)) == nil)
    }

    @Test("A video file has no artist — QuickTime's shape")
    func decodesQuickTime() {
        let line = Data(#"""
        {"type":"data","diff":false,"payload":{"mediaType":"MRMediaRemoteMediaTypeVideo","contentItemIdentifier":"A1","title":"Clip.mov","elapsedTime":3.5,"bundleIdentifier":"com.apple.QuickTimePlayerX","playing":true,"processIdentifier":512,"duration":42,"timestamp":"2026-10-20T12:00:00Z","playbackRate":1}}
        """#.utf8)
        guard case .playing(let snapshot) = NowPlayingStream.decode(line) else {
            Issue.record("expected a snapshot")
            return
        }
        #expect(snapshot.appBundleIdentifier == "com.apple.QuickTimePlayerX")
        #expect(snapshot.artist == nil)
        #expect(snapshot.isPlaying)
        #expect(snapshot.mediaType == "MRMediaRemoteMediaTypeVideo")
    }

    @Test("Position runs on from its timestamp while playing, at the rate, and stops at the end")
    func projectsPosition() {
        let stamp = Date(timeIntervalSince1970: 1_000)
        var snapshot = NowPlayingSnapshot(
            bundleIdentifier: "com.apple.Music", title: "Song", duration: 200, elapsedTime: 30,
            timestamp: stamp, isPlaying: true, playbackRate: 1
        )
        #expect(snapshot.elapsed(at: stamp.addingTimeInterval(10)) == 40)
        snapshot.playbackRate = 2
        #expect(snapshot.elapsed(at: stamp.addingTimeInterval(10)) == 50)
        #expect(snapshot.elapsed(at: stamp.addingTimeInterval(1_000)) == 200)
        snapshot.isPlaying = false
        #expect(snapshot.elapsed(at: stamp.addingTimeInterval(10)) == 30)
        snapshot.elapsedTime = nil
        #expect(snapshot.elapsed(at: stamp) == nil)
    }

    @Test("A notification ping is a blip, not something played; a livestream is not one")
    func blips() {
        let ping = NowPlayingSnapshot(
            bundleIdentifier: "com.apple.WebKit.GPU", parentApplicationBundleIdentifier: "com.apple.Safari",
            title: "(60) Discord | #rules | SideStore", duration: 1.2016326530612245, isPlaying: false
        )
        #expect(ping.isBlip)
        var song = ping
        song.duration = 214
        #expect(!song.isBlip)
        song.duration = nil
        #expect(!song.isBlip, "no end is a livestream")
    }

    @Test("A site is found by its host or a parent of it, the most specific first")
    func findsSites() {
        #expect(MediaPlayers.site(for: URL(string: "https://music.youtube.com/watch?v=dQw4w9WgXcQ")!) == MediaPlayers.youtubeMusic)
        #expect(MediaPlayers.site(for: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!) == MediaPlayers.youtube)
        #expect(MediaPlayers.site(for: URL(string: "https://m.youtube.com/watch?v=dQw4w9WgXcQ")!) == MediaPlayers.youtube)
        #expect(MediaPlayers.site(for: URL(string: "https://youtu.be/dQw4w9WgXcQ")!) == MediaPlayers.youtube)
        #expect(MediaPlayers.site(for: URL(string: "https://artist.bandcamp.com/track/x")!)?.id == "web.bandcamp")
        #expect(MediaPlayers.site(for: URL(string: "https://notyoutube.com/watch")!) == nil)
        #expect(MediaPlayers.site(for: URL(string: "https://example.com")!) == nil)
    }

    @Test("Music players share by default; video players and unknown apps wait to be asked")
    func defaults() {
        #expect(MediaPlayers.app("com.apple.Music")?.isOnByDefault == true)
        #expect(MediaPlayers.app("com.apple.QuickTimePlayerX")?.isOnByDefault == false)
        #expect(MediaPlayers.unknownApp("com.example.player", name: "Player", isVideo: false).isOnByDefault == false)
        #expect(MediaPlayers.scriptableBrowsers.contains("com.apple.Safari"))
        #expect(!MediaPlayers.scriptableBrowsers.contains("org.mozilla.firefox"))
    }
}
