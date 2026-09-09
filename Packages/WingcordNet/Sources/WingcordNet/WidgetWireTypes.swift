import Foundation
import WingcordCore

// MARK: - Profile widgets

/// One entry of the `widgets` array on `GET /users/{id}/profile`.
///
/// **The widgets ride on the profile route.** There is no `GET /users/{id}/
/// widgets` — the board's whole content arrives with the banner and the bio, in
/// a key a client that never asked for it simply ignored. Which is what this one
/// was doing.
struct ProfileWidgetDTO: Decodable, Sendable {
    var id: String?
    var updated_at: String?
    var data: DataDTO?

    struct DataDTO: Decodable, Sendable {
        var type: String?
        var games: [GameDTO]?
        var application_id: ApplicationID?
        /// A personal widget's content. Two entries at most — a cover and a
        /// field list — see `PersonalWidget`.
        var header: String?
        var sections: [SectionDTO]?
    }

    /// One section of a personal widget.
    ///
    /// **A tagged union of two shapes in one array**, so `title`/`subtitle`
    /// belong to the cover and `fields` to the list, and each is absent on the
    /// other. Decoded by the tag rather than by which keys turned up.
    struct SectionDTO: Decodable, Sendable {
        var type: String?
        var title: String?
        var subtitle: String?
        var image: AssetDTO?
        var fields: [FieldDTO]?
    }

    struct FieldDTO: Decodable, Sendable {
        var title: String?
        var description: String?
        var image: AssetDTO?
    }

    /// **A read always answers `file_id`; a write always sends `filename`.**
    /// Both are decoded because the reply to a write echoes the stored form, and
    /// a client that only understood one of them would either fail the write's
    /// reply or lose every picture on the next read.
    struct AssetDTO: Decodable, Sendable {
        var file_id: String?
        var filename: String?
        var width: Int?
        var height: Int?
        var is_animated: Bool?

        var domain: PersonalWidget.Asset? {
            if let file_id {
                return .stored(
                    fileID: file_id,
                    width: width ?? 0,
                    height: height ?? 0,
                    isAnimated: is_animated ?? false
                )
            }
            return filename.map { .staged(filename: $0) }
        }
    }

    struct GameDTO: Decodable, Sendable {
        var game_id: ApplicationID?
        var comment: String?
        var tags: [String]?

        var domain: ProfileWidgetGame? {
            guard let game_id else { return nil }
            return ProfileWidgetGame(
                gameID: game_id,
                comment: comment,
                tags: (tags ?? []).map { GameWidgetTag(rawValue: $0) }
            )
        }
    }

    /// Dropped without an id or a type: the id is what a report names and the
    /// type is what decides how it draws, so a tile missing either is not a tile
    /// this client can honour.
    var domain: ProfileWidget? {
        guard let id, let type = data?.type else { return nil }
        let games = (data?.games ?? []).compactMap(\.domain)
        let content: ProfileWidget.Content
        switch ProfileWidgetKind(rawValue: type) {
        case .favouriteGames: content = .favouriteGames(games)
        case .currentGames: content = .currentGames(games)
        case .playedGames: content = .playedGames(games)
        case .wantToPlayGames: content = .wantToPlayGames(games)
        case .application:
            guard let applicationID = data?.application_id else { return nil }
            content = .application(applicationID)
        case .personal:
            let sections = data?.sections ?? []
            let cover = sections.first { $0.type == "cover" }
            let fields = sections.first { $0.type == "fields" }?.fields ?? []
            content = .personal(
                PersonalWidget(
                    header: data?.header ?? "",
                    cover: PersonalWidget.Cover(
                        title: cover?.title ?? "",
                        subtitle: cover?.subtitle ?? "",
                        image: cover?.image?.domain
                    ),
                    fields: fields.map { field in
                        PersonalWidget.Field(
                            title: field.title ?? "",
                            description: field.description ?? "",
                            image: field.image?.domain
                        )
                    }
                )
            )
        case nil:
            content = .unknown(type)
        }
        return ProfileWidget(
            id: id,
            updatedAt: updated_at.flatMap(ISO8601DateFormatter.withFraction.date(from:)),
            content: content
        )
    }
}

