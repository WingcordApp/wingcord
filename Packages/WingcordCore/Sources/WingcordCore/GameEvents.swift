import Foundation

// MARK: - What a game says happened
//
// docs/CLIPS-PRESENCE.md, D17 / Phase 3.4. The sources a Mac can read, each
// turned into Discord's own game-event signal — `kind` as its clips engine
// names them (`unclassified kill multikill death assist item victory defeat
// level_up treasure objective_kill`), the wire type from that (kill 1,
// multikill 2, death 3, everything else 0 with its name), and an
// `event_name` in the game's own words:
//
//   * **Dota 2** (native on the Mac) and **Counter-Strike 2** (through
//     CrossOver) push Valve's Game State Integration — a JSON document per
//     change, POSTed to the address their cfg file names. Each reader keeps
//     the last state and reports what moved.
//   * **League of Legends** answers its Live Client Data API at
//     `https://127.0.0.1:2999/liveclientdata/eventdata` while a match runs —
//     Riot's documented events (`ChampionKill`, `Multikill`, `Ace`,
//     `DragonKill`, …), read from the last one seen.
//
// Every reader is pure: a payload in, the moments it adds out, times in
// whatever clock the caller stamps arrivals with.

public enum GameEventKind: String, Codable, Hashable, Sendable {
    case unclassified, kill, multikill, death, assist, item, victory, defeat
    case levelUp = "level_up"
    case treasure
    case objectiveKill = "objective_kill"

    /// The type Discord's `clip_events_timeline` carries — module 762555's
    /// switch: three named, the rest unknown with their name.
    public var wireType: ClipGameEventType {
        switch self {
        case .kill: .kill
        case .multikill: .multikill
        case .death: .death
        default: .unknown
        }
    }
}

/// One thing a game reported, on the caller's clock.
public struct GameEventMoment: Hashable, Sendable {
    public var time: Double
    public var kind: GameEventKind
    /// The game's own words — "Triple Kill", "Elder Dragon", "Victory".
    public var name: String

    public init(time: Double, kind: GameEventKind, name: String) {
        self.time = time
        self.kind = kind
        self.name = name
    }

    /// As the clip timeline takes it.
    public var timelineMoment: ClipTimeline.GameMoment {
        ClipTimeline.GameMoment(time: time, type: kind.wireType, name: name)
    }
}

// MARK: - Valve's Game State Integration

/// Reads Dota 2's game state, one POST at a time.
///
/// Fields as Valve's GSI documents them and every client library reads them:
/// `player.kills`, `player.deaths`, `player.assists`, `player.activity`,
/// `player.team_name`, `map.matchid`, `map.game_state`, `map.win_team`, and
/// `provider.steamid` / `player.steamid` — a spectator's state is somebody
/// else's, and only the reader's own is theirs to clip.
public struct DotaGameStateReader: Sendable {
    /// Dota's own window for a multi-kill: each kill within eighteen seconds
    /// of the one before.
    static let multikillWindow = 18.0

    private var matchID: String?
    private var kills: Int?
    private var deaths: Int?
    private var assists: Int?
    private var streak = 0
    private var lastKill: Double = -.infinity
    private var hasEnded = false

    public init() {}

