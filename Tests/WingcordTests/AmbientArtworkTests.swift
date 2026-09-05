import AppKit
import CoreGraphics
import SwiftUI
import Testing
@testable import Wingcord

/// The ambient field must stay inside the surface it lights.
///
/// **The bug this pins was invisible to every other kind of check.** The field
/// is a `.background`, it reported no size upward, it rendered correctly, and
/// it painted an opaque floor across the surface *beside* it — because an
/// aspect-**filled** picture reports the size it grew to, a `ZStack` sizes
/// itself to the largest child, and a background is neither bounded nor clipped
/// by its host. In the full profile that meant a wide banner erased the whole
/// identity panel and a square avatar shaved twenty-odd points off its trailing
/// gutter.
///
/// So the assertion is positional, not "did it draw": the panel's own colour has
/// to survive at the panel's own coordinates. The `fieldActuallyDrew` check is
/// the other half and is not optional — a field that renders nothing at all
/// would pass the first assertion for the wrong reason, and `ImageRenderer` has
/// three documented ways of drawing nothing (see `VoiceRenderTests`).
@MainActor
@Suite("Ambient artwork")
struct AmbientArtworkTests {

    /// The profile sheet's own arrangement: a rail, then a column lit by the
    /// person's picture, side by side with no spacing.
    private static let railWidth: CGFloat = 360
    private static let columnWidth: CGFloat = 680
    /// **Taller than the column is wide**, which is the whole hazard: a filling
    /// picture is scaled to cover, so the surplus goes sideways.
    private static let height: CGFloat = 720

    @Test("a wide picture does not paint over the surface beside it")
    func fieldStaysInsideTheSurfaceItLights() async throws {
        let picture = try Self.writeWidePicture()
        defer { try? FileManager.default.removeItem(at: picture) }
        await Self.warm(picture)

        let image = try #require(Self.render(picture), "the arrangement produced no image")
        let scale = image.width / Int(Self.railWidth + Self.columnWidth)

        // Anywhere in the rail, at three heights, and inset from the seam by a
        // point so an antialiased edge is never what is being asserted.
        for x in [4, Int(Self.railWidth) / 2, Int(Self.railWidth) - 2] {
            for y in [Int(Self.height) / 4, Int(Self.height) / 2, Int(Self.height) * 3 / 4] {
                let pixel = Self.pixel(image, x * scale, y * scale)
                #expect(
                    Self.isRail(pixel),
                    "the field painted over the rail at \(x),\(y) — \(pixel)"
                )
            }
        }

        // The other half. Without it a field that drew nothing would pass.
        let inColumn = Self.pixel(image, Int(Self.railWidth + 200) * scale, Int(Self.height) / 2 * scale)
        #expect(!Self.isRail(inColumn), "the field drew nothing to check — \(inColumn)")
    }

    // MARK: The arrangement

    /// The rail is flat magenta because nothing else in the render is: the
    /// question is only ever "is this still the rail".
    private static func isRail(_ pixel: (r: Int, g: Int, b: Int)) -> Bool {
        pixel.r > 200 && pixel.g < 60 && pixel.b > 200
    }

    private static func render(_ picture: URL) -> CGImage? {
        let renderer = ImageRenderer(
            content: HStack(spacing: 0) {
                Color(red: 1, green: 0, blue: 1)
                    .frame(width: railWidth, height: height)
                Color.clear
                    .frame(width: columnWidth, height: height)
                    .ambientArtwork(picture, tint: nil, strength: 1)
            }
            .frame(width: railWidth + columnWidth, height: height)
        )
        renderer.scale = 1
        return renderer.cgImage
    }

    // MARK: The picture

    /// 2.5:1, which is a user banner's shape and the shape that made the defect
    /// catastrophic rather than merely visible.
    private static func writeWidePicture() throws -> URL {
        let size = NSSize(width: 640, height: 256)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()

        let url = FileManager.default.temporaryDirectory
            .appending(path: "wingcord-ambient-\(UUID().uuidString).png")
        let representation = try #require(
            image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
        )
        let data = try #require(representation.representation(using: .png, properties: [:]))
        try data.write(to: url)
        return url
    }

    /// Puts the picture in the store's cache so `RemoteImage` resolves it in the
    /// same pass it is asked — its synchronous peek is what makes this a
    /// deterministic render rather than a wait on a decode.
    ///
    /// Both rungs, because the pixel size a view asks for is its point size
    /// times the display scale and the renderer sets that.
    private static func warm(_ picture: URL) async {
        for pixels in [64, 128] {
            _ = await ImageStore.shared.image(
                for: ImageStore.Key(url: picture, maximumPixelSize: pixels),
                bucket: .thumbnail
            )
        }
    }

    private static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(
                image,
                in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height)
            )
        }
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }
}
