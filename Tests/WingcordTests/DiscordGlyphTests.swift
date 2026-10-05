import AppKit
import Testing
import WingcordCore
@testable import Wingcord

/// Discord's glyphs, as the app resolves them by name.
///
/// **The failure this guards is silent.** A custom symbol the asset catalog did
/// not compile, or a name that drifted from its symbol set, draws nothing at all
/// — `Image` and `NSImage` both answer an unknown name with an empty picture, and
/// a thread row with no glyph looks like a layout quirk rather than a bug.
struct DiscordGlyphTests {
    @Test("Every thread kind names a glyph the bundle can draw", arguments: [
        ChannelKind.publicThread, .announcementThread, .privateThread,
    ])
    func threadKinds(kind: ChannelKind) throws {
        let name = kind.symbolName
        #expect(DiscordGlyph.owns(name))
        let image = try #require(NSImage.symbol(named: name))
        #expect(image.size.width > 0 && image.size.height > 0)
    }

    @Test("Create Thread's glyph resolves")
    func newThread() throws {
        let image = try #require(NSImage.symbol(named: DiscordGlyph.newThread))
        #expect(image.size.width > 0)
    }

    @Test("Every other name still reaches the system's symbols")
    func systemSymbols() {
        #expect(!DiscordGlyph.owns("number"))
        #expect(NSImage.symbol(named: "number") != nil)
    }

    /// The glyph is sized as an SF Symbol is, so it sits beside text the way the
    /// `#` it replaces in a row does: Discord's thread is 22.5 units of ink to
    /// its `#`'s 20, and the symbol keeps that ratio to `number` within a point.
    @Test("A thread glyph keeps Discord's proportion to the # beside it")
    func proportion() throws {
        let configuration = NSImage.SymbolConfiguration(pointSize: 100, weight: .regular)
        let thread = try #require(NSImage.symbol(named: DiscordGlyph.thread)?.withSymbolConfiguration(configuration))
        let number = try #require(NSImage.symbol(named: "number")?.withSymbolConfiguration(configuration))
        let ratio = Self.inkHeight(thread) / Self.inkHeight(number)
        #expect(abs(ratio - 22.5 / 20) < 0.02)
    }

    /// The height of what an image actually paints, at one pixel per point.
    private static func inkHeight(_ image: NSImage) -> Double {
        let width = Int(image.size.width.rounded(.up))
        let height = Int(image.size.height.rounded(.up))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return 0 }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        var top = height, bottom = -1
        for y in 0..<height {
            for x in 0..<width where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                top = min(top, y)
                bottom = max(bottom, y)
                break
            }
        }
        return bottom < top ? 0 : Double(bottom - top + 1)
    }
}
