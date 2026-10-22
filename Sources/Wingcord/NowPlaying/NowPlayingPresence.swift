import AppKit
import Observation
import WingcordCore

// MARK: - What is playing, as the presence Wingcord publishes
//
// Two speeds. **Once per thing played**, in a task of its own: who plays it (an
// app, or a browser's tab on a site), the channel or the cover, and the
// pictures resolved through the activity's application. **On every report**,
// at once: the activity rebuilt from the snapshot and what was learned —
// `MediaPresence` is pure, so this costs nothing — and offered for publishing,
// at most once every four seconds.
//
// **The slow half is never restarted by the fast one.** The adapter reports a
// position change as a new snapshot of the same item, and a lookup restarted by
// each of those is one that never finishes — which is exactly what a consent
// prompt left open for a minute did to the first version of this.

@Observable
@MainActor
final class NowPlayingPresence {

    /// The Now Playing application every player other than YouTube's goes out
    /// under (docs/CLIPS-PRESENCE.md, D7). **Nil until Alex has made it**,
    /// which sends those players without pictures or buttons — Discord takes
    /// both only through an application.
    static let application: ApplicationID? = nil

    /// Why nothing goes out while something plays — what the Activity pane says.
    enum Hold: Equatable {
        /// Finding out who plays it: the browser is being asked for its tab.
        case looking
        case paused
        /// The player's own switch is off.
        case playerOff
        case excluded
        /// Discord's own Spotify connection already shows it.
        case shownBySpotify
        /// A browser that could not say which tab plays.
        case noPage
        case browserDenied
    }

    /// Discord's answers about pictures, by way of the session.
    struct Assets {
        /// `mp:` ids for links.
        var external: (ApplicationID, [String]) async throws -> [String: String]
        /// An application's own pictures by name.
        var named: (ApplicationID) async throws -> [String: String]
    }

    private(set) var snapshot: NowPlayingSnapshot?
    private(set) var player: MediaPlayer?
    /// What goes out, pictures resolved; nil while nothing is shared.
    private(set) var activity: RichPresenceActivity?
    private(set) var hold: Hold?

    var isRunning: Bool { monitor.isRunning }

    @ObservationIgnored let tabs = BrowserTabReader()
    /// Nil in `--demo`, which asks Discord nothing: a YouTube picture is then
    /// the `youtube:` key the client draws by itself, and others go without.
    @ObservationIgnored var assets: Assets?
    /// Whether the account's "Share my activity" is on — Now Playing rides it.
    @ObservationIgnored var sharesActivity: () -> Bool = { true }
    /// Whether Discord's own Spotify connection already shows what plays.
    @ObservationIgnored var isSpotifyShown: () -> Bool = { false }
    /// Called after `activity` changes.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let monitor = NowPlayingMonitor()
    @ObservationIgnored private let lookups = NowPlayingLookups()
    @ObservationIgnored private var item: Item?
    @ObservationIgnored private var learning: Task<Void, Never>?
    @ObservationIgnored private var resolving: Task<Void, Never>?
    @ObservationIgnored private var publishing: Task<Void, Never>?
    @ObservationIgnored private var pending: RichPresenceActivity?
    @ObservationIgnored private var hasPending = false
    @ObservationIgnored private var lastPublished = Date.distantPast
    @ObservationIgnored private var linkAssets: [String: String] = [:]
    @ObservationIgnored private var namedAssets: [ApplicationID: [String: String]] = [:]
    /// Asked once a launch, answered or not — a picture Discord refused is not
    /// asked for again on every report.
    @ObservationIgnored private var askedLinks: Set<String> = []
    @ObservationIgnored private var askedApplications: Set<ApplicationID> = []

    /// One thing played, and what was learned about it.
    private struct Item {
        var key: String
        var firstSeen: Date
        /// Nil until the lookups have answered.
        var learned: Learned?
    }

    private struct Learned {
        var player: MediaPlayer?
        var page: BrowserTab?
        var channelURL: URL?
        var artworkURL: URL?
        var link: MediaLink?
        var isBrowserDenied = false
        /// What was asked, so a setting turned on later asks for the rest.
        var askedChannel = false
        var askedCover = false
    }

    /// Five presence updates in twenty seconds is the gateway's allowance, and
    /// everything else this client publishes shares it.
    private static let spacing: TimeInterval = 4

    // MARK: Turning on and off

    /// Starts or stops with the settings, and builds again — asking for what a
    /// setting just turned on needs (a channel for the buttons, a cover).
    func refresh() {
        let settings = AppSettings.shared
        if settings.sharesNowPlaying, settings.sharesGameActivity, sharesActivity() {
            monitor.onChange = { [weak self] snapshot in self?.snapshotChanged(snapshot) }
            monitor.start()
        } else {
            monitor.stop()
        }
        if let snapshot, let learned = item?.learned, needsMore(learned) { learn(about: snapshot) }
        rebuild()
    }

