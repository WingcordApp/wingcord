import Foundation
import Testing
@testable import WingcordCore

/// The board's domain rules.
///
/// The ordering tests are the important ones. A widget config arrives as a JSON
/// *object*, which has no order, so the only thing standing between the captured
/// widget's three stats and a random permutation of them is
/// `WidgetSurface.byTrailingNumber` — and a test that only checked the values
/// would pass on an implementation that shuffled them.
@Suite("Profile widgets")
struct ProfileWidgetTests {

    private let application = ApplicationID(rawValue: 1_530_525_061_276_924_584)

    // MARK: Tags

    @Test("A tag is grouped by which list it is in")
    func tagGrouping() {
        #expect(GameWidgetTag(rawValue: "expert") == .skill(.expert))
        #expect(GameWidgetTag(rawValue: "love_it") == .feeling(.loveIt))
        #expect(GameWidgetTag(rawValue: "open_to_teach") == .social(.openToTeach))
    }

    @Test("An unknown tag keeps its value and is titled from it")
    func unknownTag() {
        let tag = GameWidgetTag(rawValue: "open_to_duo")
        #expect(tag == .unknown("open_to_duo"))
        #expect(tag.title == "Open To Duo")
        #expect(tag.rawValue == "open_to_duo")
    }

    @Test("Chips order skill, then feeling, then social")
    func tagOrder() {
        let tags: [GameWidgetTag] = [
            .social(.lookingForGroup), .feeling(.loveIt), .skill(.casual),
        ]
        let sorted = tags.sorted { $0.sortRank < $1.sortRank }
        #expect(sorted == [.skill(.casual), .feeling(.loveIt), .social(.lookingForGroup)])
    }

    @Test("A warm feeling and a cold one take different glyphs")
    func feelingGlyphs() {
        #expect(GameWidgetTag.feeling(.loveIt).symbolName == "hand.thumbsup")
        #expect(GameWidgetTag.feeling(.rageQuitting).symbolName == "hand.thumbsdown")
    }

    // MARK: Kinds

    @Test("Each kind carries Discord's own cap")
    func caps() {
        #expect(ProfileWidgetKind.favouriteGames.gameLimit == 1)
        #expect(ProfileWidgetKind.currentGames.gameLimit == 5)
        #expect(ProfileWidgetKind.playedGames.gameLimit == 20)
        #expect(ProfileWidgetKind.wantToPlayGames.gameLimit == 20)
        #expect(ProfileWidgetKind.application.gameLimit == nil)
    }

    @Test("Only the annotated kinds are drawn in detail")
    func detailedKinds() {
        let favourite = ProfileWidget(id: "1", content: .favouriteGames([]))
        let rotation = ProfileWidget(id: "2", content: .currentGames([]))
        let liked = ProfileWidget(id: "3", content: .playedGames([]))
        let wishlist = ProfileWidget(id: "4", content: .wantToPlayGames([]))
        #expect(favourite.isDetailed)
        #expect(rotation.isDetailed)
        #expect(!liked.isDetailed)
        #expect(!wishlist.isDetailed)
    }

    @Test("An application widget lists no games and names an application")
    func applicationWidget() {
        let widget = ProfileWidget(id: "5", content: .application(application))
        #expect(widget.games.isEmpty)
        #expect(widget.applicationID == application)
        #expect(widget.typeName == "application")
    }

    // MARK: Config resolution

    /// The captured "cool thing" widget, reduced to what the resolver reads.
    private func customWidgetConfig() -> WidgetConfig {
        func custom(_ value: String) -> WidgetField {
            .field(
                WidgetField.Value(
                    valueType: .customString, presentationType: .text, value: value
                )
            )
        }
        func stat(_ value: String, _ label: String) -> WidgetComponent {
            WidgetComponent(fields: ["value": custom(value), "label": custom(label)])
        }
        return WidgetConfig(
            configID: "c",
            applicationID: application,
            displayName: "THE widget",
            surfaces: [
                "widget_top": WidgetSurface(
                    layout: "widget_top_hero",
                    components: [
                        "title": WidgetComponent(fields: ["text": custom("hi")]),
                        "subtitle_1": WidgetComponent(
                            fields: ["text": custom("how are u doing today")]
                        ),
                        "hero_image": WidgetComponent(fields: [
                            "image": .field(
                                WidgetField.Value(
                                    valueType: .applicationAsset,
                                    presentationType: .image,
                                    value: "cool_thing"
                                )
                            ),
                        ]),
                    ]
                ),
                "widget_bottom": WidgetSurface(
                    layout: "widget_bottom_stats",
                    components: [
                        "stat_3": stat("aaa", "and uh thats it i think"),
                        "stat_1": stat("uhm", "im pretty cool i think idk"),
                        "stat_2": stat("hmm", "i like technology n stuff"),
                        "stat_5": stat("", ""),
                        "stat_4": stat("", ""),
                        "stat_6": stat("", ""),
                    ]
                ),
            ],
            assets: ["cool_thing": WidgetAsset(key: "cool_thing", assetID: "1530526690340654295")]
        )
    }

