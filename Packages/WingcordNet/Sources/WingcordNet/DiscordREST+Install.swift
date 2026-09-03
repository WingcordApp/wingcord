import Foundation
import WingcordCore

// MARK: - Add App
//
// Captured in `owo 2.har` (2026-09-03): both halves of both flows.
//
// **This is not the activity's grant, and the query is what says so.** An
// activity authorizes with `response_type=code` and a `state`, and reads a
// `code` out of the redirect to hand to its own backend. An install sends
// neither and gets back `{"location":"https://discord.com/oauth2/authorized"}`
// with nothing to exchange — there is no third party here, only Discord
// recording that the reader added the app.

extension DiscordREST {

    /// What to show before somebody adds an application.
    ///
    /// `authorized` says whether the grant already exists, and the server list —
    /// 95 rows on the captured account, each with the reader's own permissions —
    /// arrives on the guild-install form and only that one.
    public func applicationInstall(
        _ id: ApplicationID,
        integrationType: IntegrationType
    ) async throws -> ApplicationInstall {
        // **The scopes are the application's own, and they are asked for
        // first.** The captured GET already carries the scopes it is about to
        // request, which means the client knew them before it called — from
        // `integration_types_config` on the application object. This resolves
        // them the same way, and falls back to the pair the capture shows for
        // the type where the application declares nothing.
        let declared = try await applicationPublicInfo(id).parameters
        let parameters = declared[integrationType] ?? Self.defaultInstallParameters(integrationType)

        let dto = try await get(
            "/oauth2/authorize",
            route: "oauth2/authorize",
            query: [
                URLQueryItem(name: "client_id", value: id.description),
                // Space-separated, and `URLQueryItem` percent-encodes it: the
                // capture's `%20` is that, not a different delimiter.
                URLQueryItem(name: "scope", value: parameters.scopes.joined(separator: " ")),
                URLQueryItem(name: "integration_type", value: String(integrationType.rawValue)),
            ],
            as: InstallDTO.self
        )
        guard let application = dto.application, let applicationID = application.id else {
            throw Failure.decoding("oauth2/authorize answered with no application")
        }
        return ApplicationInstall(
            applicationID: applicationID,
            name: application.name ?? "",
            iconHash: application.icon,
            summary: application.description ?? "",
            isVerified: application.is_verified ?? false,
            isMonetized: application.is_monetized ?? false,
            hasStorefront: application.storefront_available ?? false,
            integrationType: integrationType,
            parameters: application.parameters(for: integrationType) ?? parameters,
            isAuthorized: dto.authorized ?? false,
            guilds: (dto.guilds ?? []).compactMap(\.domain),
            termsOfServiceURL: application.terms_of_service_url.flatMap(URL.init(string:)),
            privacyPolicyURL: application.privacy_policy_url.flatMap(URL.init(string:))
        )
    }

    /// Adds it. Answers a redirect this client reads nothing out of.
    ///
    /// **`location_context` describes where the reader was**, not where the app
    /// is going: both captured installs were made from a direct message and both
    /// carry `{"guild_id": "10000", "channel_id": …, "channel_type": 1}` — the
    /// same `10000` sentinel the activity grant already sends for "no guild".
    /// The server being installed into is `guild_id` at the top level.
    public func installApplication(
        _ id: ApplicationID,
        integrationType: IntegrationType,
        parameters: InstallParameters,
        guildID: GuildID?,
        from channelID: ChannelID,
        channelKind: Int,
        currentGuildID: GuildID?
    ) async throws {
        struct LocationContext: Encodable {
            var guild_id: String
            var channel_id: String
            var channel_type: Int
        }
        struct Body: Encodable {
            /// Only on a server install; the user-install capture omits the key.
            var guild_id: String?
            /// The application's declared bitfield, as a decimal string. `"0"`
            /// for a user install.
            var permissions: String
            var authorize = true
            var integration_type: Int
            var location_context: LocationContext
        }
        struct Response: Decodable { var location: String? }

        _ = try await request(
            method: "POST",
            path: "/oauth2/authorize",
            route: "oauth2/authorize",
            query: [
                URLQueryItem(name: "client_id", value: id.description),
                URLQueryItem(name: "scope", value: parameters.scopes.joined(separator: " ")),
            ],
            body: Body(
                guild_id: guildID?.description,
                permissions: String(parameters.permissions.rawValue),
                integration_type: integrationType.rawValue,
                location_context: LocationContext(
                    guild_id: currentGuildID?.description ?? Self.dmLocationGuildID,
                    channel_id: channelID.description,
                    channel_type: channelKind
                )
            ),
            as: Response.self
        )
    }

