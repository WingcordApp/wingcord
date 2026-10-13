import Foundation

/// Sending what the account cannot use, as Vencord's Fake Nitro sends it —
/// the reader's own choice, off unless turned on (decision 9).
///
/// An emoji becomes `[name](https://cdn.discordapp.com/emojis/<id>.<webp|gif>?size=48&name=<name>&lossless=true)`
/// in place, and a sticker is appended as
/// `[name](https://media.discordapp.net/stickers/<id>.<png|gif>?size=160&name=<name>&lossless=true)`
/// — the plugin's defaults (`emojiSize` 48, `stickerSize` 160, hyperlinks on
/// with the name as their text), so a reader with the plugin, or with this
/// client, draws them as the real thing (`FakeNitroLink`), and everybody else
/// sees the picture unfurled.
public enum FakeNitroSend {
    static let emojiSize = 48
    static let stickerSize = 160

    /// Nil for a Unicode emoji, which every account can send.
    public static func link(for emoji: EmojiRef) -> String? {
        guard let id = emoji.id else { return nil }
        let name = emoji.name
        let url = "https://cdn.discordapp.com/emojis/\(id.rawValue).\(emoji.isAnimated ? "gif" : "webp")"
            + "?size=\(emojiSize)&name=\(escaped(name))&lossless=true"
        return "[\(name)](\(url))"
    }

    /// Nil for a Lottie sticker, which has no picture on the CDN to link to —
    /// and for an animated PNG, which the plugin never links (a PNG link draws
    /// one frame): it goes into the tray as a GIF instead.
    public static func link(for sticker: StickerRef) -> String? {
        let fileExtension: String
        switch sticker.format {
        case .png: fileExtension = "png"
        case .gif: fileExtension = "gif"
        case .apng, .lottie, .unknown: return nil
        }
        let url = "https://media.discordapp.net/stickers/\(sticker.id).\(fileExtension)"
            + "?size=\(stickerSize)&name=\(escaped(sticker.name))&lossless=true"
        return "[\(sticker.name)](\(url))"
    }

    /// The words with every emoji the sender cannot use replaced by its link,
    /// padded off its neighbours as the plugin pads it.
    ///
    /// - Parameter isUnusable: whether this account may not send the emoji
    ///   here — another server's without Nitro, an animated one without it.
    public static func replacingEmoji(in content: String, where isUnusable: (EmojiRef) -> Bool) -> String {
        // `<a:name:id>` or `<:name:id>` — the plugin's own pattern, which
        // also leaves one escaped with a backslash alone.
        let pattern = /<(a?):(\w+):(\d+)>/
        var result = ""
        var cursor = content.startIndex
        for match in content.matches(of: pattern) {
            let start = match.range.lowerBound
            if start > content.startIndex, content[content.index(before: start)] == "\\" { continue }
            guard let id = UInt64(match.output.3) else { continue }
            let emoji = EmojiRef(
                id: EmojiID(rawValue: id), name: String(match.output.2), isAnimated: !match.output.1.isEmpty
            )
            guard isUnusable(emoji), let link = link(for: emoji) else { continue }
            result += content[cursor..<start]
            result += boundary(before: start, in: content)
            result += link
            result += boundary(after: match.range.upperBound, in: content)
            cursor = match.range.upperBound
        }
        result += content[cursor...]
        return result
    }

    /// The words with a sticker's link at the end.
    public static func appending(_ link: String, to content: String) -> String {
        guard let last = content.last, !last.isWhitespace else { return content + link }
        return content + " " + link
    }

    private static func boundary(before index: String.Index, in content: String) -> String {
        guard index > content.startIndex, !content[content.index(before: index)].isWhitespace else { return "" }
        return " "
    }

    private static func boundary(after index: String.Index, in content: String) -> String {
        guard index < content.endIndex, !content[index].isWhitespace else { return "" }
        return " "
    }

    private static func escaped(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(["&", "=", "+"])) ?? name
    }
}
