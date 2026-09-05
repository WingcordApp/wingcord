import Foundation

/// A game's genre, as Discord's store numbers them.
///
/// **A whole table rather than a lookup, because there is nowhere to look.**
/// `/games` sends `[20, 28]` and Discord's own client prints "Role-Playing,
/// Simulation" — the names are shipped in the client and no route answers with
/// them. A client that printed the numbers would put "20, 28" under a game's
/// title.
///
/// An unrecognised value keeps its number and titles itself from it, so a genre
/// Discord adds after this was written shows as `Genre 70` rather than
/// vanishing from a line that then reads one shorter than it should.
public enum GameGenre: Hashable, Sendable {
    case known(Known)
    case other(Int)

    public init(rawValue: Int) {
        if let known = Known(rawValue: rawValue) {
            self = .known(known)
        } else {
            self = .other(rawValue)
        }
    }

    public var rawValue: Int {
        switch self {
        case .known(let genre): genre.rawValue
        case .other(let value): value
        }
    }

    public var title: String {
        switch self {
        case .known(let genre): genre.title
        case .other(let value): "Genre \(value)"
        }
    }

    public enum Known: Int, Hashable, Sendable, CaseIterable {
        case action = 1
        case actionRPG = 2
        case brawler = 3
        case hackAndSlash = 4
        case platformer = 5
        case stealth = 6
        case survival = 7
        case adventure = 8
        case actionAdventure = 9
        case metroidvania = 10
        case openWorld = 11
        case psychologicalHorror = 12
        case sandbox = 13
        case survivalHorror = 14
        case visualNovel = 15
        case drivingRacing = 16
        case vehicularCombat = 17
        case massivelyMultiplayer = 18
        case mmorpg = 19
        case rolePlaying = 20
        case dungeonCrawler = 21
        case roguelike = 22
        case shooter = 23
        case lightGun = 24
        case shootEmUp = 25
        case fps = 26
        case dualJoystickShooter = 27
        case simulation = 28
        case flightSimulator = 29
        case trainSimulator = 30
        case lifeSimulator = 31
        case fishing = 32
        case sports = 33
        case baseball = 34
        case basketball = 35
        case billiards = 36
        case bowling = 37
        case boxing = 38
        case football = 39
        case golf = 40
        case hockey = 41
        case skateboardingSkating = 42
        case snowboardingSkiing = 43
        case soccer = 44
        case trackField = 45
        case surfingWakeboarding = 46
        case wrestling = 47
        case strategy = 48
        case fourX = 49
        case artillery = 50
        case realTimeStrategy = 51
        case towerDefense = 52
        case turnBasedStrategy = 53
        case wargame = 54
        case moba = 55
        case fighting = 56
        case puzzle = 57
        case cardGame = 58
        case education = 59
        case fitness = 60
        case gambling = 61
        case musicRhythm = 62
        case partyMiniGame = 63
        case pinball = 64
        case triviaBoardGame = 65
        case tactical = 66
        case indie = 67
        case arcade = 68
        case pointAndClick = 69

        public var title: String {
            switch self {
            case .action: "Action"
            case .actionRPG: "Action RPG"
            case .brawler: "Brawler"
            case .hackAndSlash: "Hack and Slash"
            case .platformer: "Platformer"
            case .stealth: "Stealth"
            case .survival: "Survival"
            case .adventure: "Adventure"
            case .actionAdventure: "Action Adventure"
            case .metroidvania: "Metroidvania"
            case .openWorld: "Open World"
            case .psychologicalHorror: "Psychological Horror"
            case .sandbox: "Sandbox"
            case .survivalHorror: "Survival Horror"
            case .visualNovel: "Visual Novel"
            case .drivingRacing: "Driving / Racing"
            case .vehicularCombat: "Vehicular Combat"
            case .massivelyMultiplayer: "Massively Multiplayer"
            case .mmorpg: "MMORPG"
            case .rolePlaying: "Role-Playing"
            case .dungeonCrawler: "Dungeon Crawler"
            case .roguelike: "Roguelike"
            case .shooter: "Shooter"
            case .lightGun: "Light Gun"
            case .shootEmUp: "Shoot 'Em Up"
            case .fps: "First-Person Shooter"
            case .dualJoystickShooter: "Dual-Joystick Shooter"
            case .simulation: "Simulation"
            case .flightSimulator: "Flight Simulator"
            case .trainSimulator: "Train Simulator"
            case .lifeSimulator: "Life Simulator"
            case .fishing: "Fishing"
            case .sports: "Sports"
            case .baseball: "Baseball"
            case .basketball: "Basketball"
            case .billiards: "Billiards"
            case .bowling: "Bowling"
            case .boxing: "Boxing"
            case .football: "Football"
            case .golf: "Golf"
            case .hockey: "Hockey"
            case .skateboardingSkating: "Skateboarding / Skating"
            case .snowboardingSkiing: "Snowboarding / Skiing"
            case .soccer: "Soccer"
            case .trackField: "Track & Field"
            case .surfingWakeboarding: "Surfing / Wakeboarding"
            case .wrestling: "Wrestling"
            case .strategy: "Strategy"
            case .fourX: "4X"
            case .artillery: "Artillery"
            case .realTimeStrategy: "Real-Time Strategy"
            case .towerDefense: "Tower Defense"
            case .turnBasedStrategy: "Turn-Based Strategy"
            case .wargame: "Wargame"
            case .moba: "MOBA"
            case .fighting: "Fighting"
            case .puzzle: "Puzzle"
            case .cardGame: "Card Game"
            case .education: "Education"
            case .fitness: "Fitness"
            case .gambling: "Gambling"
            case .musicRhythm: "Music / Rhythm"
            case .partyMiniGame: "Party / Mini Game"
            case .pinball: "Pinball"
            case .triviaBoardGame: "Trivia / Board Game"
            case .tactical: "Tactical"
            case .indie: "Indie"
            case .arcade: "Arcade"
            case .pointAndClick: "Point-and-Click"
            }
        }
    }
}
