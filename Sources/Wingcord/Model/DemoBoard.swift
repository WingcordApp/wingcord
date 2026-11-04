import Foundation
import WingcordCore

extension DemoFixtures {

    /// A board, a linked-game widget and a game profile, for `--demo`.
    ///
    /// **Real ids and real hashes, for the reason the nameplate fixture already
    /// makes.** A cover is fetched from `/app-icons/{id}/{hash}.png` and a
    /// widget's stats are resolved through a template against an identity; an
    /// arrangement like that which has never been on screen without an account
    /// is one nobody has checked. Every id and hash below is copied out of a
    /// live response and every asset is public on the CDN — confirmed with
    /// unauthenticated requests — so a demo launch draws the same pictures a
    /// real session does.
    ///
    /// The four tiles are chosen to disagree with each other: one detailed game
    /// with a comment and a wall of badges, one rotation with mixed badges, one
    /// grid, and one linked-game widget with character art and six stats.
    static func populateBoard(_ model: AppModel, owner: UserID) {
        for game in games { model.games[game.id] = game }
        populateCommunities(model)

        // **The board's owner is themed**, because the stage's whole surface is
        // lit from `ProfileGround` and an unthemed fixture can only ever show
        // the grey branch of it. A chosen pair rather than a derived one: the
        // derived branch already has a fixture of its own.
        if let user = model.users[owner] {
            model.users[owner] = User(
                id: user.id,
                username: user.username,
                displayName: user.displayName,
                avatarHash: user.avatarHash,
                discriminator: user.discriminator,
                flags: user.flags,
                isBot: user.isBot,
                isSystem: user.isSystem,
                decoration: UserDecoration(
                    nameplate: user.decoration?.nameplate,
                    displayNameStyle: user.decoration?.displayNameStyle,
                    bio: user.decoration?.bio
                        ?? "sometimes dev sometimes music, sometimes wasting time playing games",
                    themeColorValues: [0x1F_4E_5F, 0x0E_2A_38],
                    connectedAccounts: user.decoration?.connectedAccounts
                        ?? Self.demoConnections,
                    premiumTier: .nitro,
                    premiumSince: Date.now.addingTimeInterval(-86_400 * 900),
                    // **Both lists, so the Mutuals tab exists at all.** The tab
                    // strip is gated on there being something behind each tab,
                    // so a fixture with no mutual servers can only ever show two
                    // of the three — which is the half of the picker least worth
                    // checking.
                    mutualGuilds: model.guilds.keys.sorted { $0.rawValue < $1.rawValue }
                        .map { MutualGuild(id: $0) },
                    mutualFriends: Self.demoMutualFriends(model, excluding: owner)
                )
            )
        }

        model.widgetApplications[endfieldApplication] = WidgetApplication(
            id: endfieldApplication,
            name: "Arknights Endfield",
            iconHash: "f7877b08efb704adc7f7992af7e3b799",
            connectionEntrypointURL: URL(
                string: "https://endfield.gryphline.com/special/discord-binding"
            ),
            linkedGameIDs: [endfield]
        )
        model.widgetConfigs[endfieldApplication] = endfieldConfig
        model.applicationIdentities[owner] = [
            ApplicationIdentity(
                applicationID: endfieldApplication,
                externalUserID: "6264832493",
                profile: ApplicationProfile(
                    username: "Amin",
                    fields: [
                        "level": .number(60),
                        "operator_count": .number(29),
                        "achievement_badge_count": .number(114),
                        "created_at": .text("2026-01-22"),
                        "domain_1_level": .number(12),
                        "domain_2_level": .number(24),
                        "server": .text("Americas / Europe"),
                        // The proxy, which is the address Discord's own client
                        // loads and the one this fixture was confirmed against.
                        "featured_played_character_image": .image(URL(
                            string: "https://images-ext-1.discordapp.net/external"
                                + "/5262anvBGiUJ9zGLGQwj1gTcwYxnZXbLFMvm_mfQGQg/https"
                                + "/web-static-pub.hg-cdn.com/biz_toolset/upload"
                                + "/260623/97w2QnvxOdfxwyc5.png"
                        )!),
                    ],
                    fieldOrder: [
                        "level", "operator_count", "achievement_badge_count",
                        "created_at", "domain_1_level", "domain_2_level", "server",
                    ]
                )
            ),
        ]

        // A clips gallery (Phase 7): the demo's own game footage, three
        // ways — local files, so nothing is fetched.
        let clipVideo = URL(string: DemoMedia.gameClip().url)
        let gallery: [ProfileClip] = [
            ("the bridge triple", 282, DemoMedia.GameLook.dusk, "dusk"),
            ("night raid", 120, .night, "night"),
            ("one tap", 420, .dusk, "dusk"),
        ].enumerated().map { index, entry in
            ProfileClip(
                storage: .saved(id: "d-clip-\(index)", fileID: "d-file-\(index)"),
                gameID: battlefield,
                title: entry.0,
                videoURL: clipVideo,
                thumbnailURL: DemoMedia.gameClipPoster(frame: entry.1, look: entry.2, named: entry.3)
            )
        }

        model.profileWidgets[owner] = [
            ProfileWidget(id: "d-clips", content: .clipsGallery(gallery)),
            ProfileWidget(id: "d-application", content: .application(endfieldApplication)),
            ProfileWidget(
                id: "d-favourite",
                content: .favouriteGames([
                    ProfileWidgetGame(
                        gameID: sims,
                        comment: "who doesn't love the sims??",
                        // One of each group, plus enough behind them to draw the
                        // overflow chip. Six copies of the same tag is a fixture
                        // that reads as a rendering bug.
                        tags: [
                            .skill(.expert),
                            .feeling(.loveIt),
                            .social(.openToPlay),
                            .feeling(.obsessed),
                            .social(.lookingToDiscuss),
                        ]
                    ),
                ])
            ),
            ProfileWidget(
                id: "d-rotation",
                content: .currentGames([
                    ProfileWidgetGame(
                        gameID: battlefield,
                        tags: [.skill(.casual), .feeling(.kindOfLoveIt), .feeling(.rageQuitting)]
                    ),
                    ProfileWidgetGame(gameID: beatSaber, tags: [.skill(.expert), .feeling(.loveIt)]),
                    ProfileWidgetGame(
                        gameID: endfield,
                        tags: [.skill(.betterThanYou), .social(.openToTeach)]
                    ),
                ])
            ),
            ProfileWidget(
                id: "d-liked",
                content: .playedGames([
                    ProfileWidgetGame(gameID: sims),
                    ProfileWidgetGame(gameID: beatSaber),
                    ProfileWidgetGame(gameID: endfield),
                    ProfileWidgetGame(gameID: zenless),
                    ProfileWidgetGame(gameID: battlefield),
                    ProfileWidgetGame(gameID: wuthering),
                ])
            ),
            ProfileWidget(
                id: "d-wishlist",
                content: .wantToPlayGames([
                    ProfileWidgetGame(gameID: zenless),
                    ProfileWidgetGame(gameID: wuthering),
                ])
            ),
        ]

        model.similarGames[sims] = [beatSaber, endfield, zenless, wuthering, battlefield]
        model.similarGames[endfield] = [wuthering, zenless, sims]

        // The Sims' own server, as `/invites/thesims` answers for it. The
        // community card is the one section gated on a second route, so without
        // this the demo can only ever show the page without one.
        model.gameCommunities[sims] = GuildProfile(
            id: GuildID(rawValue: 1_151_759_657_283_629_076),
            name: "The Sims",
            iconHash: "184505900c6e26ae0cffcaac933d1d17",
            description: "The official home for everything related to The Sims! "
                + "ESRB Rating T for Teen: Crude Humor, Sexual Themes, Violence.",
            memberCount: 195_663,
            onlineCount: 18_173,
            features: ["COMMUNITY", "DISCOVERABLE", "VERIFIED"]
        )
    }

