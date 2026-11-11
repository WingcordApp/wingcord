import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// What the 2026-11-10 audit against Discord's own component changed: a
/// name's emoji survive its effect, a name is cut to the row it is given, a
/// corner gradient runs the way CSS runs it, and Gummy counts letters.
@MainActor
@Suite("Display name audit")
struct DisplayNameAuditTests {

    private let font = NSFont.systemFont(ofSize: 15, weight: .semibold)

    // MARK: Emoji

    @Test("A name's emoji are kept apart from its outlines, not lost with them")
    func emojiAreKept() throws {
        let run = try #require(
            DisplayNameGlyphRun(text: "JOLLY Dusk 🎄🦌", font: font, tracking: 0, perGlyph: false)
        )
        #expect(run.colorGlyphs.count == 2)
        // Both sit after the letters, on the same line.
        let inkEnd = run.path.boundingBoxOfPath.maxX
        for glyph in run.colorGlyphs { #expect(glyph.origin.x > inkEnd - 1) }
    }

    @Test("A name of nothing but emoji is still a name")
    func emojiOnlyName() throws {
        let run = try #require(
            DisplayNameGlyphRun(text: "🎄🦌", font: font, tracking: 0, perGlyph: false)
        )
        #expect(run.path.isEmpty)
        #expect(run.colorGlyphs.count == 2)
        #expect(run.size.width > 0)
    }

    /// The pixels where the emoji are, for a name drawn by the transcript's
    /// painter: colour there is the emoji, since the effect is one flat ink.
    private func emojiInk(effect: DisplayNameEffect, time: Double?) throws -> Int {
        let name = "ab 🎄🦌"
        let run = try #require(
            DisplayNameGlyphRun(text: name, font: font, tracking: 0, perGlyph: effect == .gummy)
        )
        let prepared = DisplayNameEffectPainter.prepare(
            run: run,
            style: DisplayNameStyle(font: .default, effect: effect, colors: [0xFF_FF_FF]),
            pointSize: font.pointSize,
            characterCount: name.utf16.count
        )
        let width = 160
        let bytes = RenderProbe.pixels(width: width, height: 40) { context, _ in
            DisplayNameEffectPainter.draw(
                prepared, fallback: NSColor.white.cgColor, time: time,
                at: CGPoint(x: 8, y: 8), context: context
            )
        }
        // Anything that is neither the grey ground nor the white ink.
        var coloured = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let (r, g, b) = (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
            if abs(r - g) > 40 || abs(g - b) > 40 || abs(r - b) > 40 { coloured += 1 }
        }
        return coloured
    }

    @Test(
        "The painter draws a lit name's emoji, in their own colours",
        arguments: [DisplayNameEffect.solid, .gradient, .neon, .toon, .pop, .gummy, .prism]
    )
    func painterDrawsEmoji(_ effect: DisplayNameEffect) throws {
        #expect(try emojiInk(effect: effect, time: nil) > 40, "\(effect.title) at rest")
        #expect(try emojiInk(effect: effect, time: 1.3) > 40, "\(effect.title) mid-cycle")
    }

    @Test("The layer tree carries the emoji over the effect")
    func layersCarryEmoji() throws {
        let run = try #require(
            DisplayNameGlyphRun(text: "ab 🎄", font: font, tracking: 0, perGlyph: false)
        )
        let tree = DisplayNameEffectLayers.build(
            run: run,
            style: DisplayNameStyle(font: .default, effect: .neon, colors: [0x99_65_F3]),
            pointSize: font.pointSize,
            fallback: NSColor.white.cgColor,
            animates: false,
            characterCount: 5
        )
        // Last, so it is on top of whatever the effect laid down.
        #expect(tree.sublayers?.last is DisplayNameColorGlyphLayer)

        let plain = try #require(
            DisplayNameGlyphRun(text: "ab", font: font, tracking: 0, perGlyph: false)
        )
        let bare = DisplayNameEffectLayers.build(
            run: plain,
            style: DisplayNameStyle(font: .default, effect: .neon, colors: [0x99_65_F3]),
            pointSize: font.pointSize,
            fallback: NSColor.white.cgColor,
            animates: false,
            characterCount: 2
        )
        #expect(bare.sublayers?.contains { $0 is DisplayNameColorGlyphLayer } == false)
    }

    // MARK: A name cut to its row

    @Test("A name given less room than it needs is cut to it, from the leading edge")
    func nameIsCutToItsRow() throws {
        let view = StyledDisplayNameView()
        let configuration = StyledDisplayNameView.Configuration(
            text: "rex the VIRTUOUS dragon of the northern wastes",
            style: DisplayNameStyle(font: .default, effect: .neon, colors: [0xFF_2D_D4]),
            pointSize: 15,
            animates: false,
            maximumWidth: nil,
            maximumLines: 1
        )
        view.configure(configuration)
        let natural = view.contentSize
        #expect(natural.width > 200)

        // The row hands it 120 points.
        view.frame = CGRect(x: 0, y: 0, width: 120, height: natural.height)
        view.layout()
        let content = try #require(view.layer?.sublayers?.first)
        #expect(content.bounds.width <= 120.5)
        // At the leading edge, not centred across the row and over the face.
        #expect(content.frame.minX == 0)
        // What it reports is still what it would like, so the room can come back.
        #expect(view.contentSize == natural)

        view.frame = CGRect(x: 0, y: 0, width: natural.width + 40, height: natural.height)
        view.layout()
        let whole = try #require(view.layer?.sublayers?.first)
        #expect(abs(whole.bounds.width - natural.width) < 0.5)
    }

    // MARK: Geometry

    @Test("`to bottom right` is corner to corner only on a square")
    func cornerGradientAxis() {
        let square = DisplayNameEffectSpec.Gradient.axis(in: CGSize(width: 40, height: 40))
        #expect(abs(square.start.x) < 0.001 && abs(square.start.y - 40) < 0.001)
        #expect(abs(square.end.x - 40) < 0.001 && abs(square.end.y) < 0.001)

        // A name: five times as wide as it is tall. The ramp runs mostly DOWN,
        // because its midpoint colour has to pass through the other two corners.
        let size = CGSize(width: 100, height: 20)
        let axis = DisplayNameEffectSpec.Gradient.axis(in: size)
        let (dx, dy) = (axis.end.x - axis.start.x, axis.end.y - axis.start.y)
        #expect(abs(dy) > abs(dx) * 4)
        // Perpendicular to the other diagonal: (0, 0) → (w, h) in y-up.
        #expect(abs(dx * size.width + dy * size.height) < 0.001)
        // And the far corners are where the ramp ends: the bottom-right corner
        // projects onto the axis exactly at its end.
        let length = (dx * dx + dy * dy).squareRoot()
        let projection = ((size.width - axis.start.x) * dx + (0 - axis.start.y) * dy) / length
        #expect(abs(projection - length) < 0.001)
    }

    @Test("Stops spread from ten to ninety per cent, for any number of colours")
    func gradientStops() {
        #expect(DisplayNameEffectSpec.Gradient.stops(count: 2) == [0.1, 0.9])
        let three = DisplayNameEffectSpec.Gradient.stops(count: 3)
        #expect(three.count == 3 && abs(three[1] - 0.5) < 0.0001)
    }

    @Test("Prism's tile is a slot a character, and never under thirty-eight points")
    func prismTile() {
        #expect(DisplayNameEffectSpec.Prism.tile(characterCount: 2, zeroAdvance: 9) == 38)
        #expect(DisplayNameEffectSpec.Prism.tile(characterCount: 10, zeroAdvance: 9) == 90)
    }

    @Test("Gummy colours letters, and a space is not one")
    func gummyCountsLetters() throws {
        let run = try #require(
            DisplayNameGlyphRun(text: "ab cd", font: font, tracking: 0, perGlyph: true)
        )
        let colours: [UInt32] = [0xFF_00_00, 0x00_FF_00, 0x00_00_FF, 0xFF_FF_00]
        let tree = DisplayNameEffectLayers.build(
            run: run,
            style: DisplayNameStyle(font: .default, effect: .gummy, colors: colours),
            pointSize: font.pointSize,
            fallback: NSColor.white.cgColor,
            animates: false,
            characterCount: 5
        )
        let letters = (tree.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
        // Four letters, four colours in order: the space took none of them.
        #expect(letters.count == 4)
        let fills = letters.compactMap { $0.fillColor?.components }.map {
            UInt32(($0[0] * 255).rounded()) << 16 | UInt32(($0[1] * 255).rounded()) << 8
                | UInt32(($0[2] * 255).rounded())
        }
        #expect(fills == colours)
    }

    // MARK: Looked at

    /// Written out with `WINGCORD_RENDER_DIR` set: every effect over a name
    /// with emoji in it, at rest and mid-cycle, as the transcript paints it.
    @Test("Every effect, drawn — written out with WINGCORD_RENDER_DIR set")
    func renderSheet() throws {
        guard let directory = ProcessInfo.processInfo.environment["WINGCORD_RENDER_DIR"] else { return }
        let name = "neptune the VIRTUOUS 🐉✨"
        let colours: [DisplayNameEffect: [UInt32]] = [
            .solid: [0x1B_2A_8C],
            .gradient: [0x1B_2A_8C, 0x5B_1F_A8],
            .neon: [0x99_65_F3],
            .toon: [0xF4_20_98],
            .pop: [0x23_A5_5A],
            .gummy: [0xEA_A9_D5, 0xA9_DD_F0, 0xB9_A7_EE, 0xB9_EA_CB],
            .prism: [0xFE_92_42, 0x35_ED_7E, 0xFF_E0_47, 0xFF_4C_D2, 0x58_65_F2],
        ]
        let effects = DisplayNameEffect.offered
        let (width, rowHeight, scale) = (560, 34, 2)
        let height = rowHeight * effects.count * 2
        guard let context = CGContext(
            data: nil, width: width * scale, height: height * scale, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        // Flipped, as the transcript's canvas is.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(srgbRed: 0x1E / 255, green: 0x1F / 255, blue: 0x22 / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        for (index, effect) in effects.enumerated() {
            for (column, legible) in [false, true].enumerated() {
                var style = DisplayNameStyle(font: .default, effect: effect, colors: colours[effect] ?? [])
                if legible { style = style.legible(on: DisplayNameStyle.darkGround) }
                let run = try #require(DisplayNameGlyphRun(
                    text: name, font: font, tracking: 0, perGlyph: effect == .gummy
                ))
                let prepared = DisplayNameEffectPainter.prepare(
                    run: run, style: style, pointSize: font.pointSize,
                    characterCount: name.utf16.count
                )
                for (row, time) in [nil, 1.3].enumerated() {
                    DisplayNameEffectPainter.draw(
                        prepared, fallback: NSColor.white.cgColor, time: time,
                        at: CGPoint(
                            x: 12 + column * 280,
                            y: (index * 2 + row) * rowHeight + 8
                        ),
                        context: context
                    )
                }
            }
        }
        guard let image = context.makeImage() else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("name-effects.png")
        let rep = NSBitmapImageRep(cgImage: image)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
