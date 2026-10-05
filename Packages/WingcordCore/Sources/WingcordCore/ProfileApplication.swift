import Foundation

/// An app's own facts, as its profile carries them — the `application` object
/// `GET /users/{id}/profile` answers beside a bot, which Discord's profile
/// store keeps as `flags`, its install routes, its storefront and its two
/// policy links.
public struct ProfileApplication: Hashable, Sendable, Codable {
    public var id: ApplicationID
    /// The application's flags — the gateway intents it was granted among them.
    public var flags: UInt64
    /// Where its developer installs it instead of Discord's own sheet.
    public var customInstallURL: URL?
    /// It declares how it is installed: `install_params`, or install
    /// parameters under one of its integration types.
    public var declaresInstall: Bool
    public var hasStorefront: Bool
    public var termsOfServiceURL: URL?
    public var privacyPolicyURL: URL?

    public init(
        id: ApplicationID,
        flags: UInt64 = 0,
        customInstallURL: URL? = nil,
        declaresInstall: Bool = false,
        hasStorefront: Bool = false,
        termsOfServiceURL: URL? = nil,
        privacyPolicyURL: URL? = nil
    ) {
        self.id = id
        self.flags = flags
        self.customInstallURL = customInstallURL
        self.declaresInstall = declaresInstall
        self.hasStorefront = hasStorefront
        self.termsOfServiceURL = termsOfServiceURL
        self.privacyPolicyURL = privacyPolicyURL
    }

    /// What it can read beyond the baseline every app has.
    public enum DataAccess: Hashable, Sendable, CaseIterable {
        case messageContent
        case presence
        case members
    }

    /// Discord's `203363`, in its order: an intent counts in its full or its
    /// limited form — `GATEWAY_MESSAGE_CONTENT` (1 << 18 or 19),
    /// `GATEWAY_PRESENCE` (12 or 13), `GATEWAY_GUILD_MEMBERS` (14 or 15).
    public var dataAccess: [DataAccess] {
        func has(_ full: UInt64, _ limited: UInt64) -> Bool { flags & (1 << full | 1 << limited) != 0 }
        var access: [DataAccess] = []
        if has(18, 19) { access.append(.messageContent) }
        if has(12, 13) { access.append(.presence) }
        if has(14, 15) { access.append(.members) }
        return access
    }

    /// Discord's `Ie`: whether Add App has anywhere to go.
    public var isInstallable: Bool { customInstallURL != nil || declaresInstall }
}
