import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// The board's wire shapes, against payloads captured from a live account.
///
/// **Three of these decoders cannot be checked by reading them.** The widget
/// array rides on the profile route unasked; a widget config's `value` means
/// three different things depending on a sibling field; and an application
/// profile's numbers arrive as JSON floats in an untyped map beside a typed
/// array of the same idea. Each is a place where a plausible decoder produces
/// plausible nonsense, which is the failure a test has to catch rather than a
/// reader.
@Suite("Widget decode")
struct WidgetDecodeTests {

    private func decodeProfile(_ json: String) throws -> UserProfileDTO {
        try JSONDecoder().decode(UserProfileDTO.self, from: Data(json.utf8))
    }

    // MARK: The board on the profile route

    /// The captured board, trimmed to one tile of each kind.
    private let profile = """
    {
      "user": { "id": "96294210022814081", "username": "million", "discriminator": "0" },
      "widgets": [
        {
          "id": "1530525075935623239",
          "updated_at": "2026-07-25T10:40:13.895570+00:00",
          "data": { "type": "application", "application_id": "1530525061276924584" }
        },
        {
          "id": "1427844892191220175",
          "updated_at": "2025-12-23T07:05:32.391690+00:00",
          "data": {
            "type": "favorite_games",
            "games": [
              {
                "game_id": "359509007423242240",
                "comment": "who doesn't love the sims??",
                "tags": ["love_it", "love_it"]
              }
            ]
          }
        },
        {
          "id": "1427844583621473398",
          "updated_at": "2026-05-23T04:36:33.077518+00:00",
          "data": {
            "type": "current_games",
            "games": [
              {
                "game_id": "1425690433018925056",
                "comment": null,
                "tags": ["casual", "kind_of_love_it", "rage_quitting"]
              }
            ]
          }
        },
        {
          "id": "1427844978416303965",
          "updated_at": "2026-03-09T18:29:54.860228+00:00",
          "data": {
            "type": "want_to_play_games",
            "games": [{ "game_id": "1257819671114289184", "comment": null, "tags": [] }]
          }
        },
        {
          "id": "9999",
          "updated_at": "2026-03-09T18:29:54.860228+00:00",
          "data": { "type": "something_new", "games": [] }
        }
      ]
    }
    """

    @Test("The board comes down with the profile, and every kind decodes")
    func boardDecodes() throws {
        let widgets = try decodeProfile(profile).widgets?.compactMap(\.domain) ?? []
        #expect(widgets.count == 5)
        #expect(widgets[0].applicationID == ApplicationID(rawValue: 1_530_525_061_276_924_584))
        #expect(widgets[1].title == "Favourite Game")
        #expect(widgets[2].title == "Games in Rotation")
        #expect(widgets[3].title == "Want to Play")
        // A kind added after this was written survives the decode and is drawn
        // by nothing — rather than taking the whole board down with it.
        if case .unknown(let name) = widgets[4].content {
            #expect(name == "something_new")
        } else {
            Issue.record("an unknown kind should decode as unknown")
        }
    }

