import Foundation
import WingcordCore
import WingcordNet

/// What the sign-in screen asks of Discord, behind one seam so `--demo` and the
/// tests can answer instead.
protocol SignInService: AnyObject, Sendable {
    /// Called when the screen comes up: the fingerprint, before the first try.
    func prepare() async
    /// Somebody who can put a captcha on screen. The live client has its own
    /// REST actor — it goes out as nobody — so it needs its own installation.
    func installCaptchaSolver(_ solver: CaptchaSolver) async
    func logIn(login: String, password: String, undelete: Bool) async throws -> LoginOutcome
    func verify(_ method: MFAMethod, code: String, challenge: MFAChallenge) async throws -> String
    func sendSMS(for challenge: MFAChallenge) async throws -> String?
    func requestPasswordReset(login: String) async throws
    /// The QR code's life. A new call is a new key.
    func qrEvents() -> AsyncStream<RemoteAuthEvent>
}

/// Discord, through a client of its own that never holds a token.
///
/// **Its own `DiscordREST`, not the session's.** The session's client carries
/// the signed-in account's token while Add an Account is up, and every request
/// it makes goes out as that account; the auth routes refuse to send one
/// anyway (`DiscordREST+Auth`), but a client with nothing to leak can't leak it.
nonisolated final class LiveSignInService: SignInService {
    private let rest: DiscordREST

    init(metadata: ClientMetadata) {
        rest = DiscordREST(metadata: metadata)
    }

    func prepare() async {
        await rest.fetchFingerprint()
    }

    func installCaptchaSolver(_ solver: CaptchaSolver) async {
        await rest.setCaptchaSolver(CaptchaBridge { solver })
    }

    func logIn(login: String, password: String, undelete: Bool) async throws -> LoginOutcome {
        try await rest.logIn(login: login, password: password, undelete: undelete)
    }

    func verify(_ method: MFAMethod, code: String, challenge: MFAChallenge) async throws -> String {
        try await rest.verifyMFA(method, code: code, challenge: challenge)
    }

    func sendSMS(for challenge: MFAChallenge) async throws -> String? {
        try await rest.sendMFASMS(challenge: challenge)
    }

    func requestPasswordReset(login: String) async throws {
        try await rest.requestPasswordReset(login: login)
    }

    func qrEvents() -> AsyncStream<RemoteAuthEvent> {
        RemoteAuthSession(rest: rest).events()
    }
}

/// `--demo`'s sign-in: Discord's answers, made up, at Discord's pace.
///
/// **Nothing here reaches Discord or the Keychain** (INVARIANTS §4.898). The
/// script, which docs/LOGIN-ONBOARDING.md also lists:
///
/// - any login and password → the MFA page (app, backup code, text message);
/// - the password `wrong` → "Login or password is invalid.";
/// - a login starting `new` → the new login location notice;
/// - a login starting `deleted` → scheduled for deletion, then Restore Account;
/// - a login starting `disabled` → disabled, the same;
/// - the code `000000` → "Invalid two-factor code", any other six digits → in;
/// - the QR code is scanned by clicking it (`scan()`), so it never signs in
///   behind somebody typing a password.
@MainActor
final class DemoSignInService: SignInService {
    private var scans: [AsyncStream<Void>.Continuation] = []

    nonisolated func prepare() async {}
    nonisolated func installCaptchaSolver(_ solver: CaptchaSolver) async {}

    nonisolated func logIn(login: String, password: String, undelete: Bool) async throws -> LoginOutcome {
        try await Task.sleep(for: .milliseconds(700))
        let lowered = login.lowercased()
        if password == "wrong" {
            let invalid = AuthRefusal.FieldError(code: "INVALID_LOGIN", message: "Login or password is invalid.")
            throw AuthRefusal.form(["login": invalid, "password": invalid])
        }
        if lowered.hasPrefix("new") {
            throw AuthRefusal.form(["login": .init(
                code: "ACCOUNT_LOGIN_VERIFICATION_EMAIL",
                message: "New login location detected, please check your e-mail."
            )])
        }
        if lowered.hasPrefix("deleted"), !undelete { throw AuthRefusal.scheduledForDeletion }
        if lowered.hasPrefix("disabled"), !undelete { throw AuthRefusal.disabled }
        return .mfa(MFAChallenge(ticket: "demo-ticket", methods: [.totp, .backup, .sms], loginInstanceID: "demo"))
    }

    nonisolated func verify(_ method: MFAMethod, code: String, challenge: MFAChallenge) async throws -> String {
        try await Task.sleep(for: .milliseconds(600))
        if code == "000000" { throw AuthRefusal.wrongCode("Invalid two-factor code") }
        return "demo-token"
    }

    nonisolated func sendSMS(for challenge: MFAChallenge) async throws -> String? {
        try await Task.sleep(for: .milliseconds(500))
        return "+*******1234"
    }

    nonisolated func requestPasswordReset(login: String) async throws {
        try await Task.sleep(for: .milliseconds(500))
    }

    nonisolated func qrEvents() -> AsyncStream<RemoteAuthEvent> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                continuation.yield(.connecting)
                try? await Task.sleep(for: .milliseconds(900))
                let fingerprint = Self.fakeFingerprint()
                continuation.yield(.ready(url: RemoteAuthHandshake.codeURL(fingerprint: fingerprint), fingerprint: fingerprint))
                let (scanned, scan) = AsyncStream<Void>.makeStream()
                self.scans.append(scan)
                for await _ in scanned { break }
                guard !Task.isCancelled else { return }
                let me = DemoFixtures.demoSignInAccount
                continuation.yield(.scanned(RemoteAuthUser(
                    id: me.id, discriminator: "0", avatarHash: me.avatarHash, username: me.username
                )))
                try? await Task.sleep(for: .seconds(2.4))
                guard !Task.isCancelled else { return }
                continuation.yield(.loggingIn)
                try? await Task.sleep(for: .milliseconds(700))
                continuation.yield(.token("demo-qr-token"))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A click on the code: the phone the demo doesn't have scans it.
    func scan() {
        for scan in scans { scan.yield() }
        scans.removeAll()
    }

    private static func fakeFingerprint() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return String((0..<43).map { _ in alphabet.randomElement()! })
    }
}
