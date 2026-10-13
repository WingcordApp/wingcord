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

    /// The most one message's files may add up to — Discord's
    /// `uploadSumTooLarge` (`292348.jS`): 500 MiB, which an experiment doubles.
    public static let messageTotal = 500 * mebibyte

    // MARK: Discord's words for a refusal (`openUploadError`)

    /// A file, or the message's files together, over the limit.
    public static let tooLargeTitle = "Your files are too powerful"

    /// What the limit is, in Discord's words (`382287.WQ`): Nitro Classic has
    /// its own line. Discord ranks Basic *below* Classic (`202541.ci`), so a
    /// Basic account reads the plain one.
    public static func tooLargeHelp(limit: Int, premium: PremiumTier) -> String {
        let size = DiscordFileSize.text(limit)
        return premium == .classic
            ? "Max file size for Nitro Classic is \(size) please."
            : "Max file size is \(size) please."
    }

    /// The same, where the pictures over the limit can be compressed — the
    /// words of Discord's own Send Compressed, which its mobile client shows.
    public static func compressHelp(limit: Int) -> String {
        "To upload images larger than \(DiscordFileSize.text(limit)), you can compress it as a lower size image, "
            + "or get Nitro to send a crystal clear image without losing quality!"
    }

    /// The message's files together over `messageTotal`.
    public static var totalTooLargeHelp: String {
        "Total message size must be less than \(DiscordFileSize.text(messageTotal))"
    }

    /// More files than a message can carry.
    public static let tooManyTitle = "Too many uploads!"
    public static func tooManyHelp(limit: Int) -> String {
        "You can only upload \(limit) files at a time!"
    }

    /// A file with nothing in it — and a folder, which a drop delivers as one.
    public static let emptyTitle = "Upload Failed"
    public static let emptyHelp = "File cannot be empty"
}

/// A picture Discord's desktop turns into a JPEG before it uploads it
/// (`85582`, through the system's own image library — ImageIO on a Mac), and
/// the name it gives the result (`452661`).
public enum UploadConversion: Sendable, Equatable {
    case heic
    case jxr

    /// By the type it arrived as — matched as written, as Discord's set
    /// matches it — or by the end of its name, in any case.
    public init?(filename: String, contentType: String?) {
        let ending = filename.lastIndex(of: ".").map { filename[$0...].lowercased() } ?? ""
        func arrived(as types: Set<String>) -> Bool { contentType.map(types.contains) ?? false }
        if arrived(as: ["image/heic", "image/heif", "image/heic-sequence", "image/heif-sequence"])
            || [".heic", ".heif", ".hif"].contains(ending)
        {
            self = .heic
        } else if arrived(as: ["image/jxr", "image/vnd.ms-photo"]) || [".jxr", ".wdp", ".hdp"].contains(ending) {
            self = .jxr
        } else {
            return nil
        }
    }

    /// The JPEG's quality, as Discord encodes it.
    public var quality: Double {
        switch self {
        case .heic: 0.80
        case .jxr: 0.85
        }
    }

    /// The largest file Discord converts; a bigger one goes up as it is.
    public var maximumBytes: Int {
        switch self {
        case .heic: 20 * AttachmentLimits.mebibyte
        case .jxr: 50 * AttachmentLimits.mebibyte
        }
    }

    /// `renameToJpegExtension`: the HEIC or JXR ending becomes `.jpg`, in any
    /// case — and any other name has `.jpg` added.
    public static func jpegName(for filename: String) -> String {
        let lowered = filename.lowercased()
        for ending in [".heic", ".heif", ".hif", ".jxr", ".wdp", ".hdp"] where lowered.hasSuffix(ending) {
            return String(filename.dropLast(ending.count)) + ".jpg"
        }
        return filename + ".jpg"
    }
}
