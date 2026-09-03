import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// The activity directory and the launch flow.
///
/// Every payload below is captured — `activities123.har` and
/// `activities_search.har`, 2026-09-02 — and trimmed only of fields nothing
/// reads. None of these routes is documented anywhere, so a decoder written
/// against a remembered shape would not fail loudly; it would draw a launcher
/// that is confidently wrong.
@Suite("Activities")
struct ActivityDecodeTests {

    // MARK: The shelf

    /// Farm Merge Valley and Watch Together, with their real asset lists. FMV
    /// is here because it registers `embedded_cover` **twice** and has no
    /// `cover_image` at all; Watch Together because it has both, and
    /// `max_participants: -1`.
    private let shelf = """
    {"applications":[
      {"id":"1187013846746005515","name":"Farm Merge Valley",
       "icon":"b91a865fc18d3c14b736e54eb5e32221","summary":"","is_verified":true,
       "description":"Farm, merge, grow and expand your land!",
       "tags":["Casual Game","Farming Game","Match 3","Puzzle","Single Player"],
       "max_participants":null,
       "terms_of_service_url":"https://www.coolgames.com/terms-of-use/",
       "privacy_policy_url":"https://www.coolgames.com/privacy-policy/",
       "embedded_activity_config":{"activity_preview_video_asset_id":"1232355776870223923",
         "supported_platforms":["web","ios","android"],"requires_age_gate":false,
         "shelf_rank":63,"has_csp_exception":false,"displays_advertisements":false}},
      {"id":"880218394199220334","name":"Watch Together",
       "icon":"ec48acbad4c32efab4275cb9f3ca3a58",
       "cover_image":"3cc9446876ae9eec6e06ff565703c292","summary":"","is_verified":true,
       "description":"Create and watch shared playlists of YouTube videos with your friends. ",
       "tags":["Video Player","Watch"],"max_participants":-1,
       "terms_of_service_url":"https://discord.com/terms",
       "privacy_policy_url":"https://discord.com/privacy",
       "embedded_activity_config":{"activity_preview_video_asset_id":"1311095551336517754",
         "supported_platforms":["web","ios","android"],"requires_age_gate":false,
         "shelf_rank":49,"has_csp_exception":false,"displays_advertisements":false}}],
     "assets":{
      "1187013846746005515":[
        {"id":"1328288533535416310","type":1,"name":"background_1024x576"},
        {"id":"1328288625822993525","type":1,"name":"embedded_background"},
        {"id":"1463112735482262897","type":1,"name":"embedded_cover"},
        {"id":"1513644151886053446","type":1,"name":"embedded_cover"}],
      "880218394199220334":[
        {"id":"881026601625013486","type":1,"name":"servericon"},
        {"id":"1093243403222667494","type":1,"name":"embedded_background"},
        {"id":"1303047145993277530","type":1,"name":"embedded_cover"}]}}
    """

    private func decodeShelf() throws -> ShelfDTO {
        try JSONDecoder().decode(ShelfDTO.self, from: Data(shelf.utf8))
    }

    private func shelfApps() throws -> [ActivityApp] {
        try (decodeShelf().applications ?? []).compactMap(\.domain)
    }

    /// Six apps in the captured shelf name `embedded_cover` twice. The newer
    /// upload is the one Discord draws, and "newer" is a snowflake comparison
    /// rather than array order.
    @Test("A repeated embedded_cover resolves to the highest asset id")
    func duplicateCoverTakesNewest() throws {
        let dto = try decodeShelf()
        let farm = try #require(dto.assets?["1187013846746005515"])
        #expect(ShelfDTO.tileAsset(in: farm) == "1513644151886053446")
    }

    /// The whole reason the tile draws from `embedded_cover` rather than from
    /// `cover_image`: Farm Merge Valley has no `cover_image`, and it still has
    /// a full artwork tile in the reference client.
    @Test("An app with no cover_image still has tile artwork")
    func tileArtworkWithoutCoverImage() throws {
        let dto = try decodeShelf()
        let apps = try shelfApps()
        let farm = try #require(apps.first { $0.name == "Farm Merge Valley" })
        #expect(farm.coverHash == nil)
        #expect(ShelfDTO.tileAsset(in: dto.assets?["1187013846746005515"]) != nil)
    }

