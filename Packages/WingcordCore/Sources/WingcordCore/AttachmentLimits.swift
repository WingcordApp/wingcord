import Foundation

/// How large a file this account may attach.
///
/// **A table, not a constant, and the answer depends on two subscriptions.**
/// Discord resolves an upload ceiling from the *higher* of the reader's own
/// premium tier and the server's boost tier — a free account in a level-three
/// server may send 100 MiB, and a Nitro account in a plain server may send 500.
/// A client that hard-codes one number is wrong in both directions: it refuses
/// files Discord would have taken, and it starts uploads Discord will reject
/// after the bytes have gone up.
///
/// Documented on `docs.discord.food` under CDN & file uploads; the tiers are
/// Discord's, the arithmetic is one `max`. A direct message has no boost tier,
/// which is a real state rather than "level zero" — nil says so.
public enum AttachmentLimits {

    /// A mebibyte, because every figure below is one of Discord's and Discord
    /// counts in binary units. Writing 500 MB where the server means 500 MiB is
    /// a 24 MB error at the top of the range.
    public static let mebibyte = 1024 * 1024

    /// What the account's own subscription buys.
    ///
    /// Nitro Basic is `TIER_3` on the wire and buys the *same* 50 MiB as
    /// Classic — the numbering is chronological, not ascending, which is exactly
    /// the trap a `>=` comparison falls into.
    public static func bytes(forPremium tier: PremiumTier) -> Int {
        switch tier {
        case .none: 10 * mebibyte
        case .classic: 50 * mebibyte
        case .nitro: 500 * mebibyte
        case .basic: 50 * mebibyte
        }
    }

    /// What a server's boost level buys everybody in it.
    public static func bytes(forGuildBoost tier: Int) -> Int {
        switch tier {
        case 3: 100 * mebibyte
        case 2: 50 * mebibyte
        default: 0
        }
    }

    /// The effective ceiling: the better of the two.
    ///
    /// - Parameter guildBoostTier: The server's boost level, or nil in a direct
    ///   message — where there is no server to raise the floor.
    public static func bytes(forPremium tier: PremiumTier, guildBoostTier: Int?) -> Int {
        max(
            bytes(forPremium: tier),
            guildBoostTier.map(bytes(forGuildBoost:)) ?? 0
        )
    }

    /// Above this, Discord's edge refuses the request body outright and the
    /// Google Cloud upload flow is the only way through.
    ///
    /// This client uses that flow for *every* upload — one code path is one
    /// thing to get right — so the figure is here for the message a refusal
    /// needs rather than as a branch.
    public static let cloudOnlyThreshold = 200 * mebibyte

    /// "24.3 MB", for a sentence explaining a refusal.
    ///
    /// Decimal units on purpose: the ceiling is counted in mebibytes and the
    /// Finder is not, so a reader comparing this against what they see in a
    /// Get Info window needs the units that window uses.
    public static func describe(bytes: Int) -> String {
        ByteCountFormatStyle(style: .file).format(Int64(bytes))
    }
}
