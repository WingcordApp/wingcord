import Foundation
import WingcordCore

// MARK: - `--demo`'s Server Hub
//
// docs/BETA2.md, phase 9 (D15): a hub on the first server with every widget
// kind, so the page, its editing and its sheets can be seen without an account
// in Discord's experiment. Every picture is drawn on this Mac (`DemoGameArt`);
// nothing here reaches Discord's CDN.

extension DemoFixtures {

    static let serverHubGuild = GuildID(rawValue: 1000)
    static let serverHubChannel = ChannelID(rawValue: 1_999)

    /// Discord's catalog, as its route answers it.
    static var serverHubCatalog: [GuildSpaceCatalogEntry] {
        [
            .init(kind: .leaderboard, name: "Gaming Leaderboard",
                  staticImageURL: DemoGameArt.tile(symbol: "trophy.fill", top: (0.99, 0.78, 0.25), bottom: (0.75, 0.42, 0.05), name: "hub-leaderboard")),
            .init(kind: .whiteboard, name: "Whiteboard",
                  staticImageURL: DemoGameArt.tile(symbol: "pencil.and.scribble", top: (0.42, 0.62, 1.0), bottom: (0.18, 0.28, 0.75), name: "hub-whiteboard")),
            .init(kind: .popularGames, name: "Popular Games",
                  staticImageURL: DemoGameArt.tile(symbol: "gamecontroller.fill", top: (0.55, 0.85, 0.45), bottom: (0.12, 0.45, 0.22), name: "hub-games")),
            .init(kind: .popularMusic, name: "Popular Music", boostPrice: 2, isLocked: false,
                  staticImageURL: DemoGameArt.tile(symbol: "music.note", top: (0.98, 0.45, 0.62), bottom: (0.55, 0.12, 0.35), name: "hub-music")),
            .init(kind: .imageText, name: "Image + Text", maxInstances: 4,
                  staticImageURL: DemoGameArt.tile(symbol: "text.below.photo.fill", top: (0.75, 0.62, 0.98), bottom: (0.35, 0.22, 0.62), name: "hub-image-text")),
        ]
    }

    static func populateServerHub(_ model: AppModel) {
        let guildID = serverHubGuild
        guard model.guilds[guildID] != nil else { return }
        model.guilds[guildID]?.spaceSettings = GuildSpaceSettings(isEnabled: true, publishStatus: .published)
        // Activities allowed to everyone in the hub's own channel, as a server
        // that wants its whiteboard used sets it.
        var channel = Channel(id: serverHubChannel, kind: .guildSpace, guildID: guildID, name: "server-hub")
        channel.overwrites = [PermissionOverwrite(id: guildID.rawValue, subject: .role, allow: [.useEmbeddedActivities], deny: [])]
        model.channelIndex.upsert(channel)

        let games = serverHubGames(model)
        let people = serverHubPeople(model, in: guildID)
        let store = model.serverHub
        store.demoBannerURL = DemoGameArt.picture(.init(
            name: "hub-banner", symbol: "house.fill",
            top: (0.38, 0.30, 0.92), bottom: (0.10, 0.06, 0.32),
            size: CGSize(width: 1600, height: 520)
        ))
        store.demoImageURLs["demo-hub-announcement"] = DemoGameArt.picture(.init(
            name: "hub-announcement", symbol: "sparkles",
            top: (0.98, 0.62, 0.30), bottom: (0.62, 0.15, 0.35),
            size: CGSize(width: 900, height: 520)
        ))

        let widgets: [GuildSpaceWidget] = [
            .init(id: "demo-hub-whiteboard", kind: .whiteboard, position: .init(column: 0, order: 0), defaultTitle: "Whiteboard"),
            .init(id: "demo-hub-announcement", kind: .imageText, position: .init(column: 0, order: 1),
                  defaultTitle: "Image + Text",
                  config: GuildSpaceWidgetConfig(
                    kind: .imageText,
                    title: "Screenshot contest, round two",
                    text: "Post your best shot in #screenshot-contest before Sunday. The winner picks next week\u{2019}s theme.",
                    imageHash: "demo"
                  )),
            .init(id: "demo-hub-music", kind: .popularMusic, position: .init(column: 0, order: 2),
                  requiresHydration: true, defaultTitle: "Popular Music"),
            .init(id: "demo-hub-leaderboard", kind: .leaderboard, position: .init(column: 1, order: 0),
                  requiresHydration: true, defaultTitle: "Gaming Leaderboard"),
            .init(id: "demo-hub-games", kind: .popularGames, position: .init(column: 1, order: 1),
                  requiresHydration: true, defaultTitle: "Popular Games"),
            .init(id: "demo-hub-hello", kind: .imageText, position: .init(column: 1, order: 2),
                  defaultTitle: "Image + Text",
                  config: GuildSpaceWidgetConfig(
                    kind: .imageText,
                    title: "New here?",
                    text: "Say hi in #this-is-iris and grab your roles in Channels & Roles. Be kind, keep it on topic, have fun."
                  )),
        ]
        store.spaces[guildID] = GuildSpace(guildID: guildID, channelID: serverHubChannel, customBannerHash: "demo", widgets: widgets)
        for widget in widgets where widget.requiresHydration {
            if let data = serverHubHydration(widget.kind, people: people, games: games) {
                store.hydrations[widget.id] = .loaded(data)
            }
        }
    }