    /// `-1` is unlimited and `null` is unstated. A client that reads the
    /// absent case as zero labels half the directory "0 players".
    @Test("max_participants: -1 is unlimited, null is silence")
    func participantLabels() throws {
        let apps = try shelfApps()
        let watch = try #require(apps.first { $0.name == "Watch Together" })
        let farm = try #require(apps.first { $0.name == "Farm Merge Valley" })
        #expect(watch.maxParticipants == -1)
        #expect(watch.participantsLabel == "Unlimited")
        #expect(farm.maxParticipants == nil)
        #expect(farm.participantsLabel == nil)
    }

    @Test("An app with a web platform in its config is launchable")
    func launchability() throws {
        let apps = try shelfApps()
        let allLaunchable = apps.allSatisfy(\.isLaunchable)
        #expect(allLaunchable)

        var bot = apps[0]
        bot.config = nil
        #expect(bot.isLaunchable == false)

        var mobileOnly = apps[0]
        mobileOnly.config?.supportedPlatforms = ["ios", "android"]
        #expect(mobileOnly.isLaunchable == false)
    }

    // MARK: Collections

    /// Two rows in the order the route actually answers in — Puzzle Games
    /// first, Promoted second — which is *not* the order they are drawn in.
    private let collections = """
    [
     {"id":"1328862878782197885","title":"Puzzle Games","position":2,"type":4,
      "application_directory_collection_items":[
        {"position":1,"type":1,
         "application":{"id":"1273616940451102832","name":"Daily Sudoku Together",
          "icon":"aa","summary":"","is_verified":true,"description":"Dive into Daily Sudoku.",
          "tags":["Puzzle"],
          "embedded_activity_config":{"supported_platforms":["web"]}}}]},
     {"id":"1328814176696537109","title":"Promoted","position":1,"type":5,
      "application_directory_collection_items":[
        {"position":2,"type":1,
         "application":{"id":"1187013846746005515","name":"Farm Merge Valley",
          "icon":"b9","summary":"","is_verified":true,"description":"Farm and merge.",
          "tags":["Puzzle"],
          "embedded_activity_config":{"supported_platforms":["web"]},
          "directory_entry":{"guild_count":58200,
            "short_description":"Farm, merge, grow and expand your land!",
            "carousel_items":[{"type":2,"url":"https://www.youtube.com/embed/VWJwQ3TZ7Fo"}]}}},
        {"position":1,"type":1,
         "application":{"id":"1211781489931452447","name":"Wordle",
          "icon":"c1","summary":"","is_verified":true,"description":"Guess the word.",
          "tags":["Puzzle"],
          "embedded_activity_config":{"supported_platforms":["web"]},
          "directory_entry":{"guild_count":319000,
            "short_description":"Enjoy Wordle from New York Times Games!",
            "carousel_items":[{"type":1,
              "url":"https://app-directory-assets.discordactivities.com/wordle/screen_1.png",
              "proxy_url":"https://images-ext-1.discordapp.net/external/8Zp/screen_1.png"}]}}}]}]
    """

    private func decodeCollections() throws -> [ActivityCollection] {
        try JSONDecoder().decode([CollectionDTO].self, from: Data(collections.utf8))
            .compactMap(\.domain)
            .sorted { $0.position < $1.position }
    }

    /// The route answers Puzzle-then-Promoted and the client draws
    /// Promoted-then-Puzzle. Array order is not the answer; `position` is.
    @Test("Collections sort by position, not by array order")
    func collectionOrder() throws {
        let rows = try decodeCollections()
        #expect(rows.map(\.title) == ["Promoted", "Puzzle Games"])
    }

    /// `type: 5` is the artwork row. Everything else is a list, and a third
    /// value must not silently become one of these two.
    @Test("Type 5 is the featured row")
    func featuredKind() throws {
        let rows = try decodeCollections()
        #expect(rows[0].isFeatured)
        #expect(rows[1].isFeatured == false)
        #expect(rows[1].kind == 4)
    }

    /// Items carry their own `position`, and Wordle is sent second.
    @Test("Items inside a collection sort by their own position")
    func itemOrder() throws {
        let promoted = try #require(decodeCollections().first)
        #expect(promoted.apps.map(\.name) == ["Wordle", "Farm Merge Valley"])
    }

