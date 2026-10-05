import SwiftUI
import WingcordCore

// MARK: - The catalog
//
// **Discord's own list** — `generateSections` (`1e901507`) — in its order,
// under its headers, each row on its own predicate:
//
//   Server Profile · Server Tag · Server Theme · Engagement · Boost Perks
//   EXPRESSION   Emoji · Stickers · Soundboard
//   PEOPLE       Members ↗ · Roles · Invites · Access
//   APPS         Integrations · App Directory ↗
//   MODERATION   Safety Setup · Audit Log · Bans
//   Community Overview · Onboarding · Server Insights · Welcome Screen
//   Server Template · Delete Server
//
// **What is not here is not here in Discord either.** A channel's settings are
// opened from the channel and have a sidebar of their own (`ChannelSettings`);
// webhooks and followed channels are two rows on Integrations; the Server
// Guide is a row on Onboarding; events are created from the server's events.
//
// Two rules decide what appears, and both are `INVARIANTS.md` §5.5: a row is
// offered on what the server is (`isAvailable`) and on what the reader may do
// (`isReachable`) — absent, never greyed.

enum ServerSettingsSection: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    // The server itself.
    case profile
    case tag
    case serverTheme
    case engagement
    case boostPerks

    // Expression.
    case emoji
    case stickers
    case soundboard

    // People.
    case members
    case roles
    case invites
    case access

    // Apps.
    case integrations
    case appDirectory

    // Moderation.
    case safety
    case auditLog
    case bans

    // Community.
    case community
    case onboarding
    case insights
    case welcomeScreen

    // The last two.
    case template
    case deleteServer

    var id: String { rawValue }

    /// Discord's label.
    var title: String {
        switch self {
        case .profile: "Server Profile"
        case .tag: "Server Tag"
        case .serverTheme: "Server Theme"
        case .engagement: "Engagement"
        case .boostPerks: "Boost Perks"
        case .emoji: "Emoji"
        case .stickers: "Stickers"
        case .soundboard: "Soundboard"
        case .members: "Members"
        case .roles: "Roles"
        case .invites: "Invites"
        case .access: "Access"
        case .integrations: "Integrations"
        case .appDirectory: "App Directory"
        case .safety: "Safety Setup"
        case .auditLog: "Audit Log"
        case .bans: "Bans"
        case .community: "Community Overview"
        case .onboarding: "Onboarding"
        case .insights: "Server Insights"
        case .welcomeScreen: "Welcome Screen"
        case .template: "Server Template"
        case .deleteServer: "Delete Server"
        }
    }

    /// The label in this server: Community Overview is "Enable Community" on
    /// a server that is not one yet.
    func title(isCommunity: Bool) -> String {
        self == .community && !isCommunity ? "Enable Community" : title
    }

    var symbolName: String {
        switch self {
        case .profile: "person.crop.square.fill"
        case .tag: "tag.fill"
        case .serverTheme: "paintpalette.fill"
        case .engagement: "chart.line.uptrend.xyaxis"
        case .boostPerks: "sparkles"
        case .emoji: "face.smiling.inverse"
        case .stickers: "seal.fill"
        case .soundboard: "speaker.wave.2.fill"
        case .members: "person.2.fill"
        case .roles: "shield.fill"
        case .invites: "link"
        case .access: "lock.fill"
        case .integrations: "puzzlepiece.extension.fill"
        case .appDirectory: "square.grid.2x2.fill"
        case .safety: "exclamationmark.shield.fill"
        case .auditLog: "list.bullet.rectangle"
        case .bans: "hand.raised.fill"
        case .community: "person.3.fill"
        case .onboarding: "signpost.right.fill"
        case .insights: "chart.bar.fill"
        case .welcomeScreen: "hand.wave.fill"
        case .template: "doc.on.doc.fill"
        case .deleteServer: "trash.fill"
        }
    }

    /// The tile's tint, one per group — the groups are what the eye uses to
    /// find a row it has been to before.
    var tint: Color {
        switch self {
        case .profile, .tag, .serverTheme, .engagement, .boostPerks: Palette.accent
        case .emoji, .stickers, .soundboard: .orange
        case .members, .roles, .invites, .access: .teal
        case .integrations, .appDirectory: .indigo
        case .safety, .auditLog, .bans: .pink
        case .community, .onboarding, .insights, .welcomeScreen: .green
        case .template: .gray
        case .deleteServer: Palette.destructive
        }
    }

    /// A row that leaves rather than opens a page: Members and App Directory
    /// go to the main window (Discord's ↗), Delete Server asks first.
    var isAction: Bool {
        self == .members || self == .appDirectory || self == .deleteServer
    }

    /// Whether the row wears Discord's ↗ — it takes the reader out of settings.
    var leavesSettings: Bool { self == .members || self == .appDirectory }

    /// Extra words the search field matches on, so somebody looking for "nsfw"
    /// or "automod" finds the page that holds it rather than concluding this
    /// client does not have one.
    var keywords: [String] {
        switch self {
        case .profile: ["name", "icon", "banner", "description", "traits", "games", "about"]
        case .tag: ["badge", "clan", "letters"]
        case .serverTheme: ["theme", "colors", "colours", "gradient", "presets", "appearance"]
        case .engagement: ["system messages", "welcome", "notifications", "afk", "inactive", "widget"]
        case .boostPerks: ["boost", "nitro", "level", "perks"]
        case .emoji: ["emote", "upload", "expression"]
        case .stickers: ["expression", "upload"]
        case .soundboard: ["sounds", "audio", "expression"]
        case .members: ["people", "kick", "ban", "timeout", "pending", "applications", "prune"]
        case .roles: ["permissions", "colour", "color", "hoist", "members"]
        case .invites: ["links", "join", "vanity"]
        case .access: ["privacy", "verification", "age", "nsfw", "application", "apply", "discovery", "discoverable"]
        case .integrations: ["apps", "bots", "twitch", "youtube", "webhooks", "followed channels", "announcements"]
        case .appDirectory: ["apps", "bots", "discover"]
        case .safety: ["automod", "moderation", "raid", "spam", "filter", "captcha", "2fa"]
        case .auditLog: ["history", "log", "who did"]
        case .bans: ["banned", "unban", "moderation"]
        case .community: ["rules channel", "updates", "locale", "language", "enable community"]
        case .onboarding: ["questions", "prompts", "default channels", "server guide", "welcome", "resources", "to do"]
        case .insights: ["analytics", "statistics", "growth"]
        case .welcomeScreen: ["welcome", "recommended channels", "new members", "top things to do"]
        case .template: ["share", "copy", "duplicate"]
        case .deleteServer: ["delete", "remove"]
        }
    }

    /// Whether this row exists at all for a server in this state.
    ///
    /// **Discord's predicates on the server**: Onboarding where onboarding is
    /// offered (a community server), Server Insights for a community server,
    /// Server Tag where the server has tags, and Delete Server for its owner.
    ///
    /// The Welcome Screen is offered only where one exists and the Server
    /// Guide has not replaced it — Discord's `!welcomeScreenEmpty &&
    /// !GUILD_SERVER_GUIDE` — so it needs the route's answer as well.
    func isAvailable(in settings: GuildSettings, isOwner: Bool, hasWelcomeScreen: Bool = false) -> Bool {
        switch self {
        case .onboarding, .insights: settings.isCommunity
        case .welcomeScreen:
            settings.isCommunity && hasWelcomeScreen && !settings.features.contains("GUILD_SERVER_GUIDE")
        case .tag: settings.canSetTag
        // Discord's row is an experiment's; the page can only do anything for
        // a server that may wear a theme, and that is the feature.
        case .serverTheme: settings.features.contains("GUILD_THEME")
        case .deleteServer: isOwner
        default: true
        }
    }

    /// Whether this reader may open this row — **Discord's own predicate per
    /// page** (`getSectionDefinition`).
    ///
    /// Several are an *either*: Integrations opens for Manage Server or Manage
    /// Webhooks, Bans for Ban Members or View Audit Log, the three expression
    /// pages for Manage or Create Expressions. Boost Perks and App Directory
    /// carry no predicate of their own.
    func isReachable(with permissions: Permissions) -> Bool {
        if permissions.contains(.administrator) { return true }
        func any(_ set: Permissions) -> Bool { !permissions.isDisjoint(with: set) }
        switch self {
        case .boostPerks, .appDirectory, .deleteServer:
            return true
        case .emoji, .stickers, .soundboard:
            return any([.manageExpressions, .createExpressions])
        case .members:
            return any(.moderatorAccess)
        case .roles:
            return permissions.contains(.manageRoles)
        case .integrations:
            return any([.manageGuild, .manageWebhooks])
        case .auditLog:
            return permissions.contains(.viewAuditLog)
        case .bans:
            return any([.banMembers, .viewAuditLog])
        case .insights:
            // `canViewGuildAnalytics` — the analytics permission itself.
            return permissions.contains(.viewGuildInsights)
        case .profile, .tag, .serverTheme, .engagement, .invites, .access, .safety, .community,
             .onboarding, .welcomeScreen, .template:
            return permissions.contains(.manageGuild)
        }
    }

    /// Every page this reader could open, ungrouped.
    ///
    /// **Empty is not the gate.** The gate is `Permissions.guildSettingsAccess`
    /// — Discord's own ten-permission mask — and this list is what the sidebar
    /// draws once that gate is passed. Rows open to anybody past the gate
    /// (Boost Perks, App Directory) are not what makes a window worth opening,
    /// so they are not counted here.
    static func reachable(with permissions: Permissions) -> [ServerSettingsSection] {
        guard permissions.contains(.administrator)
            || !permissions.intersection(.guildSettingsAccess).isEmpty
        else { return [] }
        return groups.flatMap(\.sections).filter { section in
            section.isReachable(with: permissions)
                && (permissions.contains(.administrator)
                    || ![.boostPerks, .appDirectory, .deleteServer].contains(section))
        }
    }

    /// One group of rows, under Discord's header where it has one.
    struct Group: Hashable {
        var header: String?
        var sections: [ServerSettingsSection]
    }

    /// The groups, in Discord's order. Its headers are sentence case in the
    /// strings and drawn in capitals.
    static let groups: [Group] = [
        Group(header: nil, sections: [.profile, .tag, .serverTheme, .engagement, .boostPerks]),
        Group(header: "Expression", sections: [.emoji, .stickers, .soundboard]),
        Group(header: "People", sections: [.members, .roles, .invites, .access]),
        Group(header: "Apps", sections: [.integrations, .appDirectory]),
        Group(header: "Moderation", sections: [.safety, .auditLog, .bans]),
        Group(header: nil, sections: [.community, .onboarding, .insights, .welcomeScreen]),
        Group(header: nil, sections: [.template, .deleteServer]),
    ]

    /// The groups this reader may actually open, with unavailable rows and
    /// empty groups removed — so a hidden row never leaves a gap or an orphan
    /// header.
    static func groups(
        for settings: GuildSettings,
        permissions: Permissions,
        isOwner: Bool,
        hasWelcomeScreen: Bool = false
    ) -> [Group] {
        groups.compactMap { group in
            let kept = group.sections.filter { section in
                section.isAvailable(in: settings, isOwner: isOwner, hasWelcomeScreen: hasWelcomeScreen)
                    && section.isReachable(with: permissions)
            }
            // A group of only the always-open rows is not a group this reader
            // came for — Discord shows Apps to everyone past the gate, and so
            // does this; it never shows a lone Delete Server to a non-owner.
            return kept.isEmpty ? nil : Group(header: group.header, sections: kept)
        }
    }

    /// Discord's line under the page's title, where its page has one — and
    /// nothing where it has none: a sentence Discord never wrote is not
    /// written here.
    var detail: String? {
        switch self {
        case .profile:
            "Customize how your server appears in invite links and, if enabled, in Server Discovery and Announcement Channel messages"
        case .roles:
            "Use roles to group your server members and assign permissions."
        case .soundboard:
            "Upload custom sound reactions that anyone in this server can use. Nitro members will be able to access these sounds in any server on Discord."
        case .integrations:
            "Customize your server with integrations. Manage webhooks, followed channels, and apps, as well as Twitch and YouTube settings for creators."
        case .onboarding:
            "Give your members a simple starting experience with custom channels, roles, and first steps."
        case .serverTheme:
            "Pick a preset theme or build your own. Every member sees this theme when they open the server, and it adapts to their light or dark mode."
        case .engagement:
            "Manage settings that help keep your server active."
        default:
            nil
        }
    }
}
