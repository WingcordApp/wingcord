import Foundation
import WingcordCore

// MARK: - Activities, for `--demo`
//
// **Real application ids, real asset hashes, real artwork.** Lifted straight
// out of `activities123.har`'s own shelf and collections responses, so the
// launcher in demo mode draws the same pictures the reference client draws —
// which is the point: a fixture of coloured rectangles verifies the layout and
// nothing about whether the CDN paths are right.

extension DemoFixtures {

    static func populateActivities(_ model: AppModel) {
        model.activityDirectory = ActivityDirectory(
            collections: activityCollections,
            apps: Dictionary(
                activityCollections.flatMap(\.apps).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        )
        // The frecency table's own top rows, in its own order.
        model.activityRecents = [
            ApplicationID(rawValue: 880_218_394_199_220_334),
            ApplicationID(rawValue: 1_211_781_489_931_452_447),
            ApplicationID(rawValue: 1_227_719_606_223_765_687),
            ApplicationID(rawValue: 1_187_013_846_746_005_515),
        ]
        model.activityRevision &+= 1

        // **The apps themselves, as authors.** A launch message is posted
        // through the application's own webhook, so the message's author IS the
        // app — without these the transcript draws "Unknown" over a card naming
        // the app twelve points below it.
        //
        // **A bot's avatar hash is not its application's icon hash.** The
        // captured launch message carries `author.avatar = fe2b7f…` beside
        // `application.icon = ec48ac…` — two assets on two different CDN paths,
        // so the icon hash would 404 against `/avatars/`.
        for (id, name, avatar) in Self.activityBots {
            let userID = UserID(rawValue: id)
            model.users[userID] = User(
                id: userID,
                username: name,
                displayName: name,
                avatarHash: avatar,
                discriminator: "0",
                isBot: true
            )
        }
    }

    private static let activityBots: [(UInt64, String, String?)] = [
        (880_218_394_199_220_334, "Watch Together", "fe2b7fa334817b0346d57416ad75e93b"),
        (1_211_781_489_931_452_447, "Wordle", nil),
    ]

    private static func app(
        _ id: UInt64,
        _ name: String,
        icon: String,
        tile: String,
        tagline: String,
        tags: [String],
        maxParticipants: Int?,
        guildCount: Int?,
        video: String?,
        hero: String?
    ) -> ActivityApp {
        ActivityApp(
            id: ApplicationID(rawValue: id),
            name: name,
            iconHash: icon,
            tileAssetID: tile,
            heroImageURL: hero.flatMap(URL.init(string:)),
            tagline: tagline,
            guildCount: guildCount,
            isVerified: true,
            about: tagline,
            tags: tags,
            maxParticipants: maxParticipants,
            termsOfServiceURL: URL(string: "https://discord.com/terms"),
            privacyPolicyURL: URL(string: "https://discord.com/privacy"),
            config: EmbeddedActivityConfig(
                previewVideoAssetID: video,
                supportedPlatforms: ["web", "ios", "android"]
            )
        )
    }

    private static var activityCollections: [ActivityCollection] {
        [
            ActivityCollection(
                id: "1328814176696537109",
                title: "Promoted",
                position: 1,
                kind: 5,
                apps: [
                    app(
                        1211781489931452447, "Wordle",
                        icon: "8904fec86de9bb7a71b2ae1e71a1adbc", tile: "1331783780809179146",
                        tagline: "Enjoy Wordle from New York Times Games! You have 6 chances to guess a 5-letter word. When you make a guess, th",
                        tags: ["New York Times", "Official Wordle", "Word game"],
                        maxParticipants: nil, guildCount: 319000,
                        video: "1334610713074864221",
                        hero: "https://images-ext-1.discordapp.net/external/8ZpS-BjSIGbS1kzIyMpFvYQteOPbG6MdEMMshG1UsIk/https/app-directory-assets.discordactivities.com/wordle/screen_1.png"
                    ),
                    app(
                        1227719606223765687, "Magic Garden",
                        icon: "c354f90885dc749e50e34f5ddf0b80e2", tile: "1479228807847346216",
                        tagline: "Grow your own unique and MAGICAL garden! Collect rare pets, giant flowers, and complete your Garden Journal. P",
                        tags: ["Chill", "Farming", "Garden", "Multiplayer"],
                        maxParticipants: 6, guildCount: 18800,
                        video: "1433558021887361254",
                        hero: nil
                    ),
                    app(
                        1187013846746005515, "Farm Merge Valley",
                        icon: "b91a865fc18d3c14b736e54eb5e32221", tile: "1513644151886053446",
                        tagline: "Farm, merge, grow and expand your land!  Welcome to the world of farming that gets bigger and better with each",
                        tags: ["Casual Game", "Farming Game", "Match 3", "Puzzle"],
                        maxParticipants: nil, guildCount: 58200,
                        video: "1232355776870223923",
                        hero: nil
                    ),
                    app(
                        880218394199220334, "Watch Together",
                        icon: "ec48acbad4c32efab4275cb9f3ca3a58", tile: "1303047145993277530",
                        tagline: "Create and watch a playlist of YouTube videos with your friends. Your choice to share the remote or not.",
                        tags: ["Video Player", "Watch"],
                        maxParticipants: -1, guildCount: 745000,
                        video: "1311095551336517754",
                        hero: "https://images-ext-1.discordapp.net/external/kYz-pxVQVYbEwYMVvpmSbysPUujimqPAJzS-fl2o66g/https/app-directory-assets.discordactivities.com/watch-together/directory_01.gif"
                    ),
                ]
            ),
            ActivityCollection(
                id: "1328862878782197885",
                title: "Puzzle Games",
                position: 2,
                kind: 4,
                apps: [
                    app(
                        1273616940451102832, "Daily Sudoku Together",
                        icon: "032e6526f260510b6366eda5e7c1b7e2", tile: "1395676828865134662",
                        tagline: "Join Daily Sudoku Together on Discord! Solve unlimited puzzles, tackle 14 difficulty levels, explore variants ",
                        tags: ["Casual", "Puzzle", "Sudoku"],
                        maxParticipants: 99, guildCount: 24600,
                        video: "1286644732876947588",
                        hero: nil
                    ),
                    app(
                        1414977398377545749, "Daily Word Wheel",
                        icon: "a54cb9e62186181c191ecc4853685568", tile: "None",
                        tagline: "From the makers of Words with Friends, enjoy a daily word puzzle where you connect letters on the Word Wheel t",
                        tags: ["crossword", "puzzle", "word game", "words with friends"],
                        maxParticipants: nil, guildCount: 7960,
                        video: "1438614768201105438",
                        hero: nil
                    ),
                    app(
                        1335923201972240395, "BlockBuster",
                        icon: "c2226731a5f83e74e630002012dac0d7", tile: "1338767763250090055",
                        tagline: "Master the Puzzles, Conquer the Adventure!",
                        tags: ["Casual", "Logic", "Logic Game", "Puzzle"],
                        maxParticipants: nil, guildCount: 16600,
                        video: "1338769547326525450",
                        hero: "https://images-ext-1.discordapp.net/external/8-a7KD1ML7PX3IVpgniZ0p7KFwCMf0X6k_JgDSwD600/https/cleverappssg.com/img/woodenblock_0_en.48d83105.jpg"
                    ),
                    app(
                        1278030957651431434, "Hex Puzzle Adventure",
                        icon: "929953d24f6fb1386d94d209fe28b4c1", tile: "1303461190126669845",
                        tagline: "A hex stacking puzzle game. Use strategic thinking to solve the levels and explore the adventure map.",
                        tags: ["chill", "match", "puzzle", "relax"],
                        maxParticipants: 0, guildCount: 9870,
                        video: "1290314778467762258",
                        hero: nil
                    ),
                    app(
                        879863686565621790, "Letter League",
                        icon: "0096355142a9b00bc2676ec09b9c8dbc", tile: "951327458051883018",
                        tagline: "In this turn-based word game, use letter tiles to form a word that connects to a word on the board. Each lette",
                        tags: ["Classic", "Word Game"],
                        maxParticipants: 8, guildCount: 9040,
                        video: "951327524460310568",
                        hero: "https://images-ext-1.discordapp.net/external/oWoSyVU27hghq4CVhQnNhNOEF-7OWdlQ-eAD2VGp4hA/https/app-directory-assets.discordactivities.com/letter-league/directory_01.gif"
                    ),
                ]
            ),
            ActivityCollection(
                id: "1364350449096069292",
                title: "Chill Together",
                position: 5,
                kind: 4,
                apps: [
                    app(
                        880218394199220334, "Watch Together",
                        icon: "ec48acbad4c32efab4275cb9f3ca3a58", tile: "1303047145993277530",
                        tagline: "Create and watch a playlist of YouTube videos with your friends. Your choice to share the remote or not.",
                        tags: ["Video Player", "Watch"],
                        maxParticipants: -1, guildCount: 745000,
                        video: "1311095551336517754",
                        hero: "https://images-ext-1.discordapp.net/external/kYz-pxVQVYbEwYMVvpmSbysPUujimqPAJzS-fl2o66g/https/app-directory-assets.discordactivities.com/watch-together/directory_01.gif"
                    ),
                    app(
                        1230610135274225734, "Lofi",
                        icon: "caf378998f5162e251e65f65bf97df34", tile: "1288882559530303530",
                        tagline: "Vibe with your friends with lofi music and a curated ambience.",
                        tags: ["Chill", "Listen Together", "Lofi"],
                        maxParticipants: nil, guildCount: 95900,
                        video: "1278735670201815132",
                        hero: "https://images-ext-1.discordapp.net/external/JPwmM6hiMm1hzvELAm_08p9w_yYm2ZUKZtVqds2uBUg/https/app-directory-assets.discordactivities.com/lofi/directory_01.gif"
                    ),
                    app(
                        1070087967294631976, "Whiteboard",
                        icon: "9a04eab3b9f50302006577b769354520", tile: "1143973128469499915",
                        tagline: "In this collaborative whiteboard you can draw, upload images, write, and use GIFs. Boards are saved, so come b",
                        tags: ["Collaborate", "Productivity", "Whiteboard"],
                        maxParticipants: -1, guildCount: 142000,
                        video: "1146495383174926457",
                        hero: "https://images-ext-1.discordapp.net/external/ti8O6_RxLBrzikrrP-tJdsmwLqhLbMfJP4hJ3GNvHAI/https/app-directory-assets.discordactivities.com/whiteboard/directory_01.gif"
                    ),
                    app(
                        1301652913977823282, "Karaoke Party Battle",
                        icon: "a79c01220c57941b0fe0fbe9e19adc8b", tile: "1323396709933518889",
                        tagline: "The first official music game & karaoke activity on Discord. Sing along with your community, have fun with fri",
                        tags: ["entertainment", "fun social party", "karaoke", "music"],
                        maxParticipants: nil, guildCount: 10400,
                        video: "1338644904209022976",
                        hero: nil
                    ),
                    app(
                        235088799074484224, "Rythm",
                        icon: "8bbffb0f3547424baf6798ecf632831e", tile: "1419748629949841584",
                        tagline: "Listen to music together with your friends anywhere on Discord.",
                        tags: ["Music", "Rythm", "Together"],
                        maxParticipants: 20, guildCount: 15200000,
                        video: "1420083450412794108",
                        hero: nil
                    ),
                    app(
                        902271654783242291, "Sketch Heads",
                        icon: "05f3ad2c91d157cd1a0bd8e904a3182e", tile: "1325917821523329175",
                        tagline: "A drawing game where you discover that you're bad at drawing or your friends are bad at guessing! Take turns i",
                        tags: ["Creative", "Drawing Game", "Guessing Game"],
                        maxParticipants: 8, guildCount: 13800,
                        video: "1325917826007175383",
                        hero: "https://images-ext-1.discordapp.net/external/PZ0Ui_REP6YhejWrFBAwmmub3ujGjKeRbO8lf_y8mIE/https/app-directory-assets.discordactivities.com/sketch-heads/directory_01.gif"
                    ),
                ]
            ),        ]
    }
}
