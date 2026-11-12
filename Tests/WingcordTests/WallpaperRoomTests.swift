import CoreGraphics
import Foundation
import Testing
@testable import Wingcord

/// One look, one palette: what is behind the window decides the colours on it.
@MainActor
@Suite("A wallpaper's room")
struct WallpaperRoomTests {
    private let blue = WallpaperTone(hue: 264, chroma: 0.12)

    @Test("the theme's own ground, or My Theme over anything, is the theme's room")
    func themeRoom() {
        #expect(WallpaperRoom.resolve(source: .theme, colours: .automatic, tone: nil) == .theme)
        #expect(WallpaperRoom.resolve(source: .desktop, colours: .theme, tone: nil) == .theme)
        #expect(WallpaperRoom.resolve(source: .preset(.ocean), colours: .theme, tone: blue) == .theme)
    }

    @Test("the desktop has no colour to lend, and neither has a grey picture")
    func neutralRoom() {
        #expect(WallpaperRoom.resolve(source: .desktop, colours: .automatic, tone: nil) == .neutral)
        #expect(WallpaperRoom.resolve(source: .preset(.graphite), colours: .neutral, tone: blue) == .neutral)
        let grey = WallpaperTone(hue: 40, chroma: 0.004)
        #expect(WallpaperRoom.resolve(source: .preset(.graphite), colours: .automatic, tone: grey) == .neutral)
        // A picture whose colour has not been read is not guessed at.
        #expect(WallpaperRoom.resolve(source: .preset(.ocean), colours: .automatic, tone: nil) == .neutral)
    }

    @Test("a picture's room is in the picture's colour")
    func tonedRoom() {
        #expect(WallpaperRoom.resolve(source: .preset(.ocean), colours: .automatic, tone: blue) == .toned(blue))
    }

    @Test("a room is dark or light as the reader's is, and neutral means no theme colour")
    func roomColours() throws {
        #expect(ThemeStore.room(.theme, isDark: true, vividness: 0) == nil)

        let neutralDark = try #require(ThemeStore.room(.neutral, isDark: true, vividness: 0))
        #expect(neutralDark.colors == ThemePreset.graphite.colors(vividness: 0))
        #expect(neutralDark.colors.appearance == .dark)

        let neutralLight = try #require(ThemeStore.room(.neutral, isDark: false, vividness: 0))
        #expect(neutralLight.colors.appearance == .light)

        let toned = try #require(ThemeStore.room(.toned(blue), isDark: true, vividness: 0))
        #expect(toned.colors.appearance == .dark)
        // Not the house grey, and not a house theme either: its own.
        #expect(toned.colors != neutralDark.colors)
        // A light room stays light under a picture.
        let tonedLight = try #require(ThemeStore.room(.toned(blue), isDark: false, vividness: 0))
        #expect(tonedLight.colors.appearance == .light)
    }

    @Test("a tone's seed is quiet, and quieter in the olive band")
    func seedDepth() {
        #expect(blue.seed.head.hue == 264)
        #expect(blue.seed.head.depth <= 0.62)
        #expect(WallpaperTone(hue: 85, chroma: 0.15).seed.head.depth <= 0.3)
        #expect(WallpaperTone(hue: 200, chroma: 0.01).seed.head.depth >= 0.2)
    }

    @Test("a blue picture reads as blue, and a grey one as nothing")
    func toneOfAPicture() throws {
        let blueImage = try #require(Self.solid(red: 0.1, green: 0.2, blue: 0.9))
        let tone = try #require(WallpaperMedia.tone(of: blueImage))
        #expect((240...285).contains(tone.hue))
        #expect(tone.chroma > WallpaperTone.leastChroma)

        let greyImage = try #require(Self.solid(red: 0.4, green: 0.4, blue: 0.4))
        let grey = try #require(WallpaperMedia.tone(of: greyImage))
        #expect(grey.chroma < WallpaperTone.leastChroma)
    }

    private static func solid(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        return context.makeImage()
    }
}