    /// Three people the reader and the board's owner both know.
    ///
    /// Taken off the roster rather than invented, so the rows draw the same
    /// avatars the member list does and a click opens a profile that exists.
    private static func demoMutualFriends(
        _ model: AppModel,
        excluding owner: UserID
    ) -> [MutualFriend] {
        model.users.values
            .filter { $0.id != owner && $0.id != model.currentUserID && !$0.isBot }
            .sorted { $0.id.rawValue < $1.id.rawValue }
            .prefix(3)
            .map {
                MutualFriend(
                    id: $0.id,
                    name: $0.preferredName,
                    avatarHash: $0.avatarHash,
                    monogram: $0.monogram
                )
            }
    }

    /// Two linked accounts, so the Connections dock has marks to magnify and
    /// facts to spell out. The metadata below is `connected_accounts[].metadata`'s
    /// own shape — a Steam join date and a game count, Reddit karma.
    static var demoConnections: [ConnectedAccount] {
        [
            ConnectedAccount(
                id: "76561199847664494",
                service: "steam",
                name: "blahaj",
                isVerified: true,
                // `connected_accounts[].metadata`, in Steam's own keys and with
                // its own string values — captured from a live profile.
                metadata: ["created_at": "2019-04-27T09:12:04", "game_count": "16"]
            ),
            ConnectedAccount(
                id: "blahaj",
                service: "github",
                name: "blahaj",
                isVerified: true
            ),
            ConnectedAccount(
                id: "blahaj",
                service: "spotify",
                name: "blåhaj",
                isVerified: true
            ),
        ]
    }

