import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// Joining a server: the invite, the human check, and the two writes the gate
/// makes.
///
/// **Every payload below is verbatim from `forza onboarding1.har`**, trimmed
/// only of fields nothing reads. That is the point of the suite: these routes
/// are undocumented, and each of the four facts asserted here was got wrong by
/// a plausible reading first.
@Suite("Joining a server")
struct JoinFlowTests {

    // MARK: The invite

    /// `GET /invites/forza?…` — the preview card's whole source.
    private let resolved = """
    {"type":0,"code":"forza","expires_at":null,"id":0,"flags":2,
     "guild":{"id":"428691939861463042","name":"Forza Official",
       "splash":"48e34c73c9195b29e8195ef64e3065cf",
       "banner":"24d3421d9d95510428b40ce880b481f3",
       "description":"The official Discord server for the Forza Horizon and Forza Motorsport series of videogames.",
       "icon":"a_d9a3282cb10770f7dee024e1ce77bef6",
       "features":["VERIFIED","COMMUNITY","MEMBER_VERIFICATION_GATE_ENABLED"],
       "verification_level":3,"vanity_url_code":"forza"},
     "guild_id":"428691939861463042",
     "channel":{"id":"542679645038834735","type":0,"name":"\\ud83d\\udcd2\\ufe0e\\u007crules"},
     "profile":{"id":"428691939861463042","name":"Forza Official","tag":"FRZA","badge":5},
     "approximate_member_count":235334,"approximate_presence_count":48014,
     "is_nickname_changeable":true}
    """

    /// `POST /invites/forza` — the same object plus the two keys that decide
    /// what happens next.
    private let accepted = """
    {"type":0,"code":"forza","guild":{"id":"428691939861463042","name":"Forza Official"},
     "guild_id":"428691939861463042",
     "channel":{"id":"542679645038834735","type":0,"name":"rules"},
     "approximate_member_count":235335,"approximate_presence_count":48014,
     "show_verification_form":true,"new_member":true}
    """

    @Test("An invite resolves to a card")
    func invitePreviewDecodes() throws {
        let dto = try JSONDecoder().decode(InviteDTO.self, from: Data(resolved.utf8))
        let preview = try #require(dto.preview)

        #expect(preview.code == "forza")
        #expect(preview.guildID == GuildID(rawValue: 428_691_939_861_463_042))
        #expect(preview.name == "Forza Official")
        #expect(preview.memberCount == 235_334)
        #expect(preview.onlineCount == 48_014)
        #expect(preview.isVerified)
        // Both assets are present on this server, and the banner is the one the
        // card draws — see `InvitePreview.coverURL`.
        #expect(preview.bannerHash == "24d3421d9d95510428b40ce880b481f3")
        #expect(preview.splashHash == "48e34c73c9195b29e8195ef64e3065cf")
    }

    /// **`show_verification_form` and `new_member` appear only on the accept.**
    /// Reading them off the resolve would leave both false on every real join,
    /// which is a gate that never opens.
    @Test("Accepting an invite reports the gate and whether it was a real join")
    func inviteAcceptanceDecodes() throws {
        let dto = try JSONDecoder().decode(InviteDTO.self, from: Data(accepted.utf8))
        #expect(dto.show_verification_form == true)
        #expect(dto.new_member == true)
        #expect(dto.guildID == GuildID(rawValue: 428_691_939_861_463_042))

        // The resolve carries neither, and defaulting them to true is what would
        // ask a long-standing member to read the rules again.
        let preview = try JSONDecoder().decode(InviteDTO.self, from: Data(resolved.utf8))
        #expect(preview.show_verification_form == nil)
        #expect(preview.new_member == nil)
    }

    @Test("A code is read out of every shape Discord's own dialog accepts",
          arguments: [
            ("hTKzmak", "hTKzmak"),
            ("https://discord.gg/hTKzmak", "hTKzmak"),
            ("discord.gg/hTKzmak", "hTKzmak"),
            ("https://discord.gg/wumpus-friends", "wumpus-friends"),
            ("https://discord.com/invite/hTKzmak", "hTKzmak"),
            ("http://discordapp.com/invite/hTKzmak", "hTKzmak"),
            ("  discord.gg/forza  ", "forza"),
            ("discord.gg/forza/", "forza"),
            ("https://discord.gg/hTKzmak?event=123", "hTKzmak"),
          ])
    func inviteCodeIsExtracted(input: String, expected: String) {
        #expect(InvitePreview.code(in: input) == expected)
    }

