import Foundation

// MARK: - What is playing, as a Discord activity
//
// YouTube and YouTube Music are YouTubeDiscordPresence's presence exactly
// (MIT; `Extension/background.js`'s `generatePresenceData`), under its two
// public applications so they read "YouTube" / "YouTube Music" with its
// artwork: Watching YouTube — the title, "by <channel>" or "[LIVE] on
// <channel>", the thumbnail, a progress bar, Watch Video / View Channel; and
// Listening to YouTube Music with the song as the member-list line.
//
// Every other player — Apple Music, Spotify, TIDAL, a site in a browser — is
// "Listening to <player>" (or Watching), its name set by Wingcord itself under
// one Now Playing application (docs/CLIPS-PRESENCE.md, D7).
//
// Pictures leave here as references — a link or an application asset key —
// and the app resolves them through the activity's application before sending
// (`resolvingImages`): the gateway takes `mp:` ids and asset ids, not links.

/// A browser's tab — the page it shows, by its address and title.
public struct BrowserTab: Hashable, Sendable {
    public var url: URL
    public var title: String

    public init(url: URL, title: String) {
        self.url = url
        self.title = title
    }
}

/// A button on the presence.
public struct MediaLink: Hashable, Sendable {
    public var label: String
    public var url: URL

    public init(label: String, url: URL) {
        self.label = label
        self.url = url
    }
}

/// Which line names the activity in a member list — `status_display_type`.
public enum MediaPresenceLine: String, Hashable, Sendable, CaseIterable, Codable {
    /// Each player's own: the song for YouTube Music, as YouTubeDiscordPresence
    /// does, the player's name for everything else.
    case automatic
    /// "Listening to Apple Music".
    case player
    /// "Listening to <artist>".
    case artist
    /// "Listening to <title>".
    case title
}

public struct MediaPresenceOptions: Hashable, Sendable {
    public var showsWhilePaused: Bool
    public var showsYouTubeThumbnails: Bool
    public var showsButtons: Bool
    /// "by <artist>" rather than the bare name.
    public var prefixesBy: Bool
    public var memberListLine: MediaPresenceLine
    /// Words that keep a title, channel or artist off the presence.
    public var excludedWords: [String]

    public init(
        showsWhilePaused: Bool = false,
        showsYouTubeThumbnails: Bool = true,
        showsButtons: Bool = true,
        prefixesBy: Bool = true,
        memberListLine: MediaPresenceLine = .automatic,
        excludedWords: [String] = []
    ) {
        self.showsWhilePaused = showsWhilePaused
        self.showsYouTubeThumbnails = showsYouTubeThumbnails
        self.showsButtons = showsButtons
        self.prefixesBy = prefixesBy
        self.memberListLine = memberListLine
        self.excludedWords = excludedWords
    }
}

/// Who is playing it, and what the app learned about it beyond the snapshot.
public struct MediaPresenceSource: Hashable, Sendable {
    public var player: MediaPlayer
    /// The tab, for a site.
    public var page: BrowserTab?
    /// A YouTube video's channel, from oEmbed.
    public var channelURL: URL?
    /// A cover found for a song — the snapshot's own artwork has no address.
    public var artworkURL: URL?
    /// A link to the song, for a button.
    public var link: MediaLink?
    /// When the app first saw this item playing. A livestream's clock starts
    /// here, as YouTubeDiscordPresence's does: its position is not a time
    /// anyone has spent watching.
    public var firstSeen: Date?

    public init(
        player: MediaPlayer,
        page: BrowserTab? = nil,
        channelURL: URL? = nil,
        artworkURL: URL? = nil,
        link: MediaLink? = nil,
        firstSeen: Date? = nil
    ) {
        self.player = player
        self.page = page
        self.channelURL = channelURL
        self.artworkURL = artworkURL
        self.link = link
        self.firstSeen = firstSeen
    }
}

public enum MediaPresence {

    /// YouTubeDiscordPresence's applications — public in its source, with the
    /// artwork its presence names (`youtube3`, `youtubelive1`, `youtube-music`).
    public static let youtubeApplication = ApplicationID(rawValue: 847_682_519_214_456_862)
    public static let youtubeMusicApplication = ApplicationID(rawValue: 1_064_295_774_592_180_254)

    /// The activity for what is playing, or nil when it should not be shown —
    /// paused (unless the reader keeps those) or excluded.
    ///
    /// - Parameter application: the Now Playing application other players
    ///   are published under; without one they go out with no pictures.
    public static func activity(
        for snapshot: NowPlayingSnapshot,
        source: MediaPresenceSource,
        options: MediaPresenceOptions,
        application: ApplicationID?,
        now: Date
    ) -> RichPresenceActivity? {
        guard snapshot.isPlaying || options.showsWhilePaused else { return nil }
        guard !isExcluded(snapshot, words: options.excludedWords) else { return nil }
        switch source.player.id {
        case MediaPlayers.youtube.id: return youtube(snapshot, source, options, now)
        case MediaPlayers.youtubeMusic.id: return youtubeMusic(snapshot, source, options, now)
        default: return player(snapshot, source, options, application, now)
        }
    }