    // MARK: A game's communities

    /// **The Sims lists six servers**, so its profile has a Communities tab —
    /// one of them a server the fixture is in, so "Go to" shows beside
    /// "Preview", and three languages, so the filter has something to filter.
    /// Seeded as answered: `--demo` asks the route nothing.
    private static func populateCommunities(_ model: AppModel) {
        let specs: [(String, String?, Int, Int, String, Bool)] = [
            ("Simmers United", "The biggest place to share builds, stories and mods for The Sims 4.", 287_869, 60_480, "en-US", true),
            ("Sims Builders Guild", "Lots, rooms and speed builds — post yours and steal everyone else's ideas.", 97_929, 27_544, "en-US", false),
            ("Les Sims France", "La communauté francophone des Sims : défis, constructions et entraide.", 30_808, 9_452, "fr", false),
            ("Legacy Challenge Club", "Ten generations, one family, endless chaos. Rules, scoreboards and support.", 13_235, 2_694, "en-US", false),
            ("Sims Deutschland", "Alles rund um Die Sims 4 — Bauen, Mods und gemeinsame Challenges.", 11_280, 3_172, "de", false),
        ]
        var ids: [GuildID] = []
        for (offset, spec) in specs.enumerated() {
            let id = GuildID(rawValue: 9_500 + UInt64(offset))
            ids.append(id)
            model.communityGuilds[id] = DiscoverableGuild(
                id: id, name: spec.0, description: spec.1,
                features: spec.5 ? ["DISCOVERABLE", "PREVIEW_ENABLED", "VERIFIED"] : ["DISCOVERABLE", "PREVIEW_ENABLED"],
                memberCount: spec.2, onlineCount: spec.3, preferredLocale: spec.4
            )
            model.communityGuildsFetchedAt[id] = .now
        }
        if let joined = model.guilds.keys.sorted(by: { $0.rawValue < $1.rawValue }).first, let guild = model.guilds[joined] {
            ids.insert(joined, at: 1)
            model.communityGuilds[joined] = DiscoverableGuild(
                id: joined, name: guild.name, description: "You're already in this one, so its card takes you there.",
                features: ["DISCOVERABLE", "PREVIEW_ENABLED"], memberCount: guild.memberCount ?? 4_200, onlineCount: 610,
                preferredLocale: "en-US"
            )
            model.communityGuildsFetchedAt[joined] = .now
        }
        model.games[sims]?.communityGuildIDs = ids
    }

    // MARK: The applications

    // The four the presence fixture also names, so one id has one definition.
    static let sims = ApplicationID(rawValue: 359_509_007_423_242_240)
    static let beatSaber = ApplicationID(rawValue: 451_991_967_149_195_264)
    static let endfield = ApplicationID(rawValue: 1_461_154_307_171_811_401)
    private static let endfieldApplication = ApplicationID(rawValue: 1_496_037_472_226_906_183)
    private static let zenless = ApplicationID(rawValue: 1_257_819_671_114_289_184)
    static let wuthering = ApplicationID(rawValue: 1_247_227_126_416_146_462)
    static let battlefield = ApplicationID(rawValue: 1_425_690_433_018_925_056)

