import Foundation
import Testing
@testable import WingcordCore

/// Game events, from each source's documented payloads (docs/CLIPS-PRESENCE.md,
/// Phase 3.4): Valve's Game State Integration for Dota 2 and Counter-Strike 2,
/// Riot's Live Client Data for League — its own sample events file.
@Suite("Game events")
struct GameEventTests {

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func dota(kills: Int, deaths: Int = 0, assists: Int = 0, match: String = "7000",
                      state: String = "DOTA_GAMERULES_STATE_GAME_IN_PROGRESS", winner: String = "none",
                      steamid: String = "765") -> Data {
        json([
            "provider": ["name": "Dota 2", "appid": 570, "steamid": "765"],
            "map": ["matchid": match, "game_state": state, "win_team": winner],
            "player": ["steamid": steamid, "kills": kills, "deaths": deaths, "assists": assists, "team_name": "radiant"],
            "auth": ["token": "abc"],
        ])
    }

    @Test("Dota: kills, Dota's eighteen-second multi-kill, deaths, and the result")
    func dotaReader() {
        var reader = DotaGameStateReader()
        #expect(reader.read(dota(kills: 0), at: 0).isEmpty, "the first document is the baseline")
        #expect(reader.read(dota(kills: 1), at: 10).map(\.name) == ["Kill"])
        #expect(reader.read(dota(kills: 2), at: 20).map(\.name) == ["Kill", "Double Kill"])
        #expect(reader.read(dota(kills: 3), at: 50).map(\.name) == ["Kill"], "past eighteen seconds the streak starts again")
        #expect(reader.read(dota(kills: 3, deaths: 1), at: 60).map(\.kind) == [.death])
        #expect(reader.read(dota(kills: 3, deaths: 1, assists: 1), at: 61).map(\.kind) == [.assist])
        let end = reader.read(dota(kills: 3, deaths: 1, assists: 1, state: "DOTA_GAMERULES_STATE_POST_GAME", winner: "radiant"), at: 900)
        #expect(end.map(\.kind) == [.victory])
        // Watching somebody else is not the reader playing.
        #expect(reader.read(dota(kills: 9, steamid: "999"), at: 901).isEmpty)
        // A new match: a new baseline, not nine kills.
        #expect(reader.read(dota(kills: 4, match: "7001"), at: 1_000).isEmpty)
        #expect(DotaGameStateReader.multikillName(7) == "Rampage")
        #expect(GameEventKind.multikill.wireType == .multikill)
        #expect(GameEventKind.objectiveKill.wireType == .unknown)
    }

    private func cs(kills: Int, deaths: Int = 0, roundKills: Int = 0, headshots: Int = 0, round: Int = 1,
                    winner: String? = nil, steamid: String = "765") -> Data {
        var root: [String: Any] = [
            "provider": ["name": "Counter-Strike: Global Offensive", "appid": 730, "steamid": "765"],
            "map": ["name": "de_dust2", "round": round],
            "player": [
                "steamid": steamid, "team": "CT",
                "state": ["health": 100, "round_kills": roundKills, "round_killhs": headshots],
                "match_stats": ["kills": "\(kills)", "deaths": deaths],
            ],
        ]
        if let winner { root["round"] = ["phase": "over", "win_team": winner] }
        return json(root)
    }

    @Test("Counter-Strike 2: kills and headshots, a round's multi-kill, deaths, the round's result")
    func counterStrikeReader() {
        var reader = CounterStrikeGameStateReader()
        #expect(reader.read(cs(kills: 0), at: 0).isEmpty)
        #expect(reader.read(cs(kills: 1, roundKills: 1, headshots: 1), at: 1).map(\.name) == ["Headshot"])
        #expect(reader.read(cs(kills: 2, roundKills: 2, headshots: 1), at: 2).map(\.name) == ["Kill", "Double Kill"])
        #expect(reader.read(cs(kills: 2, deaths: 1, roundKills: 2, headshots: 1), at: 3).map(\.kind) == [.death])
        // Dead, the game shows somebody else; back next round, the counts are
        // a baseline rather than late events.
        #expect(reader.read(cs(kills: 5, steamid: "1"), at: 4).isEmpty)
        #expect(reader.read(cs(kills: 3, deaths: 1, round: 2), at: 30).isEmpty)
        let won = reader.read(cs(kills: 3, deaths: 1, round: 2, winner: "CT"), at: 31)
        #expect(won.map(\.name) == ["Round Won"])
        #expect(reader.read(cs(kills: 3, deaths: 1, round: 2, winner: "CT"), at: 32).isEmpty, "once a round")
    }

    /// Riot's own sample, `liveclientdata_events.json`, with ids and times
    /// given — the sample's are all zero.
    private static var leagueSample: [[String: Any]] { [
        ["EventID": 0, "EventName": "GameStart", "EventTime": 0.0],
        ["EventID": 1, "EventName": "FirstBrick", "EventTime": 300.0, "KillerName": "Riot Tuxedo"],
        ["EventID": 2, "EventName": "DragonKill", "EventTime": 400.0, "DragonType": "Elder", "Stolen": "False",
         "KillerName": "Riot Tuxedo", "Assisters": ["Player 1"]],
        ["EventID": 3, "EventName": "ChampionKill", "EventTime": 500.0, "VictimName": "Riot Gene",
         "KillerName": "Riot Tuxedo", "Assisters": ["Player 1"]],
        ["EventID": 4, "EventName": "Multikill", "EventTime": 501.0, "KillerName": "Riot Tuxedo", "KillStreak": 2],
        ["EventID": 5, "EventName": "ChampionKill", "EventTime": 600.0, "VictimName": "Riot Tuxedo",
         "KillerName": "Riot Gene", "Assisters": []],
        ["EventID": 6, "EventName": "Ace", "EventTime": 700.0, "Acer": "Riot Tuxedo", "AcingTeam": "ORDER"],
        ["EventID": 7, "EventName": "BaronKill", "EventTime": 800.0, "Stolen": "True",
         "KillerName": "Riot Gene", "Assisters": ["Riot Tuxedo"]],
    ] }

    @Test("League: Riot's sample events, the reader's own, placed where they happened")
    func leagueReader() {
        var reader = LeagueEventReader()
        let body = json(["Events": Self.leagueSample])
        let moments = reader.read(body, me: "Riot Tuxedo#NA1", gameTime: 900, at: 10_000)
        #expect(moments.map(\.name) == [
            "First Turret", "Elder Dragon", "Kill", "Double Kill", "Death", "Ace", "Baron Stolen",
        ])
        // Event 3 was at 500 s of a game now at 900 s: four hundred seconds ago.
        #expect(moments[2].time == 9_600)
        // The same body again adds nothing; the reader goes from the last id.
        #expect(reader.read(body, me: "Riot Tuxedo#NA1", gameTime: 901, at: 10_001).isEmpty)
        // Somebody else's kill is nobody's clip here.
        var other = LeagueEventReader()
        #expect(other.read(body, me: "Player 2", gameTime: 900, at: 0).isEmpty)
    }

    @Test("The cfg file points at the listener with its token")
    func configuration() {
        let text = GameStateIntegration.configuration(port: 52_041, token: "s3cret", components: GameStateIntegration.dotaComponents)
        #expect(text.contains("\"uri\"           \"http://127.0.0.1:52041/\""))
        #expect(text.contains("\"token\"     \"s3cret\""))
        #expect(text.contains("\"player\"   \"1\""))
        #expect(text.hasPrefix("\"Wingcord\"\n{"))
    }
}
