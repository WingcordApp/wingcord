import Foundation
import Observation
import WingcordCore
import WingcordNet

/// Signing in, as one state machine: every answer Discord can give and where it
/// leaves the screen (docs/LOGIN-ONBOARDING.md D6–D10).
///
/// **A value the screen draws, with the screen's every act a method here**, so
/// the rules can be tested against a scripted `SignInService` with nothing on
/// screen at all.
///
/// **The password lives here and nowhere else**: never logged, never written
/// anywhere, and dropped the moment Discord stops needing it — a token, a
/// ticket for the second factor, or the screen going away.
@MainActor
@Observable
final class SignInFlow {

    enum Purpose: Equatable {
        /// Nobody's signed in: the token starts the session.
        case signIn
        /// Somebody is: the token is another account, and the switch asks first.
        case addAccount
    }

    enum Page: Equatable {
        case credentials
        case mfa
        /// Discord's "Account Scheduled for Deletion" / "Account Disabled".
        case restore(RestoreKind)
    }

    enum RestoreKind: Equatable {
        case scheduledForDeletion
        case disabled
    }

    enum Field: Hashable {
        case login, password, code
    }

    /// What's said under the form, where it isn't about one field.
    enum Notice: Equatable {
        /// Discord's own sentence: approve the sign-in from the email, then try again.
        case newLocation(String)
        case suspended
        case phoneVerification
        case tooManyAttempts(until: Date)
        /// "We sent instructions to change your password to …".
        case resetSent(String)
        case failed(String)
    }

    enum QRState: Equatable {
        case connecting
        case ready(URL)
        case scanned(RemoteAuthUser)
        case loggingIn
    }

    let purpose: Purpose
    let service: any SignInService
    /// Hands a token on: the session checks it and comes up. Answers what went
    /// wrong, for this screen to say, or nil once it's under way.
    private let onToken: (String) async -> String?

    // The form
    var page: Page = .credentials
    var login = "" { didSet { if login != oldValue { fieldErrors[.login] = nil } } }
    var password = "" { didSet { if password != oldValue { fieldErrors[.password] = nil } } }
    var phoneCode = PhoneCode.preferred()
    var fieldErrors: [Field: String] = [:]
    var notice: Notice?
    var isWorking = false
    /// Bumped by every refusal the form shakes for.
    private(set) var rejections = 0

    // The second factor
    private(set) var challenge: MFAChallenge?
    /// Nil while choosing one.
    var method: MFAMethod?
    var code = "" { didSet { if code != oldValue { fieldErrors[.code] = nil } } }
    private(set) var smsDestination: String?
    private(set) var isSendingSMS = false

    // The QR code
    private(set) var qr: QRState = .connecting
    /// Bumped to throw the code away and start over with a new key.
    private(set) var qrGeneration = 0

    /// Set once a token's been handed on, so nothing after it moves the screen.
    private(set) var isFinished = false

    init(purpose: Purpose, service: any SignInService, onToken: @escaping (String) async -> String?) {
        self.purpose = purpose
        self.service = service
        self.onToken = onToken
    }

    // MARK: Reading

    var isPhoneLogin: Bool { LoginKind.isPhone(login) }

    var canLogIn: Bool {
        !isWorking && !login.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    /// How long a code for the method in hand is: six digits, or eight characters
    /// of backup code (dashes aside).
    var codeLength: Int { method == .backup ? 8 : 6 }

    var canSubmitCode: Bool {
        !isWorking && code.replacing("-", with: "").count == codeLength
    }

    /// The methods offered under "Verify with something else": all of them,
    /// the passkey included, so it can say why it isn't here.
    var methods: [MFAMethod] { challenge?.methods ?? [] }

    // MARK: Credentials

    func logIn() async {
        guard canLogIn else { return }
        await send(undelete: false)
    }

    /// "Restore Account": the same credentials again, with `undelete`.
    func restoreAccount() async {
        await send(undelete: true)
    }

    private func send(undelete: Bool) async {
        isWorking = true
        notice = nil
        fieldErrors = [:]
        defer { isWorking = false }
        do {
            let outcome = try await service.logIn(
                login: LoginKind.wireLogin(login, code: phoneCode),
                password: password,
                undelete: undelete
            )
            guard !isFinished else { return }
            switch outcome {
            case .token(let token):
                finish(token)
            case .mfa(let challenge):
                // The ticket stands in for the password from here.
                password = ""
                self.challenge = challenge
                code = ""
                smsDestination = nil
                method = Self.firstMethod(of: challenge)
                page = .mfa
                if method == .sms { Task { await sendSMS() } }
            }
        } catch {
            guard !isFinished else { return }
            take(error, on: .credentials)
        }
    }

    /// Discord opens on the first method; a passkey can't be answered here, so
    /// the first one that can is where this opens, and the list when none can.
    static func firstMethod(of challenge: MFAChallenge) -> MFAMethod? {
        challenge.methods.first { $0 != .webauthn }
    }

    /// "Return to Login", and the way back from the second factor.
    func returnToLogin() {
        challenge = nil
        method = nil
        code = ""
        smsDestination = nil
        fieldErrors = [:]
        notice = nil
        page = .credentials
    }

    /// "Forgot your password?": Discord emails the account. A phone number
    /// goes to Discord's site instead, which can text a code (D10).
    func resetPassword() async -> Bool {
        let trimmed = login.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            fieldErrors[.login] = "Enter your email to reset your password."
            rejections += 1
            return true
        }
        guard !isPhoneLogin else { return false }
        isWorking = true
        notice = nil
        defer { isWorking = false }
        do {
            try await service.requestPasswordReset(login: trimmed)
            notice = .resetSent(trimmed)
        } catch {
            take(error, on: .credentials)
        }
        return true
    }

