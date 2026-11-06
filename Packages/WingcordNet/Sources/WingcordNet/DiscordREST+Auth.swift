import Foundation

// Signing in, as Discord's own client signs in.
//
// **Read out of the web bundle, build 663810**, and never sent against Discord
// before this was written: `830215` holds the action creators (`login`,
// `loginMFAv2`, `forgotPassword`), `572469` the MFA screens, `52423` the QR
// handshake's last step. docs/LOGIN-ONBOARDING.md §3 has the whole of it.
//
// Three things make these routes unlike every other one in this client:
//
//  1. **They go out as nobody.** A sign-in sent with the current account's
//     token tells Discord the two accounts are one person's — Discord's own
//     Add an Account blanks the header for exactly that reason
//     (`headers:{authorization:""}`). So the request is built here with no
//     token at all, whatever the client holds.
//  2. **Their refusals are the answer.** A wrong password, an account waiting
//     to be deleted and a new login location all arrive as 400s whose body says
//     which, and `requestData` would flatten every one into the same
//     `Failure.api`. So the body is read whole, into `AuthRefusal`.
//  3. **They send `X-Fingerprint`**, the id `GET /experiments` hands a client
//     that isn't signed in, as the web client does on every request it makes
//     signed out.

/// A second factor Discord will take for this sign-in.
public enum MFAMethod: String, Sendable, Hashable, CaseIterable {
    /// A passkey or a security key. Listed so it can be explained; this client
    /// can't answer it (docs/LOGIN-ONBOARDING.md §3).
    case webauthn
    /// An authenticator app's six digits.
    case totp
    /// One of the account's eight-character backup codes.
    case backup
    /// Six digits sent by text message, after `sendMFASMS`.
    case sms
}

/// What `POST /auth/login` asks for before it hands over a token.
public struct MFAChallenge: Sendable, Hashable {
    /// Single use, and it expires: every answer to this challenge carries it.
    public var ticket: String
    /// **In Discord's order** (`AuthenticationStore.ea`): webauthn, totp,
    /// backup, sms. Its MFA screen opens on the first.
    public var methods: [MFAMethod]
    public var loginInstanceID: String?

    public init(ticket: String, methods: [MFAMethod], loginInstanceID: String? = nil) {
        self.ticket = ticket
        self.methods = methods
        self.loginInstanceID = loginInstanceID
    }
}

/// How a password sign-in came out.
public enum LoginOutcome: Sendable, Hashable {
    case token(String)
    case mfa(MFAChallenge)
}

/// Discord saying no, in the shape its sign-in screens read.
public enum AuthRefusal: Error, Sendable, Hashable {
    /// A 50035: complaints about named fields — `login`, `password`, `email`,
    /// `code` — each with Discord's own sentence and code. "New login location
    /// detected" is one of these, on `login`, with the code
    /// `ACCOUNT_LOGIN_VERIFICATION_EMAIL`.
    case form([String: FieldError])
    /// 60008: the code was wrong.
    case wrongCode(String?)
    /// 20011: the account is scheduled for deletion. Discord asks whether to
    /// cancel that and sends the same password again with `undelete: true`.
    case scheduledForDeletion
    /// 20013: the account was disabled by its owner; the same question.
    case disabled
    /// 70007: Discord wants the phone number verified from this location.
    case phoneVerificationRequired
    /// The answer carried a `suspended_user_token`: the account is suspended.
    case suspended
    /// Too many tries. `retryAfter` is in seconds, when Discord said.
    case rateLimited(retryAfter: TimeInterval?)
    /// A human check nobody answered.
    case captcha
    /// Anything else, with whatever Discord said.
    case other(status: Int, code: Int?, message: String?)

    public struct FieldError: Sendable, Hashable {
        public var code: String?
        public var message: String

        public init(code: String?, message: String) {
            self.code = code
            self.message = message
        }
    }
}

