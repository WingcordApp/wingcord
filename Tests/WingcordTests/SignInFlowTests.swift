import Foundation
import Testing
@testable import Wingcord
import WingcordNet

/// Discord, scripted: each test says what the next answer is.
@MainActor
private final class ScriptedSignInService: SignInService {
    var loginAnswer: Result<LoginOutcome, any Error> = .success(.token("password-token"))
    var verifyAnswer: Result<String, any Error> = .success("mfa-token")
    var smsAnswer: Result<String?, any Error> = .success("+*******1234")
    var resetAnswer: Result<Void, any Error> = .success(())
    var qr: [RemoteAuthEvent] = []

    var sentLogins: [(login: String, password: String, undelete: Bool)] = []
    var sentCodes: [(method: MFAMethod, code: String)] = []
    var resets: [String] = []
    var smsRequests = 0

    nonisolated func prepare() async {}
    nonisolated func installCaptchaSolver(_ solver: CaptchaSolver) async {}

    nonisolated func logIn(login: String, password: String, undelete: Bool) async throws -> LoginOutcome {
        try await MainActor.run {
            sentLogins.append((login, password, undelete))
            return try loginAnswer.get()
        }
    }

    nonisolated func verify(_ method: MFAMethod, code: String, challenge: MFAChallenge) async throws -> String {
        try await MainActor.run {
            sentCodes.append((method, code))
            return try verifyAnswer.get()
        }
    }

    nonisolated func sendSMS(for challenge: MFAChallenge) async throws -> String? {
        try await MainActor.run {
            smsRequests += 1
            return try smsAnswer.get()
        }
    }

    nonisolated func requestPasswordReset(login: String) async throws {
        try await MainActor.run {
            resets.append(login)
            try resetAnswer.get()
        }
    }

    nonisolated func qrEvents() -> AsyncStream<RemoteAuthEvent> {
        AsyncStream { continuation in
            Task { @MainActor in
                for event in self.qr { continuation.yield(event) }
                continuation.finish()
            }
        }
    }
}

@MainActor
@Suite("Signing in")
struct SignInFlowTests {

    private final class Tokens {
        var received: [String] = []
        var answer: String?
    }

    private func flow(
        _ service: ScriptedSignInService,
        tokens: Tokens = Tokens()
    ) -> SignInFlow {
        let flow = SignInFlow(purpose: .signIn, service: service) { token in
            tokens.received.append(token)
            return tokens.answer
        }
        flow.phoneCode = PhoneCode(alpha2: "RO", name: "Romania", code: "+40")
        return flow
    }

    /// Lets the tasks `finish` and `choose` start run to the end.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    // MARK: Logins

    @Test("Discord's phone rule: three of digits, spaces, dashes or parentheses, no plus")
    func phoneRule() {
        #expect(LoginKind.isPhone("555"))
        #expect(LoginKind.isPhone("(555) 123-4567"))
        #expect(!LoginKind.isPhone("55"))
        #expect(!LoginKind.isPhone("+40 712 345 678"))
        #expect(!LoginKind.isPhone("alex@example.com"))
        #expect(!LoginKind.isPhone("５５５"))
    }

    @Test("A phone number goes out after its code, as typed; an email trimmed")
    func wireLogin() {
        let romania = PhoneCode(alpha2: "RO", name: "Romania", code: "+40")
        #expect(LoginKind.wireLogin("712 345 678", code: romania) == "+40712 345 678")
        #expect(LoginKind.wireLogin("  alex@example.com ", code: romania) == "alex@example.com")
        let samoa = PhoneCode(alpha2: "AS", name: "American Samoa", code: "+1 684")
        #expect(samoa.prefix == "+1")
    }

    @Test("The picker defaults to the Mac's region, and the United States without one it knows")
    func preferredCountry() {
        #expect(PhoneCode.preferred(for: Locale(identifier: "ro_RO")).code == "+40")
        #expect(PhoneCode.preferred(for: Locale(identifier: "en_GB")).code == "+44")
        #expect(PhoneCode.preferred(for: Locale(identifier: "xx")).alpha2 == "US")
        #expect(PhoneCode.all.count >= 254)
    }

    // MARK: Credentials

    @Test("A token straight away is handed on, and the password goes")
    func token() async {
        let service = ScriptedSignInService()
        let tokens = Tokens()
        let flow = flow(service, tokens: tokens)
        flow.login = " alex@example.com "
        flow.password = "hunter2"
        await flow.logIn()
        await settle()
        #expect(service.sentLogins.first?.login == "alex@example.com")
        #expect(service.sentLogins.first?.undelete == false)
        #expect(tokens.received == ["password-token"])
        #expect(flow.password.isEmpty)
        #expect(flow.isFinished)
    }

    @Test("Nothing goes out without both fields")
    func incomplete() async {
        let service = ScriptedSignInService()
        let flow = flow(service)
        flow.login = "alex@example.com"
        await flow.logIn()
        #expect(service.sentLogins.isEmpty)
        #expect(!flow.canLogIn)
    }