    @Test("A game's comment and tags survive")
    func annotations() throws {
        let widgets = try decodeProfile(profile).widgets?.compactMap(\.domain) ?? []
        let favourite = try #require(widgets.first { $0.title == "Favourite Game" })
        let game = try #require(favourite.games.first)
        #expect(game.gameID == ApplicationID(rawValue: 359_509_007_423_242_240))
        #expect(game.comment == "who doesn't love the sims??")
        #expect(game.tags == [.feeling(.loveIt), .feeling(.loveIt)])

        let rotation = try #require(widgets.first { $0.title == "Games in Rotation" })
        #expect(
            rotation.games.first?.tags
                == [.skill(.casual), .feeling(.kindOfLoveIt), .feeling(.rageQuitting)]
        )
    }

    @Test("A null comment is nil, not an empty string")
    func nullComment() throws {
        let widgets = try decodeProfile(profile).widgets?.compactMap(\.domain) ?? []
        let rotation = try #require(widgets.first { $0.title == "Games in Rotation" })
        #expect(rotation.games.first?.comment == nil)
    }

    @Test("A profile with no widgets decodes to no board rather than failing")
    func noBoard() throws {
        let payload = try decodeProfile("""
        { "user": { "id": "1", "username": "x", "discriminator": "0" } }
        """)
        #expect(payload.widgets == nil)
    }

    // MARK: Application identities

    /// Wuthering Waves' and Arknights' identities, as captured.
    private let identities = """
    {
      "identities": [
        {
          "application_id": "1323482066758930452",
          "provider_issued_user_id": "525916311",
          "profile": {
            "username": "Amin",
            "metadata": null,
            "data": {
              "primary": {
                "featured_played_character_image": {
                  "id": "1545352501656678279",
                  "url": "https://bucket.example/a.png",
                  "proxy_url": "https://images-ext-1.discordapp.net/external/x/a.png",
                  "width": 696,
                  "height": 960
                }
              },
              "dynamic": [
                { "type": 1, "name": "server_name", "value": "Europe" },
                { "type": 2, "name": "union_level", "value": 80.0 },
                { "type": 2, "name": "total_resonators", "value": 45.0 },
                { "type": 2, "name": "login_days", "value": 771.0 }
              ]
            },
            "data_trusted": true,
            "connection_visible": true
          },
          "profiles": []
        },
        {
          "application_id": "1530525061276924584",
          "provider_issued_user_id": "0",
          "profile": {
            "username": null,
            "metadata": null,
            "data": { "dynamic": [] },
            "data_trusted": true,
            "connection_visible": true
          }
        }
      ]
    }
    """

    @Test("An identity's numbers, text and picture all decode into one table")
    func identityDecodes() throws {
        let decoded = try JSONDecoder()
            .decode(ApplicationIdentitiesDTO.self, from: Data(identities.utf8))
            .domain
        #expect(decoded.count == 2)

        let wuwa = try #require(decoded.first)
        #expect(wuwa.externalUserID == "525916311")
        let profile = try #require(wuwa.profile)
        #expect(profile.username == "Amin")
        #expect(profile.fields["union_level"] == .number(80))
        #expect(profile.fields["server_name"] == .text("Europe"))
        // **The proxy, not the origin.** The game's own CDN is a third party
        // this client would otherwise be loading from directly.
        #expect(
            profile.featuredCharacterImageURL?.absoluteString
                == "https://images-ext-1.discordapp.net/external/x/a.png"
        )
    }

    @Test("The dynamic array's own order is what a fallback prints in")
    func dynamicOrder() throws {
        let decoded = try JSONDecoder()
            .decode(ApplicationIdentitiesDTO.self, from: Data(identities.utf8))
            .domain
        let profile = try #require(decoded.first?.profile)
        #expect(
            profile.fieldOrder == ["server_name", "union_level", "total_resonators", "login_days"]
        )
    }

    @Test("A custom widget's identity is empty, and that is not a failure")
    func emptyIdentityIsNormal() throws {
        let decoded = try JSONDecoder()
            .decode(ApplicationIdentitiesDTO.self, from: Data(identities.utf8))
            .domain
        let custom = try #require(decoded.last)
        #expect(custom.externalUserID == "0")
        #expect(custom.isEmpty)
    }

    // MARK: Widget configs

    /// The captured "cool thing" config, trimmed.
    private let config = """
    [
      {
        "config_id": "1530525068500626536",
        "application_id": "1530525061276924584",
        "display_name": "THE widget",
        "status": "published",
        "surfaces": {
          "widget_bottom": {
            "layout": "widget_bottom_stats",
            "components": {
              "stat_3": {
                "fields": {
                  "value": { "value_type": "custom_string", "presentation_type": "text", "value": "aaa" },
                  "label": { "value_type": "custom_string", "presentation_type": "text", "value": "and uh thats it i think" }
                }
              },
              "stat_1": {
                "fields": {
                  "value": { "value_type": "custom_string", "presentation_type": "text", "value": "uhm" },
                  "label": { "value_type": "custom_string", "presentation_type": "text", "value": "im pretty cool i think idk" }
                }
              },
              "stat_2": {
                "fields": {
                  "value": { "value_type": "custom_string", "presentation_type": "text", "value": "hmm" },
                  "label": { "value_type": "custom_string", "presentation_type": "text", "value": "i like technology n stuff" }
                }
              }
            }
          },
          "widget_top": {
            "layout": "widget_top_hero",
            "components": {
              "title": {
                "fields": { "text": { "value_type": "custom_string", "presentation_type": "text", "value": "hi" } }
              },
              "hero_image": {
                "fields": { "image": { "value_type": "application_asset", "presentation_type": "image", "value": "cool_thing" } }
              }
            }
          }
        },
        "updated_at": "2026-07-25T10:54:55.552206+00:00",
        "published_at": "2026-07-25T10:40:12.365143+00:00",
        "resolved_assets": [
          {
            "key": "cool_thing",
            "asset_id": "1530526690340654295",
            "asset_type": "image",
            "metadata": { "width": 602, "height": 541, "is_animated": false }
          }
        ]
      }
    ]
    """

    @Test("A config's surfaces, fields and assets decode")
    func configDecodes() throws {
        let configs = try JSONDecoder()
            .decode([WidgetConfigDTO].self, from: Data(config.utf8))
            .compactMap(\.domain)
        let decoded = try #require(configs.first)
        #expect(decoded.displayName == "THE widget")
        #expect(decoded.status == .published)
        #expect(decoded.assets["cool_thing"]?.assetID == "1530526690340654295")

        let bottom = try #require(decoded.surface(.widgetBottom))
        #expect(bottom.layout == "widget_bottom_stats")
        #expect(bottom.components.count == 3)

        let resolved = try #require(
            decoded.resolve(.widgetBottom, with: nil) { _, _ in nil }
        )
        // The dictionary has no order; the keys do.
        #expect(resolved.stats.map(\.value) == ["uhm", "hmm", "aaa"])
    }

    @Test("A nested fallback decodes to a chain rather than being dropped")
    func fallbackDecodes() throws {
        let json = """
        [{
          "application_id": "1",
          "surfaces": {
            "widget_bottom": {
              "layout": "widget_bottom_stats",
              "components": {
                "stat_1": {
                  "fields": {
                    "value": {
                      "value_type": "data",
                      "presentation_type": "text",
                      "value": "rank_name",
                      "fallback": {
                        "value_type": "custom_string",
                        "presentation_type": "text",
                        "value": "Unranked"
                      }
                    },
                    "label": { "value_type": "custom_string", "presentation_type": "text", "value": "Rank" }
                  }
                }
              }
            }
          }
        }]
        """
        let configs = try JSONDecoder()
            .decode([WidgetConfigDTO].self, from: Data(json.utf8))
            .compactMap(\.domain)
        let resolved = try #require(
            configs.first?.resolve(.widgetBottom, with: ApplicationProfile()) { _, _ in nil }
        )
        #expect(resolved.stats == [ResolvedStat(key: "stat_1", value: "Unranked", label: "Rank")])
    }

    @Test("The featured map flattens to every application's configs")
    func featuredDecodes() throws {
        let json = """
        {
          "application_ids": ["1496037472226906183"],
          "configs": {
            "1496037472226906183": [
              { "application_id": "1496037472226906183", "display_name": "Endfield", "status": "published", "surfaces": {} }
            ]
          }
        }
        """
        let configs = try JSONDecoder()
            .decode(FeaturedWidgetConfigsDTO.self, from: Data(json.utf8))
            .domain
        #expect(configs.count == 1)
        #expect(configs.first?.applicationID == ApplicationID(rawValue: 1_496_037_472_226_906_183))
    }

    // MARK: The application behind a widget

    @Test("A widget application names the game it publishes stats for")
    func widgetApplicationDecodes() throws {
        // Arknights' own payload: the widget application and the game are two
        // different ids, and only this route joins them.
        let json = """
        [{
          "id": "1496037472226906183",
          "name": "Arknights Endfield",
          "icon": "f7877b08efb704adc7f7992af7e3b799",
          "is_verified": false,
          "connection_entrypoint_url": "https://endfield.gryphline.com/special/discord-binding",
          "linked_games": [
            { "id": "1461154307171811401", "type": 2, "application": { "id": "1461154307171811401", "name": "Arknights:Endfield" } }
          ]
        }]
        """
        let applications = try JSONDecoder()
            .decode([WidgetApplicationDTO].self, from: Data(json.utf8))
            .compactMap(\.domain)
        let application = try #require(applications.first)
        #expect(application.id == ApplicationID(rawValue: 1_496_037_472_226_906_183))
        #expect(application.primaryGameID == ApplicationID(rawValue: 1_461_154_307_171_811_401))
        #expect(application.connectionEntrypointURL?.host() == "endfield.gryphline.com")
    }

    // MARK: The write side

    @Test("A write caps each list at its kind's own limit")
    func writeCaps() throws {
        let games = (1...25).map {
            ProfileWidgetGame(gameID: ApplicationID(rawValue: UInt64($0)), tags: [.skill(.expert)])
        }
        let write = ProfileWidgetWrite(kind: .playedGames, games: games)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(write))
        let object = try #require(json as? [String: Any])
        #expect(object["type"] as? String == "played_games")
        #expect((object["games"] as? [Any])?.count == 20)
    }

    @Test("A favourite is capped at one and an application widget sends no games")
    func writeShapes() throws {
        let favourite = ProfileWidgetWrite(
            kind: .favouriteGames,
            games: (1...3).map { ProfileWidgetGame(gameID: ApplicationID(rawValue: UInt64($0))) }
        )
        let favouriteJSON = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(favourite))
                as? [String: Any]
        )
        #expect((favouriteJSON["games"] as? [Any])?.count == 1)

        let application = ProfileWidgetWrite(applicationID: ApplicationID(rawValue: 7))
        let applicationJSON = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(application))
                as? [String: Any]
        )
        #expect(applicationJSON["application_id"] as? String == "7")
        #expect(applicationJSON["games"] == nil)
    }
}