    /// What an application declares about itself: the scopes and permissions it
    /// asks for, and whether it has a storefront.
    ///
    /// `GET /applications/{id}/public` — the same 1,359-byte route the Add App
    /// sheet's own capture calls twice before opening. **`storefront_available`
    /// is the store gate**, and it arrives here rather than needing a store
    /// fetch to discover: §5.5 asks a surface to be offered on an answer, and
    /// this is Discord's answer about its own storefront.
    public func applicationPublicInfo(
        _ id: ApplicationID
    ) async throws -> (parameters: [IntegrationType: InstallParameters], hasStorefront: Bool) {
        let dto = try await get(
            "/applications/\(id.rawValue)/public",
            route: "applications/:id/public",
            query: [URLQueryItem(name: "with_guild", value: "false")],
            as: InstallDTO.ApplicationDTO.self
        )
        var result: [IntegrationType: InstallParameters] = [:]
        for type in [IntegrationType.guildInstall, .userInstall] {
            result[type] = dto.parameters(for: type)
        }
        return (result, dto.storefront_available ?? false)
    }

    /// What the capture sends where an application declares nothing.
    ///
    /// A user install asks for commands and no permissions; a server install
    /// asks for commands and a bot, with whatever the app declared — and an app
    /// that declared nothing gets none rather than a guess at what it wanted.
    static func defaultInstallParameters(_ type: IntegrationType) -> InstallParameters {
        switch type {
        case .userInstall: InstallParameters(scopes: ["applications.commands"], permissions: [])
        case .guildInstall:
            InstallParameters(scopes: ["applications.commands", "bot"], permissions: [])
        }
    }
}

/// `GET /oauth2/authorize` for an install.
struct InstallDTO: Decodable, Sendable {
    var application: ApplicationDTO?
    var authorized: Bool?
    var integration_type: Int?
    /// Only on the server form. 95 entries on the captured account.
    var guilds: [GuildDTO]?

    struct ApplicationDTO: Decodable, Sendable {
        var id: ApplicationID?
        var name: String?
        var icon: String?
        var description: String?
        var is_verified: Bool?
        var is_monetized: Bool?
        /// **The store gate.** True on OwO, which has one.
        var storefront_available: Bool?
        var bot_public: Bool?
        var terms_of_service_url: String?
        var privacy_policy_url: String?
        /// The legacy single form, kept as the fallback for an application that
        /// predates the per-type config.
        var install_params: ParamsDTO?
        /// Keyed by the integration type **as a string** — `"0"` and `"1"` —
        /// because JSON has no integer keys.
        var integration_types_config: [String: ConfigDTO]?

        struct ConfigDTO: Decodable, Sendable {
            var oauth2_install_params: ParamsDTO?
        }

        struct ParamsDTO: Decodable, Sendable {
            var scopes: [String]?
            /// A decimal string, like every other permission bitfield here.
            var permissions: String?

            var domain: InstallParameters? {
                guard let scopes, !scopes.isEmpty else { return nil }
                return InstallParameters(
                    scopes: scopes,
                    permissions: Permissions(string: permissions ?? "0")
                )
            }
        }

        func parameters(for type: IntegrationType) -> InstallParameters? {
            integration_types_config?[String(type.rawValue)]?.oauth2_install_params?.domain
                ?? install_params?.domain
        }
    }

    struct GuildDTO: Decodable, Sendable {
        var id: GuildID?
        var name: String?
        var icon: String?
        var permissions: String?
        /// `1` means the server requires two-factor for privileged actions.
        var mfa_level: Int?

        var domain: InstallableGuild? {
            guard let id else { return nil }
            return InstallableGuild(
                id: id,
                name: name ?? id.description,
                iconHash: icon,
                permissions: Permissions(string: permissions ?? "0"),
                requiresMFA: (mfa_level ?? 0) > 0
            )
        }
    }
}