    @Test("A second factor turns the page, opens on the first method this client can answer, and drops the password")
    func mfa() async {
        let service = ScriptedSignInService()
        service.loginAnswer = .success(.mfa(MFAChallenge(ticket: "T", methods: [.webauthn, .totp, .backup])))
        let flow = flow(service)
        flow.login = "alex@example.com"
        flow.password = "hunter2"
        await flow.logIn()
        #expect(flow.page == .mfa)
        #expect(flow.method == .totp)
        #expect(flow.password.isEmpty)
        #expect(flow.methods == [.webauthn, .totp, .backup])
    }

    @Test("A passkey alone opens on the list, which explains it")
    func passkeyOnly() async {
        let service = ScriptedSignInService()
        service.loginAnswer = .success(.mfa(MFAChallenge(ticket: "T", methods: [.webauthn])))
        let flow = flow(service)
        flow.login = "a"
        flow.password = "b"
        await flow.logIn()
        #expect(flow.page == .mfa)
        #expect(flow.method == nil)
    }

    @Test("A text-message-only account sends the text as the page opens")
    func smsFirst() async {
        let service = ScriptedSignInService()
        service.loginAnswer = .success(.mfa(MFAChallenge(ticket: "T", methods: [.sms])))
        let flow = flow(service)
        flow.login = "a"
        flow.password = "b"
        await flow.logIn()
        await settle()
        #expect(flow.method == .sms)
        #expect(service.smsRequests == 1)
        #expect(flow.smsDestination == "+*******1234")
    }

    @Test("A wrong password lands on both fields in Discord's words, and the form shakes")
    func wrongPassword() async {
        let service = ScriptedSignInService()
        let invalid = AuthRefusal.FieldError(code: "INVALID_LOGIN", message: "Login or password is invalid.")
        service.loginAnswer = .failure(AuthRefusal.form(["login": invalid, "password": invalid]))
        let flow = flow(service)
        flow.login = "a"
        flow.password = "b"
        await flow.logIn()
        #expect(flow.page == .credentials)
        #expect(flow.fieldErrors[.login] == "Login or password is invalid.")
        #expect(flow.fieldErrors[.password] == "Login or password is invalid.")
        #expect(flow.rejections == 1)
        // Typing clears that field's complaint.
        flow.password = "c"
        #expect(flow.fieldErrors[.password] == nil)
        #expect(flow.fieldErrors[.login] != nil)
    }

    @Test("A new login location is a notice, not a field error")
    func newLocation() async {
        let service = ScriptedSignInService()
        service.loginAnswer = .failure(AuthRefusal.form(["login": .init(
            code: "ACCOUNT_LOGIN_VERIFICATION_EMAIL",
            message: "New login location detected, please check your e-mail."
        )]))
        let flow = flow(service)
        flow.login = "a"
        flow.password = "b"
        await flow.logIn()
        #expect(flow.notice == .newLocation("New login location detected, please check your e-mail."))
        #expect(flow.fieldErrors.isEmpty)
    }

    @Test("An account scheduled for deletion asks, and Restore Account sends undelete")
    func restore() async {
        let service = ScriptedSignInService()
        service.loginAnswer = .failure(AuthRefusal.scheduledForDeletion)
        let flow = flow(service)
        flow.login = "a"
        flow.password = "b"
        await flow.logIn()
        #expect(flow.page == .restore(.scheduledForDeletion))
        service.loginAnswer = .success(.token("restored"))
        await flow.restoreAccount()
        #expect(service.sentLogins.last?.undelete == true)
        #expect(service.sentLogins.last?.password == "b")
    }

    @Test("Return to Login clears the challenge and the page")
    func returnToLogin() async {
        let service = ScriptedSignInService()
        service.loginAnswer = .success(.mfa(MFAChallenge(ticket: "T", methods: [.totp])))
        let flow = flow(service)
        flow.login = "a"
        flow.password = "b"
        await flow.logIn()
        flow.returnToLogin()
        #expect(flow.page == .credentials)
        #expect(flow.method == nil)
        #expect(flow.methods.isEmpty)
    }

    @Test("Too many tries says when, suspended and phone verification say so")
    func otherAnswers() async {
        let service = ScriptedSignInService()
        let flow = flow(service)
        flow.login = "a"
        flow.password = "b"

        service.loginAnswer = .failure(AuthRefusal.rateLimited(retryAfter: 10))
        await flow.logIn()
        guard case .tooManyAttempts(let until) = flow.notice else {
            Issue.record("expected a wait, got \(String(describing: flow.notice))")
            return
        }
        #expect(until.timeIntervalSinceNow > 8)

        service.loginAnswer = .failure(AuthRefusal.suspended)
        await flow.logIn()
        #expect(flow.notice == .suspended)

        service.loginAnswer = .failure(AuthRefusal.phoneVerificationRequired)
        await flow.logIn()
        #expect(flow.notice == .phoneVerification)

        service.loginAnswer = .failure(DiscordREST.Failure.transport("offline"))
        await flow.logIn()
        #expect(flow.notice == .failed("Couldn't reach Discord. Check your connection and try again."))
    }