    /// The directory hangs its own fields beside the application's rather than
    /// nesting the application inside them, which is why `DirectoryApplicationDTO`
    /// decodes the same container twice.
    @Test("A directory entry merges onto the application it sits beside")
    func directoryEntryMerges() throws {
        let promoted = try #require(decodeCollections().first)
        let wordle = try #require(promoted.apps.first { $0.name == "Wordle" })
        #expect(wordle.guildCount == 319_000)
        #expect(wordle.tagline == "Enjoy Wordle from New York Times Games!")
        #expect(wordle.rowSubtitle == "Enjoy Wordle from New York Times Games!")
        #expect(wordle.heroImageURL?.host() == "images-ext-1.discordapp.net")
    }

    /// A `type: 2` carousel item is a YouTube embed URL, which needs a browser.
    /// Skipping it is the difference between no hero and a broken one.
    @Test("A video carousel item is not offered as a hero image")
    func videoCarouselItemIsSkipped() throws {
        let promoted = try #require(decodeCollections().first)
        let farm = try #require(promoted.apps.first { $0.name == "Farm Merge Valley" })
        #expect(farm.heroImageURL == nil)
    }

    /// With no directory entry there is no short description, and the row has
    /// to fall back to the full one rather than drawing a blank line.
    @Test("A row with no tagline falls back to the description")
    func rowSubtitleFallsBack() throws {
        let puzzle = try #require(decodeCollections().last)
        let sudoku = try #require(puzzle.apps.first)
        #expect(sudoku.tagline == nil)
        #expect(sudoku.rowSubtitle == "Dive into Daily Sudoku.")
    }

    // MARK: Search

    /// Seven results a page against seventy matches — the page count is the
    /// only thing that says there are more.
    @Test("A search page reports how many pages follow it")
    func searchPaging() throws {
        let json = """
        {"results":[{"type":1,"data":{"id":"1487437995153435253","name":"test",
          "icon":null,"summary":"","description":"test","is_verified":true,"tags":[]}}],
         "num_pages":10,"result_count":70,"type":1}
        """
        let dto = try JSONDecoder().decode(SearchDTO.self, from: Data(json.utf8))
        let page = ActivitySearchPage(
            apps: (dto.results ?? []).compactMap { $0.data?.domain },
            page: 1,
            pageCount: dto.num_pages ?? 1,
            totalCount: dto.result_count ?? 0
        )
        #expect(page.apps.map(\.name) == ["test"])
        #expect(page.hasMore)
        #expect(page.totalCount == 70)
        // A bot: no embedded config, so nothing may offer to launch it.
        #expect(page.apps[0].isLaunchable == false)
    }

    // MARK: The entry point

    /// `type: 4` is a primary entry point. **The handler is not a filter** —
    /// it says who answers the interaction, not whether there is anything to
    /// launch. Six of the seven type-4 commands in the captured user index are
    /// `handler: 2` and one is `handler: 1`: Wordle's `play`, which is exactly
    /// as launchable. Gating on `2` reported "Wordle has nothing to launch."
    @Test("Any type-4 command is an entry point, whatever its handler")
    func entryPointGating() throws {
        let json = """
        {"application_commands":[
          {"id":"1275958726442426443","type":4,"application_id":"880218394199220334",
           "version":"1487256241190708420","name":"launch","dm_permission":false,
           "contexts":[0,2],"integration_types":[0,1],"handler":2}],
         "version":"1376941608135144012"}
        """
        let dto = try JSONDecoder().decode(CommandIndexDTO.self, from: Data(json.utf8))
        let entry = try #require(dto.domain.entryPoint)
        #expect(entry.name == "launch")
        #expect(entry.version == "1487256241190708420")
        #expect(entry.contexts == [0, 2])

        // Wordle's own shape, verbatim from the captured user index.
        var appHandled = try #require(dto.application_commands?.first)
        appHandled.handler = 1
        #expect(appHandled.domain?.activityEntryPoint != nil)

        // A chat-input command is not an entry point, whatever its handler.
        var chatInput = try #require(dto.application_commands?.first)
        chatInput.type = 1
        #expect(chatInput.domain?.activityEntryPoint == nil)
    }

    // MARK: The consent screen

    @Test("Authorize reports whether the grant already exists")
    func authorizationShape() throws {
        let json = """
        {"application":{"id":"880218394199220334","name":"Watch Together",
          "icon":"ec48acbad4c32efab4275cb9f3ca3a58","summary":"","is_verified":true,
          "description":"Create and watch shared playlists.","tags":["Video Player","Watch"],
          "max_participants":-1,"terms_of_service_url":"https://discord.com/terms",
          "privacy_policy_url":"https://discord.com/privacy"},
         "authorized":false,"integration_type":1,"redirect_uri":"http://127.0.0.1"}
        """
        let dto = try JSONDecoder().decode(AuthorizationDTO.self, from: Data(json.utf8))
        #expect(dto.authorized == false)
        #expect(dto.application?.name == "Watch Together")
        #expect(dto.application?.is_verified == true)
    }

