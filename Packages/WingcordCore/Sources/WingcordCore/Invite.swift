import Foundation

/// A server behind an invite code, as the resolve route describes it.
///
/// **This is not a `Guild`, and turning it into one would be a lie.** The
/// payload carries the name, the artwork and two counts, and none of a guild's
/// contents — no channels, no roles, no members. A store that accepted it as a
/// guild would answer "yes, we have that server" to every reader that asked,
/// and the rail would gain a tile for something nobody joined.
///
/// So it is its own value with its own lifetime: it exists while somebody is
/// looking at the invite, and joining is what produces the real guild — over the
/// socket, as `GUILD_CREATE`, exactly as a preview does.
///
/// **Captured**, `forza onboarding1.har` entry 3:
/// `GET /invites/forza?inputValue=forza&with_counts=true&with_expiration=true&with_permissions=true`
public struct InvitePreview: Hashable, Sendable, Identifiable {
    /// The code as it was resolved, which is **not** always what was typed: a
    /// vanity URL answers with its own code, and the accept route wants the one
    /// that came back.
    public var code: String
    public var guildID: GuildID
    public var name: String
    public var description: String?
    public var iconHash: String?
    public var bannerHash: String?
    /// The invite's own splash, which is what Discord draws behind the card when
    /// there is no banner.
    public var splashHash: String?
    /// `approximate_member_count`. Nil rather than zero when the route did not
    /// answer with one — "0 members" is a claim, and an unknown count is not it.
    public var memberCount: Int?
    /// `approximate_presence_count` — the green number under the name.
    public var onlineCount: Int?
    /// The guild's features, verbatim. Read for `VERIFIED` and `PARTNERED`,
    /// which are the two badges the card can draw.
    ///
    /// **The invite's own `channel` is deliberately not kept here.** It is on
    /// the payload — `{"id":…,"type":0,"name":"rules"}` — and the *accept*
    /// answers with it too; only the accept's copy decides anything, so a second
    /// one on the preview would be a field nothing reads.
    public var features: Set<String>

    public nonisolated var id: String { code }

    public init(
        code: String,
        guildID: GuildID,
        name: String,
        description: String? = nil,
        iconHash: String? = nil,
        bannerHash: String? = nil,
        splashHash: String? = nil,
        memberCount: Int? = nil,
        onlineCount: Int? = nil,
        features: Set<String> = []
    ) {
        self.code = code
        self.guildID = guildID
        self.name = name
        self.description = description
        self.iconHash = iconHash
        self.bannerHash = bannerHash
        self.splashHash = splashHash
        self.memberCount = memberCount
        self.onlineCount = onlineCount
        self.features = features
    }

    public var isVerified: Bool { features.contains("VERIFIED") }
    public var isPartnered: Bool { features.contains("PARTNERED") }

    /// The two letters drawn when there is no icon, built the way every other
    /// server monogram in the app is.
    public var monogram: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "#" : String(letters).uppercased()
    }

    public func iconURL(side: CGFloat) -> URL? {
        iconHash.flatMap { CDN.guildIcon(guildID: guildID, hash: $0, side: side) }
    }

    /// The picture behind the card.
    ///
    /// **Banner first, splash second.** They are different assets for different
    /// jobs — the banner runs across the top of a server somebody is in, the
    /// splash is the invite's own artwork — and the captured guild carries both.
    /// A server with neither draws no picture rather than a grey box.
    public func coverURL(width: CGFloat) -> URL? {
        if let bannerHash {
            return CDN.guildBanner(guildID: guildID, hash: bannerHash, width: width)
        }
        guard let splashHash else { return nil }
        return URL(
            string: "https://cdn.discordapp.com/splashes/\(guildID.rawValue)/\(splashHash).webp"
                + "?size=\(CDN.rung(forSide: width))"
        )
    }
}

