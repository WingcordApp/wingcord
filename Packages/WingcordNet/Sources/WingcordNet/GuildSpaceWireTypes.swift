import Foundation
import WingcordCore

// MARK: - Server Hub on the wire
//
// Discord's "guild space" routes, read from its web client (2026-11-16):
// `GET/PUT /guilds/{id}/space`, `GET …/space/widgets/hydrate?widget_ids=…`,
// `GET …/space/widgets/catalog` and `PATCH …/space/settings`.
//
// **Every DTO here decodes what it can and never throws on a field it doesn't
// know** (INVARIANTS §5.58.5): the feature is an experiment, its shapes move,
// and a hub that half-decodes is better than a page that fails to open.

/// `GET /guilds/{id}/space`.
struct GuildSpaceDTO: Decodable, Sendable {
    var guild_id: LossyID?
    var channel_id: LossyID?
    var header: Header?
    var widgets: [GuildSpaceWidgetDTO]?

    struct Header: Decodable, Sendable {
        var custom_banner_hash: String?
    }

    func domain(guildID: GuildID) -> GuildSpace {
        GuildSpace(
            guildID: guildID,
            channelID: channel_id.map { ChannelID(rawValue: $0.value) },
            customBannerHash: header?.custom_banner_hash,
            widgets: GuildSpaceLayout.normalized((widgets ?? []).compactMap(\.domain))
        )
    }
}

/// One widget as Discord sends it.
struct GuildSpaceWidgetDTO: Decodable, Sendable {
    var id: LossyID?
    var stringID: String?
    var type: String?
    var position: Position?
    var requires_hydration: Bool?
    var default_title: String?
    var locked: Bool?
    var config: JSONTree?

    struct Position: Decodable, Sendable {
        var column: Int?
        var order: Int?
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, position, requires_hydration, default_title, locked, config
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A snowflake as a string, or once in a while a number.
        stringID = try? container.decode(String.self, forKey: .id)
        id = stringID == nil ? try? container.decode(LossyID.self, forKey: .id) : nil
        type = try? container.decode(String.self, forKey: .type)
        position = try? container.decode(Position.self, forKey: .position)
        requires_hydration = try? container.decode(Bool.self, forKey: .requires_hydration)
        default_title = try? container.decode(String.self, forKey: .default_title)
        locked = try? container.decode(Bool.self, forKey: .locked)
        config = try? container.decode(JSONTree.self, forKey: .config)
    }

    var domain: GuildSpaceWidget? {
        guard let identifier = stringID ?? id.map({ String($0.value) }), let type else { return nil }
        let kind = GuildSpaceWidgetKind(rawValue: type)
        var config = GuildSpaceWidgetConfig(kind: kind)
        if case .object(let fields) = self.config {
            config.title = fields["title"]?.stringValue
            config.text = fields["text"]?.stringValue
            config.imageHash = fields["image_hash"]?.stringValue
        }
        // Kept whole for the kinds a save sends back unchanged.
        if kind != .imageText, let raw = self.config {
            config.rawJSON = try? JSONEncoder().encode(raw)
        }
        return GuildSpaceWidget(
            id: identifier,
            kind: kind,
            position: .init(column: position?.column ?? 0, order: position?.order ?? 0),
            requiresHydration: requires_hydration ?? false,
            defaultTitle: default_title,
            isLocked: locked ?? false,
            config: config
        )
    }
}

/// `PUT /guilds/{id}/space` — Discord's own save (`202762`'s `Fj`): the
/// header's banner only when it changed, and every widget with its kind,
/// position and config, a new one without an id.
struct GuildSpaceSaveBody: Encodable, Sendable {
    var header: Header
    var widgets: [Widget]

    struct Header: Encodable, Sendable {
        /// A data URL to set, an explicit null to remove, absent to keep.
        var customBanner: Banner?

        enum Banner: Sendable {
            case set(String)
            case remove
        }