    // MARK: YouTube

    private static func youtube(
        _ snapshot: NowPlayingSnapshot, _ source: MediaPresenceSource, _ options: MediaPresenceOptions, _ now: Date
    ) -> RichPresenceActivity {
        let videoID = source.page.flatMap { youtubeVideoID(in: $0.url) }
        let live = isLive(snapshot, page: source.page)
        let state = snapshot.artist.map { channel in
            options.prefixesBy ? (live ? "[LIVE] on \(channel)" : "by \(channel)") : channel
        }
        var activity = RichPresenceActivity(
            type: MediaPlayer.Kind.watching.activityType,
            name: "YouTube",
            details: padded(snapshot.title),
            state: state.map(padded),
            assets: .init(
                largeImage: thumbnail(videoID, options) ?? (live ? "youtubelive1" : "youtube3"),
                largeText: padded(snapshot.album ?? snapshot.title)
            ),
            timestamps: timestamps(snapshot, live: live, firstSeen: source.firstSeen, now: now),
            applicationID: youtubeApplication
        )
        var links: [MediaLink] = []
        if let videoID, let watch = URL(string: "https://www.youtube.com/watch?v=\(videoID)") {
            links.append(MediaLink(label: live ? "Watch Livestream" : "Watch Video", url: watch))
        }
        if let channelURL = source.channelURL { links.append(MediaLink(label: "View Channel", url: channelURL)) }
        attach(links, to: &activity, options)
        activity.statusDisplayType = line(options.memberListLine)
        return activity
    }

    private static func youtubeMusic(
        _ snapshot: NowPlayingSnapshot, _ source: MediaPresenceSource, _ options: MediaPresenceOptions, _ now: Date
    ) -> RichPresenceActivity {
        let videoID = source.page.flatMap { youtubeVideoID(in: $0.url) }
        var activity = RichPresenceActivity(
            type: MediaPlayer.Kind.listening.activityType,
            name: "YouTube Music",
            details: padded(snapshot.title),
            state: snapshot.artist.map { padded(options.prefixesBy ? "by \($0)" : $0) },
            assets: .init(
                largeImage: thumbnail(videoID, options) ?? "youtube-music",
                largeText: padded(snapshot.album ?? snapshot.title)
            ),
            timestamps: timestamps(snapshot, live: !snapshot.hasDuration, firstSeen: source.firstSeen, now: now),
            applicationID: youtubeMusicApplication
        )
        var links: [MediaLink] = []
        if let videoID, let listen = URL(string: "https://music.youtube.com/watch?v=\(videoID)") {
            links.append(MediaLink(label: "Listen Along", url: listen))
        }
        if let channelURL = source.channelURL { links.append(MediaLink(label: "View Channel", url: channelURL)) }
        attach(links, to: &activity, options)
        activity.statusDisplayType = line(options.memberListLine == .automatic ? .title : options.memberListLine)
        return activity
    }

    // MARK: Everything else

    private static func player(
        _ snapshot: NowPlayingSnapshot, _ source: MediaPresenceSource, _ options: MediaPresenceOptions,
        _ application: ApplicationID?, _ now: Date
    ) -> RichPresenceActivity {
        let player = source.player
        var activity = RichPresenceActivity(
            type: player.kind.activityType,
            name: player.name,
            details: padded(snapshot.title),
            state: snapshot.artist.map { padded(options.prefixesBy && player.kind == .listening ? "by \($0)" : $0) },
            assets: application == nil ? nil : .init(
                largeImage: source.artworkURL?.absoluteString,
                largeText: snapshot.album.map(padded)
            ),
            timestamps: timestamps(snapshot, live: !snapshot.hasDuration, firstSeen: source.firstSeen, now: now),
            applicationID: application
        )
        attach(source.link.map { [$0] } ?? [], to: &activity, options)
        activity.statusDisplayType = line(options.memberListLine)
        return activity
    }

    // MARK: Pieces

    /// The video in a YouTube address: `watch?v=`, `youtu.be/`, `/live/`,
    /// `/shorts/`, `/embed/`. Only an 11-character id counts.
    public static func youtubeVideoID(in url: URL) -> String? {
        let host = url.host()?.lowercased() ?? ""
        let parts = url.path().split(separator: "/").map(String.init)
        var candidate: String?
        if host == "youtu.be" || host.hasSuffix(".youtu.be") {
            candidate = parts.first
        } else if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value {
            candidate = v
        } else if parts.count >= 2, ["live", "shorts", "embed", "v"].contains(parts[0]) {
            candidate = parts[1]
        }
        guard let id = candidate, id.count == 11,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return id
    }