    /// The demo's Save: the edit becomes the hub, as Discord's answer would.
    static func saveServerHub(_ draft: ServerHubDraft, model: AppModel) {
        let store = model.serverHub
        let people = serverHubPeople(model, in: draft.guildID)
        let games = serverHubGames(model)
        var widgets: [GuildSpaceWidget] = []
        for var widget in draft.widgets {
            if widget.isDraft { widget.id = "demo-hub-\(UUID().uuidString.prefix(8))" }
            widget.requiresHydration = [.leaderboard, .popularGames, .popularMusic].contains(widget.kind)
            switch widget.config.imageChange {
            case .replaced(let dataURL):
                if let data = AppModel.decodeDataURL(dataURL) {
                    let file = FileManager.default.temporaryDirectory.appending(path: "hub-\(widget.id).png")
                    try? data.write(to: file)
                    store.demoImageURLs[widget.id] = file
                }
                widget.config.imageHash = "demo"
            case .removed:
                widget.config.imageHash = nil
                store.demoImageURLs[widget.id] = nil
            case .unchanged:
                break
            }
            widget.config.imageChange = .unchanged
            if widget.requiresHydration, store.hydrations[widget.id] == nil,
               let data = serverHubHydration(widget.kind, people: people, games: games) {
                store.hydrations[widget.id] = .loaded(data)
            }
            widgets.append(widget)
        }
        var bannerHash = store.spaces[draft.guildID]?.customBannerHash
        switch draft.banner {
        case .replaced(_, let preview):
            let file = FileManager.default.temporaryDirectory.appending(path: "hub-banner-\(UUID().uuidString.prefix(6)).png")
            try? preview.write(to: file)
            store.demoBannerURL = file
            bannerHash = "demo"
        case .removed:
            bannerHash = nil
        case .unchanged:
            break
        }
        store.spaces[draft.guildID] = GuildSpace(
            guildID: draft.guildID,
            channelID: store.spaces[draft.guildID]?.channelID ?? serverHubChannel,
            customBannerHash: bannerHash,
            widgets: GuildSpaceLayout.normalized(widgets)
        )
        store.missing.remove(draft.guildID)
        store.draft = nil
        store.sheet = nil
    }

    // MARK: The people and the games

    private static func serverHubPeople(_ model: AppModel, in guildID: GuildID) -> [UserID] {
        let members = model.members[guildID].map { Array($0.keys) } ?? Array(model.users.keys)
        return members
            .filter { model.users[$0]?.isBot == false && $0 != model.currentUserID }
            .sorted { $0.rawValue < $1.rawValue }
    }