        private enum CodingKeys: String, CodingKey { case custom_banner }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch customBanner {
            case .set(let dataURL): try container.encode(dataURL, forKey: .custom_banner)
            case .remove: try container.encodeNil(forKey: .custom_banner)
            case nil: break
            }
        }
    }

    struct Widget: Encodable, Sendable {
        var id: String?
        var type: String
        var position: Position
        var config: JSONTree

        struct Position: Encodable, Sendable {
            var column: Int
            var order: Int
        }

        private enum CodingKeys: String, CodingKey { case id, type, position, config }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(id, forKey: .id)
            try container.encode(type, forKey: .type)
            try container.encode(position, forKey: .position)
            try container.encode(config, forKey: .config)
        }
    }

    init(banner: Header.Banner?, widgets: [GuildSpaceWidget]) {
        header = Header(customBanner: banner)
        self.widgets = GuildSpaceLayout.normalized(widgets).map { widget in
            Widget(
                id: widget.isDraft ? nil : widget.id,
                type: widget.kind.rawValue,
                position: .init(column: widget.position.column, order: widget.position.order),
                config: Self.config(for: widget)
            )
        }
    }

    /// Discord's `y0`: Image + Text sends its words, and its picture only when
    /// it changed; every other kind sends back the config it came with.
    static func config(for widget: GuildSpaceWidget) -> JSONTree {
        let config = widget.config
        guard widget.kind == .imageText else {
            if let raw = config.rawJSON, let tree = try? JSONDecoder().decode(JSONTree.self, from: raw) {
                return tree
            }
            return .object(["type": .string(widget.kind.rawValue)])
        }
        var fields: [String: JSONTree] = [
            "type": .string(widget.kind.rawValue),
            "title": config.title.map(JSONTree.string) ?? .null,
            "text": config.text.map(JSONTree.string) ?? .null,
        ]
        switch config.imageChange {
        case .unchanged: break
        case .replaced(let dataURL): fields["image"] = .string(dataURL)
        case .removed: fields["image"] = .null
        }
        return .object(fields)
    }
}

/// `GET …/space/widgets/hydrate`.
struct GuildSpaceHydrateResponse: Decodable, Sendable {
    var widgets: [Item]

    struct Item: Decodable, Sendable {
        var id: String
        var data: GuildSpaceHydrationDTO

        private enum CodingKeys: String, CodingKey { case id, data }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let string = try? container.decode(String.self, forKey: .id) {
                id = string
            } else {
                id = String(try container.decode(LossyID.self, forKey: .id).value)
            }
            data = (try? container.decode(GuildSpaceHydrationDTO.self, forKey: .data)) ?? .other
        }
    }
}

/// One widget's data, told apart by the keys it carries — the answer says
/// nothing about which kind of data it is.
enum GuildSpaceHydrationDTO: Decodable, Sendable {
    case leaderboard(LeaderboardDTO)
    case popularGames(PopularGamesDTO)
    case popularMusic(PopularMusicDTO)
    case other

    private struct Probe: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: any Decoder) throws {
        let keys = Set(try decoder.container(keyedBy: Probe.self).allKeys.map(\.stringValue))
        if keys.contains("entries"), keys.contains("stat") {
            self = .leaderboard(try LeaderboardDTO(from: decoder))
        } else if keys.contains("ranked_songs") {
            self = .popularMusic(try PopularMusicDTO(from: decoder))
        } else if keys.contains("games") {
            self = .popularGames(try PopularGamesDTO(from: decoder))
        } else {
            self = .other
        }
    }

    var domain: GuildSpaceHydration {
        switch self {
        case .leaderboard(let dto): .leaderboard(dto.domain)
        case .popularGames(let dto): .popularGames(dto.domain)
        case .popularMusic(let dto): .popularMusic(dto.domain)
        case .other: .other
        }
    }
}

struct LeaderboardDTO: Decodable, Sendable {
    var stat: Int?
    var next_stat: Int?
    var week_start_ts: Double?
    var day_pt: String?
    var computed_at: FlexibleDate?
    var entries: [Entry]?

    struct Entry: Decodable, Sendable {
        var user_id: LossyID?
        var rank: Int?
        var value: Double?
        var time_played_seconds: Int?
        var application_ids: [LossyID]?
        var application_count: Int?
    }

    var domain: GuildSpaceLeaderboard {
        GuildSpaceLeaderboard(
            stat: GuildSpaceLeaderboard.Stat(rawValue: stat ?? 1) ?? .hoursPlayed,
            nextStat: GuildSpaceLeaderboard.Stat(rawValue: next_stat ?? stat ?? 1) ?? .hoursPlayed,
            weekStart: Date(timeIntervalSince1970: week_start_ts ?? 0),
            dayPT: day_pt,
            computedAt: computed_at?.date,
            entries: (entries ?? []).enumerated().compactMap { index, entry in
                guard let user = entry.user_id else { return nil }
                return GuildSpaceLeaderboard.Entry(
                    userID: UserID(rawValue: user.value),
                    rank: entry.rank ?? index + 1,
                    value: entry.value ?? 0,
                    timePlayedSeconds: entry.time_played_seconds,
                    applicationIDs: (entry.application_ids ?? []).map { ApplicationID(rawValue: $0.value) },
                    applicationCount: entry.application_count ?? 0
                )
            }
        )
    }
}

