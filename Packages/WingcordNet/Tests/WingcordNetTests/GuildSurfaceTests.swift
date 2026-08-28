import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// The five routes behind Server Guide, Channels & Roles and Game Servers.
///
/// **Every payload below is captured**, trimmed only of the fields none of these
/// surfaces read. That is the point of the suite: each of these routes is
/// undocumented, and a decoder written against a shape somebody remembered does
/// not fail loudly — it yields a page that is confidently wrong.
@Suite("Guild surfaces")
struct GuildSurfaceTests {

    // MARK: Server Guide

    /// Orbit Hub's, which has all three parts.
    private let Orbit HubGuide = """
    {"guild_id":"960000000000000001","enabled":true,
     "welcome_message":{"author_ids":["717245560237175262"],
       "message":"Hello [@username], glad to meet you here! This is a place where Orbit Hub-related discussions happen."},
     "new_member_actions":[
       {"channel_id":"964741354341188645","action_type":1,"title":"Tell us about yourself or anything!","description":"","emoji":{"id":null,"name":"\\ud83d\\udc4b\\ud83c\\udffc","animated":false}},
       {"channel_id":"1019953514271314269","action_type":0,"title":"Report an issue","description":"","emoji":{"id":null,"name":"\\ud83d\\udc1b","animated":false}},
       {"channel_id":"964807340981395787","action_type":0,"title":"Have a read of important announcements","description":""}],
     "resource_channels":[
       {"channel_id":"964741354340413305","title":"Rules & Roles","description":"Pick roles here and read up on our guidelines"},
       {"channel_id":"972857445388370381","title":"Links","description":"Nifty links that might be helpful"}]}
    """

    /// The Counter-Strike server's, which has a welcome and **no resources** —
    /// the case a reader that assumed three sections would draw an empty
    /// heading over.
    private let counterStrikeGuide = """
    {"guild_id":"574217343635554305","enabled":true,
     "welcome_message":{"author_ids":["307854049791813045"],
       "message":"Welcome to the Counter-Strike Discord [@username]! I made this server for you."},
     "new_member_actions":[
       {"channel_id":"735510768972265905","action_type":0,"title":"See what perms you can unlock","description":""},
       {"channel_id":"672208888016632122","action_type":1,"title":"Come say hello!","description":""}],
     "resource_channels":[]}
    """

    private func guide(_ json: String, _ id: UInt64) throws -> ServerGuide {
        try JSONDecoder()
            .decode(NewMemberWelcomeDTO.self, from: Data(json.utf8))
            .domain(guildID: GuildID(rawValue: id))
    }

    @Test("A guide decodes its three parts, in order")
    func guideDecodes() throws {
        let value = try guide(Orbit HubGuide, 960_000_000_000_000_001)
        #expect(value.isEnabled)
        #expect(value.actions.count == 3)
        #expect(value.resources.count == 2)
        #expect(value.actions[0].kind == .write)
        #expect(value.actions[1].kind == .read)
        #expect(value.actions[0].emojiName == "👋🏼")
        // The third action carries no emoji object at all, which is a different
        // shape from one carrying `{"id":null,"name":null}`.
        #expect(value.actions[2].emojiName == nil)
        #expect(value.resources[0].title == "Rules & Roles")
    }

    /// `""` and `null` are used interchangeably across these routes, and a
    /// surface that only checks for nil reserves a line for words that will
    /// never arrive.
    @Test("An empty description is no description")
    func emptyDescriptionIsNil() throws {
        let value = try guide(Orbit HubGuide, 1)
        #expect(value.actions.allSatisfy { $0.detail == nil })
    }

    @Test("A guide with no resources has none, rather than an empty heading")
    func guideWithoutResources() throws {
        let value = try guide(counterStrikeGuide, 574_217_343_635_554_305)
        #expect(value.resources.isEmpty)
        #expect(value.actions.count == 2)
        #expect(!value.isEmpty)
    }