    func stop() {
        monitor.stop()
        learning?.cancel()
        resolving?.cancel()
        publishing?.cancel()
        publishing = nil
        hasPending = false
        snapshot = nil
        player = nil
        hold = nil
        item = nil
        activity = nil
    }

    /// Something outside changed what is shown — Spotify's own presence came or
    /// went.
    func reconsider() { rebuild() }

    // MARK: Once per thing played

    private func snapshotChanged(_ snapshot: NowPlayingSnapshot?) {
        // A ping, not a song: what was playing still is, as far as anyone
        // watching the presence should know.
        if let snapshot, snapshot.isBlip { return }
        self.snapshot = snapshot
        if let snapshot {
            if snapshot.itemKey != item?.key {
                item = Item(key: snapshot.itemKey, firstSeen: .now)
                learn(about: snapshot)
            }
        } else {
            learning?.cancel()
            item = nil
        }
        rebuild()
    }

    private func learn(about snapshot: NowPlayingSnapshot) {
        learning?.cancel()
        let key = snapshot.itemKey
        let known = item?.learned
        NowPlayingMonitor.trace("learning about \(snapshot.appBundleIdentifier)")
        learning = Task { [weak self] in
            guard let self else { return }
            let learned = await lookUp(snapshot, knowing: known)
            guard !Task.isCancelled, item?.key == key else { return }
            item?.learned = learned
            NowPlayingMonitor.trace(
                "\(learned.player?.name ?? "no player") for \(snapshot.appBundleIdentifier)"
                    + (learned.page.map { " — \($0.url.host() ?? "")" } ?? "")
                    + (learned.isBrowserDenied ? " (browser declined)" : "")
            )
            rebuild()
        }
    }

