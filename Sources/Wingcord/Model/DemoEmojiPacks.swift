import AppKit
import WingcordCore

/// The Nitro Emoji Packs `--demo` offers: three packs with made-up ids, their
/// emoji **drawn here, once, into the caches folder** from Unicode glyphs (the
/// `DemoGIFs` arrangement), since the demo makes no requests and a made-up id
/// has no picture on Discord's CDN.
enum DemoEmojiPacks {
    private static let sets: [(id: UInt64, name: String, glyphs: [String])] = [
        (1_400_000_000_000_100_001, "Meow Squad",
         ["😺", "😸", "😹", "😻", "😼", "😽", "🙀", "😿", "😾", "🐱", "🐈", "🐾",
          "🧶", "🐟", "🥛", "📦", "😺", "🫶", "💤", "✨", "🎀", "👑", "🍣", "🌙"]),
        (1_400_000_000_000_200_001, "Little Guys",
         ["🐸", "🐻", "🐼", "🐨", "🐰", "🦊", "🐹", "🐭", "🐷", "🐮", "🐯", "🦁",
          "🐵", "🐔", "🐧", "🐦", "🐤", "🦆", "🦉", "🐺", "🐗", "🐴", "🦄", "🐝", "🐢"]),
        (1_400_000_000_000_300_001, "Skelly",
         ["💀", "☠️", "👻", "🎃", "🦴", "🕷️", "🕸️", "🦇", "⚰️", "🪦", "🔮", "🧟",
          "🧛", "🧙", "👽", "🤖"]),
    ]

    /// Every pack, as `GET /emoji-packs` would answer.
    static let packs: [EmojiPack] = sets.map { set in
        EmojiPack(
            id: set.id,
            name: set.name,
            representativeEmojiID: set.id + 1,
            emojis: set.glyphs.enumerated().map { index, _ in
                EmojiPack.Emoji(id: set.id + 1 + UInt64(index), name: "\(slug(set.name))_\(index + 1)", isAnimated: false)
            }
        )
    }

    /// The pack the demo account has added.
    static let pinned: [UInt64] = [sets[0].id]

    /// A drawn picture for one of these emoji, or nil for any other id.
    static func artURL(for emojiID: UInt64) -> URL? {
        guard let glyph = glyph(for: emojiID) else { return nil }
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DemoEmojiPacks", isDirectory: true)
        let url = folder.appendingPathComponent("\(emojiID).png")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = draw(glyph) else { return nil }
        try? data.write(to: url)
        return url
    }

    private static func glyph(for emojiID: UInt64) -> String? {
        for set in sets where emojiID > set.id && emojiID <= set.id + UInt64(set.glyphs.count) {
            return set.glyphs[Int(emojiID - set.id - 1)]
        }
        return nil
    }

    private static func slug(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: " ", with: "")
    }

    private static func draw(_ glyph: String) -> Data? {
        let side: CGFloat = 96
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let text = NSAttributedString(string: glyph, attributes: [.font: NSFont.systemFont(ofSize: 76)])
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