    /// A message link is not an invite, and taking its first path component
    /// would join a server nobody named.
    @Test("Anything that is not one code is refused", arguments: [
        "",
        "   ",
        "https://discord.com/channels/428691939861463042/542679645038834735",
        "discord.gg/",
    ])
    func nonInvitesAreRefused(input: String) {
        #expect(InvitePreview.code(in: input) == nil)
    }

    // MARK: The human check

    /// The 400 that refused the first join.
    ///
    /// **No `code` and no `message`**, which is why it cannot be recognised by
    /// the shared error envelope and is read before the status becomes an error.
    private let challenge = """
    {"captcha_key":["You need to update your app to join this server."],
     "captcha_sitekey":"a9b5fb07-92ff-493f-86fe-352a2803b3df",
     "captcha_service":"hcaptcha",
     "captcha_session_id":"4d637c3a-2dcf-435f-b304-b085a38306ed",
     "captcha_rqdata":"MUO5r+7AQ7gDZpe1PUio5lv1Qwet+NIKewGQdJ0EKuKwrfWQWmw33RHeToUXe9fd",
     "captcha_rqtoken":"IkV2ak5zSUZ4ZUpWZ2xqOGVGa3l6RkUwT0FXd1p2Q2xr.ap7Wcg.c5M-efG"}
    """

    @Test("A captcha rejection is recognised and carries all five fields")
    func captchaChallengeDecodes() throws {
        let value = try #require(DiscordREST.captchaChallenge(in: Data(challenge.utf8)))
        #expect(value.sitekey == "a9b5fb07-92ff-493f-86fe-352a2803b3df")
        #expect(value.service == "hcaptcha")
        // The one field absent from every written description of this envelope
        // this project has seen. A retry that dropped it binds the token to a
        // session the server is not holding.
        #expect(value.sessionID == "4d637c3a-2dcf-435f-b304-b085a38306ed")
        #expect(value.rqdata?.isEmpty == false)
        #expect(value.rqtoken?.isEmpty == false)
        #expect(value.isSolvable)
    }

    /// **The sitekey is the test, not `captcha_key`.** That key holds a sentence
    /// — "You need to update your app to join this server." — so an ordinary
    /// refusal that happened to carry one must not open a window at somebody.
    @Test("A rejection without a sitekey is not a challenge")
    func nonChallengesAreRefused() {
        let ordinary = #"{"code":50035,"message":"Invalid Form Body"}"#
        #expect(DiscordREST.captchaChallenge(in: Data(ordinary.utf8)) == nil)
        #expect(DiscordREST.captchaChallenge(in: Data()) == nil)

        let keyOnly = #"{"captcha_key":["captcha-required"]}"#
        #expect(DiscordREST.captchaChallenge(in: Data(keyOnly.utf8)) == nil)
    }

    @Test("A solved check goes back as the three captured headers")
    func solutionAppliesHeaders() {
        var request = URLRequest(url: URL(string: "https://discord.com/api/v9/invites/forza")!)
        CaptchaSolution(key: "P1_token", rqtoken: "rq", sessionID: "sess").apply(to: &request)
        #expect(request.value(forHTTPHeaderField: "X-Captcha-Key") == "P1_token")
        #expect(request.value(forHTTPHeaderField: "X-Captcha-Rqtoken") == "rq")
        #expect(request.value(forHTTPHeaderField: "X-Captcha-Session-Id") == "sess")
    }

    // MARK: The ballot