    /// Made-up ids beside Counter-Strike 2's (the demo's own): a real game's id
    /// can be one an account's data carries, which the push check refuses.
    private static func serverHubGames(_ model: AppModel) -> [ApplicationID] {
        let specs: [(UInt64, String, String, RGBTriple, RGBTriple)] = [
            (1_158_877_933_042_143_272, "Counter-Strike 2", "scope", (0.98, 0.55, 0.12), (0.55, 0.18, 0.05)),
            (1_400_000_000_000_000_001, "Minecraft", "cube.fill", (0.45, 0.80, 0.35), (0.20, 0.42, 0.18)),
            (1_400_000_000_000_000_002, "Fortnite", "bolt.fill", (0.45, 0.55, 1.0), (0.30, 0.15, 0.62)),
            (1_400_000_000_000_000_003, "Roblox", "square.stack.3d.up.fill", (0.92, 0.25, 0.25), (0.35, 0.08, 0.10)),
            (1_400_000_000_000_000_004, "Rocket League", "car.fill", (0.25, 0.70, 0.98), (0.95, 0.45, 0.10)),
        ]
        return specs.map { id, name, symbol, top, bottom in
            let applicationID = ApplicationID(rawValue: id)
            if model.games[applicationID] == nil {
                let slug = name.lowercased().replacing(" ", with: "-")
                model.games[applicationID] = Game(
                    id: applicationID,
                    name: name,
                    media: GameMedia(
                        icon: DemoGameArt.tile(symbol: symbol, top: top, bottom: bottom, name: slug).map(GameMediaRef.url),
                        cover: DemoGameArt.cover(symbol: symbol, top: top, bottom: bottom, name: slug).map(GameMediaRef.url)
                    )
                )
            }
            return applicationID
        }
    }

    private typealias RGBTriple = (Double, Double, Double)

    private static func serverHubHydration(
        _ kind: GuildSpaceWidgetKind,
        people: [UserID],
        games: [ApplicationID]
    ) -> GuildSpaceHydration? {
        guard !people.isEmpty, !games.isEmpty else { return nil }
        let now = Date.now
        switch kind {
        case .leaderboard:
            let hours: [Double] = [44.75, 29.75, 29.33, 25.25, 24.83, 24.25, 22.83, 18.83, 14.66, 14.58, 12, 9.5]
            let entries = people.prefix(hours.count).enumerated().map { index, userID in
                GuildSpaceLeaderboard.Entry(
                    userID: userID,
                    rank: index + 1,
                    value: hours[index] * 3_600_000,
                    applicationIDs: Array(games.dropFirst(index % games.count) + games.prefix(index % games.count)).prefix(3).map(\.self),
                    applicationCount: 2 + (index * 3) % 6
                )
            }
            return .leaderboard(GuildSpaceLeaderboard(
                stat: .hoursPlayed,
                nextStat: .daysPlayed,
                weekStart: now.addingTimeInterval(-6 * 86_400 + 3_600 * 5),
                computedAt: now.addingTimeInterval(-3 * 3_600),
                entries: Array(entries)
            ))
        case .popularGames:
            let players = [39, 15, 13, 9, 6]
            return .popularGames(GuildSpacePopularGames(
                userIDs: Array(people.prefix(12)),
                games: games.enumerated().map { index, id in
                    .init(applicationID: id, userIDs: Array(people.prefix(min(players[index % players.count], people.count))))
                },
                totalUsers: 64,
                totalGames: 9_278
            ))
        case .popularMusic:
            let songs: [(String, String, Int)] = [
                ("Midnight City", "M83", 212), ("Redbone", "Childish Gambino", 187), ("Nights", "Frank Ocean", 164),
                ("Blinding Lights", "The Weeknd", 151), ("Kids", "MGMT", 122), ("Pink + White", "Frank Ocean", 98),
            ]
            return .popularMusic(GuildSpacePopularMusic(
                songs: songs.enumerated().map { index, song in
                    .init(trackID: "demo-track-\(index)", title: song.0, artistName: song.1, coverArtHash: nil,
                          plays: song.2, userIDs: Array(people.prefix(3)))
                },
                artists: [("Frank Ocean", 262), ("M83", 212), ("Childish Gambino", 187), ("The Weeknd", 151)].enumerated().map { index, artist in
                    .init(artistID: "demo-artist-\(index)", name: artist.0, imageHash: nil, plays: artist.1)
                },
                listeners: people.prefix(5).enumerated().map { index, userID in
                    .init(userID: userID, plays: [341, 280, 199, 154, 120][index], lastTrackTitle: songs[index].0, lastArtistName: songs[index].1)
                },
                distinctSongs: 128,
                distinctArtists: 57,
                distinctListeners: 31
            ))
        default:
            return nil
        }
    }
}