    public mutating func read(_ payload: Data, at time: Double) -> [GameEventMoment] {
        guard let root = GSIPayload(payload) else { return [] }
        let map = root.object("map")
        let player = root.object("player")
        // A new match starts every count again.
        let match = map?.string("matchid")
        if match != matchID {
            self = DotaGameStateReader()
            matchID = match
        }
        guard let player, root.isOwnPlayer(player) else { return [] }

        var moments: [GameEventMoment] = []
        if let now = player.int("kills") {
            if let before = kills, now > before {
                for _ in before..<now {
                    streak = time - lastKill <= Self.multikillWindow ? streak + 1 : 1
                    lastKill = time
                    moments.append(GameEventMoment(time: time, kind: .kill, name: "Kill"))
                    if let name = Self.multikillName(streak) {
                        moments.append(GameEventMoment(time: time, kind: .multikill, name: name))
                    }
                }
            }
            kills = now
        }
        if let now = player.int("deaths") {
            if let before = deaths, now > before {
                moments.append(GameEventMoment(time: time, kind: .death, name: "Death"))
                streak = 0
            }
            deaths = now
        }
        if let now = player.int("assists") {
            if let before = assists, now > before {
                moments.append(GameEventMoment(time: time, kind: .assist, name: "Assist"))
            }
            assists = now
        }
        if !hasEnded, map?.string("game_state") == "DOTA_GAMERULES_STATE_POST_GAME",
           let winner = map?.string("win_team"), winner != "none",
           let team = player.string("team_name")
        {
            hasEnded = true
            moments.append(winner == team
                ? GameEventMoment(time: time, kind: .victory, name: "Victory")
                : GameEventMoment(time: time, kind: .defeat, name: "Defeat"))
        }
        return moments
    }

    /// Dota's announcer, from the second kill in a row.
    static func multikillName(_ streak: Int) -> String? {
        switch streak {
        case ..<2: nil
        case 2: "Double Kill"
        case 3: "Triple Kill"
        case 4: "Ultra Kill"
        default: "Rampage"
        }
    }
}

/// Reads Counter-Strike 2's game state, one POST at a time.
///
/// `player.match_stats.kills/deaths` for the match, `player.state.round_kills`
/// and `round_killhs` for the round — the multi-kill is a round's, as the
/// game counts them — and `round.win_team` against `player.team`.
public struct CounterStrikeGameStateReader: Sendable {
    private var map: String?
    private var kills: Int?
    private var deaths: Int?
    private var roundKills = 0
    private var roundHeadshots = 0
    private var round: Int?
    private var hasCalledRound = false
    /// When the reader's own block was last seen. Dead, the game shows the
    /// player being watched instead, and the reader's counts come back at the
    /// next round — late, so they set the baseline rather than being events.
    private var lastOwn: Double = -.infinity

    public init() {}

    public mutating func read(_ payload: Data, at time: Double) -> [GameEventMoment] {
        guard let root = GSIPayload(payload) else { return [] }
        let mapObject = root.object("map")
        let mapName = mapObject?.string("name")
        if mapName != map {
            self = CounterStrikeGameStateReader()
            map = mapName
        }
        // Rounds turn over whoever is being watched.
        if let number = mapObject?.int("round"), number != round {
            round = number
            hasCalledRound = false
        }
        guard let player = root.object("player"), root.isOwnPlayer(player) else { return [] }
        if time - lastOwn > Self.staleAfter {
            kills = nil
            deaths = nil
        }
        lastOwn = time

        var moments: [GameEventMoment] = []
        let state = player.object("state")
        let stats = player.object("match_stats")
        let nowRoundKills = state?.int("round_kills") ?? 0
        let nowHeadshots = state?.int("round_killhs") ?? 0
        if let now = stats?.int("kills") {
            if let before = kills, now > before {
                let headshots = max(0, nowHeadshots - roundHeadshots)
                for index in 0..<(now - before) {
                    moments.append(GameEventMoment(
                        time: time, kind: .kill, name: index < headshots ? "Headshot" : "Kill"
                    ))
                }
                if nowRoundKills >= 2, let name = Self.multikillName(nowRoundKills) {
                    moments.append(GameEventMoment(time: time, kind: .multikill, name: name))
                }
            }
            kills = now
        }
        roundKills = nowRoundKills
        roundHeadshots = nowHeadshots
        if let now = stats?.int("deaths") {
            if let before = deaths, now > before {
                moments.append(GameEventMoment(time: time, kind: .death, name: "Death"))
            }
            deaths = now
        }
        if !hasCalledRound, let winner = root.object("round")?.string("win_team"),
           let team = player.string("team")
        {
            hasCalledRound = true
            moments.append(winner == team
                ? GameEventMoment(time: time, kind: .victory, name: "Round Won")
                : GameEventMoment(time: time, kind: .defeat, name: "Round Lost"))
        }
        return moments
    }

