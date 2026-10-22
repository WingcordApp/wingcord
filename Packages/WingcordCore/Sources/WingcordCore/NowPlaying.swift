import Foundation

// MARK: - What macOS says is playing
//
// One record of the vendored mediaremote-adapter's stream (docs/CLIPS-PRESENCE.md
// §2.2; seen on 27.2 in Phase 0.3). A browser's media arrives from its helper
// process — Safari's as `com.apple.WebKit.GPU` with `com.apple.Safari` as the
// parent — and a YouTube page reports the video as the title and the channel as
// the artist, with no URL: the page itself has to be asked for that.

public struct NowPlayingSnapshot: Hashable, Sendable {
    public var bundleIdentifier: String
    /// The app behind a helper process — Safari for `com.apple.WebKit.GPU`.
    public var parentApplicationBundleIdentifier: String?
    public var processIdentifier: Int?
    public var title: String
    public var artist: String?
    public var album: String?
    /// Seconds. Nil or zero for something with no end — a livestream.
    public var duration: Double?
    /// Seconds into the media at `timestamp`.
    public var elapsedTime: Double?
    public var timestamp: Date?
    public var isPlaying: Bool
    public var playbackRate: Double?
    public var mediaType: String?
    public var contentItemIdentifier: String?

    public init(
        bundleIdentifier: String,
        parentApplicationBundleIdentifier: String? = nil,
        processIdentifier: Int? = nil,
        title: String,
        artist: String? = nil,
        album: String? = nil,
        duration: Double? = nil,
        elapsedTime: Double? = nil,
        timestamp: Date? = nil,
        isPlaying: Bool,
        playbackRate: Double? = nil,
        mediaType: String? = nil,
        contentItemIdentifier: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.parentApplicationBundleIdentifier = parentApplicationBundleIdentifier
        self.processIdentifier = processIdentifier
        self.title = title
        self.artist = artist.flatMap { $0.isEmpty ? nil : $0 }
        self.album = album.flatMap { $0.isEmpty ? nil : $0 }
        self.duration = duration
        self.elapsedTime = elapsedTime
        self.timestamp = timestamp
        self.isPlaying = isPlaying
        self.playbackRate = playbackRate
        self.mediaType = mediaType
        self.contentItemIdentifier = contentItemIdentifier
    }

    /// The app the reader sees playing it.
    public var appBundleIdentifier: String {
        parentApplicationBundleIdentifier ?? bundleIdentifier
    }

    /// Whether it has an end. A livestream reports none.
    public var hasDuration: Bool { (duration ?? 0) > 0 }

    /// A sound rather than something played: a web page's notification ping
    /// reports itself as Now Playing too — Discord's own, 1.2 seconds, seen in
    /// Safari on 2026-10-20. Under ten seconds, it is not anything to share,
    /// and taking it for one would knock what is playing off and on again.
    public var isBlip: Bool {
        guard let duration, duration > 0 else { return false }
        return duration < 10
    }

    /// A video, as the player reports it — `MRMediaRemoteMediaTypeVideo`.
    public var isVideo: Bool { mediaType?.localizedCaseInsensitiveContains("video") == true }

    /// One thing played: a new key is a new song or video, even from the same
    /// player.
    public var itemKey: String {
        [appBundleIdentifier, contentItemIdentifier ?? "", title, artist ?? ""].joined(separator: "\u{1F}")
    }

    /// How far in, at `now` — projected forward from `timestamp` while
    /// playing, at the playback rate, and never past the end.
    public func elapsed(at now: Date) -> Double? {
        guard let elapsedTime else { return nil }
        var position = elapsedTime
        if isPlaying, let timestamp {
            position += max(0, now.timeIntervalSince(timestamp)) * (playbackRate.map { $0 > 0 ? $0 : 1 } ?? 1)
        }
        if let duration, duration > 0 { position = min(position, duration) }
        return position
    }
}

/// One line of the adapter's `stream` output.
public enum NowPlayingUpdate: Hashable, Sendable {
    case playing(NowPlayingSnapshot)
    /// Nothing plays — an empty payload.
    case nothing
}

public enum NowPlayingStream {