/// Who scanned the code, as the QR handshake's `pending_ticket` names them.
public struct RemoteAuthUser: Sendable, Hashable {
    public var id: String
    public var discriminator: String
    public var avatarHash: String?
    public var username: String

    public init(id: String, discriminator: String, avatarHash: String?, username: String) {
        self.id = id
        self.discriminator = discriminator
        self.avatarHash = avatarHash
        self.username = username
    }
}

extension DiscordREST {

    // MARK: Routes

    /// The id Discord hands a client that isn't signed in, kept on this client
    /// and sent with every sign-in request after it.
    ///
    /// **Best effort.** The web client sends it when it has one and signs in
    /// without one when it hasn't, so a failure here costs nothing but the
    /// header.
    @discardableResult
    public func fetchFingerprint() async -> String? {
        if let fingerprint { return fingerprint }
        guard let answer = try? await authRequest(
            method: "GET", path: "experiments", route: "GET /experiments", body: Optional<Empty>.none
        ), (200..<300).contains(answer.status),
              let decoded = try? JSONDecoder().decode(FingerprintDTO.self, from: answer.data),
              let value = decoded.fingerprint, !value.isEmpty
        else { return nil }
        fingerprint = value
        return value
    }

    /// For tests, and for a fingerprint carried over from another client.
    public func setFingerprint(_ value: String?) {
        fingerprint = value
    }

    /// `POST /auth/login`.
    ///
    /// - Parameter undelete: true only on the second try, once somebody has said
    ///   yes to cancelling their account's deletion.
    public func logIn(login: String, password: String, undelete: Bool = false) async throws -> LoginOutcome {
        let body = LoginBody(login: login, password: password, undelete: undelete)
        let answer = try await authRequest(method: "POST", path: "auth/login", route: "POST /auth/login", body: body)
        guard (200..<300).contains(answer.status) else {
            throw Self.authRefusal(status: answer.status, data: answer.data, headers: answer.headers)
        }
        let decoded: LoginDTO
        do {
            decoded = try JSONDecoder().decode(LoginDTO.self, from: answer.data)
        } catch {
            throw Failure.decoding("login: \(error)")
        }
        if decoded.mfa == true, let ticket = decoded.ticket {
            return .mfa(MFAChallenge(
                ticket: ticket,
                methods: decoded.methods,
                loginInstanceID: decoded.login_instance_id
            ))
        }
        guard let token = decoded.token, !token.isEmpty else {
            throw Failure.decoding("login: neither a token nor a ticket")
        }
        return .token(token)
    }

    /// `POST /auth/mfa/{totp|sms|backup}`: the second factor, for a token.
    ///
    /// A backup code goes without its dashes, as Discord's screen sends it.
    public func verifyMFA(_ method: MFAMethod, code: String, challenge: MFAChallenge) async throws -> String {
        let cleaned = method == .backup ? code.replacing("-", with: "") : code
        let body = MFABody(code: cleaned, ticket: challenge.ticket, login_instance_id: challenge.loginInstanceID)
        let answer = try await authRequest(
            method: "POST", path: "auth/mfa/\(method.rawValue)", route: "POST /auth/mfa", body: body
        )
        guard (200..<300).contains(answer.status) else {
            throw Self.authRefusal(status: answer.status, data: answer.data, headers: answer.headers)
        }
        guard let decoded = try? JSONDecoder().decode(TokenDTO.self, from: answer.data),
              let token = decoded.token, !token.isEmpty
        else { throw Failure.decoding("mfa: no token") }
        return token
    }

    /// `POST /auth/mfa/sms/send`. Returns the number it went to, masked by
    /// Discord ("+*******1234"), or nil where the answer didn't say.
    public func sendMFASMS(challenge: MFAChallenge) async throws -> String? {
        let answer = try await authRequest(
            method: "POST", path: "auth/mfa/sms/send", route: "POST /auth/mfa/sms/send",
            body: TicketBody(ticket: challenge.ticket)
        )
        guard (200..<300).contains(answer.status) else {
            throw Self.authRefusal(status: answer.status, data: answer.data, headers: answer.headers)
        }
        return (try? JSONDecoder().decode(PhoneDTO.self, from: answer.data))?.phone
    }