    private func assetURL(_ id: ApplicationID, _ assetID: String) -> URL? {
        URL(string: "https://cdn.test/\(id.rawValue)/\(assetID).png")
    }

    @Test("Stats come out in the order their keys number them, not the map's")
    func statOrder() throws {
        let surface = try #require(
            customWidgetConfig().resolve(.widgetBottom, with: nil, assetURL: assetURL)
        )
        #expect(surface.stats.map(\.key) == ["stat_1", "stat_2", "stat_3"])
        #expect(surface.stats.map(\.value) == ["uhm", "hmm", "aaa"])
    }

    @Test("An empty stat slot draws nothing")
    func emptyStatsDropped() throws {
        let surface = try #require(
            customWidgetConfig().resolve(.widgetBottom, with: nil, assetURL: assetURL)
        )
        // Six slots on the wire, three of them filled.
        #expect(surface.stats.count == 3)
    }

    @Test("stat_10 sorts after stat_2")
    func twoDigitStatOrder() {
        var keys = ["stat_10", "stat_2", "stat_1"]
        keys.sort(by: WidgetSurface.byTrailingNumber)
        #expect(keys == ["stat_1", "stat_2", "stat_10"])
    }

    @Test("An application asset resolves through the config's own asset table")
    func heroImage() throws {
        let surface = try #require(
            customWidgetConfig().resolve(.widgetTop, with: nil, assetURL: assetURL)
        )
        #expect(surface.title == "hi")
        #expect(surface.subtitles == ["how are u doing today"])
        #expect(
            surface.heroImageURL?.absoluteString
                == "https://cdn.test/\(application.rawValue)/1530526690340654295.png"
        )
        #expect(surface.isHero)
    }

    @Test("A data field takes its value from the person's identity")
    func dataField() throws {
        let config = WidgetConfig(
            configID: "c",
            applicationID: application,
            displayName: "Arknights Endfield",
            surfaces: [
                "widget_bottom": WidgetSurface(
                    layout: "widget_bottom_stats",
                    components: [
                        "stat_1": WidgetComponent(fields: [
                            "value": .field(
                                WidgetField.Value(
                                    valueType: .data, presentationType: .number, value: "level"
                                )
                            ),
                            "label": .field(
                                WidgetField.Value(
                                    valueType: .customString,
                                    presentationType: .text,
                                    value: "Authority Level"
                                )
                            ),
                        ]),
                    ]
                ),
            ]
        )
        let profile = ApplicationProfile(
            username: "Amin",
            fields: ["level": .number(60)],
            fieldOrder: ["level"]
        )
        let surface = try #require(
            config.resolve(.widgetBottom, with: profile, assetURL: assetURL)
        )
        // **`60`, not `60.0`.** Every number on the wire is a JSON float.
        #expect(surface.stats == [ResolvedStat(key: "stat_1", value: "60", label: "Authority Level")])
    }

    @Test("A field with a fallback uses it when the primary resolves to nothing")
    func fallbackField() {
        let field = WidgetField.fallback(
            WidgetField.Value(valueType: .data, presentationType: .text, value: "missing"),
            .field(
                WidgetField.Value(
                    valueType: .customString, presentationType: .text, value: "Unranked"
                )
            )
        )
        #expect(field.resolveText(in: ApplicationProfile()) == "Unranked")
    }

    @Test("A placeholder string in an image slot is not a URL")
    func imagePlaceholderIsNotAURL() {
        let field = WidgetField.field(
            WidgetField.Value(
                valueType: .customString,
                presentationType: .image,
                value: "change this to an image"
            )
        )
        let url = field.resolveImage(
            applicationID: application, profile: nil, assets: [:], assetURL: assetURL
        )
        #expect(url == nil)
    }

    // MARK: The identity's own fallback

    @Test("An identity with no config still yields labelled stats")
    func fallbackStats() {
        let profile = ApplicationProfile(
            username: "Amin",
            fields: [
                "union_level": .number(80),
                "server_name": .text("Europe"),
                "featured_played_character_image": .image(URL(string: "https://x/y.png")!),
            ],
            fieldOrder: ["server_name", "union_level", "featured_played_character_image"]
        )
        let stats = profile.fallbackStats
        // The character art is a picture, not a stat.
        #expect(stats.map(\.key) == ["server_name", "union_level"])
        #expect(stats.map(\.label) == ["Server Name", "Union Level"])
        #expect(stats.map(\.value) == ["Europe", "80"])
    }

    @Test("An identity with no data at all is empty, and that is normal")
    func emptyIdentity() {
        let identity = ApplicationIdentity(
            applicationID: application,
            externalUserID: "0",
            profile: ApplicationProfile()
        )
        #expect(identity.isEmpty)
    }

    @Test("Playtime is printed as a duration, not as a bare float")
    func durationFormatting() {
        #expect(ApplicationProfileValue.number(2.29).formatted(as: .duration) == "2 hrs")
        #expect(ApplicationProfileValue.number(0.5).formatted(as: .duration) == "30 min")
    }
}