    /// Decodes one line: `{"type":"data","diff":false,"payload":{…}}`. Nil for
    /// anything that is not a data line.
    ///
    /// **Stream with `--no-diff`.** In diff mode a payload carries only what
    /// changed, which would make every consumer keep and merge state the
    /// adapter already has.
    public static func decode(_ line: Data) -> NowPlayingUpdate? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "data" else { return nil }
        guard let payload = object["payload"] as? [String: Any], !payload.isEmpty else { return .nothing }
        return snapshot(payload).map(NowPlayingUpdate.playing) ?? .nothing
    }

    /// The adapter's `get` output, which is the payload alone (or `null`).
    public static func decodeGet(_ data: Data) -> NowPlayingUpdate? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        guard let payload = object as? [String: Any], !payload.isEmpty else { return .nothing }
        return snapshot(payload).map(NowPlayingUpdate.playing) ?? .nothing
    }

    static func snapshot(_ payload: [String: Any]) -> NowPlayingSnapshot? {
        guard let bundle = payload["bundleIdentifier"] as? String,
              let title = payload["title"] as? String, !title.isEmpty else { return nil }
        let timestamp = (payload["timestamp"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
        return NowPlayingSnapshot(
            bundleIdentifier: bundle,
            parentApplicationBundleIdentifier: payload["parentApplicationBundleIdentifier"] as? String,
            processIdentifier: (payload["processIdentifier"] as? NSNumber)?.intValue,
            title: title,
            artist: payload["artist"] as? String,
            album: payload["album"] as? String,
            duration: (payload["duration"] as? NSNumber)?.doubleValue,
            elapsedTime: (payload["elapsedTime"] as? NSNumber)?.doubleValue,
            timestamp: timestamp,
            isPlaying: payload["playing"] as? Bool ?? false,
            playbackRate: (payload["playbackRate"] as? NSNumber)?.doubleValue,
            mediaType: payload["mediaType"] as? String,
            contentItemIdentifier: payload["contentItemIdentifier"] as? String
        )
    }
}

// MARK: - Who is playing it

/// A player the presence knows by name — an app, or a site in a browser.
public struct MediaPlayer: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case listening
        case watching

        /// Discord's activity type: 2 Listening, 3 Watching.
        public var activityType: Int { self == .listening ? 2 : 3 }
    }

    /// The settings key: a bundle identifier, or `web.<site>`.
    public var id: String
    public var name: String
    public var kind: Kind
    /// Shared as soon as the presence is on. **Video players and unknown
    /// sites are not** — a file's name or a page's title can say more than
    /// the reader meant to broadcast, so those wait to be switched on.
    public var isOnByDefault: Bool
    /// The hosts a site plays on; empty for an app.
    public var hosts: [String]

    public init(id: String, name: String, kind: Kind, isOnByDefault: Bool, hosts: [String] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isOnByDefault = isOnByDefault
        self.hosts = hosts
    }

    public var isWebSite: Bool { id.hasPrefix("web.") }
}

public enum MediaPlayers {

