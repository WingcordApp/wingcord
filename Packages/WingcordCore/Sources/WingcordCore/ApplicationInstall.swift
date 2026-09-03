import Foundation

// MARK: - Adding an application
//
// "Add App" is an **install**, not an authorization-code grant, and the wire
// says so: the activity flow sends `response_type=code` and `state` and reads a
// `code` back out of the redirect, where this sends neither and gets
// `{"location":"https://discord.com/oauth2/authorized"}` with nothing to
// exchange. Same route, two flows, and folding them together would mean sending
// a `response_type` the reference client does not.
//
// Captured in `owo 2.har` (2026-09-03): both halves, user install and server
// install, request and response.

/// Where an application is being added.
///
/// The wire's own numbers, and they decide the scopes, the permissions and the
/// shape of the sheet — `integration_types_config` is keyed by exactly these.
public enum IntegrationType: Int, Hashable, Sendable {
    /// Added to a server. Carries the `bot` scope and a permission bitfield.
    case guildInstall = 0
    /// Added to the reader's own account, usable everywhere. No permissions —
    /// the captured install sends `"0"`.
    case userInstall = 1
}

/// What one install of an application asks for.
///
/// **Read from `integration_types_config`, never assumed.** OwO declares
/// `applications.commands` alone for a user install and
/// `applications.commands bot` plus `277025754184` for a server one; an app that
/// declares something else gets what it declared.
public struct InstallParameters: Hashable, Sendable {
    public var scopes: [String]
    public var permissions: Permissions

    public init(scopes: [String], permissions: Permissions) {
        self.scopes = scopes
        self.permissions = permissions
    }
}

/// A server the reader could add an application to.
///
/// The install route answers these itself — 95 of them on the captured account —
/// each with the reader's own permissions in it, which is what decides whether
/// it may be offered at all.
public struct InstallableGuild: Hashable, Sendable, Identifiable {
    public var id: GuildID
    public var name: String
    public var iconHash: String?
    public var permissions: Permissions
    /// Whether the server requires two-factor for privileged actions. Carried
    /// because an account without 2FA cannot complete the install into one, and
    /// the failure otherwise arrives as an opaque 400.
    public var requiresMFA: Bool

    public init(
        id: GuildID,
        name: String,
        iconHash: String? = nil,
        permissions: Permissions = [],
        requiresMFA: Bool = false
    ) {
        self.id = id
        self.name = name
        self.iconHash = iconHash
        self.permissions = permissions
        self.requiresMFA = requiresMFA
    }

    /// **`MANAGE_GUILD` is the gate Discord's own sheet states in words** —
    /// "This requires you to have Manage Server permission in the server." An
    /// administrator holds it implicitly.
    public var canInstall: Bool {
        permissions.contains(.administrator) || permissions.contains(.manageGuild)
    }
}

/// Everything the Add App sheet needs for one integration type.
public struct ApplicationInstall: Hashable, Sendable {
    public var applicationID: ApplicationID
    public var name: String
    public var iconHash: String?
    public var summary: String
    public var isVerified: Bool
    /// Whether this application sells anything. Paired with
    /// `hasStorefront` — an app can be monetized without a published store.
    public var isMonetized: Bool
    /// **The store gate, and it needs no extra request.** `storefront_available`
    /// arrives on the application object itself, so an app's page knows whether
    /// to offer a store before fetching one. `INVARIANTS.md` §5.5 asks for a
    /// surface to be gated on an *answer* rather than on a flag that implies it;
    /// this is the answer, stated by Discord about its own storefront.
    public var hasStorefront: Bool
    public var integrationType: IntegrationType
    public var parameters: InstallParameters
    /// Whether the reader has already added it this way.
    public var isAuthorized: Bool
    /// Only on a server install. Empty for a user install, where there is
    /// nothing to pick.
    public var guilds: [InstallableGuild]
    public var termsOfServiceURL: URL?
    public var privacyPolicyURL: URL?

    public init(
        applicationID: ApplicationID,
        name: String,
        iconHash: String? = nil,
        summary: String = "",
        isVerified: Bool = false,
        isMonetized: Bool = false,
        hasStorefront: Bool = false,
        integrationType: IntegrationType,
        parameters: InstallParameters,
        isAuthorized: Bool = false,
        guilds: [InstallableGuild] = [],
        termsOfServiceURL: URL? = nil,
        privacyPolicyURL: URL? = nil
    ) {
        self.applicationID = applicationID
        self.name = name
        self.iconHash = iconHash
        self.summary = summary
        self.isVerified = isVerified
        self.isMonetized = isMonetized
        self.hasStorefront = hasStorefront
        self.integrationType = integrationType
        self.parameters = parameters
        self.isAuthorized = isAuthorized
        self.guilds = guilds
        self.termsOfServiceURL = termsOfServiceURL
        self.privacyPolicyURL = privacyPolicyURL
    }

    /// The servers worth offering, best first.
    ///
    /// **Servers the reader cannot install into are dropped, not dimmed.** The
    /// permission is one they would have to be granted by somebody else, and a
    /// list of ninety-five rows with four usable ones is a list nobody reads.
    public var installableGuilds: [InstallableGuild] {
        guilds.filter(\.canInstall).sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }
}