    /// Seconds without the reader's own block before its counts are stale.
    /// GSI's heartbeat is thirty, but a live round sends far more often.
    static let staleAfter = 3.0

    static func multikillName(_ roundKills: Int) -> String? {
        switch roundKills {
        case ..<2: nil
        case 2: "Double Kill"
        case 3: "Triple Kill"
        case 4: "Quad Kill"
        default: "Ace"
        }
    }
}

/// One GSI document, read leniently: Valve's numbers sometimes arrive as
/// strings, and every component is optional.
struct GSIPayload {
    let fields: [String: Any]

    init?(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        fields = object
    }

    init(fields: [String: Any]) {
        self.fields = fields
    }

    func object(_ key: String) -> GSIPayload? {
        (fields[key] as? [String: Any]).map(GSIPayload.init(fields:))
    }

    func string(_ key: String) -> String? {
        switch fields[key] {
        case let value as String: value
        case let value as NSNumber: value.stringValue
        default: nil
        }
    }

    func int(_ key: String) -> Int? {
        switch fields[key] {
        case let value as NSNumber: value.intValue
        case let value as String: Int(value)
        default: nil
        }
    }

    /// Whether `player` is the person playing on this machine: the provider
    /// names their Steam id, and a spectating player's block is somebody
    /// else's. With no ids at all, it is theirs — a cfg without them.
    func isOwnPlayer(_ player: GSIPayload) -> Bool {
        guard let own = object("provider")?.string("steamid"), let shown = player.string("steamid") else { return true }
        return own == shown
    }

    /// The token the cfg file gave the game, for the listener to check.
    var authToken: String? { object("auth")?.string("token") }
}

// MARK: - League's Live Client Data

/// Reads League of Legends' `eventdata`, from the last event already seen.
///
/// Names are compared as Riot writes them: the active player's Riot ID is
/// `name#tag` and the events carry the name, so either matches.
public struct LeagueEventReader: Sendable {
    private var lastEventID = -1

    public init() {}

    public static func isSelf(_ name: String?, _ me: String) -> Bool {
        guard let name, !name.isEmpty else { return false }
        let ownName = me.split(separator: "#", maxSplits: 1).first.map(String.init) ?? me
        return name.caseInsensitiveCompare(me) == .orderedSame || name.caseInsensitiveCompare(ownName) == .orderedSame
    }

    /// - Parameters:
    ///   - payload: the `eventdata` body.
    ///   - me: `activeplayername`.
    ///   - gameTime: `gamestats.gameTime` when the body was read, and `time`
    ///     the caller's clock then — each event lands where it happened, not
    ///     where the poll found it.
    public mutating func read(_ payload: Data, me: String, gameTime: Double?, at time: Double) -> [GameEventMoment] {
        guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let events = root["Events"] as? [[String: Any]]
        else { return [] }
        var moments: [GameEventMoment] = []
        for event in events {
            let fields = GSIPayload(fields: event)
            guard let id = fields.int("EventID"), id > lastEventID else { continue }
            lastEventID = id
            let at: Double
            if let gameTime, let eventTime = (event["EventTime"] as? NSNumber)?.doubleValue {
                at = time - max(0, gameTime - eventTime)
            } else {
                at = time
            }
            if let moment = Self.moment(fields, me: me, at: at) { moments.append(moment) }
        }
        return moments
    }

    /// A new match, or League restarted: event ids count from zero again.
    public mutating func reset() {
        lastEventID = -1
    }

