import Foundation
import Testing
@testable import WingcordNet

/// Signing in, on the wire as Discord's web client (build 663810) sends it:
/// `830215.login`, `.loginMFAv2`, `.forgotPassword`, and the QR's last step.
@Suite("Signing in on the wire")
struct AuthWireTests {

    @Test("A password sign-in goes out as nobody, in Discord's shape")
    func loginShape() async throws {
        let (rest, key) = await RequestRecorder.anonymousClient(
            body: #"{"user_id":"1","token":"secret-token","user_settings":{"locale":"en-US"}}"#
        )
        let outcome = try await rest.logIn(login: "alex@example.com", password: "hunter2")
        #expect(outcome == .token("secret-token"))

        let request = try #require(RequestRecorder.requests(for: key).first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/v9/auth/login")
        #expect(request.headers["Authorization"] == nil)
        #expect(request.headers["X-Fingerprint"] == key)
        #expect(request.json?.keys.sorted() == ["gift_code_sku_id", "login", "login_source", "password", "undelete"])
        #expect(request.json?["login"] as? String == "alex@example.com")
        #expect(request.json?["password"] as? String == "hunter2")
        #expect(request.json?["undelete"] as? Bool == false)
        #expect(request.json?["login_source"] is NSNull)
        #expect(request.json?["gift_code_sku_id"] is NSNull)
    }

