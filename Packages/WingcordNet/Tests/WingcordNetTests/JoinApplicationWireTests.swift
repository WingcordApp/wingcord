import Foundation
import Testing
@testable import WingcordCore
@testable import WingcordNet

/// Applying to join, pinned on the requests the client makes.
///
/// Discord's `fetchVerificationForm` and `submitVerificationForm` (`408213`):
/// the form is asked for `with_guild` when the reader is outside the server,
/// and goes back whole with each field's `response` added — a boolean for the
/// rules, the text for a written answer, **the index** for a choice.
@Suite("Applying to join on the wire")
struct JoinApplicationWireTests {

    private let guild = GuildID(rawValue: 1)

    private let form = """
    {"version":"2026-09-04T04:22:35.782535+00:00","description":null,
     "form_fields":[
       {"field_type":"TERMS","label":"Read and agree to the server rules",
        "values":["Be kind.","No spam."],"required":true},
       {"field_type":"TEXT_INPUT","label":"Why do you want to join our server?",
        "description":null,"automations":null,"required":true,"placeholder":null},
       {"field_type":"PARAGRAPH","label":"Tell us about yourself","required":true},
       {"field_type":"MULTIPLE_CHOICE","label":"How did you find us?",
        "choices":["A friend","Discovery","Somewhere else"],"required":true},
       {"field_type":"TEXT_INPUT","label":"Anything else?","required":false}],
     "guild":{"id":"1","name":"Yoho Club","icon":"abc","banner":null,"splash":"def",
              "description":"Sailing.","features":["MEMBER_VERIFICATION_GATE_ENABLED",
              "MEMBER_VERIFICATION_MANUAL_APPROVAL"],
              "approximate_member_count":1200,"approximate_presence_count":300}}
    """

    @Test("Somebody outside the server asks with the guild, and its header is read")
    func fetchWithGuild() async throws {
        let (rest, token) = await RequestRecorder.client(body: form)
        let verification = try await rest.memberVerification(of: guild, inviteCode: "yoho", withGuild: true)
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.path == "/api/v9/guilds/1/member-verification")
        #expect(request.query["with_guild"] == "true")
        #expect(request.query["invite_code"] == "yoho")

