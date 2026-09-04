import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Wingcord
@testable import WingcordCore

/// Writes a picture of the channel head, when asked.
///
/// **Off unless `WINGCORD_SNAPSHOTS` names a directory.** A test that writes
/// files on every run is a test that fails on a machine with a read-only
/// checkout, and the picture is for a person to look at rather than for CI to
/// compare — the assertions that hold the geometry are in
/// `ChannelHeadLayoutTests`.
///
///     WINGCORD_SNAPSHOTS=/tmp/shots swift test --filter ChannelHead
@MainActor
@Suite("Channel head snapshot")
struct ChannelHeadSnapshotTests {

    @Test("Writes a picture of the head when asked to")
    func snapshot() throws {
        guard let directory = ProcessInfo.processInfo.environment["WINGCORD_SNAPSHOTS"] else {
            return
        }
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )

        for (name, topic) in [
            ("general", nil as String?),
            ("🗳 | voting", "Vote on things here"),
        ] {
            var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
            let rows = TimelineLayoutEngine(presentationRevision: 1).layout(
                TimelineLayoutEngine.Input(
                    items: [.conversationStart],
                    width: 640,
                    style: MessageTextStyle.current(),
                    mentions: MentionContext(),
                    channelName: name,
                    channelSymbol: "number",
                    channelTopic: topic,
                    authors: [:],
                    calendar: .current,
                    settings: PresentationRevision.shared.timeline
                ),
                cache: &cache
            )
            let height = Int(rows[0].height.rounded(.up)) + 24
            let scale = 2
            guard let context = CGContext(
                data: nil,
                width: 640 * scale,
                height: height * scale,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                Issue.record("no bitmap context")
                return
            }
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            context.setFillColor(ThemeInk.current.canvas)
            context.fill(CGRect(x: 0, y: 0, width: 640, height: CGFloat(height)))
            // The canvas is flipped; a bitmap context is not.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            TimelineRowPainter.draw(
                row: rows[0],
                in: CGRect(x: 0, y: 0, width: 640, height: rows[0].height),
                context: context,
                style: MessageTextStyle.current(),
                state: TimelineRowPainter.State(),
                images: ImageStore.shared,
                scale: CGFloat(scale)
            )
            NSGraphicsContext.restoreGraphicsState()

            guard let image = context.makeImage() else {
                Issue.record("no image")
                return
            }
            let file = URL(filePath: directory)
                .appending(path: "head-\(name.replacingOccurrences(of: " ", with: "_")).png")
            guard let destination = CGImageDestinationCreateWithURL(
                file as CFURL, "public.png" as CFString, 1, nil
            ) else {
                Issue.record("no destination")
                return
            }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
    }
}