/// What accepting an invite answered with.
///
/// **The guild that comes back is the invite's guild half, not a membership.**
/// The 200 on `POST /invites/{code}` carries the same trimmed guild object the
/// resolve did; the real one arrives over the socket as `GUILD_CREATE`. What is
/// worth keeping from the answer is therefore the *identity* — which server was
/// joined — and nothing else.
///
/// Two fields decide what happens next, and **both appear only on the accept** —
/// the resolve carries neither:
///
/// ```
/// "show_verification_form": true,
/// "new_member": true
/// ```
public struct InviteAcceptance: Hashable, Sendable {
    public var guildID: GuildID
    public var channelID: ChannelID?
    /// `show_verification_form` — the server's own statement that a rules gate
    /// stands between this account and posting.
    public var requiresVerification: Bool
    /// `new_member` — whether this join actually added somebody.
    ///
    /// **False is a real and ordinary answer**: re-accepting an invite to a
    /// server you are already in succeeds, and treating that as a fresh join is
    /// how a client ends up asking a three-year member to read the rules again.
    public var isNewMember: Bool
    /// Whether the server reviews applications — `MEMBER_VERIFICATION_GATE_ENABLED`
    /// and `MEMBER_VERIFICATION_MANUAL_APPROVAL` on the invite's guild, Discord's
    /// `h` in `610101`.
    ///
    /// **Such an accept joins nobody.** It opens a join request, no
    /// `GUILD_CREATE` follows, and what comes next is the application form —
    /// Discord's `transitionToInvite` opens it for a new member of one.
    public var isApplication: Bool
    /// The request such an accept opened, where the answer carried one, and
    /// the server as the invite describes it — what Discord's store files on
    /// `INVITE_ACCEPT_SUCCESS`, so the application is in the Pending
    /// Applications folder before it has been sent.
    public var joinRequest: OwnJoinRequest?
    public var applicationGuild: JoinRequestGuild?
    /// The server's Welcome Screen, where the invite's guild carried one —
    /// Discord's store files `guild.welcome_screen` off the accept and greets
    /// the new member with it.
    public var welcomeScreen: WelcomeScreen?
    /// The invite's guild's features — whether Onboarding has replaced the
    /// Welcome Screen is one of them.
    public var features: Set<String>

    public init(
        guildID: GuildID,
        channelID: ChannelID? = nil,
        requiresVerification: Bool = false,
        isNewMember: Bool = false,
        isApplication: Bool = false,
        joinRequest: OwnJoinRequest? = nil,
        applicationGuild: JoinRequestGuild? = nil,
        welcomeScreen: WelcomeScreen? = nil,
        features: Set<String> = []
    ) {
        self.guildID = guildID
        self.channelID = channelID
        self.joinRequest = joinRequest
        self.applicationGuild = applicationGuild
        self.welcomeScreen = welcomeScreen
        self.features = features
        self.requiresVerification = requiresVerification
        self.isNewMember = isNewMember
        self.isApplication = isApplication
    }
}

// MARK: - Reading a code out of what somebody pasted

extension InvitePreview {

