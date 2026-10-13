import Foundation

/// An emoji or a sticker sent as a link to its picture — Vencord's Fake Nitro,
/// which every client without the plugin draws as a blue name with the picture
/// unfurled beneath it ("FMOG", `references/2026-10-05/06`).
///
/// ```
/// [FMOG](https://cdn.discordapp.com/emojis/<id>.webp?size=48&name=FMOG&lossless=true)
/// [wave](https://media.discordapp.net/stickers/<id>.png?size=160&name=wave&lossless=true)
/// ```
///
/// **Drawn as what it stands for, whether or not the reader sends them**
/// (decision 10): an emoji inline in the sentence, a sticker as a sticker, and
/// the unfurl not at all — the plugin's own receiving rules, its regexes
/// `/emojis/(\d+?)\.(png|webp|gif)` and `/stickers/(\d+?)\.`, masked or bare,
/// inside longer messages too.
///
/// **Only on Discord's own CDN**, which the plugin does not check: a link
/// elsewhere that happened to end in `/emojis/1.png` would otherwise draw as
/// an emoji and hide where it goes. Every sender writes Discord's hosts.
public enum FakeNitroLink: Hashable, Sendable {
    case emoji(EmojiRef)
    case sticker(StickerRef)

    private static let hosts: Set<String> = ["cdn.discordapp.com", "media.discordapp.net"]

    /// - Parameter label: a masked link's text, the name's last resort.
    public init?(url: String, label: String? = nil) {
        guard let components = URLComponents(string: url),
              let host = components.host?.lowercased(), Self.hosts.contains(host)
        else { return nil }
        let parts = components.path.split(separator: "/")
        guard parts.count == 2 else { return nil }
        let file = parts[1].split(separator: ".", maxSplits: 1)
        guard file.count == 2, let id = UInt64(file[0]) else { return nil }
        let fileExtension = file[1].lowercased()
        let query = components.queryItems ?? []
        let named = query.first { $0.name == "name" }?.value.flatMap { $0.isEmpty ? nil : $0 }
            ?? label.flatMap { $0.isEmpty || $0.hasPrefix("http") ? nil : $0 }

        switch parts[0] {
        case "emojis":
            guard ["png", "webp", "gif"].contains(fileExtension) else { return nil }
            let animated = fileExtension == "gif"
                || query.first { $0.name == "animated" }?.value == "true"
            self = .emoji(EmojiRef(id: EmojiID(rawValue: id), name: named ?? "emoji", isAnimated: animated))
        case "stickers":
            self = .sticker(StickerRef(
                id: id, name: named ?? "sticker", format: fileExtension == "gif" ? .gif : .png
            ))
        default:
            return nil
        }
    }

    /// The sticker an attachment stands for: the plugin's animated sticker,
    /// sent as `<sticker id>.gif` — its `/attachments/\d+?/\d+?/(\d+?)\.gif`,
    /// on a GIF. Whether it IS that sticker the plugin asks its sticker store,
    /// and so does the caller; a GIF that happens to be named with digits is
    /// otherwise just a GIF.
    public static func gifStickerID(in attachment: Attachment) -> UInt64? {
        guard attachment.contentType == "image/gif" || attachment.filename.lowercased().hasSuffix(".gif"),
              let components = URLComponents(string: attachment.url),
              let host = components.host?.lowercased(), hosts.contains(host)
        else { return nil }
        let parts = components.path.split(separator: "/")
        guard parts.count == 4, parts[0] == "attachments",
              UInt64(parts[1]) != nil, UInt64(parts[2]) != nil,
              parts[3].lowercased().hasSuffix(".gif")
        else { return nil }
        return UInt64(parts[3].dropLast(4))
    }

    /// Every fake link in a message's words — bare, or as `[name](url)` — in
    /// the order written.
    public static func links(in content: String) -> [FakeNitroLink] {
        var found: [FakeNitroLink] = []
        var rest = Substring(content)
        while let open = rest.range(of: "http") {
            let start = open.lowerBound
            // A masked link's label, when the URL sits in `[label](…)`.
            var label: String?
            if start > rest.startIndex, rest[rest.index(before: start)] == "(",
               let closeBracket = rest[..<start].lastIndex(of: "]"),
               let openBracket = rest[..<closeBracket].lastIndex(of: "[") {
                label = String(rest[rest.index(after: openBracket)..<closeBracket])
            }
            let end = rest[start...].firstIndex { $0.isWhitespace || $0 == ")" || $0 == ">" }
                ?? rest.endIndex
            if let link = FakeNitroLink(url: String(rest[start..<end]), label: label) {
                found.append(link)
            }
            rest = rest[end...]
        }
        return found
    }
}