struct PopularGamesDTO: Decodable, Sendable {
    var user_ids: [LossyID]?
    var games: [Game]?
    var total_users: Int?
    var total_games: Int?

    struct Game: Decodable, Sendable {
        var application_id: LossyID?
        var user_ids: [LossyID]?
    }

    var domain: GuildSpacePopularGames {
        GuildSpacePopularGames(
            userIDs: (user_ids ?? []).map { UserID(rawValue: $0.value) },
            games: (games ?? []).compactMap { game in
                guard let id = game.application_id else { return nil }
                return .init(
                    applicationID: ApplicationID(rawValue: id.value),
                    userIDs: (game.user_ids ?? []).map { UserID(rawValue: $0.value) }
                )
            },
            totalUsers: total_users ?? 0,
            totalGames: total_games ?? 0
        )
    }
}

struct PopularMusicDTO: Decodable, Sendable {
    var ranked_songs: [Song]?
    var ranked_artists: [Artist]?
    var top_listeners: [Listener]?
    var distinct_songs: Int?
    var distinct_artists: Int?
    var distinct_listeners: Int?

    struct Song: Decodable, Sendable {
        var track_external_id: String?
        var track_title: String?
        var artist_name: String?
        var cover_art_hash: String?
        var plays: Int?
        var facepile_user_ids: [LossyID]?
    }

    /// Named tolerantly: the artist card's fields aren't all in Discord's
    /// client where they can be read.
    struct Artist: Decodable, Sendable {
        var artist_external_id: String?
        var name: String?
        var artist_name: String?
        var image_hash: String?
        var plays: Int?
    }

    struct Listener: Decodable, Sendable {
        var user_id: LossyID?
        var plays: Int?
        var play_count: Int?
        var track_title: String?
        var last_track_title: String?
        var artist_name: String?
        var last_artist_name: String?
    }

    var domain: GuildSpacePopularMusic {
        GuildSpacePopularMusic(
            songs: (ranked_songs ?? []).compactMap { song in
                guard let id = song.track_external_id else { return nil }
                return .init(
                    trackID: id,
                    title: song.track_title ?? "Unknown song",
                    artistName: song.artist_name,
                    coverArtHash: song.cover_art_hash,
                    plays: song.plays ?? 0,
                    userIDs: (song.facepile_user_ids ?? []).map { UserID(rawValue: $0.value) }
                )
            },
            artists: (ranked_artists ?? []).compactMap { artist in
                guard let id = artist.artist_external_id else { return nil }
                return .init(
                    artistID: id,
                    name: artist.name ?? artist.artist_name ?? "Unknown artist",
                    imageHash: artist.image_hash,
                    plays: artist.plays ?? 0
                )
            },
            listeners: (top_listeners ?? []).compactMap { listener in
                guard let user = listener.user_id else { return nil }
                return .init(
                    userID: UserID(rawValue: user.value),
                    plays: listener.plays ?? listener.play_count ?? 0,
                    lastTrackTitle: listener.last_track_title ?? listener.track_title,
                    lastArtistName: listener.last_artist_name ?? listener.artist_name
                )
            },
            distinctSongs: distinct_songs ?? 0,
            distinctArtists: distinct_artists ?? 0,
            distinctListeners: distinct_listeners ?? 0
        )
    }
}

/// `GET …/space/widgets/catalog`.
struct GuildSpaceCatalogResponse: Decodable, Sendable {
    var widgets: [Entry]?

    struct Entry: Decodable, Sendable {
        var type: String?
        var name: String?
        var max_instances: Int?
        var boost_price: Int?
        var locked: Bool?
        var assets: Assets?

        struct Assets: Decodable, Sendable {
            var catalog_image_static_url: String?
            var catalog_image_animated_url: String?
        }
    }

    var domain: [GuildSpaceCatalogEntry] {
        (widgets ?? []).compactMap { entry in
            guard let type = entry.type else { return nil }
            return GuildSpaceCatalogEntry(
                kind: GuildSpaceWidgetKind(rawValue: type),
                name: entry.name ?? type,
                maxInstances: entry.max_instances ?? 1,
                boostPrice: entry.boost_price,
                isLocked: entry.locked ?? false,
                staticImageURL: entry.assets?.catalog_image_static_url.flatMap(URL.init(string:)),
                animatedImageURL: entry.assets?.catalog_image_animated_url.flatMap(URL.init(string:))
            )
        }
    }
}