    /// The invite code in a string somebody typed, pasted or dragged in.
    ///
    /// Discord's own dialog accepts three shapes, and its placeholder says so:
    /// `hTKzmak`, `https://discord.gg/hTKzmak`, `https://discord.gg/wumpus-friends`.
    /// All three are the same thing with more or less URL in front of it, so
    /// this strips rather than parses — a `URL` would reject the bare code,
    /// which is the shape most people actually paste.
    ///
    /// **A query string is dropped and a path below the code is not.** Invites
    /// arrive with `?event=…` on them from scheduled events, and the code is
    /// still the first path component; anything after a second slash is not part
    /// of any invite shape observed and is left in so the route can reject it
    /// rather than this quietly inventing a different code.
    public static func code(in text: String) -> String? {
        var slice = text.trimmingCharacters(in: .whitespacesAndNewlines)[...]
        guard !slice.isEmpty else { return nil }

        // Strip a scheme, then any of the hosts an invite is written with.
        for prefix in ["https://", "http://"] where slice.hasPrefix(prefix) {
            slice = slice.dropFirst(prefix.count)
        }
        for host in ["discord.gg/", "discord.com/invite/", "discordapp.com/invite/",
                     "www.discord.gg/", "ptb.discord.com/invite/", "canary.discord.com/invite/"]
        where slice.lowercased().hasPrefix(host) {
            slice = slice.dropFirst(host.count)
            break
        }

        if let mark = slice.firstIndex(of: "?") { slice = slice[..<mark] }
        if let mark = slice.firstIndex(of: "#") { slice = slice[..<mark] }
        while slice.hasSuffix("/") { slice = slice.dropLast() }

        let code = String(slice)
        // A code is one path component. Something still carrying a slash is a
        // link to a message or a channel, not an invite, and resolving its first
        // component would join a server nobody named.
        guard !code.isEmpty, !code.contains("/") else { return nil }
        return code
    }
}

