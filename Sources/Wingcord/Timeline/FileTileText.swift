import AppKit
import CoreText
import Foundation
import os
import Synchronization
import UniformTypeIdentifiers
import WingcordCore

/// The words on a file card (docs/BETA3.md §7, R8): the name shortened in the
/// middle so its extension stays, and the file's kind beside its size.
///
/// **Laid out, not painted**: the layout knows the room, and a repaint should
/// not measure a name again.
nonisolated enum FileTileText {
    /// The name's face: the body's size, a little heavier, so the name reads
    /// as the card's title over its quieter second line.
    static func nameFont(_ style: MessageTextStyle) -> NSFont {
        NSFont.systemFont(ofSize: style.bodyFont.pointSize, weight: .medium)
    }

    /// "PNG image · 22.18 KB" — the system's own name for the kind, the size
    /// as Discord writes it.
    static func kindAndSize(_ attachment: Attachment) -> String {
        let size = DiscordFileSize.text(attachment.size)
        guard let kind = kindName(forExtension: Attachment.extensionOf(attachment.filename)) else { return size }
        return "\(kind) · \(size)"
    }

    private static let kinds = OSAllocatedUnfairLock(initialState: [String: String?]())

    /// The system's description of a file type ("PNG image", "ZIP archive"),
    /// cached by extension — the type database is asked once per kind.
    static func kindName(forExtension ext: String?) -> String? {
        guard let ext, !ext.isEmpty else { return nil }
        if let hit = kinds.withLock({ $0[ext] }) { return hit }
        let name = UTType(filenameExtension: ext)
            .flatMap { $0.isDynamic ? nil : $0.localizedDescription }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        kinds.withLock { $0[ext] = .some(name) }
        return name
    }

    /// The name as it fits `width`: whole where it does, otherwise cut in the
    /// middle — "Screen_Shot_2021-01-1…_AM.png" — so the end of the name and
    /// its extension, which say what the file is, are never what's lost.
    static func fitting(_ name: String, font: NSFont, width: CGFloat) -> String {
        guard width > 0, measure(name, font: font) > width else { return name }
        let characters = Array(name)
        let ext = (name as NSString).pathExtension
        let tail = min(max(0, characters.count - 1), ext.isEmpty ? 6 : ext.count + 7)
        let ending = String(characters.suffix(tail))
        var low = 0
        var high = characters.count - tail
        var best = "…" + ending
        while low <= high {
            let middle = (low + high) / 2
            let candidate = String(characters.prefix(middle)) + "…" + ending
            if measure(candidate, font: font) <= width {
                best = candidate
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return best
    }

    /// A single line's advance, through Core Text (safe off the main thread).
    static func measure(_ text: String, font: NSFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}

/// A file's Finder icon, drawn into the transcript at the card's size.
///
/// **The system's own icon** (`NSWorkspace.icon(for:)`), so a PDF, a ZIP or a
/// Keynote file looks as it does on the desktop — the familiar picture rather
/// than a stand-in. Cached by extension, side and scale; **nonisolated, behind
/// a lock**, because the painter that asks is (as `FileIconArt`).
nonisolated enum FinderIconArt {
    private static let cache = Mutex<[String: CGImage]>([:])

    static func image(forExtension ext: String, side: CGFloat, scale: CGFloat) -> CGImage? {
        let key = "\(ext)@\(Int(side))@\(scale)"
        if let hit = cache.withLock({ $0[key] }) { return hit }
        let type = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
        let icon = NSWorkspace.shared.icon(for: type)
        var rect = CGRect(x: 0, y: 0, width: side * scale, height: side * scale)
        guard let image = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        cache.withLock { $0[key] = image }
        return image
    }
}