/// `PUT /users/@me/widgets`.
///
/// The write side of the board, and **the array sent is the board afterwards**:
/// its order is the order the tiles are drawn in, and a widget left out of it is
/// deleted.
///
/// **The envelope is `{id, data}`, and the `id` is what makes a save an edit
/// rather than a replacement.** This type used to encode the payload flat and
/// send no id at all, which was derived from the read's *inner* object and was
/// wrong on both counts — captured, `widgets order changed + game link
/// widgets.har`:
///
/// ```
/// PUT /users/@me/widgets
/// {"widgets":[{"data":{"type":"application","application_id":"1323482066758930452"}},
///             {"id":"1539974257327743066","data":{"type":"played_games","games":[…]}}]}
/// ```
///
/// and the reply gives the entry with no id a **fresh** id and a new
/// `updated_at`, while the one that carried its id keeps both. So an editor that
/// dropped ids would delete and recreate every tile on the board on every save —
/// which is invisible until something references a widget id, and a report does.
public struct ProfileWidgetWrite: Encodable, Sendable {
    /// The widget being edited, or nil to create one. The server assigns ids.
    var id: String?
    var data: Payload

    struct Payload: Encodable, Sendable {
        var type: String
        var games: [Game]?
        var application_id: String?
        var header: String?
        var sections: [Section]?
    }

    /// **Rebuilt on the way out, never carried.** The domain keeps a cover and a
    /// flat field list because that is the only arrangement the wire has ever
    /// sent; the array is assembled here so nothing upstream has to know the
    /// order or the tag strings.
    public struct Section: Encodable, Sendable {
        var type: String
        var title: String?
        var subtitle: String?
        var image: Asset?
        var fields: [Field]?
    }

    public struct Field: Encodable, Sendable {
        var title: String
        var description: String
        var image: Asset?
    }

    /// **Only a staged filename is ever written.** A picture already stored is
    /// left out entirely rather than echoed back as a `file_id`, which the route
    /// does not accept — see `PersonalWidget.Asset`.
    public struct Asset: Encodable, Sendable {
        var filename: String
    }

    public struct Game: Encodable, Sendable {
        var game_id: String
        var comment: String?
        var tags: [String]?
    }

    /// A list widget — favourites, rotation, liked, wishlist.
    ///
    /// Truncated to the kind's own cap rather than sent long: the route rejects
    /// an over-long list outright, so a save that quietly kept twenty-one games
    /// would lose all twenty-one.
    public init(id: String? = nil, kind: ProfileWidgetKind, games: [ProfileWidgetGame]) {
        self.id = id
        let capped = kind.gameLimit.map { Array(games.prefix($0)) } ?? games
        data = Payload(
            type: kind.rawValue,
            games: capped.map { game in
                Game(
                    game_id: String(game.gameID.rawValue),
                    // **Empty is nil, and the wire says so.** A game with no
                    // comment comes back `"comment": null`, never `""`, and a
                    // blank string is a comment the profile would then draw as
                    // an empty quotation.
                    comment: game.comment?.isEmpty == true ? nil : game.comment,
                    tags: game.tags.isEmpty ? nil : game.tags.map(\.rawValue)
                )
            },
            application_id: nil,
            header: nil,
            sections: nil
        )
    }

    /// A widget the reader wrote.
    ///
    /// A slot whose picture has not been uploaded is sent with no `image` at
    /// all — the route takes a filename or nothing, and an empty object is a
    /// 400 on a field nobody filled in.
    public init(id: String? = nil, personal: PersonalWidget) {
        self.id = id
        var sections: [Section] = [
            Section(
                type: "cover",
                title: personal.cover.title,
                subtitle: personal.cover.subtitle,
                image: personal.cover.image?.stagedFilename.map(Asset.init(filename:)),
                fields: nil
            )
        ]
        if !personal.fields.isEmpty {
            sections.append(
                Section(
                    type: "fields",
                    title: nil,
                    subtitle: nil,
                    image: nil,
                    fields: personal.fields.prefix(PersonalWidget.fieldLimit).map { field in
                        Field(
                            title: field.title,
                            description: field.description,
                            image: field.image?.stagedFilename.map(Asset.init(filename:))
                        )
                    }
                )
            )
        }
        data = Payload(
            type: ProfileWidgetKind.personal.rawValue,
            games: nil,
            application_id: nil,
            header: personal.header,
            sections: sections
        )
    }