        #expect(verification.fields.count == 5)
        #expect(verification.asksQuestions)
        #expect(verification.rules == ["Be kind.", "No spam."])
        #expect(verification.guild?.name == "Yoho Club")
        #expect(verification.guild?.memberCount == 1200)
        #expect(verification.guild?.onlineCount == 300)
        #expect(verification.guild?.splashHash == "def")
    }

    @Test("Every field goes back with its answer, a choice as its index")
    func submitEchoesAnswers() async throws {
        let decoded = try JSONDecoder()
            .decode(MemberVerificationDTO.self, from: Data(form.utf8))
            .domain(guildID: guild)
        let fields = decoded.fields
        let application = JoinApplication(form: decoded, answers: [
            fields[0].id: .agreed(true),
            fields[1].id: .text("I sail."),
            fields[2].id: .text("A paragraph."),
            fields[3].id: .choice(1),
        ])
        #expect(application.isComplete)

        let (rest, token) = await RequestRecorder.client(
            status: 201,
            body: #"{"application_status":"SUBMITTED","reviewed_at":null}"#
        )
        let outcome = try await rest.submitJoinApplication(application)
        #expect(outcome == .pending)

        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.method == "PUT")
        #expect(request.path == "/api/v9/guilds/1/requests/@me")
        let json = try #require(request.json)
        #expect(json["version"] as? String == "2026-09-04T04:22:35.782535+00:00")
        let sent = try #require(json["form_fields"] as? [[String: Any]])
        #expect(sent.count == 5)
        #expect(sent[0]["response"] as? Bool == true)
        #expect(sent[0]["values"] as? [String] == ["Be kind.", "No spam."])
        #expect(sent[1]["response"] as? String == "I sail.")
        #expect(sent[2]["response"] as? String == "A paragraph.")
        // A number, not the words — `{name: choice, value: index}`.
        #expect(sent[3]["response"] as? Int == 1)
        #expect(sent[3]["choices"] as? [String] == ["A friend", "Discovery", "Somewhere else"])
        // Unanswered and optional: no response at all, as on Discord's form.
        #expect(sent[4]["response"] == nil)
        #expect(sent[4]["required"] as? Bool == false)
    }

    @Test("A form missing a required answer is not complete, and says which kind")
    func completeness() throws {
        let decoded = try JSONDecoder()
            .decode(MemberVerificationDTO.self, from: Data(form.utf8))
            .domain(guildID: guild)
        var application = JoinApplication(form: decoded)
        #expect(!application.isComplete)
        #expect(application.isMissingAgreement)
        #expect(application.incompleteMessage
            == "All required fields must be filled, including agreeing to the rules.")

        application.answers[decoded.fields[0].id] = .agreed(true)
        application.answers[decoded.fields[1].id] = .text("   ")
        #expect(!application.isMissingAgreement)
        #expect(application.incompleteMessage == "All required fields must be filled.")
        // Spaces are not an answer — Discord's `"" !== n.trim()`.
        #expect(!application.isAnswered(decoded.fields[1]))
        // Optional questions pass untouched.
        #expect(application.isAnswered(decoded.fields[4]))
        #expect(!application.hasProgress)
        application.answers[decoded.fields[3].id] = .choice(0)
        #expect(application.hasProgress)
    }

    @Test("Saving the application form sends the rules back with it")
    func adminSaveKeepsRules() async throws {
        let decoded = try JSONDecoder()
            .decode(JoinApplicationFormDTO.self, from: Data(form.utf8))
            .domain(guildID: guild)
        #expect(decoded.fields.first?.kind == .terms(["Be kind.", "No spam."]))

        let (rest, token) = await RequestRecorder.client(body: form)
        _ = try await rest.updateJoinApplicationForm(decoded)
        let request = try #require(RequestRecorder.requests(for: token).first)
        let sent = try #require(request.json?["form_fields"] as? [[String: Any]])
        #expect(sent.first?["field_type"] as? String == "TERMS")
        #expect(sent.first?["values"] as? [String] == ["Be kind.", "No spam."])
    }

    @Test("An onboarding answer's custom emoji goes up with its id and animation")
    func onboardingCustomEmoji() async throws {
        let (rest, token) = await RequestRecorder.client(body: #"{"guild_id":"1","prompts":[],"enabled":true}"#)
        var option = OnboardingDraft.Option(title: "Sailing")
        option.emoji = EmojiRef(id: EmojiID(rawValue: 77), name: "boat", isAnimated: true)
        var unicode = OnboardingDraft.Option(title: "Fishing")
        unicode.emoji = EmojiRef(name: "🎣")
        let prompt = OnboardingDraft.Prompt(title: "What brings you here?", options: [option, unicode])
        _ = try await rest.setOnboardingPrompts(in: guild, prompts: [prompt])

        let request = try #require(RequestRecorder.requests(for: token).first)
        let prompts = try #require(request.json?["prompts"] as? [[String: Any]])
        let options = try #require(prompts.first?["options"] as? [[String: Any]])
        #expect(options[0]["emoji_id"] as? String == "77")
        #expect(options[0]["emoji_name"] as? String == "boat")
        #expect(options[0]["emoji_animated"] as? Bool == true)
        #expect((options[0]["emoji"] as? [String: Any])?["animated"] as? Bool == true)
        // A Unicode emoji stays as captured: a name, no id, no animation.
        #expect(options[1]["emoji_name"] as? String == "🎣")
        #expect(options[1]["emoji_id"] == nil)
        #expect(options[1]["emoji_animated"] == nil)
    }

    @Test("An invite into a server that reviews applications is marked as one")
    func inviteIntoApplication() async throws {
        let body = """
        {"code":"yoho","type":0,"new_member":true,"show_verification_form":true,
         "guild":{"id":"1","name":"Yoho Club","features":["MEMBER_VERIFICATION_GATE_ENABLED",
         "MEMBER_VERIFICATION_MANUAL_APPROVAL"]},"guild_id":"1"}
        """
        let (rest, _) = await RequestRecorder.client(body: body)
        let acceptance = try await rest.acceptInvite("yoho", sessionID: "s")
        #expect(acceptance.isApplication)
        #expect(acceptance.isNewMember)
        // No request in the answer, nothing to file.
        #expect(acceptance.joinRequest == nil)
        #expect(acceptance.applicationGuild == nil)
    }

    @Test("The request an accept opens is filed with the server it is to")
    func inviteOpensARequest() async throws {
        let body = """
        {"code":"yoho","type":0,"new_member":true,
         "guild":{"id":"1","name":"Yoho Club","icon":"5c05","splash":"abc",
                  "features":["MEMBER_VERIFICATION_GATE_ENABLED","MEMBER_VERIFICATION_MANUAL_APPROVAL"]},
         "guild_id":"1",
         "join_request":{"guild_id":"1","user_id":"2","application_status":"STARTED","join_request_id":"3"}}
        """
        let (rest, _) = await RequestRecorder.client(body: body)
        let acceptance = try await rest.acceptInvite("yoho", sessionID: "s")
        let request = try #require(acceptance.joinRequest)
        #expect(request.guildID == GuildID(rawValue: 1))
        #expect(request.status == .started)
        let guild = try #require(acceptance.applicationGuild)
        #expect(guild.name == "Yoho Club")
        #expect(guild.splashHash == "abc")
        #expect(guild.acceptsApplications)
    }
}