    /// Who plays it and what else the presence needs — only what `known` does
    /// not already have.
    private func lookUp(_ snapshot: NowPlayingSnapshot, knowing known: Learned?) async -> Learned {
        var learned = known ?? Learned()
        let bundle = snapshot.appBundleIdentifier
        if known == nil {
            if MediaPlayers.browsers.contains(bundle) {
                learned.page = await playingTab(of: snapshot, in: bundle)
                // A tab's title can follow its media's by a moment: once more.
                if learned.page == nil, !tabs.deniedBrowsers.contains(bundle), !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    learned.page = await playingTab(of: snapshot, in: bundle)
                }
                learned.isBrowserDenied = tabs.deniedBrowsers.contains(bundle)
                learned.player = learned.page.flatMap {
                    MediaPlayers.site(for: $0.url) ?? MediaPlayers.otherSite($0.url, isVideo: snapshot.isVideo)
                }
            } else {
                learned.player = MediaPlayers.app(bundle)
                    ?? MediaPlayers.unknownApp(bundle, name: Self.name(of: bundle), isVideo: snapshot.isVideo)
            }
        }
        guard let player = learned.player, !Task.isCancelled else { return learned }
        let settings = AppSettings.shared
        if Self.isYouTube(player) {
            if settings.nowPlayingShowsButtons, !learned.askedChannel,
               let videoID = learned.page.flatMap({ MediaPresence.youtubeVideoID(in: $0.url) }) {
                learned.askedChannel = true
                learned.channelURL = await lookups.channel(of: videoID)
            }
        } else if player.kind == .listening, Self.application != nil, settings.nowPlayingFindsCovers, !learned.askedCover {
            learned.askedCover = true
            if let match = await lookups.cover(title: snapshot.title, artist: snapshot.artist, album: snapshot.album) {
                learned.artworkURL = match.artworkURL
                if Self.isAppleMusic(player), let url = match.trackURL {
                    learned.link = MediaLink(label: "Listen on Apple Music", url: url)
                }
            }
        }
        return learned
    }

    private func needsMore(_ learned: Learned) -> Bool {
        guard let player = learned.player else { return false }
        let settings = AppSettings.shared
        if Self.isYouTube(player) { return settings.nowPlayingShowsButtons && !learned.askedChannel }
        return player.kind == .listening && Self.application != nil && settings.nowPlayingFindsCovers && !learned.askedCover
    }

    private func playingTab(of snapshot: NowPlayingSnapshot, in browser: String) async -> BrowserTab? {
        guard case .pages(let tabs) = await tabs.pages(of: browser) else { return nil }
        return BrowserTabs.playingTab(among: tabs, title: snapshot.title)
    }

    // MARK: On every report

    private func rebuild() {
        let settings = AppSettings.shared
        guard monitor.isRunning, let snapshot, let item,
              snapshot.appBundleIdentifier != Bundle.main.bundleIdentifier
        else {
            player = nil
            hold = nil
            offer(nil)
            return
        }
        // Still asking: what is out stays out until the answer — a song that
        // follows another is one publish, not a removal and then an arrival.
        guard let learned = item.learned else {
            player = nil
            hold = .looking
            return
        }
        player = learned.player
        guard let player = learned.player else {
            hold = learned.isBrowserDenied ? .browserDenied : .noPage
            offer(nil)
            return
        }
        let reason: Hold? = if !settings.sharesNowPlaying(from: player) {
            .playerOff
        } else if player.name == "Spotify", isSpotifyShown() {
            .shownBySpotify
        } else if !snapshot.isPlaying, !settings.nowPlayingShowsWhilePaused {
            .paused
        } else if MediaPresence.isExcluded(snapshot, words: settings.nowPlayingExcludedWords) {
            .excluded
        } else {
            nil
        }
        hold = reason
        let source = MediaPresenceSource(
            player: player, page: learned.page, channelURL: learned.channelURL,
            artworkURL: learned.artworkURL, link: learned.link, firstSeen: item.firstSeen
        )
        guard reason == nil, let built = MediaPresence.activity(
            for: snapshot, source: source, options: settings.nowPlayingOptions,
            application: Self.application, now: .now
        ) else {
            offer(nil)
            return
        }
        offerResolving(built)
    }

    /// Out with its pictures resolved — asked for first when they never have
    /// been, so a new song is one publish with its cover rather than one
    /// without and one with.
    private func offerResolving(_ built: RichPresenceActivity) {
        let references = built.imageReferences
        guard let assets else {
            offer(built.resolvingImages(Self.drawnLocally(references)))
            return
        }
        guard let application = built.applicationID else {
            offer(built.resolvingImages([:]))
            return
        }
        let links = references.filter { Self.isLink($0) && linkAssets[$0] == nil && !askedLinks.contains($0) }
        let needsNames = references.contains { !Self.isLink($0) }
            && namedAssets[application] == nil && !askedApplications.contains(application)
        guard links.isEmpty, !needsNames else {
            resolving?.cancel()
            resolving = Task { [weak self] in
                guard let self else { return }
                await resolve(links: links, namesOf: needsNames ? application : nil, through: application, assets)
                guard !Task.isCancelled else { return }
                rebuild()
            }
            return
        }
        var resolved: [String: String] = [:]
        for key in references {
            resolved[key] = Self.isLink(key) ? linkAssets[key] : namedAssets[application]?[key]
        }
        offer(built.resolvingImages(resolved))
    }

    /// Discord's `fetchAssetIds`: a link through the application's external
    /// assets, a key from its own pictures.
    private func resolve(links: [String], namesOf named: ApplicationID?, through application: ApplicationID, _ assets: Assets) async {
        if askedLinks.count >= 512 { askedLinks.removeAll(keepingCapacity: true) }
        askedLinks.formUnion(links)
        if !links.isEmpty {
            do {
                let answered = try await assets.external(application, links)
                if linkAssets.count >= 256 { linkAssets.removeAll(keepingCapacity: true) }
                linkAssets.merge(answered) { _, new in new }
            } catch {
                NowPlayingMonitor.trace("picture links refused: \(error.localizedDescription)")
            }
        }
        if let named {
            askedApplications.insert(named)
            do {
                namedAssets[named] = try await assets.named(named)
            } catch {
                NowPlayingMonitor.trace("picture keys refused: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Publishing

    /// Out now, or four seconds after the last — whichever is later — and only
    /// the newest of what arrived meanwhile.
    private func offer(_ next: RichPresenceActivity?) {
        pending = next
        hasPending = true
        guard publishing == nil else { return }
        let wait = max(0, Self.spacing - Date.now.timeIntervalSince(lastPublished))
        publishing = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let self, !Task.isCancelled else { return }
            publishing = nil
            flush()
        }
    }

    private func flush() {
        guard hasPending else { return }
        hasPending = false
        guard MediaPresence.differs(pending, from: activity) else { return }
        activity = pending
        lastPublished = .now
        NowPlayingMonitor.trace(activity.map { "sharing \($0.name): \($0.details ?? "")" } ?? "sharing nothing")
        onChange?()
    }

    // MARK: Pieces

    private static func isLink(_ reference: String) -> Bool {
        reference.hasPrefix("https:") || reference.hasPrefix("http:")
    }

    private static func isYouTube(_ player: MediaPlayer) -> Bool {
        player.id == MediaPlayers.youtube.id || player.id == MediaPlayers.youtubeMusic.id
    }

    private static func isAppleMusic(_ player: MediaPlayer) -> Bool {
        player.id == "com.apple.Music" || player.id == "web.apple-music"
    }

    /// Pictures this client draws without asking anyone: a YouTube still, as
    /// the `youtube:` key `Activity.assetURL` knows.
    private static func drawnLocally(_ references: [String]) -> [String: String] {
        var drawn: [String: String] = [:]
        for reference in references {
            guard let url = URL(string: reference), url.host() == "i.ytimg.com" else { continue }
            let parts = url.path().split(separator: "/")
            if parts.count >= 2, parts[0] == "vi" { drawn[reference] = "youtube:\(parts[1])" }
        }
        return drawn
    }

    /// An app nobody listed, by the name it goes by.
    private static func name(of bundleIdentifier: String) -> String {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.localizedName {
            return running
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleIdentifier
    }
}