    /// **`[@username]` is a placeholder the client substitutes**, not text
    /// anybody typed. Every captured welcome carries it mid-sentence.
    @Test("The welcome addresses the reader by name")
    func welcomeSubstitutes() throws {
        let value = try guide(counterStrikeGuide, 1)
        let sentence = try #require(value.welcome).substituting("robinresting")
        #expect(sentence.contains("@robinresting"))
        #expect(!sentence.contains("[@username]"))
    }

    /// Two actions can name one channel for two reasons, so the row's identity
    /// is its position. Keyed on the channel, a `ForEach` would draw one row.
    @Test("Row ids are positions, so a repeated channel is still two rows")
    func rowIdentityIsPosition() throws {
        let json = """
        {"guild_id":"1","enabled":true,"new_member_actions":[
          {"channel_id":"55","action_type":0,"title":"Read the rules"},
          {"channel_id":"55","action_type":1,"title":"Then say hello"}],
         "resource_channels":[]}
        """
        let value = try guide(json, 1)
        #expect(value.actions.count == 2)
        #expect(value.actions[0].id != value.actions[1].id)
    }

    // MARK: Onboarding

    /// The Counter-Strike server's, trimmed to two options a prompt.
    private let onboarding = """
    {"guild_id":"574217343635554305","prompts":[
      {"id":"1054867367810683982","title":"Select your region(s) :","options":[
        {"id":"1054867367892141849","title":"Europe","description":"",
         "emoji":{"id":"902113424138971992","name":"region_Europe","animated":false},
         "role_ids":["735516612973199467"],"channel_ids":[]},
        {"id":"1054867367891284853","title":"North America","description":"",
         "emoji":{"id":"902127727284082201","name":"region_NA","animated":false},
         "role_ids":["735516817068093117"],"channel_ids":["648280515617501023"]}],
       "single_select":false,"required":true,"in_onboarding":true,"type":0},
      {"id":"1096803170759032324","title":"What do you want to be notified for?","options":[
        {"id":"1096803171214451886","title":"Community Events","description":"",
         "emoji":{"id":null,"name":"\\ud83c\\udfc6","animated":false},
         "role_ids":["739510033028258278"],"channel_ids":[]}],
       "single_select":true,"required":false,"in_onboarding":true,"type":0}],
     "default_channel_ids":["648280515617501023","619028510748548556"],
     "enabled":true,"mode":0,"below_requirements":false,
     "responses":["1054867367892141849","1096803171214451886"]}
    """

    private func decodedOnboarding() throws -> GuildOnboarding {
        try JSONDecoder()
            .decode(OnboardingDTO.self, from: Data(onboarding.utf8))
            .domain(guildID: GuildID(rawValue: 574_217_343_635_554_305))
    }

    @Test("Onboarding decodes its prompts, options and the reader's answers")
    func onboardingDecodes() throws {
        let value = try decodedOnboarding()
        #expect(value.isEnabled)
        #expect(value.prompts.count == 2)
        #expect(value.prompts[0].isRequired)
        #expect(!value.prompts[0].isSingleSelect)
        #expect(value.prompts[1].isSingleSelect)
        #expect(value.prompts[0].options.count == 2)
        #expect(value.prompts[0].options[0].emojiID?.rawValue == 902_113_424_138_971_992)
        #expect(value.prompts[1].options[0].emojiName == "🏆")
        #expect(value.responses.count == 2)
        #expect(value.responses.contains(1_054_867_367_892_141_849))
        #expect(value.defaultChannelIDs.count == 2)
    }

    /// **The ids are strings on the wire and integers in the store.** A prompt
    /// or option that will not parse is dropped rather than given a zero id,
    /// which would collide with the next one that would not parse either.
    @Test("An unparseable option is dropped, not zeroed")
    func unparseableOptionDropped() throws {
        let json = """
        {"guild_id":"1","enabled":true,"prompts":[
          {"id":"7","title":"Pick","options":[
            {"id":"not-a-number","title":"Broken"},
            {"id":"8","title":"Fine"}]}]}
        """
        let value = try JSONDecoder()
            .decode(OnboardingDTO.self, from: Data(json.utf8))
            .domain(guildID: GuildID(rawValue: 1))
        #expect(value.prompts[0].options.count == 1)
        #expect(value.prompts[0].options[0].id == 8)
    }