    /// **`seen` means SHOWN, and this is the assertion that pins it.**
    ///
    /// The captured server has six prompts and the join flow submitted the seen
    /// maps for exactly one — the one with `in_onboarding: true`. A body built
    /// from every prompt tells Discord somebody has been shown five questions
    /// nobody asked them, and Discord stops offering them.
    @Test("The ballot's seen maps carry only the prompts that were drawn")
    func ballotSeenMapsCoverOnlyShownPrompts() throws {
        let shown = GuildOnboarding.Prompt(
            id: 1_108_815_692_297_416_788,
            title: "Would you like to join any of our non-English speaking sections?",
            options: [
                .init(id: 1_108_815_692_299_928_788, title: "Français"),
                .init(id: 1_108_815_692_298_409_086, title: "Deutsch"),
                .init(id: 1_420_883_137_133_189_392, title: "Español"),
                .init(id: 1_420_915_398_888_726_290, title: "日本語"),
            ],
            isInOnboarding: true
        )
        let hidden = GuildOnboarding.Prompt(
            id: 1_420_883_137_133_086_804,
            title: "Which games would you like to talk about?",
            options: [.init(id: 1_420_883_137_615_184_846, title: "Forza Horizon 6")],
            isInOnboarding: false
        )

        let body = OnboardingResponsesBody(
            responses: [1_108_815_692_299_928_788],
            // What the gate draws, which is the filtered list.
            prompts: [shown, hidden].filter(\.isInOnboarding)
        )

        #expect(body.onboarding_responses == ["1108815692299928788"])
        #expect(body.onboarding_prompts_seen.keys.sorted() == ["1108815692297416788"])
        #expect(body.onboarding_responses_seen.count == 4)
        #expect(body.onboarding_responses_seen["1420883137615184846"] == nil)

        // Milliseconds, which is a different unit from every `Date` on the wire.
        let stamp = try #require(body.onboarding_prompts_seen.values.first)
        #expect(stamp > 1_700_000_000_000)
    }

    // MARK: The rules

    /// `GET /guilds/{id}/member-verification` — trimmed to two of six rules.
    private let verification = """
    {"version":"2025-09-25T21:04:15.651000+00:00",
     "description":"Welcome to the official Forza Discord Server!",
     "form_fields":[{"field_type":"TERMS","label":"Read and agree to the server rules",
       "description":null,"automations":null,"required":true,
       "values":["\\ud83d\\uded1 This server has a ZERO tolerance policy for hate speech.",
                 "\\ud83c\\udf10  Please read through the rules channel after joining."]}]}
    """

    /// **The version is echoed byte for byte.** It looks like a timestamp, and
    /// this client's shared decoder would happily make it a `Date` — but the
    /// agreement is recorded against the *string*, and re-serialising a `Date`
    /// produces a different one for the same instant.
    @Test("The rules submission echoes the whole form and adds one key")
    func rulesSubmissionEchoesTheForm() throws {
        let rules = try JSONDecoder()
            .decode(MemberVerificationDTO.self, from: Data(verification.utf8))
            .domain(guildID: GuildID(rawValue: 428_691_939_861_463_042))

        #expect(rules.version == "2025-09-25T21:04:15.651000+00:00")
        #expect(rules.rules.count == 2)
        #expect(rules.canSubmit)

        let terms = try #require(rules.termsField)
        let body = try #require(MemberVerificationSubmitBody(
            JoinApplication(form: rules, answers: [terms.id: .agreed(true)])
        ))
        #expect(body.version == "2025-09-25T21:04:15.651000+00:00")
        #expect(body.form_fields.count == 1)
        #expect(body.form_fields[0].field_type == "TERMS")
        #expect(body.form_fields[0].label == "Read and agree to the server rules")
        #expect(body.form_fields[0].values?.count == 2)
        #expect(body.form_fields[0].required)
        #expect(body.form_fields[0].response == .bool(true))
    }

    /// The 201 the capture answered with. `APPROVED` is what clears `pending`;
    /// the other two states are real and are told apart.
    @Test("The join request's status is read", arguments: [
        ("APPROVED", MemberVerificationOutcome.approved),
        ("PENDING", .pending),
        ("STARTED", .pending),
    ])
    func joinRequestOutcome(status: String, expected: MemberVerificationOutcome) throws {
        let payload = #"{"application_status":"\#(status)","rejection_reason":null}"#
        let dto = try JSONDecoder().decode(JoinRequestDTO.self, from: Data(payload.utf8))
        #expect(dto.outcome == expected)
    }
}