    private static func website(_ url: String, _ category: GameLinkCategory) -> GameWebsite {
        GameWebsite(url: URL(string: url)!, category: category)
    }

    private static func sku(_ distributor: String, _ id: String) -> GameSKU {
        GameSKU(distributor: distributor, id: id)
    }

    private static func date(_ iso: String) -> Date? {
        ISO8601DateFormatter().date(from: iso)
    }

    /// The six games the board names, as `/games` answered for them.
    ///
    /// The Sims is the one with everything — a rank, three review rows, a
    /// Discord server, four platforms, three companies — and Beat Saber is the
    /// one with almost none of it. Both are in here on purpose: the page has to
    /// look deliberate at both ends of that range, and only the demo can show
    /// them side by side.
    private static var games: [Game] {
        [
            Game(
                id: sims,
                name: "The Sims 4",
                summary: """
                Unleash your imagination and create a unique world of Sims that's an \
                expression of you! Explore and customize every detail from Sims to homes, \
                and much more with The Sims 4. Life, and Sims, are yours to control.
                """,
                media: GameMedia(
                    icon: .hash("912bd1dd19dfd2ef3b0191985f942a40"),
                    banner: .hash("4bf8d6cfe112edc9295cb7e8d93db7a6"),
                    artwork: [.hash("4bf8d6cfe112edc9295cb7e8d93db7a6")]
                ),
                genres: [20, 28].map(GameGenre.init(rawValue:)),
                platforms: [.desktop, .xbox, .playStation, .macOS],
                websites: [
                    website("https://discord.com/invite/thesims", .discord),
                    website("https://store.steampowered.com/app/1222670/The_Sims_4", .steam),
                    website("https://www.ea.com/games/the-sims/the-sims-4/features", .official),
                    website("https://twitter.com/TheSims", .twitter),
                    website("https://www.reddit.com/r/Sims4", .reddit),
                    website("https://www.youtube.com/user/TheSims", .youtube),
                    website("https://www.instagram.com/thesims", .instagram),
                    website("https://www.facebook.com/TheSims", .facebook),
                    website("https://www.twitch.tv/directory/game/The%20Sims%204", .twitch),
                ],
                companies: [
                    GameCompany(name: "Electronic Arts", roles: [.publisher]),
                    GameCompany(name: "The Sims Studio", roles: [.developer]),
                    GameCompany(name: "Maxis", roles: [.developer]),
                ],
                releaseDate: date("2014-09-02T00:00:00Z"),
                reviews: GameReviews(
                    steam: GameReviews.SteamReviews(
                        rating: 86, ratingCount: 199_981,
                        recentRating: 80, recentRatingCount: 1_717,
                        localizedRating: 86, localizedRatingCount: 106_026
                    ),
                    openCritic: GameReviews.OpenCriticReviews(
                        topCriticRating: 69.969, topCriticRatingCount: 71, tier: .fair
                    )
                ),
                openCriticURL: URL(string: "https://opencritic.com/game/572/the-sims-4"),
                globalRank: 43,
                screenshotURLs: [
                    "scbtf2", "sctf9p", "sctf9q", "scbtf3", "scbtbp", "scbtf1",
                ].compactMap { URL(string: "https://images.igdb.com/igdb/image/upload/t_1080p/\($0).jpg") },
                thirdPartySkus: [
                    sku("igdb", "3212"), sku("opencritic", "572"),
                    sku("epic", "2A14CF8A83B149919A2399504E5686A6"),
                    sku("steam", "1222670"), sku("gop", "21009"),
                ],
                steamReleaseStatus: .postRelease
            ),
            Game(
                id: beatSaber,
                name: "Beat Saber",
                summary: """
                Beat Saber is an immersive rhythm experience you have never seen before! \
                Enjoy tons of handcrafted levels and swing your way through the pulsing \
                music beats, surrounded by a futuristic world.
                """,
                media: GameMedia(
                    icon: .hash("6cf886555e951b22d80e4a30ae326378"),
                    banner: .hash("054c37a7215637afbf06eb1f47adc19a"),
                    artwork: [.hash("054c37a7215637afbf06eb1f47adc19a")]
                ),
                genres: [33, 67, 68, 62].map(GameGenre.init(rawValue:)),
                platforms: [.playStation],
                websites: [
                    website("https://store.steampowered.com/app/620980", .steam),
                    website("https://beatsaber.com/", .official),
                    website("https://twitter.com/BeatSaber", .twitter),
                    website("https://www.reddit.com/r/beatsaber", .reddit),
                    website("https://www.youtube.com/beatsaber", .youtube),
                ],
                companies: [
                    GameCompany(name: "Beat Games", roles: [.publisher, .developer]),
                    GameCompany(name: "Hyperbolic Magnetism", roles: [.publisher, .developer]),
                ],
                releaseDate: date("2018-05-01T00:00:00Z"),
                reviews: GameReviews(
                    steam: GameReviews.SteamReviews(rating: 96, ratingCount: 69_711),
                    openCritic: GameReviews.OpenCriticReviews(
                        topCriticRating: 85.926, topCriticRatingCount: 27, tier: .mighty
                    )
                ),
                openCriticURL: URL(string: "https://opencritic.com/game/6151/beat-saber"),
                // **The multi-SKU case, and its numbers are the real ones.**
                // `/games` sends three Steam SKUs for Beat Saber and only the
                // last is the game — 38598 and 37124 are a demo and a delisted
                // listing. Taking the first, which is what Discord's own store
                // button does, opens neither. The tie is broken by the STEAM
                // website above, which names 620980. See `Game.storeOffers`.
                thirdPartySkus: [
                    sku("playstation", "PPSA15035_00"), sku("playstation", "CUSA14143_00"),
                    sku("steam", "38598"), sku("gop", "60240"), sku("opencritic", "6151"),
                    sku("igdb", "83731"), sku("steam", "37124"),
                    sku("playstation", "CUSA12878_00"), sku("playstation", "PPSA14734_00"),
                    sku("gdco", "8380"), sku("steam", "620980"),
                ],
                steamReleaseStatus: .postRelease
            ),
            Game(
                id: endfield,
                name: "ARKNIGHTS: ENDFIELD",
                summary: """
                Arknights: Endfield is a 3D real-time strategy RPG developed by HYPERGRYPH. \
                You will take on the role of the Endministrator of Endfield Industries, set \
                out across Talos-II to uncover its secrets.
                """,
                media: GameMedia(
                    icon: .hash("a1c43f46f274856e6fb9edc8afda149d"),
                    banner: .hash("bcd9ef8e06beeb4734c8fe9984baff1c"),
                    cover: .hash("ad75eaf2f6ac04d55cbcefe77c143ce7"),
                    artwork: [.hash("bcd9ef8e06beeb4734c8fe9984baff1c")]
                ),
                genres: [48, 8, 20].map(GameGenre.init(rawValue:)),
                platforms: [.desktop, .playStation, .iOS, .android],
                websites: [
                    website("https://discord.gg/AKEndfield", .discord),
                    website("https://endfield.gryphline.com/", .official),
                    website("https://x.com/AKEndfield", .twitter),
                    website("https://www.reddit.com/r/Endfield/", .reddit),
                    website("https://www.youtube.com/@arknightsendfieldEN", .youtube),
                ],
                companies: [
                    GameCompany(name: "Gryphline", roles: [.publisher]),
                    GameCompany(name: "Hypergryph", roles: [.developer]),
                ],
                releaseDate: date("2026-01-22T00:00:00Z"),
                reviews: GameReviews(
                    openCritic: GameReviews.OpenCriticReviews(
                        topCriticRating: 79.286, topCriticRatingCount: 15, tier: .strong
                    )
                ),
                globalRank: 79,
                // **No Steam and no Game Pass**, which is why it is worth
                // having in the demo: the aside has to look deliberate for a
                // game nobody can be sent to buy, and Endfield is that game.
                thirdPartySkus: [
                    sku("igdb", "194558"), sku("opencritic", "19963"),
                    sku("epic", "14D53B5D3FCB4526A69D59F35C9DD28F"),
                    sku("google_play", "com.gryphline.endfield.gp"),
                    sku("apple_app_store", "6752642477"),
                ]
            ),
            Game(
                id: zenless,
                name: "Zenless Zone Zero",
                media: GameMedia(icon: .hash("fb528a20677f93d8f365fac88e3f0713")),
                genres: [8, 4, 20].map(GameGenre.init(rawValue:)),
                platforms: [.desktop, .xbox, .playStation, .iOS, .android],
                globalRank: 32,
                thirdPartySkus: [sku("steam", "4162040"), sku("igdb", "200551")],
                steamReleaseStatus: .postRelease
            ),
            Game(
                id: wuthering,
                name: "Wuthering Waves",
                media: GameMedia(icon: .hash("1e7d7e9ca69ea0951467994c581f70f5")),
                genres: [8, 20, 4].map(GameGenre.init(rawValue:)),
                platforms: [.desktop, .xbox, .playStation, .iOS, .android, .macOS],
                globalRank: 51,
                thirdPartySkus: [sku("steam", "3513350"), sku("igdb", "202956")]
            ),
            Game(
                id: battlefield,
                name: "Battlefield 6",
                media: GameMedia(icon: .hash("385864ebfdda22c76c0bd944c8722efd")),
                genres: [GameGenre(rawValue: 23)],
                platforms: [.desktop, .xbox, .playStation],
                globalRank: 23,
                // **A Steam SKU and no STEAM website**, which is the shape that
                // used to draw no store button anywhere — and this is the game
                // the demo presence is playing, so it is the one the card's new
                // button is seen on.
                thirdPartySkus: [
                    sku("steam", "2807960"), sku("xbox", "9P4BB02MWDZK"),
                    sku("epic", "A14A02AA3C8143729605EAF7C93D7501"),
                    sku("igdb", "317407"), sku("opencritic", "19051"),
                ]
            ),
        ]
    }