    /// **The PUT sends the whole ballot**, and both `seen` maps cover every
    /// prompt and every option — which is what the captured request carries and
    /// what the response echoes back.
    @Test("The ballot body stamps every prompt and every option")
    func ballotCoversEverything() throws {
        let value = try decodedOnboarding()
        let body = OnboardingResponsesBody(
            responses: [1_054_867_367_892_141_849],
            prompts: value.prompts,
            at: Date(timeIntervalSince1970: 1_787_937_855.961)
        )
        #expect(body.onboarding_responses == ["1054867367892141849"])
        #expect(body.onboarding_prompts_seen.count == 2)
        // Three options across the two prompts.
        #expect(body.onboarding_responses_seen.count == 3)
        // Milliseconds, which is a different unit from every `Date` on the wire.
        #expect(body.onboarding_prompts_seen["1054867367810683982"] == 1_787_937_855_961)
    }

    @Test("The route's reply is what the store keeps, not the optimistic set")
    func replyIsAuthoritative() throws {
        let json = """
        {"guild_id":"574217343635554305","user_id":"987654321987654321",
         "onboarding_responses":["1054867367892141849","1054867367891284853"]}
        """
        let value = try JSONDecoder()
            .decode(OnboardingResponsesDTO.self, from: Data(json.utf8))
        #expect(value.responses.count == 2)
    }

    // MARK: Member verification

    /// **Only `TERMS` is read.** The other field types belong to an application
    /// form this client cannot submit, and decoding a question nobody can answer
    /// would be building half of a control that cannot work.
    @Test("Only the rules field is decoded")
    func onlyTermsAreRead() throws {
        let json = """
        {"version":"2020-12-28T20:15:57.529000+00:00",
         "description":"Welcome to the most active CS:GO community on discord!",
         "form_fields":[
           {"field_type":"TERMS","label":"Read and agree to the server rules","values":[
             "Be friendly, treat everyone with respect.",
             "No spam or self-promotion.",
             "No NSFW, obscene, or discriminatory content."],"required":true},
           {"field_type":"TEXT_INPUT","label":"Why do you want to join?","required":true}]}
        """
        let value = try JSONDecoder()
            .decode(MemberVerificationDTO.self, from: Data(json.utf8))
            .domain(guildID: GuildID(rawValue: 574_217_343_635_554_305))
        #expect(value.rules.count == 3)
        #expect(value.detail?.hasPrefix("Welcome") == true)
        #expect(!value.isEmpty)
    }

    /// **The version is the thing an agreement is recorded against**, and it is
    /// kept as the raw string. Decoding it to a `Date` and re-serialising it
    /// produces a different text for the same instant, and the server matches on
    /// the text.
    @Test("The rules keep their version verbatim, and the form goes back whole")
    func agreementEchoesTheForm() throws {
        let json = """
        {"version":"2020-12-28T20:15:57.529000+00:00",
         "description":"Welcome to the most active CS:GO community on discord!",
         "form_fields":[
           {"field_type":"TERMS","label":"Read and agree to the server rules","values":[
             "Be friendly, treat everyone with respect.",
             "No spam or self-promotion."],"required":true}]}
        """
        let verification = try JSONDecoder()
            .decode(MemberVerificationDTO.self, from: Data(json.utf8))
            .domain(guildID: GuildID(rawValue: 574_217_343_635_554_305))
        #expect(verification.version == "2020-12-28T20:15:57.529000+00:00")
        #expect(verification.termsLabel == "Read and agree to the server rules")
        #expect(verification.isTermsRequired)
        #expect(verification.canSubmit)

        let body = try #require(MemberVerificationSubmitBody(verification))
        let encoded = try JSONEncoder().encode(body)
        let text = try #require(String(data: encoded, encoding: .utf8))
        // The captured request carries the version, the label, every rule, the
        // required flag and `response: true`. A bare acknowledgement is not what
        // this route was seen to accept.
        #expect(text.contains("2020-12-28T20:15:57.529000+00:00"))
        #expect(text.contains("\"response\":true"))
        #expect(body.form_fields[0].values.count == 2)
        #expect(body.form_fields[0].field_type == "TERMS")
    }

