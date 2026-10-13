import AppKit
import CoreGraphics
import Synchronization
import WingcordCore

/// Discord's file icons (`492313`'s `./icon-file-*.svg`): rasterised once per
/// icon, size and backing scale — a file card's and an upload's 30×40, or
/// Modify Attachment's 72×96, which is the drawing's own.
///
/// **Nonisolated, behind a lock**, because the painter that asks is.
nonisolated enum FileIconArt {
    /// The size the drawings are made at, which Modify Attachment shows them at.
    static let naturalSize = CGSize(width: 72, height: 96)

    private static let cache = Mutex<[String: CGImage]>([:])

    static func image(
        for kind: AttachmentFileKind,
        size: CGSize = TimelineMetrics.fileCardIcon,
        scale: CGFloat
    ) -> CGImage? {
        let key = "\(kind.iconName)@\(size.width)x\(size.height)@\(scale)"
        if let hit = cache.withLock({ $0[key] }) { return hit }
        guard let url = Bundle.module.url(forResource: kind.iconName, withExtension: "svg", subdirectory: "Art/FileIcons"),
              let source = NSImage(contentsOf: url)
        else { return nil }
        var rect = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
        guard let image = source.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        cache.withLock { $0[key] = image }
        return image
    }
}