    @Test("A sign-in on a client that holds a token still goes out as nobody")
    func loginNeverCarriesAToken() async throws {
        let (rest, key) = await RequestRecorder.anonymousClient(body: #"{"token":"t"}"#)
        await rest.setToken("the-signed-in-account")
        _ = try await rest.logIn(login: "a", password: "b")
        let request = try #require(RequestRecorder.requests(for: key).first)
        #expect(request.headers["Authorization"] == nil)
    }

    @Test("Saying yes to cancelling a deletion sends undelete")
    func undelete() async throws {
        let (rest, key) = await RequestRecorder.anonymousClient(body: #"{"token":"t"}"#)
        _ = try await rest.logIn(login: "a", password: "b", undelete: true)
        let request = try #require(RequestRecorder.requests(for: key).first)
        #expect(request.json?["undelete"] as? Bool == true)
    }

    @Test("An account with two factors answers with a ticket and its methods, in Discord's order")
    func mfaChallenge() async throws {
        let (rest, _) = await RequestRecorder.anonymousClient(body: """
        {"user_id":"1","mfa":true,"sms":true,"ticket":"T1","backup":true,"totp":true,
         "webauthn":"{\\"publicKey\\":{}}","login_instance_id":"L1"}
        """)
        let outcome = try await rest.logIn(login: "a", password: "b")
        #expect(outcome == .mfa(MFAChallenge(
            ticket: "T1", methods: [.webauthn, .totp, .backup, .sms], loginInstanceID: "L1"
        )))
    }

    @Test("No webauthn, no sms: only what the account has")
    func mfaChallengeTotpOnly() async throws {
        let (rest, _) = await RequestRecorder.anonymousClient(
            body: #"{"mfa":true,"sms":false,"ticket":"T","backup":true,"totp":true,"webauthn":null}"#
        )
        guard case .mfa(let challenge) = try await rest.logIn(login: "a", password: "b") else {
            Issue.record("expected a challenge")
            return
        }
        #expect(challenge.methods == [.totp, .backup])
        #expect(challenge.loginInstanceID == nil)
    }

    @Test("A wrong password is a form refusal on both fields, in Discord's words")
    func wrongPassword() async throws {
        let (rest, _) = await RequestRecorder.anonymousClient(status: 400, body: """
        {"message":"Invalid Form Body","code":50035,"errors":{
         "login":{"_errors":[{"code":"INVALID_LOGIN","message":"Login or password is invalid."}]},
         "password":{"_errors":[{"code":"INVALID_LOGIN","message":"Login or password is invalid."}]}}}
        """)
        await #expect(throws: AuthRefusal.form([
            "login": .init(code: "INVALID_LOGIN", message: "Login or password is invalid."),
            "password": .init(code: "INVALID_LOGIN", message: "Login or password is invalid."),
        ])) {
            _ = try await rest.logIn(login: "a", password: "b")
        }
    }

    @Test("A new login location is a form refusal with its own code")
    func newLocation() async throws {
        let refusal = DiscordREST.authRefusal(status: 400, data: Data("""
        {"message":"Invalid Form Body","code":50035,"errors":{"login":{"_errors":[
         {"code":"ACCOUNT_LOGIN_VERIFICATION_EMAIL","message":"New login location detected, please check your e-mail."}]}}}
        """.utf8))
        guard case .form(let fields) = refusal else {
            Issue.record("expected a form refusal, got \(refusal)")
            return
        }
        #expect(fields["login"]?.code == "ACCOUNT_LOGIN_VERIFICATION_EMAIL")
    }

    @Test("Discord's codes read as what they mean")
    func codes() {
        func refusal(_ code: Int) -> AuthRefusal {
            DiscordREST.authRefusal(status: 400, data: Data(#"{"code":\#(code),"message":"m"}"#.utf8))
        }
        #expect(refusal(20011) == .scheduledForDeletion)
        #expect(refusal(20013) == .disabled)
        #expect(refusal(70007) == .phoneVerificationRequired)
        #expect(refusal(60008) == .wrongCode("m"))
        #expect(refusal(50001) == .other(status: 400, code: 50001, message: "m"))
    }

    @Test("A suspended account is read before its code")
    func suspended() {
        let refusal = DiscordREST.authRefusal(
            status: 400, data: Data(#"{"code":20013,"suspended_user_token":"x"}"#.utf8)
        )
        #expect(refusal == .suspended)
    }

    @Test("Too many tries carries Discord's wait, from the body or the header")
    func rateLimited() {
        #expect(DiscordREST.authRefusal(status: 429, data: Data(#"{"retry_after":12.5}"#.utf8))
            == .rateLimited(retryAfter: 12.5))
        #expect(DiscordREST.authRefusal(status: 429, data: Data(), headers: ["Retry-After": "7"])
            == .rateLimited(retryAfter: 7))
    }

    @Test("A challenge nobody answered is a captcha refusal, not a form")
    func unansweredCaptcha() {
        let refusal = DiscordREST.authRefusal(status: 400, data: Data("""
        {"captcha_key":["captcha-required"],"captcha_sitekey":"a9b5fb07-92ff-493f-86fe-352a2803b3df","captcha_service":"hcaptcha"}
        """.utf8))
        #expect(refusal == .captcha)
    }

    @Test("Discord asking for the invisible widget is read, and a plain challenge isn't")
    func invisibleCaptcha() throws {
        let invisible = try #require(DiscordREST.captchaChallenge(in: Data("""
        {"captcha_key":["captcha-required"],"captcha_sitekey":"s","captcha_service":"hcaptcha",
         "captcha_rqdata":"r","captcha_rqtoken":"t","should_serve_invisible":true,"user_flow":"remote_auth_login"}
        """.utf8)))
        #expect(invisible.serveInvisible)
        #expect(invisible.rqdata == "r")
        let plain = try #require(DiscordREST.captchaChallenge(in: Data(#"{"captcha_sitekey":"s"}"#.utf8)))
        #expect(!plain.serveInvisible)
    }

    @Test("A code goes to its method's route with the ticket and the instance")
    func totp() async throws {
        let (rest, key) = await RequestRecorder.anonymousClient(body: #"{"token":"mfa-token"}"#)
        let challenge = MFAChallenge(ticket: "T", methods: [.totp], loginInstanceID: "L")
        let token = try await rest.verifyMFA(.totp, code: "123456", challenge: challenge)
        #expect(token == "mfa-token")
        let request = try #require(RequestRecorder.requests(for: key).first)
        #expect(request.path == "/api/v9/auth/mfa/totp")
        #expect(request.headers["Authorization"] == nil)
        #expect(request.json?["code"] as? String == "123456")
        #expect(request.json?["ticket"] as? String == "T")
        #expect(request.json?["login_instance_id"] as? String == "L")
        #expect(request.json?["login_source"] is NSNull)
    }

    @Test("A backup code loses its dashes, as Discord's screen sends it")
    func backup() async throws {
        let (rest, key) = await RequestRecorder.anonymousClient(body: #"{"token":"t"}"#)
        _ = try await rest.verifyMFA(.backup, code: "abcd-1234", challenge: MFAChallenge(ticket: "T", methods: [.backup]))
        let request = try #require(RequestRecorder.requests(for: key).first)
        #expect(request.path == "/api/v9/auth/mfa/backup")
        #expect(request.json?["code"] as? String == "abcd1234")
        #expect(request.json?["login_instance_id"] == nil)
    }

    @Test("A wrong code is its own refusal")
    func wrongCode() async throws {
        let (rest, _) = await RequestRecorder.anonymousClient(
            status: 400, body: #"{"message":"Invalid two-factor code","code":60008}"#
        )
        await #expect(throws: AuthRefusal.wrongCode("Invalid two-factor code")) {
            _ = try await rest.verifyMFA(.totp, code: "000000", challenge: MFAChallenge(ticket: "T", methods: [.totp]))
        }
    }

    @Test("A text message is asked for with the ticket, and says where it went")
    func sms() async throws {
        let (rest, key) = await RequestRecorder.anonymousClient(body: #"{"phone":"+*******1234"}"#)
        let phone = try await rest.sendMFASMS(challenge: MFAChallenge(ticket: "T", methods: [.sms]))
        #expect(phone == "+*******1234")
        let request = try #require(RequestRecorder.requests(for: key).first)
        #expect(request.path == "/api/v9/auth/mfa/sms/send")
        #expect(request.json?.keys.sorted() == ["ticket"])
    }

    @Test("Forgot password sends the login and nothing else")
    func forgot() async throws {
        let (rest, key) = await RequestRecorder.anonymousClient(body: #"{"method":"email"}"#)
        try await rest.requestPasswordReset(login: "alex@example.com")
        let request = try #require(RequestRecorder.requests(for: key).first)
        #expect(request.path == "/api/v9/auth/forgot")
        #expect(request.json?.keys.sorted() == ["login"])
    }

    @Test("The QR's ticket is exchanged for the still-encrypted token")
    func remoteAuthExchange() async throws {
        let (rest, key) = await RequestRecorder.anonymousClient(body: #"{"encrypted_token":"Y2lwaGVy"}"#)
        let encrypted = try await rest.exchangeRemoteAuthTicket("TICKET")
        #expect(encrypted == "Y2lwaGVy")
        let request = try #require(RequestRecorder.requests(for: key).first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/v9/users/@me/remote-auth/login")
        #expect(request.json?.keys.sorted() == ["ticket"])
        #expect(request.headers["Authorization"] == nil)
    }
}
