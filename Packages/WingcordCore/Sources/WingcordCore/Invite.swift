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

    public init(
        guildID: GuildID,
        channelID: ChannelID? = nil,
        requiresVerification: Bool = false,
        isNewMember: Bool = false
    ) {
        self.guildID = guildID
        self.channelID = channelID
        self.requiresVerification = requiresVerification
        self.isNewMember = isNewMember
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