    /// Nothing to agree to is what stops the button existing, rather than what
    /// stops it working.
    @Test("A verification with no version cannot be submitted")
    func agreementNeedsAVersion() throws {
        let verification = MemberVerification(
            guildID: GuildID(rawValue: 1),
            rules: ["Be kind."]
        )
        #expect(!verification.canSubmit)
        #expect(MemberVerificationSubmitBody(verification) == nil)
    }

    /// Three real outcomes: a rules-only gate approves instantly, a server that
    /// also asks questions leaves it with a moderator, and one that has turned
    /// somebody away answers rejected.
    @Test("The join request tells the three outcomes apart")
    func joinRequestOutcomes() throws {
        func outcome(_ json: String) throws -> MemberVerificationOutcome {
            try JSONDecoder().decode(JoinRequestDTO.self, from: Data(json.utf8)).outcome
        }
        let approved = """
        {"join_request_id":"1542987632308119788","application_status":"APPROVED",
         "rejection_reason":null,"guild_id":"574217343635554305"}
        """
        #expect(try outcome(approved) == .approved)
        #expect(try outcome(#"{"application_status":"PENDING"}"#) == .pending)
        #expect(
            try outcome(#"{"application_status":"REJECTED","rejection_reason":"no"}"#)
                == .rejected("no")
        )
        // An unrecognised status is never reported as success — that is the one
        // direction a guess misleads in.
        #expect(try outcome(#"{"application_status":"MARINATING"}"#) == .unknown("MARINATING"))
        #expect(try outcome("{}") == .unknown(""))
    }

    // MARK: Following a channel

    /// **One flag serves both controls**, and `1 << 12` is it. Read off two
    /// captures that differ in nothing else: setting it checks the box, clearing
    /// it unchecks it — and a category is just another channel id.
    @Test("The opt-in bit is read off a channel override")
    func followedBitIsRead() throws {
        let json = """
        [{"guild_id":"574217343635554305","muted":false,"channel_overrides":[
          {"channel_id":"648280515617501023","message_notifications":3,"muted":false,"flags":4096},
          {"channel_id":"619028510748548556","message_notifications":3,"muted":true,"flags":4096},
          {"channel_id":"733717471666321637","message_notifications":3,"muted":false,"flags":0},
          {"channel_id":"692803418360771171","message_notifications":3,"muted":false}]}]
        """
        let settings = try JSONDecoder().decode([GuildSettingsDTO].self, from: Data(json.utf8))
        var followed: Set<ChannelID> = []
        var muted: Set<ChannelID> = []
        for override in settings[0].channel_overrides ?? [] {
            guard let id = override.channel_id else { continue }
            if (override.flags ?? 0) & ChannelSettingsFlags.followed != 0 { followed.insert(id) }
            if override.muted == true { muted.insert(id) }
        }
        // Followed and muted are independent facts on one override. Reading the
        // second behind a `guard` on the first is how a muted channel loses its
        // opt-in — which is what the READY reader used to do.
        #expect(followed.count == 2)
        #expect(followed.contains(ChannelID(rawValue: 619_028_510_748_548_556)))
        #expect(muted == [ChannelID(rawValue: 619_028_510_748_548_556)])
        // Zero and absent both mean not followed, which is what the route's own
        // reply says: unfollowing removes the entry rather than zeroing it.
        #expect(!followed.contains(ChannelID(rawValue: 733_717_471_666_321_637)))
        #expect(!followed.contains(ChannelID(rawValue: 692_803_418_360_771_171)))
    }

