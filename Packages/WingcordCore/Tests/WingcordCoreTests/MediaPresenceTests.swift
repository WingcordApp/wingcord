import Foundation
import Testing
@testable import WingcordCore

/// What is playing, as the activity Wingcord publishes for it.
struct MediaPresenceTests {
    private let now = Date(timeIntervalSince1970: 1_792_507_300)
    private let nowPlayingApp = ApplicationID(rawValue: 1_300_000_000_000_000_000)
    private let watch = BrowserTab(url: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=10s")!, title: "Video - YouTube")
    private let channel = URL(string: "https://www.youtube.com/@AndrewTsai")!

    private func video(playing: Bool = true, duration: Double? = 514, elapsed: Double = 74) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            bundleIdentifier: "com.apple.WebKit.GPU", parentApplicationBundleIdentifier: "com.apple.Safari",
            title: "Nintendo Games Are Now Running Natively on Mac", artist: "Andrew Tsai", album: "",
            duration: duration, elapsedTime: elapsed, timestamp: now, isPlaying: playing, playbackRate: playing ? 1 : 0
        )
    }

    private func song(playing: Bool = true) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            bundleIdentifier: "com.apple.Music", title: "Blue in Green", artist: "Miles Davis", album: "Kind of Blue",
            duration: 337, elapsedTime: 37, timestamp: now, isPlaying: playing, playbackRate: 1
        )
    }

    @Test("A YouTube video is YouTubeDiscordPresence's presence")
    func youtubeVideo() throws {
        let activity = try #require(MediaPresence.activity(
            for: video(), source: MediaPresenceSource(player: MediaPlayers.youtube, page: watch, channelURL: channel),
            options: MediaPresenceOptions(), application: nowPlayingApp, now: now
        ))
        #expect(activity.type == 3)
        #expect(activity.name == "YouTube")
        #expect(activity.applicationID == MediaPresence.youtubeApplication)
        #expect(activity.details == "Nintendo Games Are Now Running Natively on Mac")
        #expect(activity.state == "by Andrew Tsai")
        #expect(activity.assets?.largeImage == "https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg")
        #expect(activity.assets?.largeText == "Nintendo Games Are Now Running Natively on Mac")
        #expect(activity.buttons == ["Watch Video", "View Channel"])
        #expect(activity.buttonURLs == [URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!, channel])
        #expect(activity.statusDisplayType == nil)
        let start = 1_792_507_300_000 - 74_000
        #expect(activity.timestamps == .init(start: start, end: start + 514_000))
    }

    @Test("A livestream is on its channel, with a clock from when it was first seen")
    func youtubeLive() throws {
        let since = now.addingTimeInterval(-90)
        let page = BrowserTab(url: URL(string: "https://www.youtube.com/live/dQw4w9WgXcQ")!, title: "Live - YouTube")
        let activity = try #require(MediaPresence.activity(
            for: video(duration: nil, elapsed: 5_000),
            source: MediaPresenceSource(player: MediaPlayers.youtube, page: page, firstSeen: since),
            options: MediaPresenceOptions(showsYouTubeThumbnails: false), application: nil, now: now
        ))
        #expect(activity.state == "[LIVE] on Andrew Tsai")
        #expect(activity.assets?.largeImage == "youtubelive1")
        #expect(activity.buttons == ["Watch Livestream"])
        #expect(activity.timestamps == .init(start: Int(since.timeIntervalSince1970 * 1000)))
    }

    @Test("Without the page, YouTube still has its own picture and no buttons")
    func youtubeWithoutPage() throws {
        let activity = try #require(MediaPresence.activity(
            for: video(), source: MediaPresenceSource(player: MediaPlayers.youtube),
            options: MediaPresenceOptions(), application: nil, now: now
        ))
        #expect(activity.assets?.largeImage == "youtube3")
        #expect(activity.buttons.isEmpty)
    }

    @Test("YouTube Music is Listening, and names the song in a member list")
    func youtubeMusic() throws {
        let page = BrowserTab(url: URL(string: "https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=RD")!, title: "YouTube Music")
        let snapshot = NowPlayingSnapshot(
            bundleIdentifier: "com.apple.WebKit.GPU", parentApplicationBundleIdentifier: "com.apple.Safari",
            title: "Never Gonna Give You Up", artist: "Rick Astley", album: "Whenever You Need Somebody",
            duration: 213, elapsedTime: 0, timestamp: now, isPlaying: true, playbackRate: 1
        )
        let activity = try #require(MediaPresence.activity(
            for: snapshot, source: MediaPresenceSource(player: MediaPlayers.youtubeMusic, page: page),
            options: MediaPresenceOptions(), application: nil, now: now
        ))
        #expect(activity.type == 2)
        #expect(activity.name == "YouTube Music")
        #expect(activity.applicationID == MediaPresence.youtubeMusicApplication)
        #expect(activity.state == "by Rick Astley")
        #expect(activity.assets?.largeText == "Whenever You Need Somebody")
        #expect(activity.buttons == ["Listen Along"])
        #expect(activity.buttonURLs == [URL(string: "https://music.youtube.com/watch?v=dQw4w9WgXcQ")!])
        #expect(activity.statusDisplayType == 2)

        let named = try #require(MediaPresence.activity(
            for: snapshot, source: MediaPresenceSource(player: MediaPlayers.youtubeMusic, page: page),
            options: MediaPresenceOptions(memberListLine: .player), application: nil, now: now
        ))
        #expect(named.statusDisplayType == nil, "asked for the player's name, YouTube Music gets it")
    }

    @Test("Any other player is Listening to it, under the Now Playing app")
    func musicPlayer() throws {
        let artwork = URL(string: "https://is1-ssl.mzstatic.com/image/thumb/kind-of-blue/512x512bb.jpg")!
        let link = MediaLink(label: "Listen on Apple Music", url: URL(string: "https://music.apple.com/album/1")!)
        let music = try #require(MediaPlayers.app("com.apple.Music"))
        let activity = try #require(MediaPresence.activity(
            for: song(),
            source: MediaPresenceSource(player: music, artworkURL: artwork, link: link),
            options: MediaPresenceOptions(memberListLine: .artist), application: nowPlayingApp, now: now
        ))
        #expect(activity.type == 2)
        #expect(activity.name == "Apple Music")
        #expect(activity.applicationID == nowPlayingApp)
        #expect(activity.details == "Blue in Green")
        #expect(activity.state == "by Miles Davis")
        #expect(activity.assets?.largeImage == artwork.absoluteString)
        #expect(activity.assets?.largeText == "Kind of Blue")
        #expect(activity.buttons == ["Listen on Apple Music"])
        #expect(activity.statusDisplayType == 1)
    }

    @Test("Without the Now Playing app a player goes out with no pictures")
    func musicPlayerWithoutApplication() throws {
        let music = try #require(MediaPlayers.app("com.apple.Music"))
        let activity = try #require(MediaPresence.activity(
            for: song(),
            source: MediaPresenceSource(player: music, artworkURL: URL(string: "https://example.com/a.jpg")),
            options: MediaPresenceOptions(), application: nil, now: now
        ))
        #expect(activity.assets == nil)
        #expect(activity.applicationID == nil)
    }

    @Test("A watched player's artist line has no \"by\"")
    func watchingHasNoBy() throws {
        let tv = try #require(MediaPlayers.app("com.apple.TV"))
        let activity = try #require(MediaPresence.activity(
            for: song(), source: MediaPresenceSource(player: tv),
            options: MediaPresenceOptions(), application: nil, now: now
        ))
        #expect(activity.type == 3)
        #expect(activity.state == "Miles Davis")
    }

    @Test("Paused is nothing, unless the reader keeps it — and then it has no clock")
    func paused() throws {
        let source = MediaPresenceSource(player: MediaPlayers.youtube, page: watch)
        #expect(MediaPresence.activity(for: video(playing: false), source: source, options: MediaPresenceOptions(), application: nil, now: now) == nil)
        let kept = try #require(MediaPresence.activity(
            for: video(playing: false), source: source, options: MediaPresenceOptions(showsWhilePaused: true), application: nil, now: now
        ))
        #expect(kept.timestamps == nil)
    }

    @Test("An excluded word anywhere keeps it off — case and accents folded")
    func excluded() {
        let source = MediaPresenceSource(player: MediaPlayers.youtube, page: watch)
        for words in [["nintendo"], ["  TSAI "], ["Natívely"]] {
            #expect(MediaPresence.activity(for: video(), source: source, options: MediaPresenceOptions(excludedWords: words), application: nil, now: now) == nil)
        }
        #expect(MediaPresence.activity(for: video(), source: source, options: MediaPresenceOptions(excludedWords: ["", "   ", "Zelda"]), application: nil, now: now) != nil)
    }

    @Test("Options: no thumbnails, no buttons, no \"by\"")
    func options() throws {
        let activity = try #require(MediaPresence.activity(
            for: video(), source: MediaPresenceSource(player: MediaPlayers.youtube, page: watch, channelURL: channel),
            options: MediaPresenceOptions(showsYouTubeThumbnails: false, showsButtons: false, prefixesBy: false),
            application: nil, now: now
        ))
        #expect(activity.assets?.largeImage == "youtube3")
        #expect(activity.buttons.isEmpty)
        #expect(activity.buttonURLs.isEmpty)
        #expect(activity.state == "Andrew Tsai")
    }

    @Test("Lines are padded to two characters and cut at 128")
    func padding() {
        #expect(MediaPresence.padded("A") == "A\u{200B}")
        #expect(MediaPresence.padded("") == "\u{200B}\u{200B}")
        #expect(MediaPresence.padded(String(repeating: "x", count: 300)).count == 128)
        #expect(MediaPresence.padded("OK") == "OK")
    }

    @Test("A video id from every kind of YouTube address, and nothing from a wrong one")
    func videoIDs() {
        let id = "dQw4w9WgXcQ"
        for address in [
            "https://www.youtube.com/watch?v=\(id)", "https://youtube.com/watch?feature=share&v=\(id)",
            "https://youtu.be/\(id)?t=3", "https://www.youtube.com/live/\(id)", "https://www.youtube.com/shorts/\(id)",
            "https://www.youtube.com/embed/\(id)", "https://music.youtube.com/watch?v=\(id)&list=RD",
        ] {
            #expect(MediaPresence.youtubeVideoID(in: URL(string: address)!) == id, "\(address)")
        }
        for address in [
            "https://www.youtube.com/", "https://www.youtube.com/watch?v=short", "https://www.youtube.com/@channel",
            "https://www.youtube.com/watch?v=dQw4w9WgXc%C3%A9", "https://www.youtube.com/feed/subscriptions",
        ] {
            #expect(MediaPresence.youtubeVideoID(in: URL(string: address)!) == nil, "\(address)")
        }
    }

    @Test("A clock that moved under three seconds is not worth a republish")
    func differs() {
        var a = RichPresenceActivity(type: 2, name: "Apple Music", details: "Song", timestamps: .init(start: 100_000, end: 300_000))
        var b = a
        b.timestamps = .init(start: 102_500, end: 302_500)
        #expect(!MediaPresence.differs(b, from: a))
        b.timestamps = .init(start: 104_000, end: 304_000)
        #expect(MediaPresence.differs(b, from: a), "a seek moves the clock")
        b.timestamps = .init(start: 100_000)
        #expect(MediaPresence.differs(b, from: a), "an end that went is a change")
        b = a
        b.details = "Another Song"
        #expect(MediaPresence.differs(b, from: a))
        #expect(MediaPresence.differs(nil, from: a))
        #expect(MediaPresence.differs(a, from: nil))
        #expect(!MediaPresence.differs(nil, from: nil))
        a.timestamps = nil
        #expect(!MediaPresence.differs(a, from: a))
    }

    @Test("Pictures swap for what resolved; one that did not is dropped")
    func resolvesImages() {
        let activity = RichPresenceActivity(
            type: 3, name: "YouTube",
            assets: .init(largeImage: "https://i.ytimg.com/vi/x/mqdefault.jpg", largeText: "T", smallImage: "youtube3")
        )
        #expect(activity.imageReferences == ["https://i.ytimg.com/vi/x/mqdefault.jpg", "youtube3"])
        let resolved = activity.resolvingImages(["https://i.ytimg.com/vi/x/mqdefault.jpg": "mp:external/abc"])
        #expect(resolved.assets?.largeImage == "mp:external/abc")
        #expect(resolved.assets?.smallImage == nil)
        #expect(resolved.assets?.largeText == "T")
    }
}
