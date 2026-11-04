import AppKit
import SwiftUI
import Testing
@testable import Wingcord

/// The coloured squircles in both settings windows' sidebars.
///
/// **A glyph set at a point size is as wide as its artwork**, so the wide ones
/// drew past their tile — Community Overview's three people spilled out on both
/// sides (Alex, 2026-10-26). Each tile is rendered centred in a transparent
/// frame three times its size, and any ink outside the tile's own square is a
/// glyph escaping it.
@MainActor
@Suite("Settings icon tiles")
struct SettingsIconTileTests {

    /// Every symbol a settings sidebar draws, at every size a tile is drawn.
    private static var symbols: [String] {
        SettingsSection.allCases.map(\.symbolName) + ServerSettingsSection.allCases.map(\.symbolName)
    }

    @Test("No glyph draws outside its tile, at any size", arguments: [
        SettingsMetrics.sidebarIconSide, SettingsMetrics.navigationIconSide, 64,
    ])
    func glyphsStayInside(side: CGFloat) throws {
        for symbol in Self.symbols {
            let outside = try inkOutsideTile(symbol, side: side)
            #expect(outside == 0, "\(symbol) at \(side) pt draws \(outside) pixels outside its tile")
        }
    }

    @Test("A square glyph keeps its size; only a wide one is scaled down")
    func onlyWideGlyphsScale() {
        #expect(SettingsIconTile.fit("gearshape.fill", side: 20) == 1)
        #expect(SettingsIconTile.fit("bell.fill", side: 20) == 1)
        #expect(SettingsIconTile.fit("person.3.fill", side: 20) < 1)
    }

    /// Pixels with any ink outside the centred tile's square, rendered at 2x.
    private func inkOutsideTile(_ symbol: String, side: CGFloat) throws -> Int {
        let frame = side * 3
        let renderer = ImageRenderer(
            content: SettingsIconTile(symbolName: symbol, tint: .green, side: side, radius: side / 4)
                .frame(width: frame, height: frame)
                .environment(\.colorScheme, .dark)
        )
        renderer.scale = 2
        let image = try #require(renderer.cgImage, "\(symbol) rendered nothing")

        if let directory = ProcessInfo.processInfo.environment["WINGCORD_RENDER_DIR"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("tile-\(symbol)-\(Int(side)).png")
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        }

        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        // The tile's square, in pixels. No grace: at 2x its edges land on
        // whole pixels, so its own antialiasing stays inside — and a one-pixel
        // grace is exactly what let the sidebar's 20-point spill through.
        let low = Int((side * 2).rounded(.down))
        let high = Int((side * 4).rounded(.up)) - 1
        var outside = 0
        for y in 0..<height {
            for x in 0..<width where x < low || x > high || y < low || y > high {
                if pixels[(y * width + x) * 4 + 3] > 8 { outside += 1 }
            }
        }
        return outside
    }
}