    // MARK: The second factor

    /// A method picked from the list, or the list itself with nil.
    func choose(_ method: MFAMethod?) {
        self.method = method
        code = ""
        fieldErrors[.code] = nil
        if method == .sms, smsDestination == nil { Task { await sendSMS() } }
    }

    func sendSMS() async {
        guard let challenge, !isSendingSMS else { return }
        isSendingSMS = true
        defer { isSendingSMS = false }
        do {
            smsDestination = try await service.sendSMS(for: challenge) ?? "your phone"
        } catch {
            take(error, on: .mfa)
        }
    }

    func submitCode() async {
        guard let challenge, let method, canSubmitCode else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let token = try await service.verify(method, code: code, challenge: challenge)
            guard !isFinished else { return }
            finish(token)
        } catch {
            guard !isFinished else { return }
            // A wrong code is cleared, so the next one can just be typed — and
            // cleared first, since clearing it takes its complaint with it.
            code = ""
            take(error, on: .mfa)
        }
    }

    // MARK: The QR code

    /// Runs the code for as long as the screen is up: the screen's task.
    func runQR() async {
        for await event in service.qrEvents() {
            guard !isFinished else { return }
            switch event {
            case .connecting, .interrupted:
                qr = .connecting
            case .ready(let url, _):
                qr = .ready(url)
            case .scanned(let user):
                qr = .scanned(user)
            case .loggingIn:
                qr = .loggingIn
            case .failed(let refusal):
                // Said where the form is: the code is about to be replaced, and a
                // fresh code on its own reads as nothing having happened.
                qr = .connecting
                notice = .failed(Self.qrFailure(refusal))
            case .token(let token):
                finish(token)
            }
        }
    }

    /// Why a QR login the phone approved didn't finish, in a sentence.
    static func qrFailure(_ refusal: AuthRefusal?) -> String {
        switch refusal {
        case .captcha:
            "Your phone approved it, but Discord's human check wasn't passed. Scan the new code to try again."
        case .rateLimited:
            "Your phone approved it, but Discord asked to slow down. Wait a moment, then scan the new code."
        case .other(_, _, let message?):
            "Your phone approved it, but Discord said: \(message) Scan the new code to try again."
        default:
            "Your phone approved it, but the login didn't finish. Scan the new code to try again."
        }
    }

    /// "Not me, start over": a new key, a new code.
    func restartQR() {
        qr = .connecting
        qrGeneration += 1
    }

    // MARK: Answers

    /// A refusal, said where it belongs.
    func take(_ error: any Error, on page: Page) {
        rejections += 1
        guard let refusal = error as? AuthRefusal else {
            notice = .failed(Self.describe(error))
            return
        }
        switch refusal {
        case .form(let fields):
            if let location = fields.values.first(where: { $0.code == "ACCOUNT_LOGIN_VERIFICATION_EMAIL" }) {
                notice = .newLocation(location.message)
                return
            }
            for (name, field) in fields {
                switch name {
                case "login", "email": fieldErrors[.login] = field.message
                case "password": fieldErrors[.password] = field.message
                case "code": fieldErrors[.code] = field.message
                default: notice = .failed(field.message)
                }
            }
            if page == .mfa, fieldErrors[.code] == nil, let first = fields.values.first {
                fieldErrors[.code] = first.message
            }
        case .wrongCode(let message):
            fieldErrors[.code] = message ?? "Invalid two-factor code"
        case .scheduledForDeletion:
            self.page = .restore(.scheduledForDeletion)
        case .disabled:
            self.page = .restore(.disabled)
        case .phoneVerificationRequired:
            notice = .phoneVerification
        case .suspended:
            notice = .suspended
        case .rateLimited(let retryAfter):
            notice = .tooManyAttempts(until: .now.addingTimeInterval(retryAfter ?? 30))
        case .captcha:
            notice = .failed("The human check wasn't completed. Try again.")
        case .other(_, _, let message):
            notice = .failed(message ?? "Something went wrong. Try again.")
        }
    }

    private static func describe(_ error: any Error) -> String {
        if case DiscordREST.Failure.transport = error {
            return "Couldn't reach Discord. Check your connection and try again."
        }
        return "Something went wrong. Try again."
    }

    private func finish(_ token: String) {
        guard !isFinished else { return }
        isFinished = true
        password = ""
        code = ""
        Task {
            guard let problem = await onToken(token) else { return }
            // The token didn't take: back to the form, saying why, with a new code.
            isFinished = false
            returnToLogin()
            notice = .failed(problem)
            restartQR()
        }
    }
}