    /// An application widget.
    public init(id: String? = nil, applicationID: ApplicationID) {
        self.id = id
        data = Payload(
            type: ProfileWidgetKind.application.rawValue,
            games: nil,
            application_id: String(applicationID.rawValue),
            header: nil,
            sections: nil
        )
    }
}

// MARK: - Application identities

/// `GET /users/{id}/application-identities?with_profiles=true`.
struct ApplicationIdentitiesDTO: Decodable, Sendable {
    var identities: [IdentityDTO]?

    var domain: [ApplicationIdentity] {
        (identities ?? []).compactMap(\.domain)
    }

    struct IdentityDTO: Decodable, Sendable {
        var application_id: ApplicationID?
        var provider_issued_user_id: String?
        var profile: ApplicationProfileDTO?
        /// The wire sends the same object twice — once as `profile` and once as
        /// the only element of `profiles`. Read as a standby rather than
        /// ignored: they are equal in every capture, and if Discord ever stops
        /// sending the singular one the widget should not go blank.
        var profiles: [ApplicationProfileDTO]?

        var domain: ApplicationIdentity? {
            guard let application_id else { return nil }
            return ApplicationIdentity(
                applicationID: application_id,
                externalUserID: provider_issued_user_id ?? "",
                profile: (profile ?? profiles?.first)?.domain
            )
        }
    }
}

/// One application profile, as both the identity route and the gateway send it.
struct ApplicationProfileDTO: Decodable, Sendable {
    var username: String?
    var data: DataDTO?

    struct DataDTO: Decodable, Sendable {
        /// A free-form object of documented keys. Decoded through
        /// `WireJSON` because its values are three different JSON types and
        /// its key set grows per application.
        var primary: [String: WireJSON]?
        var dynamic: [DynamicDTO]?
    }

    /// One entry of `dynamic`: a name, a type tag and a value whose JSON shape
    /// follows the tag.
    struct DynamicDTO: Decodable, Sendable {
        var name: String?
        var type: Int?
        var value: WireJSON?
    }

    var domain: ApplicationProfile {
        var fields: [String: ApplicationProfileValue] = [:]
        var order: [String] = []

        // Primary first, so a `dynamic` entry of the same name wins — which is
        // the order Discord's own resolution takes and the only one that can be
        // checked: Wuthering Waves publishes `server_name` in `dynamic`, and the
        // documentation lists it under `primary`.
        for (name, json) in data?.primary ?? [:] {
            guard let value = Self.value(from: json, type: nil) else { continue }
            fields[name] = value
        }
        for entry in data?.dynamic ?? [] {
            guard let name = entry.name,
                  let json = entry.value,
                  let value = Self.value(from: json, type: entry.type)
            else { continue }
            if fields.updateValue(value, forKey: name) == nil || !order.contains(name) {
                order.append(name)
            }
        }

        return ApplicationProfile(username: username, fields: fields, fieldOrder: order)
    }

    /// The wire's `type` is `1` text, `2` number, `3` image — but the `primary`
    /// object carries no type at all, so the JSON's own shape has to answer for
    /// those. Both paths land here.
    static func value(from json: WireJSON, type: Int?) -> ApplicationProfileValue? {
        switch json {
        case .string(let text):
            return text.isEmpty ? nil : .text(text)
        case .number(let number):
            return .number(number)
        case .object(let object):
            // An image is an unfurled media item: the game's own URL, with
            // Discord's proxy beside it. The **proxy** is taken — the origin is
            // a third-party CDN this client would otherwise be reaching
            // directly, and the proxy is the address Discord's own client
            // loads.
            guard let media = object["proxy_url"] ?? object["url"],
                  case .string(let text) = media,
                  let url = URL(string: text)
            else { return nil }
            return .image(url)
        case .bool, .null, .array:
            return nil
        }
    }
}

// MARK: - Widget configs

/// `GET /applications/{id}/widget-configs` — an array.
struct WidgetConfigDTO: Decodable, Sendable {
    var config_id: String?
    var application_id: ApplicationID?
    var display_name: String?
    var status: String?
    var surfaces: [String: SurfaceDTO]?
    var resolved_assets: [AssetDTO]?
    var published_at: String?
    var updated_at: String?