    /// Browsers: their media belongs to whichever page plays it.
    public static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "company.thebrowser.Browser", "company.thebrowser.dia",
        "com.brave.Browser", "com.microsoft.edgemac", "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi", "com.kagi.kagimacOS", "org.mozilla.firefox", "app.zen-browser.zen",
    ]

    /// Browsers that answer AppleScript for their tabs' addresses. Firefox
    /// and Zen do not.
    public static let scriptableBrowsers: Set<String> = browsers.subtracting(["org.mozilla.firefox", "app.zen-browser.zen"])

    public static let apps: [MediaPlayer] = [
        MediaPlayer(id: "com.apple.Music", name: "Apple Music", kind: .listening, isOnByDefault: true),
        MediaPlayer(id: "com.spotify.client", name: "Spotify", kind: .listening, isOnByDefault: true),
        MediaPlayer(id: "com.tidal.desktop", name: "TIDAL", kind: .listening, isOnByDefault: true),
        MediaPlayer(id: "com.deezer.deezer-desktop", name: "Deezer", kind: .listening, isOnByDefault: true),
        MediaPlayer(id: "com.amazon.music", name: "Amazon Music", kind: .listening, isOnByDefault: true),
        MediaPlayer(id: "com.qobuz.QobuzDesktop", name: "Qobuz", kind: .listening, isOnByDefault: true),
        MediaPlayer(id: "com.apple.podcasts", name: "Podcasts", kind: .listening, isOnByDefault: true),
        MediaPlayer(id: "tv.plex.plexamp", name: "Plexamp", kind: .listening, isOnByDefault: true),
        MediaPlayer(id: "co.brushedtype.doppler-macos", name: "Doppler", kind: .listening, isOnByDefault: true),
        MediaPlayer(id: "com.swinsian.Swinsian", name: "Swinsian", kind: .listening, isOnByDefault: true),
        MediaPlayer(id: "com.coppertino.Vox", name: "VOX", kind: .listening, isOnByDefault: true),
        MediaPlayer(id: "com.foobar2000.mac", name: "foobar2000", kind: .listening, isOnByDefault: true),
        MediaPlayer(id: "com.apple.TV", name: "Apple TV", kind: .watching, isOnByDefault: false),
        MediaPlayer(id: "com.apple.QuickTimePlayerX", name: "QuickTime Player", kind: .watching, isOnByDefault: false),
        MediaPlayer(id: "com.colliderli.iina", name: "IINA", kind: .watching, isOnByDefault: false),
        MediaPlayer(id: "org.videolan.vlc", name: "VLC", kind: .watching, isOnByDefault: false),
    ]

    public static let youtube = MediaPlayer(
        id: "web.youtube", name: "YouTube", kind: .watching, isOnByDefault: true,
        hosts: ["youtube.com", "m.youtube.com", "youtu.be"]
    )
    public static let youtubeMusic = MediaPlayer(
        id: "web.youtube-music", name: "YouTube Music", kind: .listening, isOnByDefault: true,
        hosts: ["music.youtube.com"]
    )

    public static let sites: [MediaPlayer] = [
        youtubeMusic,
        youtube,
        MediaPlayer(id: "web.soundcloud", name: "SoundCloud", kind: .listening, isOnByDefault: true, hosts: ["soundcloud.com"]),
        MediaPlayer(id: "web.spotify", name: "Spotify", kind: .listening, isOnByDefault: true, hosts: ["open.spotify.com"]),
        MediaPlayer(id: "web.apple-music", name: "Apple Music", kind: .listening, isOnByDefault: true, hosts: ["music.apple.com"]),
        MediaPlayer(id: "web.bandcamp", name: "Bandcamp", kind: .listening, isOnByDefault: true, hosts: ["bandcamp.com"]),
        MediaPlayer(id: "web.deezer", name: "Deezer", kind: .listening, isOnByDefault: true, hosts: ["deezer.com"]),
        MediaPlayer(id: "web.tidal", name: "TIDAL", kind: .listening, isOnByDefault: true, hosts: ["listen.tidal.com", "tidal.com"]),
        MediaPlayer(id: "web.twitch", name: "Twitch", kind: .watching, isOnByDefault: false, hosts: ["twitch.tv"]),
        MediaPlayer(id: "web.netflix", name: "Netflix", kind: .watching, isOnByDefault: false, hosts: ["netflix.com"]),
        MediaPlayer(id: "web.crunchyroll", name: "Crunchyroll", kind: .watching, isOnByDefault: false, hosts: ["crunchyroll.com"]),
    ]

    public static func app(_ bundleIdentifier: String) -> MediaPlayer? {
        apps.first { $0.id == bundleIdentifier }
    }

    /// The site a page belongs to, by its host or a parent of it — the most
    /// specific match first, so `music.youtube.com` is YouTube Music.
    public static func site(for url: URL) -> MediaPlayer? {
        guard var host = url.host()?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return sites.first { site in site.hosts.contains { host == $0 || host.hasSuffix("." + $0) } }
    }

    /// A player for an app nobody listed, under the name its bundle gives.
    public static func unknownApp(_ bundleIdentifier: String, name: String, isVideo: Bool) -> MediaPlayer {
        MediaPlayer(id: bundleIdentifier, name: name, kind: isVideo ? .watching : .listening, isOnByDefault: false)
    }

    /// Every site nobody listed shares one switch, off until turned on.
    public static let otherSitesID = "web.other"

    /// A site nobody listed, under its host — "Watching vimeo.com".
    public static func otherSite(_ url: URL, isVideo: Bool) -> MediaPlayer? {
        guard var host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return MediaPlayer(id: otherSitesID, name: host, kind: isVideo ? .watching : .listening, isOnByDefault: false, hosts: [host])
    }
}
