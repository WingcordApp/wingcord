import Foundation

/// What the account page shows about the signed-in account itself.
///
/// **Separate from `User`, and deliberately.** `User` is what this client knows
/// about *anybody* — it is built for a roster row and a message header, it is
/// held for every person the session has ever seen, and it is merged from six
/// different routes. These four fields exist only for the account that is
/// signed in, arrive only from `GET /users/@me`, and two of them are a phone
/// number and an e-mail address. Putting them on `User` would mean every roster
/// row in the app carried two empty optionals and one real secret.
public struct AccountDetails: Hashable, Sendable {
    /// Nil where the account has none, which is a real state — an account made
    /// through a phone number may have no e-mail at all.
    public let email: String?
    public let phone: String?
    /// Whether the e-mail has been confirmed.
    public let isEmailVerified: Bool
    /// Whether two-factor authentication is on.
    public let hasMFA: Bool

    public init(
        email: String? = nil,
        phone: String? = nil,
        isEmailVerified: Bool = false,
        hasMFA: Bool = false
    ) {
        self.email = email
        self.phone = phone
        self.isEmailVerified = isEmailVerified
        self.hasMFA = hasMFA
    }

    /// An e-mail with its local part covered.
    ///
    /// **The domain stays, and that is the point of masking rather than
    /// hiding.** Somebody glancing at this page needs to recognise *which*
    /// account they are signed in as, and `…@gmail.com` answers that while
    /// `someone@example.com` is a line anybody standing behind them can read.
    /// Discord masks exactly this way.
    public var maskedEmail: String? {
        guard let email, let at = email.firstIndex(of: "@") else { return email }
        return String(repeating: "•", count: email.distance(from: email.startIndex, to: at))
            + email[at...]
    }

    /// A phone number with everything but its last four digits covered.
    public var maskedPhone: String? {
        guard let phone else { return nil }
        let digits = phone.suffix(4)
        guard phone.count > 4 else { return phone }
        return String(repeating: "•", count: phone.count - 4) + digits
    }
}

/// One place the account is signed in.
///
/// **Not a device, a SESSION** — the same Mac signed in through the app and
/// through a browser is two of these, and Discord's own page says so by naming
/// the client rather than the machine.
public struct AuthSession: Hashable, Sendable, Identifiable {
    public let id: String
    /// `macOS`, `iOS`, `Windows`, `Linux`, `Android` — as the route spells it.
    public let platform: String?
    /// `Discord Client`, `Chrome`, `Safari`, `Mobile Safari`.
    public let client: String?
    public let location: String?
    public let lastUsed: Date?
    /// Whether this is the session the client is running in. It cannot be
    /// signed out from here, and the page says so rather than offering a
    /// control that logs the reader out of the window they are looking at.
    public let isCurrent: Bool

    public init(
        id: String,
        platform: String? = nil,
        client: String? = nil,
        location: String? = nil,
        lastUsed: Date? = nil,
        isCurrent: Bool = false
    ) {
        self.id = id
        self.platform = platform
        self.client = client
        self.location = location
        self.lastUsed = lastUsed
        self.isCurrent = isCurrent
    }

    /// The SF Symbol for the platform.
    ///
    /// **A shape, not a picture of a specific Mac.** Discord's own page draws a
    /// photograph of a MacBook for a macOS session, which is wrong about
    /// somebody on an iMac and impossible to keep right as hardware changes —
    /// `desktopcomputer` is true of every one of them.
    public var symbolName: String {
        switch platform?.lowercased() {
        case "ios", "ipados": "iphone"
        case "android": "candybarphone"
        case "macos", "mac os x", "windows", "linux": "desktopcomputer"
        case .none: "questionmark.circle"
        default: "globe"
        }
    }

    /// "macOS · Discord Client", or whichever half the route gave.
    public var title: String {
        [platform, client].compactMap { $0 }.joined(separator: " · ")
    }
}