    // MARK: The instance id

    /// The composite id from the captured invitation message. A DM carries no
    /// guild, so the location is two segments rather than three.
    @Test("A private-channel instance id round-trips")
    func privateInstanceID() throws {
        let raw = "i-1544745440824660141-pc-1424759145021837325"
        let id = try #require(ActivityInstanceID(rawValue: raw))
        #expect(id.instance == "1544745440824660141")
        #expect(id.location.guildID == nil)
        #expect(id.location.channelID.description == "1424759145021837325")
        #expect(id.location.kind == "pc")
        #expect(id.rawValue == raw)
    }

    /// The same id in a server, which the leave route splits at a different
    /// place. Never captured — a launch into a guild channel was not recorded
    /// — so this pins the *shape* the docs and the `pc` capture agree on
    /// rather than claiming a payload.
    @Test("A guild instance id keeps its guild segment")
    func guildInstanceID() throws {
        let raw = "i-123-gc-456-789"
        let id = try #require(ActivityInstanceID(rawValue: raw))
        #expect(id.location.guildID?.description == "456")
        #expect(id.location.channelID.description == "789")
        #expect(id.rawValue == raw)
    }

    @Test("Malformed instance ids are refused rather than half-parsed")
    func rejectsMalformedInstanceIDs() {
        #expect(ActivityInstanceID(rawValue: "1544745440824660141-pc-1") == nil)
        #expect(ActivityInstanceID(rawValue: "i--pc-1") == nil)
        #expect(ActivityInstanceID(rawValue: "i-abc-pc-1") == nil)
        #expect(ActivityInstanceID(rawValue: "i-1-xx-1") == nil)
        #expect(ActivityInstanceID(rawValue: "i-1-gc-1") == nil)
        #expect(ActivityInstanceID(rawValue: "i-1-pc-") == nil)
    }

    // MARK: The invitation message

    /// The captured launch message, trimmed. **Everything a reader sees on
    /// this row is drawn from `application` and `activity_instance`** —
    /// `content` is empty, `embeds` is empty, `components` is empty. A client
    /// that renders only what Discord sent as content renders a blank row.
    private let inviteMessage = """
    {"id":"1544745442306937008","channel_id":"1424759145021837325","type":23,
     "content":"","mentions":[],"mention_roles":[],"attachments":[],"embeds":[],
     "components":[],"flags":0,"pinned":false,"mention_everyone":false,
     "timestamp":"2026-09-02T16:26:53.428000+00:00","edited_timestamp":null,
     "author":{"id":"880218394199220334","username":"Watch Together",
       "avatar":"fe2b7fa334817b0346d57416ad75e93b","discriminator":"5319","bot":true},
     "application":{"id":"880218394199220334","name":"Watch Together",
       "icon":"ec48acbad4c32efab4275cb9f3ca3a58",
       "description":"Create and watch shared playlists."},
     "webhook_id":"880218394199220334",
     "activity_instance":{"id":"i-1544745440824660141-pc-1424759145021837325"}}
    """

    /// A plain decoder is enough here: the only `Date` on `MessageDTO` is
    /// `edited_timestamp`, and a launch message has never been edited.
    private func decodeMessage(_ json: String) throws -> Message {
        try JSONDecoder().decode(MessageDTO.self, from: Data(json.utf8)).domain
    }

    @Test("A launch message becomes an invitation card")
    func inviteDecodes() throws {
        let message = try decodeMessage(inviteMessage)
        let invite = try #require(message.activityInvite)
        #expect(invite.name == "Watch Together")
        #expect(invite.applicationID.description == "880218394199220334")
        #expect(invite.iconHash == "ec48acbad4c32efab4275cb9f3ca3a58")
        #expect(invite.instance?.instance == "1544745440824660141")
        #expect(invite.instance?.location.channelID.description == "1424759145021837325")
    }

    /// The row has no content, no embed and no component — so the renderer's
    /// "is there anything to draw" check has to count the invitation, or the
    /// one thing on the row reads as nothing.
    @Test("An invitation is a body, not an empty message")
    func inviteIsNotEmpty() throws {
        let message = try decodeMessage(inviteMessage)
        #expect(message.content.isEmpty)
        #expect(message.embeds.isEmpty)
        #expect(message.components.isEmpty)
        #expect(message.isEmpty == false)
    }

