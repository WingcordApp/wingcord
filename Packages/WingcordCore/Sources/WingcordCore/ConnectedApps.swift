import Foundation

// MARK: - Connections and Authorized Apps
//
// Two lists behind one settings section: which third-party accounts this
// account has linked (`GET /users/@me/connections`) and which third-party
// applications it has handed an OAuth2 token (`GET /oauth2/tokens`). Neither
// arrives on READY, so both are asked for once when the pane opens rather
// than kept resident like the roster — see `SessionController+ConnectedApps`.
//
// Every field below is captured, not documented: both routes are
// undocumented, and `ConnectedAppsDecodeTests` pins the exact payloads they
// were read from.

/// One linked third-party account — Spotify, Steam, GitHub, and so on.
public struct AccountConnection: Hashable, Sendable, Identifiable {
    /// The connection's own id on its platform — a Spotify account id, not a
    /// Discord snowflake. What `PATCH`/`DELETE` address it by, alongside `type`.
    public var id: String
    /// The raw platform key Discord's routes take — `"spotify"`, `"steam"` —
    /// and what `ConnectionPlatform` is looked up by.
    public var type: String
    /// The account's own name on that platform.
    public var name: String
    public var isVerified: Bool
    /// "Display \(platform) as your status" — whether this connection's
    /// activity may be shown as the account's presence.
    public var showsActivity: Bool
    /// "Display on profile". The wire's `visibility` is `0`/`1`; this is that
    /// fact as a `Bool` — `false` on write, an `Int` on every read, and both
    /// forms are real: `ConnectedAppsDecodeTests` pins both.
    public var isVisibleOnProfile: Bool
    public var isFriendSyncEnabled: Bool
    /// Whether Discord itself considers the credential dead. A revoked
    /// connection cannot report activity or a status, whatever the two
    /// switches above say — captured as `false` on every connection seen so
    /// far, so this client has never observed the alternative.
    public var isRevoked: Bool

    public init(
        id: String,
        type: String,
        name: String,
        isVerified: Bool,
        showsActivity: Bool,
        isVisibleOnProfile: Bool,
        isFriendSyncEnabled: Bool,
        isRevoked: Bool
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.isVerified = isVerified
        self.showsActivity = showsActivity
        self.isVisibleOnProfile = isVisibleOnProfile
        self.isFriendSyncEnabled = isFriendSyncEnabled
        self.isRevoked = isRevoked
    }
}

/// `GET /oauth2/tokens` — one row: an OAuth2 grant this account made to a
/// third-party application, and the application it named.
public struct AuthorizedApp: Hashable, Sendable, Identifiable {
    /// The grant's own id — a genuine snowflake, and the one
    /// `DELETE /oauth2/tokens/{id}` takes.
    public var id: OAuthGrantID
    public var applicationID: ApplicationID
    public var name: String
    public var iconHash: String?
    /// Empty more often than not: most of this app's own captures carry `""`
    /// here, which reads as "the developer wrote nothing" rather than as an
    /// absence to apologise for.
    public var description: String
    public var isVerified: Bool
    /// What the grant actually lets the application do. Order is the wire's.
    public var scopes: [String]
    public var termsOfServiceURL: URL?
    public var privacyPolicyURL: URL?

    public init(
        id: OAuthGrantID,
        applicationID: ApplicationID,
        name: String,
        iconHash: String?,
        description: String,
        isVerified: Bool,
        scopes: [String],
        termsOfServiceURL: URL? = nil,
        privacyPolicyURL: URL? = nil
    ) {
        self.id = id
        self.applicationID = applicationID
        self.name = name
        self.iconHash = iconHash
        self.description = description
        self.isVerified = isVerified
        self.scopes = scopes
        self.termsOfServiceURL = termsOfServiceURL
        self.privacyPolicyURL = privacyPolicyURL
    }

    /// **There is no date field on the wire.** Discord's own client reads this
    /// off the grant id, which is a snowflake like any other — verified by
    /// decoding a captured id and landing on the exact day its screenshot
    /// showed.
    public var authorizedAt: Date { id.timestamp }
}

// MARK: - Domain connections
//
// The one platform that is not a browser redirect. Discord verifies a
// personal domain in-app: `POST /users/@me/connections/domain/{domain}`
// answers with a proof token whether or not the domain has been proven yet —
// captured live, against a domain the account does not own, which is exactly
// the "not yet" case this exists to carry.