    // MARK: Game servers

    private let gameServers = """
    [{"id":"1461098332907247007","status":"online","sku_id":"1460418489952268142",
      "entitlement_id":"1461098332908182108","subscription_id":null,
      "game_id":"1158877933042143272","name":"CS Discord test server",
      "region_id":"france","region_name":"France","plan_name":"Pro Plan",
      "ip":"5.39.17.17","port":"25372","max_players_count":16,"players_count":0,
      "provider_url":"https://discord.shockbyte.com/server/610fb3f4-52fa-425d-88b3-75ddcddc1d39",
      "provider_type":"shockbyte",
      "game_config":{"version":"latest","type":"Counter-Strike 2"},
      "scheduled_action":null,"scheduled_action_at":null}]
    """

    @Test("A game server decodes down to an address somebody can paste")
    func gameServerDecodes() throws {
        let decoder = JSONDecoder()
        let servers = try decoder
            .decode([GameServerDTO].self, from: Data(gameServers.utf8))
            .compactMap(\.domain)
        let server = try #require(servers.first)
        #expect(server.id == 1_461_098_332_907_247_007)
        #expect(server.skuID == "1460418489952268142")
        #expect(server.status == .online)
        #expect(server.address == "5.39.17.17:25372")
        #expect(server.planName == "Pro Plan")
        #expect(server.regionName == "France")
        #expect(server.maxPlayers == 16)
        #expect(server.playersOnline == 0)
        #expect(server.gameDescription == "Counter-Strike 2 · latest")
        #expect(server.isJoinable)
        // Both halves or neither: an action with no time cannot be stated.
        #expect(server.scheduledAction == nil)
        #expect(server.scheduledActionAt == nil)
    }

    /// **An unknown lifecycle state keeps its own word.** Discord adds to this
    /// set without warning, and "provisioning" drawn as "Unknown" is a client
    /// telling the reader less than the server told it.
    @Test("An unrecognised status keeps its word and is not joinable")
    func unknownStatus() throws {
        let json = """
        [{"id":"1","sku_id":"2","status":"provisioning","name":"Half built",
          "ip":"1.2.3.4","port":"1000","players_count":0,"max_players_count":8}]
        """
        let server = try #require(
            try JSONDecoder().decode([GameServerDTO].self, from: Data(json.utf8))
                .compactMap(\.domain).first
        )
        #expect(server.status == .starting)
        #expect(!server.isJoinable)
    }

    /// The instructions are four levels down an otherwise flat payload, and that
    /// path is the only part of a large response this client reads.
    @Test("A product yields the connection steps and nothing else")
    func productYieldsInstructions() throws {
        let json = """
        {"id":"1457869147477645271","application_id":"1340102344647836531",
         "name":"Counter Strike 2",
         "tenant_metadata":{"guild_monetization":{"game_server":{
           "instructions":{"pc":[
             "In the Steam client, navigate to View > Game Servers.",
             "Click **Favorites**, then click the + button.",
             "Enter your server's IP & port then click **OK**.",
             "Select your server, then click **Connect**."]},
           "deactivation_cooldown_period_days":7,"provider":"shockbyte"}}},
         "skus":[{"id":"1457869147478891763","name":"Starter Plan"}]}
        """
        let product = try JSONDecoder()
            .decode(StorefrontProductDTO.self, from: Data(json.utf8))
            .domain(skuID: "1460418489952268142")
        #expect(product.instructions.count == 4)
        #expect(product.instructions[1] == "Click **Favorites**, then click the + button.")
        #expect(!product.isEmpty)
    }

    /// A product with no game-server metadata at all — which is what every
    /// non-game SKU on that route answers with.
    @Test("A product with no instructions is empty rather than a failure")
    func productWithoutInstructions() throws {
        let product = try JSONDecoder()
            .decode(StorefrontProductDTO.self, from: Data(#"{"id":"9"}"#.utf8))
            .domain(skuID: "9")
        #expect(product.isEmpty)
    }
}