    // MARK: The second factor

    @Test("A code is sent only at its length, and a wrong one is said and cleared")
    func codes() async {
        let service = ScriptedSignInService()
        service.loginAnswer = .success(.mfa(MFAChallenge(ticket: "T", methods: [.totp, .backup])))
        let tokens = Tokens()
        let flow = flow(service, tokens: tokens)
        flow.login = "a"
        flow.password = "b"
        await flow.logIn()

        flow.code = "12345"
        #expect(!flow.canSubmitCode)
        await flow.submitCode()
        #expect(service.sentCodes.isEmpty)

        service.verifyAnswer = .failure(AuthRefusal.wrongCode("Invalid two-factor code"))
        flow.code = "000000"
        await flow.submitCode()
        #expect(flow.fieldErrors[.code] == "Invalid two-factor code")
        #expect(flow.code.isEmpty)

        service.verifyAnswer = .success("in")
        flow.code = "123456"
        await flow.submitCode()
        await settle()
        #expect(service.sentCodes.last?.method == .totp)
        #expect(tokens.received == ["in"])
    }

    @Test("A backup code is eight characters, dashes aside")
    func backupLength() async {
        let service = ScriptedSignInService()
        service.loginAnswer = .success(.mfa(MFAChallenge(ticket: "T", methods: [.totp, .backup])))
        let flow = flow(service)
        flow.login = "a"
        flow.password = "b"
        await flow.logIn()
        flow.choose(.backup)
        #expect(flow.codeLength == 8)
        flow.code = "abcd-1234"
        #expect(flow.canSubmitCode)
    }

    @Test("Choosing text message sends one, once")
    func chooseSMS() async {
        let service = ScriptedSignInService()
        service.loginAnswer = .success(.mfa(MFAChallenge(ticket: "T", methods: [.totp, .sms])))
        let flow = flow(service)
        flow.login = "a"
        flow.password = "b"
        await flow.logIn()
        flow.choose(.sms)
        await settle()
        flow.choose(nil)
        flow.choose(.sms)
        await settle()
        #expect(service.smsRequests == 1)
        #expect(flow.smsDestination == "+*******1234")
    }

    // MARK: Handing on

    @Test("A token the session refuses brings the form back, saying why")
    func refusedToken() async {
        let service = ScriptedSignInService()
        let tokens = Tokens()
        tokens.answer = "That sign-in did not produce a usable token. Try again."
        let flow = flow(service, tokens: tokens)
        flow.login = "a"
        flow.password = "b"
        await flow.logIn()
        await settle()
        #expect(!flow.isFinished)
        #expect(flow.page == .credentials)
        #expect(flow.notice == .failed("That sign-in did not produce a usable token. Try again."))
        #expect(flow.qrGeneration == 1)
    }

    @Test("The QR code's life reaches the screen, and its token is handed on")
    func qr() async {
        let service = ScriptedSignInService()
        let user = RemoteAuthUser(id: "1", discriminator: "0", avatarHash: nil, username: "alex")
        let url = URL(string: "https://discord.com/ra/abc")!
        service.qr = [.connecting, .ready(url: url, fingerprint: "abc"), .scanned(user), .loggingIn, .token("qr-token")]
        let tokens = Tokens()
        let flow = flow(service, tokens: tokens)
        await flow.runQR()
        await settle()
        #expect(flow.qr == .loggingIn)
        #expect(tokens.received == ["qr-token"])
    }

    @Test("A QR login the phone approved but Discord refused says so, and a new code follows")
    func qrFailedAfterApproval() async {
        let service = ScriptedSignInService()
        let url = URL(string: "https://discord.com/ra/abc")!
        service.qr = [.ready(url: url, fingerprint: "abc"), .loggingIn, .failed(.captcha), .connecting]
        let tokens = Tokens()
        let flow = flow(service, tokens: tokens)
        await flow.runQR()
        #expect(tokens.received.isEmpty)
        #expect(flow.qr == .connecting)
        #expect(flow.notice == .failed(SignInFlow.qrFailure(.captcha)))
        #expect(SignInFlow.qrFailure(.captcha).contains("human check"))
    }

    // MARK: Forgot password

    @Test("Forgot password: an email gets the instructions, an empty field a nudge, a phone the website")
    func forgot() async {
        let service = ScriptedSignInService()
        let flow = flow(service)

        #expect(await flow.resetPassword())
        #expect(flow.fieldErrors[.login] != nil)
        #expect(service.resets.isEmpty)

        flow.login = "712 345 678"
        #expect(await flow.resetPassword() == false)
        #expect(service.resets.isEmpty)

        flow.login = "alex@example.com"
        #expect(await flow.resetPassword())
        #expect(service.resets == ["alex@example.com"])
        #expect(flow.notice == .resetSent("alex@example.com"))
    }
}