/// An invite as the transcript draws it: a server, a group conversation or a
/// friend request behind a link somebody posted — Discord's invite embed.
///
/// **One value for all three**, because every card is an icon, a name, a line
/// under it and one button. What differs is which of Discord's cards draws it:
/// a server with a profile gets the profile card (`ct`, `guild_invite_v2`), and
/// everything else the classic one (`o2`, `oq`, `oX`).
public struct InviteCard: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case server
        case groupDirectMessage
        case friend
    }

    public var code: String
    public var kind: Kind
    public var guildID: GuildID?
    public var channelID: ChannelID?
    /// The server's name, the group's, or — for a friend invite — the person's.
    public var name: String
    /// A server's icon or a group's, by hash. Drawn from the right CDN path by
    /// `kind`.
    public var iconHash: String?
    /// The server's splash, drawn across the top of the classic card.
    public var splashHash: String?
    /// The server's feature list: its mark, and whether joining is an
    /// application rather than a click.
    public var features: Set<String>
    public var boostTier: Int
    public var boostCount: Int
    public var memberCount: Int?
    public var onlineCount: Int?
    /// The channel the invite opens onto, for a server with too few people to
    /// have counts worth showing.
    public var channelName: String?
    /// Whether that channel is a voice channel — which, for a reader who can
    /// see it, makes the card Discord's voice invite (`dF`, web 641803).
    public var isVoiceChannel: Bool
    /// The server's profile — the whole of Discord's current server card. Nil
    /// for a group or a friend link, and for a server whose invite carried none.
    public var profile: GuildProfile?
    /// Who sent it — drawn on the card with their face.
    public var inviterID: UserID?
    public var inviterName: String?
    /// The inviter's handle, which is the title of a friend link's card.
    public var inviterUsername: String?
    public var inviterAvatarHash: String?
    public var expiresAt: Date?
    /// The event the link carried (`?event=`), as the invite answered with
    /// it — which, while it is not over, turns the card into the event's.
    public var event: ScheduledEvent?
    /// `is_nickname_changeable` — whether the invite's sheet offers a Server
    /// Nickname field (Discord's `504394`).
    public var isNicknameChangeable: Bool
    /// `roles` — what accepting grants: Discord's "Roles Granted". Also why a
    /// member of the server still gets the sheet, if they lack one of them.
    public var grantedRoles: [InviteGrantedRole]
    /// `flags`' `IS_GUEST_INVITE`. A guest gets no Server Settings.
    public var isGuestInvite: Bool

    public init(
        code: String,
        kind: Kind,
        guildID: GuildID? = nil,
        channelID: ChannelID? = nil,
        name: String,
        iconHash: String? = nil,
        splashHash: String? = nil,
        features: Set<String> = [],
        boostTier: Int = 0,
        boostCount: Int = 0,
        memberCount: Int? = nil,
        onlineCount: Int? = nil,
        channelName: String? = nil,
        isVoiceChannel: Bool = false,
        profile: GuildProfile? = nil,
        inviterID: UserID? = nil,
        inviterName: String? = nil,
        inviterUsername: String? = nil,
        inviterAvatarHash: String? = nil,
        expiresAt: Date? = nil,
        event: ScheduledEvent? = nil,
        isNicknameChangeable: Bool = false,
        grantedRoles: [InviteGrantedRole] = [],
        isGuestInvite: Bool = false
    ) {
        self.isNicknameChangeable = isNicknameChangeable
        self.grantedRoles = grantedRoles
        self.isGuestInvite = isGuestInvite
        self.code = code
        self.kind = kind
        self.guildID = guildID
        self.channelID = channelID
        self.name = name
        self.iconHash = iconHash
        self.splashHash = splashHash
        self.features = features
        self.boostTier = boostTier
        self.boostCount = boostCount
        self.memberCount = memberCount
        self.onlineCount = onlineCount
        self.channelName = channelName
        self.isVoiceChannel = isVoiceChannel
        self.profile = profile
        self.inviterID = inviterID
        self.inviterName = inviterName
        self.inviterUsername = inviterUsername
        self.inviterAvatarHash = inviterAvatarHash
        self.expiresAt = expiresAt
        self.event = event
    }

    /// The invite's own picture, which Discord's modal draws on its right
    /// (`getGuildSplashURL`). A server's banner is not used here: it's another
    /// asset for another job.
    public func splashURL(width: CGFloat) -> URL? {
        guard let guildID, let splashHash else { return nil }
        return URL(
            string: "https://cdn.discordapp.com/splashes/\(guildID.rawValue)/\(splashHash).webp"
                + "?size=\(CDN.rung(forSide: width))"
        )
    }

    /// "Invite expires in 3 days" — Discord's `804070`, inside its last week and
    /// never for one that has already gone.
    public func expiryWords(now: Date) -> String? {
        guard kind == .server, let expiresAt else { return nil }
        let left = expiresAt.timeIntervalSince(now)
        guard left > 0, left <= 7 * 86_400 else { return nil }
        let minutes = Int(left / 60)
        func words(_ count: Int, _ unit: String) -> String {
            "Invite expires in \(count) \(unit)\(count == 1 ? "" : "s")"
        }
        if minutes >= 1_440 { return words(minutes / 1_440, "day") }
        if minutes >= 60 { return words(minutes / 60, "hour") }
        return words(max(1, minutes), "minute")
    }

    /// The server's mark — see `GuildMark`. Nil for a group or a friend link.
    public var mark: GuildMark? {
        guard kind == .server else { return nil }
        return GuildMark(features: features, boostTier: boostTier, boostCount: boostCount)
    }

    /// Whether joining is an application: Discord's `APPLY_TO_JOIN`, the rules
    /// gate with manual approval behind it.
    public var joinsByApplication: Bool {
        features.contains("MEMBER_VERIFICATION_GATE_ENABLED")
            && features.contains("MEMBER_VERIFICATION_MANUAL_APPROVAL")
    }

    /// Discord's header over the classic card, word for word. A server's and a
    /// group's are about who posted the link (`oU/lsl`/`BoQUFf`,
    /// `Fyamu8`/`2tr5Qz`); a friend link's is about whose link it is
    /// (`eQyu1F`/`PYJHW6`), which the caller decides.
    public func header(sentByReader: Bool) -> String {
        switch kind {
        case .server:
            sentByReader ? "You sent an invite to join a server" : "You've been invited to join a server"
        case .groupDirectMessage:
            sentByReader ? "You sent an invite to" : "You've been invited to"
        case .friend:
            sentByReader ? "You sent a friend link" : "You've got a friend link"
        }
    }

    /// A group conversation's title from its members' names — Discord's own
    /// joins (`LJpTRF`, `gwRP0Y`, `/KSOKY`, `m5uYso`).
    public static func groupTitle(_ names: [String]) -> String {
        switch names.count {
        case 0: "Unnamed"
        case 1: names[0]
        case 2: "\(names[0]), \(names[1])"
        case 3: "\(names[0]), \(names[1]), and \(names[2])"
        default: "\(names[0]), \(names[1]) and others"
        }
    }
}