/// `POST /users/@me/connections/domain/{domain}` either way.
public enum DomainConnectionOutcome: Sendable {
    /// Not yet proven. `proof` is what to publish — as a DNS TXT record at
    /// `_discord.<domain>`, or as the contents of a file at
    /// `<domain>/.well-known/discord` — before asking again.
    case pending(proof: String)
    /// Proven. This route's own success shape has never been captured, so
    /// the caller re-fetches `connections()` to see the new row rather than
    /// this decoding a guess of what a verified answer looks like.
    case verified
}

// MARK: - Platform list

/// Which connection types this client offers to start — a wire fact, not a
/// presentation one. The mark, the tint and the display name for each of
/// these live where the rest of this app's brand marks do: `BrandMark` and
/// `ConnectionMark`, in the app target, not here — `WingcordCore` has no
/// SwiftUI to draw with and no business owning that table twice.
public enum ConnectionPlatform {
    /// The one type that does not go through `GET /connections/{type}/authorize`
    /// at all — see `DomainConnectionOutcome`. Named here so the raw string
    /// is written once rather than matched against at every call site.
    public static let domain = "domain"

    /// Every type `GET /connections/{type}/authorize` is documented to answer
    /// for, minus the four this client has no business offering that way.
    ///
    /// `contacts` is phone-contact sync and arrives unasked on every account
    /// (see `ConnectionDTO.domain`); `playstation-stg` is Sony's own staging
    /// target. **`samsung` and `soundcloud` are cut on evidence, not
    /// documentation**: both answered this exact route with a live account's
    /// session and got back `400 Invalid Form Body` — captured in
    /// `session.log` — where every other type in this list either succeeded
    /// or was never tried. Whatever links those two accounts, it is not this
    /// route, and a tile that always fails is the inert control §5.5 forbids.
    /// Unordered — the caller sorts by whatever it displays.
    public static let addable: [String] = [
        "amazon-music", "battlenet", "bluesky", "bungie", "crunchyroll",
        "ebay", "epicgames", "facebook", "github", "instagram",
        "leagueoflegends", "letterboxd", "mastodon", "paypal", "playstation", "reddit",
        "riotgames", "roblox", "skype", "spotify",
        "steam", "tiktok", "twitch", "twitter", "xbox", "youtube",
    ]
}

// MARK: - Scopes

/// What an OAuth2 scope actually grants, in this app's own words.
///
/// Grounded in Discord's *published* scope semantics — the developer
/// documentation's own descriptions — rather than in its consumer client's
/// copy, which this app does not try to reproduce: the wire only ever sends
/// the raw scope string, never a sentence, and the sentence Discord's own
/// settings window shows is that client's design, not a fact.
public enum OAuthScope {
    /// One line, plain enough to act on: can this app be trusted with this.
    public static func description(_ scope: String) -> String {
        table[scope] ?? humanized(scope)
    }

    /// A scope this table has never named still reads as *something* rather
    /// than vanishing — Discord adds scopes continuously, and a permission
    /// list that silently drops an unrecognised one is the inert control
    /// §5.5 forbids, wearing a settings pane instead of a button.
    private static func humanized(_ scope: String) -> String {
        guard !scope.isEmpty else { return "Uses an unnamed permission" }
        return "Uses its “\(scope)” permission"
    }

    private static let table: [String: String] = [
        "identify": "See your username, avatar and banner",
        "identify.premium": "See your Nitro subscription",
        "email": "See your email address",
        "connections": "See your linked third-party accounts",
        "guilds": "See which servers you're in",
        "guilds.join": "Add you to servers on its own",
        "guilds.members.read": "Read your nickname, roles and avatar in servers you share with it",
        "gdm.join": "Add you to a group DM",
        "dm_channels.read": "See your DMs and group DMs",
        "relationships.read": "See your friends list and blocked users",
        "applications.commands": "Add its own commands to a server",
        "applications.commands.update": "Update its own commands",
        "applications.commands.permissions.update": "Change who can use its commands in a server",
        "applications.entitlements": "See what you've purchased through it",
        "applications.builds.read": "Read its own build data",
        "applications.builds.upload": "Upload builds for itself",
        "applications.store.update": "Update its own store listing",
        "role_connections.write": "Set the linked-role information it shows about you",
        "bot": "Join a server as its own bot",
        "webhook.incoming": "Post messages into one channel you choose",
        "voice": "Connect to voice for you and see who else is there",
        "messages.read": "Read messages from your open channels",
        "rpc": "Control this Discord client on your behalf",
        "rpc.activities.write": "Set your current activity",
        "rpc.voice.read": "Read your voice settings and when you're in a call",
        "rpc.voice.write": "Change your voice settings",
        "rpc.notifications.read": "See notifications sent to you",
        "activities.read": "See what you've recently played",
        "activities.write": "Update your current activity",
        "openid": "Confirm who you are to sites outside Discord",
    ]
}