    /// `POST /auth/forgot`. Discord emails the account a link.
    public func requestPasswordReset(login: String) async throws {
        let answer = try await authRequest(
            method: "POST", path: "auth/forgot", route: "POST /auth/forgot", body: ForgotBody(login: login)
        )
        guard (200..<300).contains(answer.status) else {
            throw Self.authRefusal(status: answer.status, data: answer.data, headers: answer.headers)
        }
    }

    /// `POST /users/@me/remote-auth/login`: the QR handshake's ticket, for the
    /// token **still encrypted** to the handshake's own key. Only the session
    /// that made the key can read it — see `RemoteAuthSession`.
    public func exchangeRemoteAuthTicket(_ ticket: String) async throws -> String {
        let answer = try await authRequest(
            method: "POST", path: "users/@me/remote-auth/login", route: "POST /users/@me/remote-auth/login",
            body: TicketBody(ticket: ticket)
        )
        guard (200..<300).contains(answer.status) else {
            throw Self.authRefusal(status: answer.status, data: answer.data, headers: answer.headers)
        }
        guard let decoded = try? JSONDecoder().decode(EncryptedTokenDTO.self, from: answer.data),
              let token = decoded.encrypted_token, !token.isEmpty
        else { throw Failure.decoding("remote auth: no encrypted token") }
        return token
    }

    // MARK: The request

    /// Sends one sign-in request and hands back the answer whole.
    ///
    /// **As nobody, always** — see the note at the top. A human check is put on
    /// screen and the request sent once more with its answer, exactly as
    /// `requestData` does; a second challenge is reported, not presented.
    func authRequest<Body: Encodable>(
        method: String,
        path: String,
        route: String,
        body: Body?
    ) async throws -> (data: Data, status: Int, headers: [AnyHashable: Any]) {
        await limiter.acquire(route: route)
        var request = URLRequest(url: metadata.apiBase.appending(path: path))
        request.httpMethod = method
        metadata.apply(to: &request, token: nil)
        if let fingerprint { request.setValue(fingerprint, forHTTPHeaderField: "X-Fingerprint") }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        var (data, http) = try await sendAuth(request)
        await limiter.update(route: route, headers: http.allHeaderFields, statusCode: http.statusCode)
        if http.statusCode == 400, let solution = await solveCaptcha(in: data) {
            solution.apply(to: &request)
            (data, http) = try await sendAuth(request)
            await limiter.update(route: route, headers: http.allHeaderFields, statusCode: http.statusCode)
        }
        return (data, http.statusCode, http.allHeaderFields)
    }