/// A role an invite grants, as far as Discord's "Roles Granted" draws one.
public struct InviteGrantedRole: Hashable, Sendable, Identifiable {
    public var id: RoleID
    public var name: String
    public var colorValue: UInt32?

    public init(id: RoleID, name: String, colorValue: UInt32? = nil) {
        self.id = id
        self.name = name
        self.colorValue = colorValue
    }
}

/// What asking about an invite came back with.
public enum InviteLookup: Hashable, Sendable {
    case resolved(InviteCard)
    /// Expired, revoked or never real — Discord draws its own card for it.
    case invalid
}

extension InviteCard {
    /// The invites a message's text links to, in order and each once —
    /// `discord.gg/…`, `discord.com/invite/…` and `discordapp.com/invite/…`,
    /// which is what Discord draws a card under a message for.
    ///
    /// **Keyed as Discord keys them** (`21599`'s `fB`): the code, and
    /// `?event=` after it where the link names an event — the same invite
    /// with an event on it is another card, the event's. `code(ofKey:)` and
    /// `eventID(ofKey:)` take a key apart.
    public static func codes(in content: String) -> [String] {
        guard content.contains("discord") else { return [] }
        var seen = Set<String>()
        var codes: [String] = []
        for match in content.matches(of: linkPattern) {
            let code = String(match.1)
            let key = match.2.flatMap(eventID(inQuery:)).map { "\(code)?event=\($0)" } ?? code
            if seen.insert(key).inserted { codes.append(key) }
        }
        return codes
    }

    /// The key of a link that is nothing but an invite, or nil for any other
    /// link — so a clicked link goes to the invite sheet, or to the browser.
    ///
    /// **The whole link has to be one.** `codes(in:)` finds invites anywhere in
    /// a message; here a page that merely mentions discord.gg in its path or
    /// query is not an invite somebody clicked.
    public static func key(ofLink link: String) -> String? {
        var text = link.trimmingCharacters(in: .whitespacesAndNewlines)[...]
        if let fragment = text.firstIndex(of: "#") { text = text[..<fragment] }
        while text.hasSuffix("/") { text = text.dropLast() }
        guard let match = String(text).wholeMatch(of: linkPattern) else { return nil }
        let code = String(match.1)
        return match.2.flatMap(eventID(inQuery:)).map { "\(code)?event=\($0)" } ?? code
    }

    /// The invite code a key names, without the event on it.
    public static func code(ofKey key: String) -> String {
        key.firstIndex(of: "?").map { String(key[..<$0]) } ?? key
    }

    /// The event a key carries, where its link named one.
    public static func eventID(ofKey key: String) -> UInt64? {
        key.firstIndex(of: "?").flatMap { eventID(inQuery: key[key.index(after: $0)...]) }
    }

    /// `event=` in a link's query, a snowflake or nothing.
    private static func eventID(inQuery query: Substring) -> UInt64? {
        for pair in query.split(separator: "&") where pair.hasPrefix("event=") {
            return UInt64(pair.dropFirst("event=".count).prefix { $0.isASCII && $0.isNumber })
        }
        return nil
    }

    nonisolated(unsafe) private static let linkPattern =
        /(?i)(?:https?:\/\/)?(?:www\.|ptb\.|canary\.)?(?:discord\.gg|discord(?:app)?\.com\/invite)\/([A-Za-z0-9-]{2,32})(?:\/?\?([^\s<>#]*))?/
}