    /// A `type: 23` without an instance is an ordinary context-menu command —
    /// an app answering a right-click — and drawing a Play button on one would
    /// be a control with nothing behind it.
    @Test("A context-menu command with no instance is not an invitation")
    func contextMenuCommandIsNotAnInvite() throws {
        let json = """
        {"id":"1","channel_id":"2","type":23,"content":"done","attachments":[],"embeds":[],
         "author":{"id":"3","username":"bot","discriminator":"0001","bot":true},
         "application":{"id":"3","name":"Some App","icon":null}}
        """
        let message = try decodeMessage(json)
        #expect(message.activityInvite == nil)
    }

    /// A payload is rebuilt field by field on every reaction and every poll
    /// change, and a rebuild that forgets a field drops it silently. This is
    /// the check that the invitation survives one.
    @Test("A rebuilt payload keeps the invitation")
    func inviteSurvivesPayloadCopies() throws {
        let message = try decodeMessage(inviteMessage)
        let payload = try #require(message.payload)
        #expect(payload.replacingReactions([]).activityInvite == message.activityInvite)
        #expect(payload.replacingPoll(nil).activityInvite == message.activityInvite)
    }

    // MARK: The launch body

    /// The launch echoes the whole command record back inside the interaction
    /// rather than naming it — captured that way, and the shape the route was
    /// observed to accept.
    @Test("A launch interaction carries the command twice")
    func launchBodyShape() throws {
        let entry = ActivityEntryPoint(
            id: "1275958726442426443",
            applicationID: ApplicationID(rawValue: 880_218_394_199_220_334),
            version: "1487256241190708420",
            name: "launch",
            contexts: [0, 2],
            integrationTypes: [0, 1]
        )
        let body = LaunchInteraction(
            entry,
            channelID: ChannelID(rawValue: 1_424_759_145_021_837_325),
            sessionID: "dcc0d7c84604fff2d928b72fb8c07272",
            nonce: "1544784235997429760",
            section: "Promoted"
        )
        // Decoded back through a mirror of the captured body rather than
        // inspected as a dictionary: the field *names* are the thing under
        // test, and a mirror that misspells one fails to decode.
        let sent = try JSONDecoder().decode(
            SentLaunch.self,
            from: JSONEncoder().encode(body)
        )

        #expect(sent.type == 2)
        #expect(sent.session_id == "dcc0d7c84604fff2d928b72fb8c07272")
        #expect(sent.channel_id == "1424759145021837325")
        #expect(sent.application_id == "880218394199220334")
        #expect(sent.nonce == "1544784235997429760")
        #expect(sent.analytics_location == "app_launcher")
        #expect(sent.section_name == "Promoted")
        #expect(sent.source == "TEXT")

        #expect(sent.data.id == "1275958726442426443")
        #expect(sent.data.version == "1487256241190708420")
        #expect(sent.data.name == "launch")
        #expect(sent.data.type == 4)
        #expect(sent.data.options.isEmpty)
        #expect(sent.data.attachments.isEmpty)

        let command = sent.data.application_command
        #expect(command.handler == 2)
        #expect(command.type == 4)
        #expect(command.version == "1487256241190708420")
        #expect(command.contexts == [0, 2])
        #expect(command.integration_types == [0, 1])
        #expect(command.dm_permission == false)
        #expect(command.description.isEmpty)
        #expect(command.name_localized == "launch")
    }

    /// The captured `POST /interactions` body, spelled out. Every name here is
    /// read off the capture, so a rename on the encoder side breaks decoding.
    private struct SentLaunch: Decodable {
        var type: Int
        var application_id: String
        var channel_id: String
        var session_id: String
        var data: Data
        var nonce: String
        var analytics_location: String
        var section_name: String?
        var source: String

        struct Data: Decodable {
            var version: String
            var id: String
            var name: String
            var type: Int
            var options: [String]
            var application_command: Command
            var attachments: [String]

            struct Command: Decodable {
                var id: String
                var type: Int
                var application_id: String
                var version: String
                var name: String
                var dm_permission: Bool
                var contexts: [Int]
                var integration_types: [Int]
                var handler: Int
                var description: String
                var options: [String]
                var name_localized: String
            }
        }
    }
}
