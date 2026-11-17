import Foundation

/// Discord's own podium pictures, fetched from its CDN when they are first
/// drawn and kept like any other picture — never shipped in the app (Alex,
/// 2026-11-17: fetch at runtime). Everything else on the podium is drawn here
/// from Discord's numbers.
///
/// **Each has a drawn stand-in** for while it loads, and for when Discord
/// renames the file in a later build and the address stops answering.
enum DiscordPodiumArt {
    /// The trophy at the winner's foot (module `125858`), at 3×.
    static let trophy = cdn("7932e36c4b8669c5e63659892d67e50374cd334d7d34026d428db30055172f4a")

    /// The medals by place — the rows' rank 1 to 3 (`83827`, `eT`, `eD`) and
    /// the podium's second and third — at 3×.
    static func medal(_ rank: Int) -> URL? {
        switch rank {
        case 1: cdn("aafe397aef05aff53782c96f270e731d8ffb4f8ea0a1ac64eacea2e9619029ed")
        case 2: cdn("7e79963a2b009fabcc285dc56b301eb819e63b604739b0a48c8e0044a527a800")
        case 3: cdn("b1f5d190ed2b05b6cefd2d44fc875f383134d87d928e3422de92e5e19378a3ae")
        default: nil
        }
    }

    /// The star field behind the podium: a still, shown alone under Reduce
    /// Motion, and its four-second loop.
    static let backdropStill = URL(string: "https://discord.com/assets/df4c2af7174fe116.png")
    static let backdropLoop = URL(string: "https://discord.com/assets/ba010552067644bd.mp4")

    private static func cdn(_ hash: String) -> URL? {
        URL(string: "https://cdn.discordapp.com/assets/content/\(hash).png")
    }
}