    /// Arknights' widget template, as `/widget-configs/featured` answers for it.
    ///
    /// **The labels are what a config is FOR.** Nothing in the identity says
    /// that `level` is called "Authority Level" or that `domain_1_level` is
    /// "Valley IV Regional Development Level"; those are authored per
    /// application and arrive only here. Without a config the demo would show
    /// the fallback's title-cased field names — which is a real state, and one
    /// the widget draws honestly, but not the one worth looking at.
    private static var endfieldConfig: WidgetConfig {
        func custom(_ value: String) -> WidgetField {
            .field(
                WidgetField.Value(
                    valueType: .customString, presentationType: .text, value: value
                )
            )
        }
        func data(_ name: String, _ presentation: WidgetField.PresentationType) -> WidgetField {
            .field(
                WidgetField.Value(valueType: .data, presentationType: presentation, value: name)
            )
        }
        func stat(_ field: String, _ label: String, number: Bool = true) -> WidgetComponent {
            WidgetComponent(fields: [
                "value": data(field, number ? .number : .text),
                "label": custom(label),
            ])
        }
        return WidgetConfig(
            configID: "demo-endfield",
            applicationID: endfieldApplication,
            displayName: "Arknights Endfield",
            surfaces: [
                WidgetSurface.Kind.widgetTop.rawValue: WidgetSurface(
                    layout: "widget_top_hero",
                    components: [
                        "title": WidgetComponent(fields: ["text": data("username", .text)]),
                        "subtitle_1": WidgetComponent(fields: ["text": custom("Server: Americas / Europe")]),
                        "hero_image": WidgetComponent(fields: [
                            "image": data("featured_played_character_image", .image),
                        ]),
                    ]
                ),
                WidgetSurface.Kind.widgetBottom.rawValue: WidgetSurface(
                    layout: "widget_bottom_stats",
                    components: [
                        "stat_1": stat("level", "Authority Level"),
                        "stat_2": stat("operator_count", "Operators"),
                        "stat_3": stat("achievement_badge_count", "Path of Glory"),
                        "stat_4": stat("created_at", "Awakening Day", number: false),
                        "stat_5": stat("domain_1_level", "Valley IV Regional Development Level"),
                        "stat_6": stat("domain_2_level", "Wuling Regional Development Level"),
                    ]
                ),
            ]
        )
    }
}
