import AppKit
import CoreGraphics
import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// A shared theme drawn through Discord's custom-theme generator, kept as a
/// choice, and its card in the transcript.
@MainActor
@Suite("Shared themes")
struct SharedThemeTests {

    private let theme = SharedClientTheme(
        colors: [0x58_65_F2, 0xEB_45_9E], gradientAngle: 90, baseMix: 74, baseTheme: 1
    )

    @Test("The generator is fed from the share: its colours, angle, mix and its own room")
    func generator() {
        let dark = ServerTheme(shared: theme)
        #expect(dark.stops == [0x58_65_F2, 0xEB_45_9E])
        #expect(dark.angle == 90)
        #expect(dark.room == .dark)
        // `dY` at a base mix of 74: the veils through (30 + 0.7·26)/100,
        // written by Discord as `toFixed(2)` — 0.48 — and the base mixed in
        // at 60 + 0.4·26 = 70.4 %.
        #expect(dark.veilMix == 0.48)
        #expect(abs(dark.baseAmount - 70.4) < 0.0001)
        #expect(dark.colors.appearance == .dark)

        var light = theme
        light.baseTheme = 2
        let lit = ServerTheme(shared: light)
        #expect(lit.room == .light)
        #expect(abs(lit.baseAmount - (30 - 0.2 * 74)) < 0.0001)
        #expect(lit.colors.appearance == .light)
    }

    @Test("A blend shared lands on the sharer's page, through Discord's veil")
    func sharingABlend() {
        for preset in [ThemePreset.nightfall, .ember, .lagoon] {
            var seed = preset.seed
            seed.middle = [seed.stop(at: 0.5)]
            let shared = SharedClientTheme(sharing: seed)
            #expect(shared.colors.count == 3, "every colour of the blend")
            #expect(shared.gradientAngle == seed.angle)
            #expect(shared.baseMix == 100)
            #expect(shared.baseTheme == 1, "a blend is the dark room")
            #expect(shared.isValid)

            // What Discord's generator shows of each stop on the page is the
            // sharer's own page colour, to a step of rounding.
            let keep = 1 - ServerTheme(shared: shared).pageVeil
            for (index, sent) in shared.colors.enumerated() {
                let own = seed.field(at: seed.position(ofAnchor: index)).packedRGB()
                for shift: UInt32 in [16, 8, 0] {
                    let shown = Double((sent >> shift) & 0xFF) * keep
                    #expect(abs(shown - Double((own >> shift) & 0xFF)) <= 1, "\(preset) stop \(index)")
                }
            }
        }
    }

    @Test("A kept theme is a choice that survives a relaunch")
    func storage() {
        let stored = ThemeStore.storageValue(for: .shared(theme))
        #expect(ThemeStore.choice(forStorageValue: stored) == .shared(theme))
        #expect(ThemeChoice.shared(theme).isStated, "its intensity is the sharer's")
        // A blob that does not decode is no choice at all, never a broken one.
        #expect(ThemeStore.choice(forStorageValue: "shared·garbage") == nil)
    }

    @Test("Saved themes round-trip as stored")
    func savedCoding() throws {
        let saved = SavedTheme(theme: theme, creatorName: "alex")
        let back = try JSONDecoder().decode(SavedTheme.self, from: JSONEncoder().encode(saved))
        #expect(back == saved)
    }

    @Test("The card lays out and draws — written out with WINGCORD_RENDER_DIR set")
    func card() throws {
        let style = MessageTextStyle.current()
        let slot = SharedThemeCardLayoutEngine.layout(
            theme, creatorName: "alex", creatorAvatarURL: nil,
            origin: .zero, availableWidth: 600, style: style
        )
        #expect(slot.rect.width == 300)
        #expect(slot.title.text.attributed.string == "Custom Theme")
        #expect(slot.creator.text.attributed.string == "Created by alex")
        #expect(slot.preview.idle.label.text.attributed.string == "Preview")
        #expect(slot.preview.active.label.text.attributed.string == "Stop Preview")
        #expect(slot.save.active.label.text.attributed.string == "Saved")

        guard let directory = ProcessInfo.processInfo.environment["WINGCORD_RENDER_DIR"] else { return }
        for (name, previewing, saved) in [("theme-card", false, false), ("theme-card-previewing", true, true)] {
            let size = CGSize(width: slot.rect.width + 24, height: slot.rect.height + 24)
            let scale: CGFloat = 2
            let context = try #require(CGContext(
                data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.scaleBy(x: scale, y: scale)
            context.setFillColor(ThemeInk.current.canvas)
            context.fill(CGRect(origin: .zero, size: size))
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            TimelineRowPainter.drawSharedThemeCard(
                slot, offset: CGPoint(x: 12, y: 12), context: context,
                isPreviewing: previewing, isSaved: saved, hovered: nil,
                images: ImageStore.shared, scale: scale
            )
            NSGraphicsContext.current = nil
            let image = try #require(context.makeImage())
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }
}