/// `guild_space_settings` on a guild, and the answer to `PATCH …/space/settings`.
struct GuildSpaceSettingsDTO: Decodable, Sendable {
    var enabled: Bool?
    var publish_status: Int?

    var domain: GuildSpaceSettings {
        GuildSpaceSettings(
            isEnabled: enabled,
            publishStatus: GuildSpaceSettings.PublishStatus(rawValue: publish_status ?? 0) ?? .draft
        )
    }
}

/// `guild_space_settings` as it can arrive: an object, a null, or something
/// this client can't read — the last two both mean no hub. Never throws: the
/// field rides every READY (`GuildThemeField`'s reasoning).
struct GuildSpaceSettingsField: Decodable, Sendable {
    var settings: GuildSpaceSettings?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        settings = container.decodeNil() ? nil : (try? container.decode(GuildSpaceSettingsDTO.self))?.domain
    }
}

/// `guild_space_data` as it can arrive. Never throws: a message that carries a
/// shape this client can't read is still a message.
struct GuildSpaceMessageDataField: Decodable, Sendable {
    var data: GuildSpaceMessageData?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        data = container.decodeNil() ? nil : (try? container.decode(GuildSpaceMessageDataDTO.self))?.domain
    }
}

/// `guild_space_data` on a type-69 message.
struct GuildSpaceMessageDataDTO: Decodable, Sendable {
    var whiteboard_busy: Whiteboard?
    var leaderboard: Leaderboard?
    var music: Music?

    struct Whiteboard: Decodable, Sendable {
        var sampled_user_ids: [LossyID]?
        var connected_user_count: Int?
    }

    struct Leaderboard: Decodable, Sendable {
        var event: Int?
        var stat: Int?
        var user_id: LossyID?
        var secondary_user_id: LossyID?
        var value: Double?
    }

    struct Music: Decodable, Sendable {
        var event: Int?
        var track_title: String?
        var artist_name: String?
        var user_id: LossyID?
    }

    var domain: GuildSpaceMessageData? {
        let board = whiteboard_busy.map {
            GuildSpaceMessageData.Whiteboard(
                sampledUserIDs: ($0.sampled_user_ids ?? []).map { UserID(rawValue: $0.value) },
                connectedUserCount: $0.connected_user_count ?? 0
            )
        }
        // Discord's own guards (`518782`'s `Nu`, `825476`'s `x`): an event it
        // knows, a stat it knows, somebody to name.
        let ranking = leaderboard.flatMap { entry -> GuildSpaceMessageData.Leaderboard? in
            guard let event = entry.event.flatMap(GuildSpaceMessageData.Leaderboard.Event.init(rawValue:)),
                  let stat = entry.stat.flatMap(GuildSpaceLeaderboard.Stat.init(rawValue:)), stat != .unspecified,
                  let user = entry.user_id
            else { return nil }
            return .init(
                event: event,
                stat: stat,
                userID: UserID(rawValue: user.value),
                secondaryUserID: entry.secondary_user_id.map { UserID(rawValue: $0.value) },
                value: entry.value ?? 0
            )
        }
        let tune = music.flatMap { entry -> GuildSpaceMessageData.Music? in
            guard let event = entry.event.flatMap(GuildSpaceMessageData.Music.Event.init(rawValue:)) else { return nil }
            return .init(
                event: event,
                trackTitle: entry.track_title.flatMap { $0.isEmpty ? nil : $0 },
                artistName: entry.artist_name.flatMap { $0.isEmpty ? nil : $0 },
                userID: entry.user_id.map { UserID(rawValue: $0.value) }
            )
        }
        guard board != nil || ranking != nil || tune != nil else { return nil }
        return GuildSpaceMessageData(whiteboard: board, leaderboard: ranking, music: tune)
    }
}

/// A snowflake as Discord sends it: a string, or a number.
struct LossyID: Decodable, Sendable, Hashable {
    var value: UInt64

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self), let number = UInt64(string) {
            value = number
        } else {
            value = try container.decode(UInt64.self)
        }
    }
}

/// A time as an ISO string or as milliseconds — `new Date(t)` takes both.
struct FlexibleDate: Decodable, Sendable {
    var date: Date?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let milliseconds = try? container.decode(Double.self) {
            date = Date(timeIntervalSince1970: milliseconds / 1000)
        } else if let string = try? container.decode(String.self) {
            date = (try? Date(string, strategy: .iso8601))
                ?? (try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        } else {
            date = nil
        }
    }
}

extension JSONTree {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}