    static func moment(_ event: GSIPayload, me: String, at time: Double) -> GameEventMoment? {
        let killer = event.string("KillerName")
        let isMine = isSelf(killer, me) || (event.fields["Assisters"] as? [String])?.contains { isSelf($0, me) } == true
        switch event.string("EventName") {
        case "ChampionKill":
            if isSelf(killer, me) { return GameEventMoment(time: time, kind: .kill, name: "Kill") }
            if isSelf(event.string("VictimName"), me) { return GameEventMoment(time: time, kind: .death, name: "Death") }
            if isMine { return GameEventMoment(time: time, kind: .assist, name: "Assist") }
            return nil
        case "Multikill":
            guard isSelf(killer, me), let streak = event.int("KillStreak") else { return nil }
            let name = switch streak {
            case 2: "Double Kill"
            case 3: "Triple Kill"
            case 4: "Quadra Kill"
            default: "Penta Kill"
            }
            return GameEventMoment(time: time, kind: .multikill, name: name)
        case "Ace":
            guard isSelf(event.string("Acer"), me) else { return nil }
            return GameEventMoment(time: time, kind: .multikill, name: "Ace")
        case "DragonKill":
            guard isMine else { return nil }
            let dragon = event.string("DragonType").map { "\($0) Dragon" } ?? "Dragon"
            return GameEventMoment(time: time, kind: .objectiveKill, name: event.string("Stolen") == "True" ? "\(dragon) Stolen" : dragon)
        case "BaronKill":
            guard isMine else { return nil }
            return GameEventMoment(time: time, kind: .objectiveKill, name: event.string("Stolen") == "True" ? "Baron Stolen" : "Baron Nashor")
        case "HeraldKill":
            guard isMine else { return nil }
            return GameEventMoment(time: time, kind: .objectiveKill, name: "Rift Herald")
        case "TurretKilled":
            guard isMine else { return nil }
            return GameEventMoment(time: time, kind: .objectiveKill, name: "Turret")
        case "InhibKilled":
            guard isMine else { return nil }
            return GameEventMoment(time: time, kind: .objectiveKill, name: "Inhibitor")
        case "FirstBrick":
            guard isSelf(killer, me) else { return nil }
            return GameEventMoment(time: time, kind: .objectiveKill, name: "First Turret")
        case "GameEnd":
            switch event.string("Result") {
            case "Win": return GameEventMoment(time: time, kind: .victory, name: "Victory")
            case "Lose": return GameEventMoment(time: time, kind: .defeat, name: "Defeat")
            default: return nil
            }
        default:
            return nil
        }
    }
}

// MARK: - The cfg files

public enum GameStateIntegration {
    /// The file Valve's games read, pointing at Wingcord's listener — the
    /// components a clip's events need and nothing more, and a token so the
    /// listener knows a POST is the game's.
    ///
    /// - Parameter components: Dota's `provider map player`; CS2's
    ///   `provider map round player_id player_state player_match_stats`.
    public static func configuration(port: UInt16, token: String, components: [String]) -> String {
        var lines = [
            "\"Wingcord\"",
            "{",
            "    \"uri\"           \"http://127.0.0.1:\(port)/\"",
            "    \"timeout\"       \"5.0\"",
            "    \"buffer\"        \"0.1\"",
            "    \"throttle\"      \"0.1\"",
            "    \"heartbeat\"     \"30.0\"",
            "    \"auth\"",
            "    {",
            "        \"token\"     \"\(token)\"",
            "    }",
            "    \"data\"",
            "    {",
        ]
        lines += components.map { "        \"\($0)\"   \"1\"" }
        lines += ["    }", "}", ""]
        return lines.joined(separator: "\n")
    }

    public static let dotaComponents = ["provider", "map", "player"]
    public static let counterStrikeComponents = [
        "provider", "map", "round", "player_id", "player_state", "player_match_stats",
    ]
    /// What each game calls the file — Valve reads every
    /// `gamestate_integration_*.cfg` in the folder.
    public static let fileName = "gamestate_integration_wingcord.cfg"
}
