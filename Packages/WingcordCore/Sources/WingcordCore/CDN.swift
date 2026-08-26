import Foundation

/// Builds Discord CDN URLs.
///
/// Pure string work, no networking, so it lives beside the models and can be
/// called from a painter running off the main actor.
///
/// **Every builder takes a drawn side in points and rounds it to a CDN rung.**
/// That is not a convenience — it is the fix for the two ways an avatar comes
/// out wrong. Ask for an asset larger than the slot and the compositor is handed
/// an oversized texture to minify at draw time, which is what a blurry icon
/// actually is; ask for one smaller and it is upscaled. Both ends have to be
/// sized: the rung requested here, and the pixel size the decoder is told to
/// decode to.
public enum CDN {
    public static let host = "https://cdn.discordapp.com"
    public static let mediaHost = "https://media.discordapp.net"

    /// The sizes Discord actually serves. Anything else is rounded up to one of
    /// these server-side, so asking for 100 costs the same as asking for 128 and
    /// returns 128.
    static let rungs: [Int] = [16, 32, 64, 80, 96, 128, 160, 256, 320, 512, 600, 1024, 2048, 4096]

    /// The smallest rung that covers a slot of `side` points at `scale`.
    ///
    /// Backing scale is a parameter rather than a lookup because this runs off
    /// the main actor, where asking a window for its scale is neither possible
    /// nor meaningful.
    public static func rung(forSide side: CGFloat, scale: CGFloat = 2) -> Int {
        let pixels = Int((side * scale).rounded(.up))
        return rungs.first { $0 >= pixels } ?? rungs[rungs.count - 1]
    }

    /// An animated asset is served as GIF; a static one as WebP, which is
    /// roughly a third the bytes of PNG at the same quality and which every
    /// Apple platform decodes natively.
    private static func fileExtension(animated: Bool) -> String {
        animated ? "gif" : "webp"
    }

    public static func avatar(
        userID: UserID,
        hash: String,
        side: CGFloat,
        scale: CGFloat = 2
    ) -> URL? {
        let ext = fileExtension(animated: hash.hasPrefix("a_"))
        return URL(
            string: "\(host)/avatars/\(userID.rawValue)/\(hash).\(ext)?size=\(rung(forSide: side, scale: scale))"
        )
    }

    /// The per-guild avatar override, which beats the account avatar wherever
    /// that guild is the context.
    public static func guildMemberAvatar(
        guildID: GuildID,
        userID: UserID,
        hash: String,
        side: CGFloat,
        scale: CGFloat = 2
    ) -> URL? {
        let ext = fileExtension(animated: hash.hasPrefix("a_"))
        return URL(
            string: "\(host)/guilds/\(guildID.rawValue)/users/\(userID.rawValue)/avatars/\(hash).\(ext)"
                + "?size=\(rung(forSide: side, scale: scale))"
        )
    }

    /// The fallback for an account with no avatar. Always PNG and always 256 —
    /// it is a flat colour with a glyph, so there is nothing a larger rung buys
    /// and no animated form to ask for.
    public static func defaultAvatar(index: Int) -> URL? {
        URL(string: "\(host)/embed/avatars/\(index).png")
    }

    public static func guildIcon(
        guildID: GuildID,
        hash: String,
        side: CGFloat,
        scale: CGFloat = 2
    ) -> URL? {
        let ext = fileExtension(animated: hash.hasPrefix("a_"))
        return URL(
            string: "\(host)/icons/\(guildID.rawValue)/\(hash).\(ext)?size=\(rung(forSide: side, scale: scale))"
        )
    }

    public static func guildBanner(
        guildID: GuildID,
        hash: String,
        width: CGFloat,
        scale: CGFloat = 2
    ) -> URL? {
        let ext = fileExtension(animated: hash.hasPrefix("a_"))
        return URL(
            string: "\(host)/banners/\(guildID.rawValue)/\(hash).\(ext)?size=\(rung(forSide: width, scale: scale))"
        )
    }

    public static func userBanner(
        userID: UserID,
        hash: String,
        width: CGFloat,
        scale: CGFloat = 2
    ) -> URL? {
        let ext = fileExtension(animated: hash.hasPrefix("a_"))
        return URL(
            string: "\(host)/banners/\(userID.rawValue)/\(hash).\(ext)?size=\(rung(forSide: width, scale: scale))"
        )
    }

    /// A custom emoji. Animated ones are GIF; the size rung matters here more
    /// than anywhere, because an inline emoji is drawn at 20pt and the source is
    /// 128.
    public static func emoji(
        id: EmojiID,
        animated: Bool,
        side: CGFloat,
        scale: CGFloat = 2
    ) -> URL? {
        URL(
            string: "\(host)/emojis/\(id.rawValue).\(fileExtension(animated: animated))"
                + "?size=\(rung(forSide: side, scale: scale))"
        )
    }

    /// An avatar decoration — the ring or frame drawn around an avatar. Always
    /// PNG: these are authored with alpha and Discord does not serve a WebP
    /// rendition.
    public static func avatarDecoration(hash: String) -> URL? {
        URL(string: "\(host)/avatar-decoration-presets/\(hash).png?size=160&passthrough=true")
    }

    /// A group DM's icon.
    public static func channelIcon(
        channelID: ChannelID,
        hash: String,
        side: CGFloat,
        scale: CGFloat = 2
    ) -> URL? {
        URL(
            string: "\(host)/channel-icons/\(channelID.rawValue)/\(hash).webp"
                + "?size=\(rung(forSide: side, scale: scale))"
        )
    }

    /// The badge that rides inside a clan tag chip.
    ///
    /// Always PNG and always small: it is drawn at eleven points beside nine-point
    /// letters, so there is nothing a larger rung buys.
    public static func guildTagBadge(guildID: GuildID, hash: String) -> URL? {
        URL(string: "\(host)/clan-badges/\(guildID.rawValue)/\(hash).png?size=32")
    }

    public static func roleIcon(
        roleID: RoleID,
        hash: String,
        side: CGFloat,
        scale: CGFloat = 2
    ) -> URL? {
        URL(
            string: "\(host)/role-icons/\(roleID.rawValue)/\(hash).webp"
                + "?size=\(rung(forSide: side, scale: scale))"
        )
    }

    public static func sticker(id: UInt64, format: StickerRef.Format) -> URL? {
        switch format {
        case .lottie:
            URL(string: "\(host)/stickers/\(id).json")
        case .gif:
            URL(string: "\(mediaHost)/stickers/\(id).gif")
        case .png, .apng, .unknown:
            URL(string: "\(host)/stickers/\(id).png?size=320")
        }
    }

    /// Rewrites an attachment URL to request a resized rendition from the media
    /// proxy.
    ///
    /// The proxy accepts `width`/`height` query parameters and returns a scaled
    /// image; the raw `cdn.discordapp.com` URL does not. Downloading a 12-megapixel
    /// phone photo to draw it 400pt wide is the single largest avoidable cost on
    /// an image-heavy channel, and this is where it is avoided.
    public static func resizedAttachment(
        proxyURL: String,
        width: CGFloat,
        scale: CGFloat = 2
    ) -> URL? {
        guard var components = URLComponents(string: proxyURL) else {
            return URL(string: proxyURL)
        }
        let pixels = Int((width * scale).rounded(.up))
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "width" || $0.name == "height" || $0.name == "format" }
        items.append(URLQueryItem(name: "width", value: String(pixels)))
        // Height is deliberately left to the proxy so the aspect ratio is
        // preserved; asking for both forces a crop.
        components.queryItems = items
        return components.url
    }
}