    /// The 320 × 180 still YouTubeDiscordPresence uses.
    public static func youtubeThumbnail(_ videoID: String) -> URL {
        URL(string: "https://i.ytimg.com/vi/\(videoID)/mqdefault.jpg")!
    }

    /// A livestream has no end, or plays from a `/live/` address.
    /// YouTubeDiscordPresence reads the player's LIVE badge instead; the
    /// page's DOM is out of reach here.
    public static func isLive(_ snapshot: NowPlayingSnapshot, page: BrowserTab?) -> Bool {
        !snapshot.hasDuration || page?.url.path().hasPrefix("/live/") == true
    }

    /// Whether a word the reader listed appears in the title, the artist or
    /// the album — case and accents folded.
    public static func isExcluded(_ snapshot: NowPlayingSnapshot, words: [String]) -> Bool {
        let haystack = [snapshot.title, snapshot.artist, snapshot.album].compactMap(\.self)
            .joined(separator: "\n").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return words.contains { word in
            let needle = word.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return !needle.isEmpty && haystack.contains(needle)
        }
    }

    /// Milliseconds since the epoch. While it plays: start and end — the
    /// progress bar — when it has an end, or a start alone for a livestream,
    /// from when it was first seen. Nothing while paused, where a running
    /// clock would be a lie.
    static func timestamps(
        _ snapshot: NowPlayingSnapshot, live: Bool, firstSeen: Date?, now: Date
    ) -> RichPresenceActivity.Timestamps? {
        guard snapshot.isPlaying else { return nil }
        if live { return .init(start: milliseconds(firstSeen ?? now)) }
        let start = milliseconds(now.addingTimeInterval(-(snapshot.elapsed(at: now) ?? 0)))
        guard let duration = snapshot.duration, duration > 0 else { return .init(start: start) }
        return .init(start: start, end: start + Int((duration * 1000).rounded()))
    }

    /// Whether `next` says something `published` does not. A clock moved by
    /// under three seconds is the same clock: positions arrive stamped at
    /// slightly different moments, and every republish spends the gateway's
    /// allowance of five presence updates in twenty seconds.
    public static func differs(_ next: RichPresenceActivity?, from published: RichPresenceActivity?) -> Bool {
        guard var next, let published else { return (next == nil) != (published == nil) }
        if let a = next.timestamps, let b = published.timestamps,
           close(a.start, b.start), close(a.end, b.end) {
            next.timestamps = b
        }
        return next != published
    }

    private static func close(_ a: Int?, _ b: Int?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): abs(a - b) < 3_000
        default: false
        }
    }

    static func line(_ line: MediaPresenceLine) -> Int? {
        switch line {
        case .automatic, .player: nil
        case .artist: 1
        case .title: 2
        }
    }

    /// Discord refuses a details, state or hover line under two characters
    /// and cuts at 128 — YouTubeDiscordPresence pads with a zero-width space.
    static func padded(_ text: String) -> String {
        let cut = String(text.prefix(128))
        return cut.count < 2 ? cut + String(repeating: "\u{200B}", count: 2 - cut.count) : cut
    }

    private static func thumbnail(_ videoID: String?, _ options: MediaPresenceOptions) -> String? {
        guard options.showsYouTubeThumbnails, let videoID else { return nil }
        return youtubeThumbnail(videoID).absoluteString
    }

    /// At most two, as Discord takes.
    private static func attach(_ links: [MediaLink], to activity: inout RichPresenceActivity, _ options: MediaPresenceOptions) {
        guard options.showsButtons else { return }
        let shown = links.prefix(2)
        activity.buttons = shown.map(\.label)
        activity.buttonURLs = shown.map(\.url)
    }

    private static func milliseconds(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 * 1000).rounded())
    }
}

extension RichPresenceActivity {
    /// The activity with its pictures swapped for what its application
    /// resolved them to — `mp:` ids for links, asset ids for keys. A picture
    /// that did not resolve is dropped: the gateway takes no bare link.
    public func resolvingImages(_ resolved: [String: String]) -> RichPresenceActivity {
        guard var assets else { return self }
        assets.largeImage = assets.largeImage.flatMap { resolved[$0] }
        assets.smallImage = assets.smallImage.flatMap { resolved[$0] }
        var copy = self
        copy.assets = assets
        return copy
    }

    /// The pictures still to resolve, as the activity names them.
    public var imageReferences: [String] {
        [assets?.largeImage, assets?.smallImage].compactMap(\.self)
    }
}