    private func sendAuth(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw Failure.transport("no HTTP response")
        }
        return (data, http)
    }

    // MARK: Reading a refusal

    /// A sign-in refusal, read the way Discord's screens read it.
    ///
    /// **Order matters**: a suspended account's answer can carry a code as
    /// well, and Discord checks `suspended_user_token` first; a captcha that
    /// was never answered still looks like a captcha envelope.
    nonisolated static func authRefusal(status: Int, data: Data, headers: [AnyHashable: Any] = [:]) -> AuthRefusal {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let suspended = root?["suspended_user_token"] as? String, !suspended.isEmpty {
            return .suspended
        }
        if status == 429 {
            let header = headers.first { ($0.key as? String)?.lowercased() == "retry-after" }?.value
            let fromHeader = (header as? String).flatMap(TimeInterval.init) ?? (header as? NSNumber)?.doubleValue
            let fromBody = (root?["retry_after"] as? NSNumber)?.doubleValue
            return .rateLimited(retryAfter: fromBody ?? fromHeader)
        }
        if captchaChallenge(in: data) != nil {
            return .captcha
        }
        let code = (root?["code"] as? NSNumber)?.intValue
        let message = root?["message"] as? String
        switch code {
        case 20011: return .scheduledForDeletion
        case 20013: return .disabled
        case 70007: return .phoneVerificationRequired
        case 60008: return .wrongCode(message)
        default: break
        }
        if let fields = formErrors(in: root), !fields.isEmpty {
            return .form(fields)
        }
        return .other(status: status, code: code, message: message)
    }

    /// `errors`, flattened as Discord's `oldFormErrors` flattens it
    /// (`636537.ni`): a field's first `_errors` entry, and a top-level
    /// `_errors` filed under `_misc`.
    nonisolated static func formErrors(in root: [String: Any]?) -> [String: AuthRefusal.FieldError]? {
        guard let errors = root?["errors"] as? [String: Any] else { return nil }
        var fields: [String: AuthRefusal.FieldError] = [:]
        for (name, value) in errors {
            if name == "_errors" {
                if let first = (value as? [[String: Any]])?.first, let message = first["message"] as? String {
                    fields["_misc"] = .init(code: first["code"] as? String, message: message)
                }
                continue
            }
            guard let entry = value as? [String: Any],
                  let first = (entry["_errors"] as? [[String: Any]])?.first,
                  let message = first["message"] as? String
            else { continue }
            fields[name] = .init(code: first["code"] as? String, message: message)
        }
        return fields
    }
}

// MARK: - Bodies and answers

private struct Empty: Encodable {}

/// Discord's own shape: `login_source` and `gift_code_sku_id` are always sent,
/// null when there's neither an invite nor a gift behind the sign-in.
private struct LoginBody: Encodable {
    var login: String
    var password: String
    var undelete: Bool
    var login_source: String? = nil
    var gift_code_sku_id: String? = nil

    enum CodingKeys: String, CodingKey { case login, password, undelete, login_source, gift_code_sku_id }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(login, forKey: .login)
        try container.encode(password, forKey: .password)
        try container.encode(undelete, forKey: .undelete)
        try container.encode(login_source, forKey: .login_source)
        try container.encode(gift_code_sku_id, forKey: .gift_code_sku_id)
    }
}

private struct MFABody: Encodable {
    var code: String
    var ticket: String
    var login_instance_id: String?
    var login_source: String? = nil
    var gift_code_sku_id: String? = nil

    enum CodingKeys: String, CodingKey { case code, ticket, login_instance_id, login_source, gift_code_sku_id }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(ticket, forKey: .ticket)
        try container.encode(login_source, forKey: .login_source)
        try container.encode(gift_code_sku_id, forKey: .gift_code_sku_id)
        try container.encodeIfPresent(login_instance_id, forKey: .login_instance_id)
    }
}

private struct TicketBody: Encodable { var ticket: String }
private struct ForgotBody: Encodable { var login: String }

private struct FingerprintDTO: Decodable { var fingerprint: String? }
private struct TokenDTO: Decodable { var token: String? }
private struct PhoneDTO: Decodable { var phone: String? }
private struct EncryptedTokenDTO: Decodable { var encrypted_token: String? }

private struct LoginDTO: Decodable {
    var token: String?
    var mfa: Bool?
    var ticket: String?
    var totp: Bool?
    var sms: Bool?
    var backup: Bool?
    /// A JSON string — the WebAuthn request options — or null.
    var webauthn: String?
    var login_instance_id: String?

    /// `AuthenticationStore.ea`'s order.
    var methods: [MFAMethod] {
        var methods: [MFAMethod] = []
        if let webauthn, !webauthn.isEmpty { methods.append(.webauthn) }
        if totp == true { methods.append(.totp) }
        if backup == true { methods.append(.backup) }
        if sms == true { methods.append(.sms) }
        return methods
    }
}