    struct SurfaceDTO: Decodable, Sendable {
        var layout: String?
        var components: [String: ComponentDTO]?
    }

    struct ComponentDTO: Decodable, Sendable {
        var fields: [String: FieldDTO]?
    }

    /// Recursive through `fallback`, which the wire nests to arbitrary depth.
    indirect enum FieldDTO: Decodable, Sendable {
        case value(ValueDTO)

        struct ValueDTO: Decodable, Sendable {
            var value_type: String?
            var presentation_type: String?
            var value: String?
            var fallback: FieldDTO?
        }

        init(from decoder: any Decoder) throws {
            self = .value(try ValueDTO(from: decoder))
        }

        var domain: WidgetField {
            guard case .value(let dto) = self else {
                return .field(
                    WidgetField.Value(valueType: .unknown, presentationType: .unknown, value: "")
                )
            }
            let value = WidgetField.Value(
                valueType: WidgetField.ValueType(rawValue: dto.value_type ?? ""),
                presentationType: WidgetField.PresentationType(
                    rawValue: dto.presentation_type ?? ""
                ),
                value: dto.value ?? ""
            )
            guard let fallback = dto.fallback else { return .field(value) }
            return .fallback(value, fallback.domain)
        }
    }

    struct AssetDTO: Decodable, Sendable {
        var key: String?
        var asset_id: String?
        var metadata: MetadataDTO?

        struct MetadataDTO: Decodable, Sendable {
            var width: Int?
            var height: Int?
            var is_animated: Bool?
        }
    }

    /// Dropped without an application id: a config that cannot be attributed to
    /// an application cannot be matched to the widget that names one.
    var domain: WidgetConfig? {
        guard let application_id else { return nil }
        var assets: [String: WidgetAsset] = [:]
        for asset in resolved_assets ?? [] {
            guard let key = asset.key, let assetID = asset.asset_id else { continue }
            assets[key] = WidgetAsset(
                key: key,
                assetID: assetID,
                width: asset.metadata?.width,
                height: asset.metadata?.height,
                isAnimated: asset.metadata?.is_animated ?? false
            )
        }
        var surfaces: [String: WidgetSurface] = [:]
        for (name, surface) in self.surfaces ?? [:] {
            var components: [String: WidgetComponent] = [:]
            for (key, component) in surface.components ?? [:] {
                let fields = (component.fields ?? [:]).mapValues(\.domain)
                guard !fields.isEmpty else { continue }
                components[key] = WidgetComponent(fields: fields)
            }
            surfaces[name] = WidgetSurface(
                layout: surface.layout ?? "",
                components: components
            )
        }
        return WidgetConfig(
            configID: config_id ?? String(application_id.rawValue),
            applicationID: application_id,
            displayName: display_name ?? "",
            status: WidgetConfig.Status(rawValue: status ?? "") ?? .published,
            surfaces: surfaces,
            assets: assets,
            publishedAt: published_at.flatMap(ISO8601DateFormatter.withFraction.date(from:)),
            updatedAt: updated_at.flatMap(ISO8601DateFormatter.withFraction.date(from:))
        )
    }
}

/// `GET /widget-configs/featured`.
///
/// **The route that answers for a linked game without being asked per game.**
/// Discord's client has Arknights' and Wuthering Waves' labels the instant a
/// profile opens and never requests them — measured on a capture where the two
/// application widgets resolve with no `/widget-configs` call at all — because
/// the featured set is already resident. This is that set.
struct FeaturedWidgetConfigsDTO: Decodable, Sendable {
    var application_ids: [ApplicationID]?
    var configs: [String: [WidgetConfigDTO]]?

    var domain: [WidgetConfig] {
        (configs ?? [:]).values.flatMap { $0 }.compactMap(\.domain)
    }
}

// MARK: - A JSON value of unknown shape

/// One decoded JSON value, for the two places an application publishes a map
/// whose value types it chooses.
///
/// Kept here rather than in a shared file because these are the only routes that
/// need it, and a general-purpose `AnyCodable` invites use where a real type
/// would do.
enum WireJSON: Decodable, Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: WireJSON])
    case array([WireJSON])
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode([String: WireJSON].self) {
            self = .object(value)
        } else if let value = try? container.decode([WireJSON].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }
}
