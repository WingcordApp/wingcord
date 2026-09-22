import SwiftUI
import WingcordCore

// MARK: - The catalog
//
// Twenty sections in six groups. Same shape as `SettingsCatalog` and a different
// list, because these are two different windows about two different things — and
// the app's own settings list has no server in it to be scoped to.
//
// TWO RULES DECIDE WHAT APPEARS, and both are `INVARIANTS.md` §5.5:
//
//   1. **A section is offered on the ANSWER, not on a flag that implies it.**
//      Six of these exist only for a community server, and `COMMUNITY` is the
//      one feature string that genuinely predicts something — without it Discord
//      has not given the server a rules channel, onboarding, discovery or safety
//      alerts, so the pages have nothing behind them rather than being empty.
//      That is the exception that proves the rule the server *reader* pages
//      follow: there, no flag worked, so each row waited on its own route.
//   2. **A section the reader cannot act on is not drawn.** Every page here
//      needs `MANAGE_GUILD` or better, and the window is not opened without it —
//      but three sections need a *second* permission on top, and those are
//      filtered rather than shown greyed.

enum ServerSettingsSection: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    // The server itself.
    case profile
    case tag
    case engagement
    case events

    // What it can say.
    case emoji
    case stickers
    case soundboard

    // Who is in it.
    case channels
    case members
    case roles
    case invites
    case access

    // What is plugged into it.
    case integrations
    case webhooks

    // Keeping order.
    case safety
    case auditLog
    case bans

    // Community.
    case community
    case onboarding
    case serverGuide

    // The exits.
    case template

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profile: "Server Profile"
        case .tag: "Server Tag"
        case .engagement: "Engagement"
        case .events: "Events"
        case .emoji: "Emoji"
        case .stickers: "Stickers"
        case .soundboard: "Soundboard"
        case .channels: "Channels"
        case .members: "Members"
        case .roles: "Roles"
        case .invites: "Invites"
        case .access: "Access"
        case .integrations: "Integrations"
        case .webhooks: "Webhooks"
        case .safety: "Safety Setup"
        case .auditLog: "Audit Log"
        case .bans: "Bans"
        case .community: "Community Overview"
        case .onboarding: "Onboarding"
        case .serverGuide: "Server Guide"
        case .template: "Server Template"
        }
    }

    var symbolName: String {
        switch self {
        case .profile: "person.crop.square.fill"
        case .tag: "tag.fill"
        case .engagement: "chart.line.uptrend.xyaxis"
        case .events: "calendar"
        case .emoji: "face.smiling.inverse"
        case .stickers: "seal.fill"
        case .soundboard: "speaker.wave.2.fill"
        case .channels: "number"
        case .members: "person.2.fill"
        case .roles: "shield.fill"
        case .invites: "link"
        case .access: "lock.fill"
        case .integrations: "puzzlepiece.extension.fill"
        case .webhooks: "arrow.triangle.branch"
        case .safety: "exclamationmark.shield.fill"
        case .auditLog: "list.bullet.rectangle"
        case .bans: "hand.raised.fill"
        case .community: "person.3.fill"
        case .onboarding: "square.grid.2x2.fill"
        case .serverGuide: "signpost.right.fill"
        case .template: "doc.on.doc.fill"
        }
    }

    /// The tile's tint. Grouped by *what the page is about* rather than one
    /// colour per row: twenty distinct hues is a paint chart, and the groups are
    /// what the eye actually uses to find a row it has been to before.
    var tint: Color {
        switch self {
        case .profile, .tag, .engagement, .events: Palette.accent
        case .emoji, .stickers, .soundboard: .orange
        case .channels, .members, .roles, .invites, .access: .teal
        case .integrations, .webhooks: .indigo
        case .safety, .auditLog, .bans: .pink
        case .community, .onboarding, .serverGuide: .green
        case .template: .gray
        }
    }

    /// Extra words the search field matches on, so somebody looking for "nsfw"
    /// or "automod" finds the page that holds it rather than concluding this
    /// client does not have one.
    var keywords: [String] {
        switch self {
        case .profile: ["name", "icon", "banner", "description", "traits", "games", "about"]
        case .tag: ["badge", "clan", "letters"]
        case .engagement: ["system messages", "welcome", "notifications", "afk", "inactive", "widget", "boost"]
        case .events: ["scheduled", "calendar", "stage", "rsvp", "recurring"]
        case .emoji: ["emote", "upload", "expression"]
        case .stickers: ["expression", "upload"]
        case .soundboard: ["sounds", "audio", "expression"]
        case .channels: ["create channel", "category", "private", "topic", "slowmode", "permissions", "delete"]
        case .members: ["people", "kick", "ban", "timeout", "pending", "applications", "prune"]
        case .roles: ["permissions", "colour", "color", "hoist", "members"]
        case .invites: ["links", "join", "vanity"]
        case .access: ["privacy", "verification", "age", "nsfw", "application", "apply", "discovery", "discoverable"]
        case .integrations: ["apps", "bots", "twitch", "youtube"]
        case .webhooks: ["follow", "announcements"]
        case .safety: ["automod", "moderation", "raid", "spam", "filter"]
        case .auditLog: ["history", "log", "who did"]
        case .bans: ["banned", "unban", "moderation"]
        case .community: ["rules channel", "updates", "locale", "language", "enable community"]
        case .onboarding: ["questions", "prompts", "default channels", "customisation"]
        case .serverGuide: ["welcome", "new member", "resources", "to do"]
        case .template: ["share", "copy", "duplicate"]
        }
    }

    /// Whether this page exists at all for a server in this state.
    ///
    /// **Community pages are hidden, not disabled.** A non-community server has
    /// not been given a rules channel, onboarding or discovery by Discord — so
    /// the page would open on "this server has not set one up", which is the
    /// inert surface §5.5 forbids. Community Overview stays, because it is where
    /// somebody turns community *on*.
    func isAvailable(in settings: GuildSettings) -> Bool {
        switch self {
        case .onboarding, .serverGuide:
            settings.isCommunity
        case .tag:
            settings.canSetTag
        default:
            true
        }
    }

    /// Whether this reader may open this page at all.
    ///
    /// **`requiredPermission` is a permission needed *beyond* `MANAGE_GUILD`,
    /// and nothing used to supply the `MANAGE_GUILD`.** A page with no extra
    /// requirement therefore passed for everybody — so a reader who is just a
    /// member of somebody else's server could open the window and find Server
    /// Profile, Engagement, Onboarding and Server Template waiting for them,
    /// with Invites answering "You do not have permission to do that here".
    /// Every one of those is a page whose every write is a 403, which is exactly
    /// what `INVARIANTS.md` §5.5 forbids.
    ///
    /// A moderator holding only `MANAGE_ROLES` still gets a window — with Roles
    /// in it and nothing else — which is what Discord does and the reason this
    /// is per page rather than one gate on the window.
    func isReachable(with permissions: Permissions) -> Bool {
        if permissions.contains(.administrator) { return true }
        guard let required = requiredPermission else { return permissions.contains(.manageGuild) }
        return permissions.contains(required)
    }

    /// Every page this reader could open, ungrouped.
    ///
    /// **Empty is not the gate.** Deriving "may this window open at all" from
    /// the pages was wrong twice over: the Invites page asks for `createInvite`,
    /// which `@everyone` holds, so every member of every server passed. The gate
    /// is `Permissions.guildSettingsAccess` — Discord's own ten-permission mask
    /// — and this list is what the sidebar draws once that gate is passed.
    static func reachable(with permissions: Permissions) -> [ServerSettingsSection] {
        guard permissions.contains(.administrator)
            || !permissions.intersection(.guildSettingsAccess).isEmpty
        else { return [] }
        return groups.flatMap(\.self).filter { $0.isReachable(with: permissions) }
    }

    /// The permission the page needs beyond the `MANAGE_GUILD` that opened the
    /// window.
    var requiredPermission: Permissions? {
        switch self {
        case .roles: .manageRoles
        case .events: .createEvents
        case .invites: .createInvite
        case .auditLog: .viewAuditLog
        case .bans: .banMembers
        case .members: .kickMembers
        case .channels: .manageChannels
        case .emoji, .stickers, .soundboard: .manageExpressions
        case .webhooks, .integrations: .manageWebhooks
        default: nil
        }
    }

    /// The groups, in order. Separated by space alone — no dividers and no
    /// headers, which is what `SettingsSidebar` already does and the reason a
    /// long source list stays scannable.
    static let groups: [[ServerSettingsSection]] = [
        [.profile, .tag, .engagement, .events],
        [.emoji, .stickers, .soundboard],
        [.channels, .members, .roles, .invites, .access],
        [.integrations, .webhooks],
        [.safety, .auditLog, .bans],
        [.community, .onboarding, .serverGuide],
        [.template],
    ]

    /// The groups this reader may actually open, with unavailable rows and empty
    /// groups removed.
    ///
    /// Empty groups are dropped so a hidden section never leaves a gap where a
    /// group used to be — the same trim the app settings sidebar makes for a
    /// search query.
    static func groups(
        for settings: GuildSettings,
        permissions: Permissions
    ) -> [[ServerSettingsSection]] {
        groups.compactMap { group in
            let kept = group.filter { section in
                section.isAvailable(in: settings) && section.isReachable(with: permissions)
            }
            return kept.isEmpty ? nil : kept
        }
    }

    /// A short line under the page's title. What the page is *for*, which the
    /// sidebar row has no room to say.
    var detail: String {
        switch self {
        case .profile:
            "How your server appears in invite links and, if enabled, in Server Discovery."
        case .tag:
            "The two-to-four letters members can wear beside their name."
        case .engagement:
            "Settings that help keep your server active."
        case .events:
            "What is happening here, and when."
        case .emoji:
            "Custom emoji anyone in this server can use."
        case .stickers:
            "Custom stickers anyone in this server can send."
        case .soundboard:
            "Custom sound reactions anyone in this server can play in voice."
        case .channels:
            "Create, rename and remove the rooms this server is made of."
        case .members:
            "Everyone here, how they got in, and who is still waiting."
        case .roles:
            "Group your members and give them permissions."
        case .invites:
            "The links that let people in, and who made them."
        case .access:
            "How people join, and what they agree to first."
        case .integrations:
            "Apps and services connected to this server."
        case .webhooks:
            "Endpoints that post into your channels, and the channels you follow."
        case .safety:
            "The automatic rules that act before a moderator has to."
        case .auditLog:
            "Everything administrators and moderators have done here."
        case .bans:
            "Everyone who cannot come back."
        case .community:
            "The channels Discord uses to reach your moderators, and the language it uses."
        case .onboarding:
            "The questions and default channels a new member starts with."
        case .serverGuide:
            "The welcome, the first tasks and the pages you point new members at."
        case .template:
            "Share this server's setup so anyone can create one like it."
        }
    }
}
