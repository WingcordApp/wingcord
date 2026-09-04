import Foundation

// MARK: - Integrations
//
// One route answers for three unrelated things, and the Integrations page draws
// them as three unrelated sections because that is what they are:
//
//   - `type: "discord"` is a **bot or app** somebody added. Its `application`
//     carries the icon, the description and the scopes it was granted.
//   - `type: "twitch"` / `"youtube"` is a **subscriber sync**. It has an
//     `account` on the other service and a `role_id` it grants.
//   - Followed channels and webhooks are neither, and come from
//     `GET /guilds/{id}/webhooks` — a different route entirely, which is why the
//     page's first two rows are counts rather than lists.

/// Something connected to the server.
public struct GuildIntegration: Hashable, Sendable, Identifiable {
    public var id: UInt64
    public var kind: Kind
    public var name: String
    public var isEnabled: Bool
    /// Who added it.
    public var installerID: UserID?
    /// The app behind a `discord` integration.
    public var application: App?
    /// OAuth scopes the install was granted, as Discord's own strings.
    public var scopes: [String]
    /// The role a subscriber sync grants. Only ever set on Twitch and YouTube.
    public var roleID: RoleID?
    /// The account on the other service.
    public var accountName: String?

    public init(
        id: UInt64,
        kind: Kind,
        name: String,
        isEnabled: Bool = true,
        installerID: UserID? = nil,
        application: App? = nil,
        scopes: [String] = [],
        roleID: RoleID? = nil,
        accountName: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.isEnabled = isEnabled
        self.installerID = installerID
        self.application = application
        self.scopes = scopes
        self.roleID = roleID
        self.accountName = accountName
    }

    public enum Kind: Hashable, Sendable {
        case discord
        case twitch
        case youtube
        case guildSubscription
        /// A service this client has not seen. Named rather than hidden — an
        /// integration the page refuses to list is one nobody can remove.
        case unrecognised(String)

        public init(wireName: String) {
            self = switch wireName {
            case "discord": .discord
            case "twitch": .twitch
            case "youtube": .youtube
            case "guild_subscription": .guildSubscription
            default: .unrecognised(wireName)
            }
        }

        public var title: String {
            switch self {
            case .discord: "App"
            case .twitch: "Twitch"
            case .youtube: "YouTube"
            case .guildSubscription: "Server Subscription"
            case .unrecognised(let name): name.capitalized
            }
        }
    }

    /// The app behind a `discord` integration.
    public struct App: Hashable, Sendable, Identifiable {
        public var id: ApplicationID
        public var name: String
        public var iconHash: String?
        public var description: String?
        public var isVerified: Bool
        /// The bot user, where the app has one. An app installed for its
        /// commands alone does not.
        public var botID: UserID?

        public init(
            id: ApplicationID,
            name: String,
            iconHash: String? = nil,
            description: String? = nil,
            isVerified: Bool = false,
            botID: UserID? = nil
        ) {
            self.id = id
            self.name = name
            self.iconHash = iconHash
            self.description = description
            self.isVerified = isVerified
            self.botID = botID
        }

        public var iconURL: URL? {
            iconHash.flatMap { CDN.applicationIcon(id: id, hash: $0) }
        }
    }

    /// When it was added, from the integration's own snowflake.
    public var addedAt: Date { Snowflake<IntegrationTag>(rawValue: id).timestamp }

    /// Whether this client can remove it.
    ///
    /// `DELETE /guilds/{id}/integrations/{id}` is captured and works — the
    /// "Watch Together" removal in the second HAR took the list from three to
    /// two. It is offered for every kind, because the route does not distinguish
    /// and a Remove that is present on apps and absent on a Twitch sync would be
    /// this client inventing a rule Discord does not have.
    public var canRemove: Bool { true }
}

/// Discord's snowflake tag for an integration.
public enum IntegrationTag {}

// MARK: - Webhooks

/// One webhook.
///
/// Two kinds behind one type, and the difference decides what the row offers:
/// an **incoming** webhook (type 1) has a URL somebody pastes into another
/// service, and a **channel follower** (type 2) is the other end of a "Follow"
/// on somebody else's announcement channel — it has no URL, and it names the
/// server it follows instead.
public struct GuildWebhook: Hashable, Sendable, Identifiable {
    public var id: UInt64
    public var kind: Kind
    public var name: String
    public var avatarHash: String?
    public var channelID: ChannelID?
    public var creatorID: UserID?
    /// **Present only on an incoming webhook, and it is a credential.**
    ///
    /// Anybody holding it can post to the channel as the webhook, forever, with
    /// no account behind it — so it is never drawn, never logged and never put
    /// on a pasteboard except by an explicit press on Copy. The row shows the
    /// name and the channel; the URL is behind one deliberate action.
    public var token: String?
    /// The announcement channel a follower webhook is following.
    public var sourceGuildName: String?
    public var sourceChannelName: String?

    public init(
        id: UInt64,
        kind: Kind = .incoming,
        name: String,
        avatarHash: String? = nil,
        channelID: ChannelID? = nil,
        creatorID: UserID? = nil,
        token: String? = nil,
        sourceGuildName: String? = nil,
        sourceChannelName: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.avatarHash = avatarHash
        self.channelID = channelID
        self.creatorID = creatorID
        self.token = token
        self.sourceGuildName = sourceGuildName
        self.sourceChannelName = sourceChannelName
    }

    public enum Kind: Hashable, Sendable {
        case incoming
        case channelFollower
        case application
        case unrecognised(Int)

        public init(rawValue: Int) {
            self = switch rawValue {
            case 1: .incoming
            case 2: .channelFollower
            case 3: .application
            default: .unrecognised(rawValue)
            }
        }

        public var rawValue: Int {
            switch self {
            case .incoming: 1
            case .channelFollower: 2
            case .application: 3
            case .unrecognised(let value): value
            }
        }
    }

    /// Discord's own default for a new webhook, and the name the capture sent.
    public static let defaultName = "Captain Hook"

    /// The posting URL, where there is one.
    public var url: URL? {
        guard kind == .incoming, let token else { return nil }
        return URL(string: "https://discord.com/api/webhooks/\(id)/\(token)")
    }

    /// A follower webhook's origin, in one line.
    public var followedSource: String? {
        guard let sourceChannelName else { return nil }
        guard let sourceGuildName else { return "#\(sourceChannelName)" }
        return "\(sourceGuildName) · #\(sourceChannelName)"
    }

    public var createdAt: Date { Snowflake<WebhookTag>(rawValue: id).timestamp }

    /// Whether the row may be renamed or re-pointed.
    ///
    /// **A follower webhook may not.** Its name and avatar are the followed
    /// server's, Discord rewrites them on every sync, and a rename that reverts
    /// itself an hour later is a control that looks like it worked.
    public var isEditable: Bool { kind == .incoming }
}

/// Discord's snowflake tag for a webhook.
public enum WebhookTag {}
