import Foundation
import WingcordCore

/// The reader's own account, as an account-scoped answer carries it —
/// `GET /users/@me` or READY's `user`.
///
/// **The tier and the age status ride beside the user, not on it**, and are
/// nil where the answer did not carry them: they merge into
/// `AccountEntitlements` field by field, so a thinner answer never takes a perk
/// away. See `AccountEntitlements`.
public struct CurrentAccount: Sendable {
    public var user: User
    public var premiumType: Int?
    public var ageVerificationStatus: Int?
    /// Nil where the answer was not the reader's private object.
    public var verification: AccountVerification?
}

extension DiscordREST {

    // MARK: - The signed-in account

    /// The account's own details, beside the public user object.
    ///
    /// **One request for both, because it is one route.** `GET /users/@me`
    /// already runs at launch to validate the token and returns the e-mail, the
    /// phone number and the MFA flag in the same body as the avatar and the
    /// name — they were simply not being decoded. Asking again from the account
    /// page would be a second round trip for bytes the first one already had.
    public func currentAccount() async throws -> (account: CurrentAccount, details: AccountDetails) {
        let dto = try await get("/users/@me", route: "users/@me", as: UserDTO.self)
        return (
            dto.currentAccount,
            AccountDetails(
                email: dto.email,
                phone: dto.phone,
                isEmailVerified: dto.verified ?? false,
                hasMFA: dto.mfa_enabled ?? false
            )
        )
    }

    /// Sends the account's confirmation e-mail again — Discord's
    /// `verifyResend`, the Verify and Resend Email of an application form's
    /// e-mail row. `POST /auth/verify/resend`, no body. Not captured.
    public func resendVerificationEmail() async throws {
        _ = try await requestData(
            method: "POST",
            path: "/auth/verify/resend",
            route: "auth/verify/resend",
            body: Optional<String>.none
        )
    }

    /// Everywhere the account is signed in.
    ///
    /// **`/auth/sessions`, and the shape is from the unofficial documentation
    /// rather than from a capture.** Nothing in this tree has watched it, so the
    /// decode is deliberately tolerant: every field is optional, an unknown
    /// platform falls through to a globe, and a body that does not match at all
    /// yields an empty list rather than throwing. A page that says "no other
    /// devices" when it cannot read the answer is wrong in the quiet direction;
    /// one that throws takes the whole account pane down with it.
    ///
    /// The **writes** on this surface — signing a session out, changing a
    /// password, enrolling a second factor — are deliberately not here. Each
    /// needs the account's password and, on some accounts, a captcha, and none
    /// of them has been watched on the wire. They are the next pass, not a guess
    /// shipped into somebody's security settings.
    public func authSessions() async throws -> [AuthSession] {
        struct Response: Decodable {
            var user_sessions: [SessionDTO]?
        }
        struct SessionDTO: Decodable {
            var id_hash: String?
            var approx_last_used_time: String?
            var client_info: ClientInfo?
        }
        struct ClientInfo: Decodable {
            var os: String?
            var platform: String?
            var location: String?
        }

        let response = try await get(
            "/auth/sessions",
            route: "auth/sessions",
            as: Response.self
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()

        return (response.user_sessions ?? []).enumerated().map { index, session in
            let stamp = session.approx_last_used_time
            return AuthSession(
                id: session.id_hash ?? "session-\(index)",
                platform: session.client_info?.os,
                client: session.client_info?.platform,
                location: session.client_info?.location,
                lastUsed: stamp.flatMap { formatter.date(from: $0) ?? plain.date(from: $0) },
                // **The route does not flag the current session**, so the
                // client cannot honestly claim one. Better to say nothing than
                // to mark the wrong row "this device".
                isCurrent: false
            )
        }
    }
}
