import AppKit
import QuartzCore
import Testing
import WingcordCore
@testable import Wingcord

/// What the styled-name renderer builds.
///
/// **These assert the layer tree and its animations, not pixels.** Every
/// duration, keyframe and stop below is Discord's own, and the thing most
/// likely to rot is a number quietly drifting — a 4s cycle becoming 4.5, a hold
/// disappearing, `keyTimes` and `values` falling out of step. A screenshot
/// cannot catch any of those; reading the animation back can.
///
/// The other half is the cost argument: if these were driven by a timer instead
/// of by Core Animation, `animation(forKey:)` would come back nil and every one
/// of these would fail.
@Suite("Display name rendering")
@MainActor
struct DisplayNameRenderingTests {

    private let font = NSFont.systemFont(ofSize: 24, weight: .bold)

    private func run(_ text: String, perGlyph: Bool = false) throws -> DisplayNameGlyphRun {
        try #require(
            DisplayNameGlyphRun(text: text, font: font, tracking: 0, perGlyph: perGlyph)
        )
    }

    private func build(
        _ effect: DisplayNameEffect,
        colors: [UInt32],
        text: String = "alex",
        animates: Bool = true
    ) throws -> CALayer {
        let perGlyph = effect == .gummy
        return DisplayNameEffectLayers.build(
            run: try run(text, perGlyph: perGlyph),
            style: DisplayNameStyle(font: .default, effect: effect, colors: colors),
            pointSize: 24,
            fallback: CGColor.white,
            animates: animates,
            characterCount: text.utf16.count
        )
    }

    /// Walks the tree, since the effects nest a gradient inside a masked window.
    private func descendants(of layer: CALayer) -> [CALayer] {
        (layer.sublayers ?? []).flatMap { [$0] + descendants(of: $0) }
    }

    private func animations(in layer: CALayer) -> [CAAnimation] {
        ([layer] + descendants(of: layer)).flatMap { node in
            (node.animationKeys() ?? []).compactMap { node.animation(forKey: $0) }
        }
    }

    /// Keyframe values are floats derived from a point size, so they are
    /// compared within a tolerance rather than exactly — an assertion that
    /// depends on the last bit of `0.05 * 24` is testing the FPU, not the
    /// renderer.
    private func expectClose(
        _ got: [CGFloat],
        _ want: [CGFloat],
        _ label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(got.count == want.count, "\(label) length", sourceLocation: sourceLocation)
        for (index, (a, b)) in zip(got, want).enumerated() {
            #expect(
                abs(a - b) < 1e-9,
                "\(label)[\(index)]: got \(a), want \(b)",
                sourceLocation: sourceLocation
            )
        }
    }

    // MARK: Layout

    @Test("A run measures its own box and finds the digit advance")
    func glyphRunMetrics() throws {
        let laid = try run("alex")
        #expect(laid.size.width > 0)
        #expect(laid.size.height > 0)
        #expect(laid.zeroAdvance > 0)
        #expect(!laid.path.isEmpty)
        // Split only when asked, because Gummy is the only effect that needs it.
        #expect(laid.glyphs.isEmpty)
    }

    @Test("Splitting per glyph keeps one box per character, spaces included")
    func perGlyphBoxes() throws {
        let laid = try run("a b", perGlyph: true)
        #expect(laid.glyphs.count == 3)
        // A space owns a box and no outline — Gummy still squashes it, which is
        // what keeps the wave's phase across a two-word name.
        #expect(laid.glyphs[1].path.isEmpty)
        #expect(laid.glyphs[1].box.width > 0)
        // Boxes tile left to right without overlapping.
        for (left, right) in zip(laid.glyphs, laid.glyphs.dropFirst()) {
            #expect(right.box.minX >= left.box.minX)
        }
    }

    // MARK: The static two

    @Test("Solid and Gradient are built with nothing to animate")
    func staticEffectsCarryNoAnimations() throws {
        for effect in [DisplayNameEffect.solid, .gradient] {
            let layer = try build(effect, colors: [0xF4_20_98, 0x2A_AE_A6])
            #expect(animations(in: layer).isEmpty, "\(effect) should not animate")
        }
    }

    /// The inset is a design decision, not a rounding of 0 and 100: it holds
    /// each endpoint colour across a tenth of the diagonal so a short name shows
    /// both rather than reading as one midpoint.
    @Test("Gradient's stops are 10% and 90%")
    func gradientStopInset() throws {
        let layer = try build(.gradient, colors: [0x2A_AE_A6, 0xFF_C4_90])
        let gradient = try #require(
            ([layer] + descendants(of: layer)).compactMap { $0 as? CAGradientLayer }.first
        )
        #expect(gradient.locations == [0.1, 0.9])
        #expect(gradient.colors?.count == 2)
        // `to bottom right`, in the y-up space the layers are built in.
        #expect(gradient.startPoint == CGPoint(x: 0, y: 1))
        #expect(gradient.endPoint == CGPoint(x: 1, y: 0))
    }

    // MARK: The animated five

    @Test("Every animated effect runs on Discord's own cycle, forever")
    func cyclesAndRepeat() throws {
        for (effect, colors, duration) in [
            (DisplayNameEffect.neon, [0x99_65_F3], 4.0),
            (.toon, [0xF4_20_98], 4.0),
            (.pop, [0x23_A5_5A], 4.0),
            (.gummy, [0xEA_A9_D5, 0xA9_DD_F0, 0xB9_A7_EE, 0xB9_EA_CB], 4.0),
            (.prism, [0xFE_92_42, 0x35_ED_7E, 0xFF_E0_47, 0xFF_4C_D2, 0x58_65_F2], 2.0),
        ] as [(DisplayNameEffect, [UInt32], Double)] {
            let found = animations(in: try build(effect, colors: colors))
            #expect(!found.isEmpty, "\(effect) built no animation")
            for animation in found {
                #expect(animation.duration == duration, "\(effect) duration")
                #expect(animation.repeatCount == .infinity, "\(effect) should loop")
                #expect(!animation.isRemovedOnCompletion, "\(effect) would stop and vanish")
            }
        }
    }

    /// A keyframe animation with one timing function eases the whole run and
    /// flattens every hold in it. A browser eases each segment.
    @Test("Keyframes carry one timing function per segment")
    func perSegmentTiming() throws {
        for (effect, colors) in [
            (DisplayNameEffect.neon, [0x99_65_F3]),
            (.toon, [0xF4_20_98]),
            (.pop, [0x23_A5_5A]),
            (.gummy, [0xEA_A9_D5, 0xA9_DD_F0]),
        ] as [(DisplayNameEffect, [UInt32])] {
            for case let frames as CAKeyframeAnimation in animations(in: try build(effect, colors: colors)) {
                let times = try #require(frames.keyTimes)
                #expect(frames.values?.count == times.count, "\(effect) values/keyTimes disagree")
                #expect(frames.timingFunctions?.count == times.count - 1, "\(effect) timing count")
            }
        }
    }

    @Test("Neon flickers on the fill and leaves the glow alone")
    func neonFlickersOnlyTheCore() throws {
        let layer = try build(.neon, colors: [0x99_65_F3])
        // Glow, stroke, core.
        #expect(layer.sublayers?.count == 3)
        let found = animations(in: layer)
        #expect(found.count == 1, "only the core should animate")
        let flicker = try #require(found.first as? CAKeyframeAnimation)
        #expect(flicker.keyPath == "fillColor")
        // 0, 15, 16, 18, 20, 22, 23, 25, 28, 50, 100.
        #expect(flicker.keyTimes?.count == 11)
        // The glow is a blurred silhouette, and blurring it once instead of per
        // frame is the difference between a shadow and a Gaussian every tick.
        let glow = try #require(layer.sublayers?.first as? CAShapeLayer)
        #expect(glow.shadowOpacity == 1)
        #expect(glow.shadowRadius == 4 + 0.12 * 24)
        #expect(glow.shadowPath != nil)
    }

    @Test("Toon's sheen is four line-boxes tall and slides three of them")
    func toonSheenTravel() throws {
        let layer = try build(.toon, colors: [0xF4_20_98])
        let sheen = try #require(descendants(of: layer).compactMap { $0 as? CAGradientLayer }.first)
        #expect(sheen.colors?.count == 10)
        #expect(sheen.locations == [0, 0.08, 0.15, 0.25, 0.45, 0.55, 0.75, 0.83, 0.90, 1])
        let height = layer.bounds.height
        #expect(sheen.bounds.height == height * 4)
        let slide = try #require(sheen.animation(forKey: "sheen") as? CAKeyframeAnimation)
        let values = try #require(slide.values as? [CGFloat])
        #expect(values == [-height, -height, height * 2, height * 2])
        // The hold is in the keyframes, not in the easing.
        #expect(slide.keyTimes == [0, 0.05, 0.55, 1])
    }

    @Test("Pop moves its letters and its extrusion in opposite phase")
    func popSeparation() throws {
        let layer = try build(.pop, colors: [0x23_A5_5A])
        let lifts = ([layer] + descendants(of: layer))
            .compactMap { $0.animation(forKey: "lift") as? CAKeyframeAnimation }
        #expect(lifts.count == 2)
        let em = 24.0
        let letters = try #require(lifts.compactMap { $0.values as? [CGFloat] }
            .first { $0.first == 0 })
        let shadow = try #require(lifts.compactMap { $0.values as? [CGFloat] }
            .first { $0.first != 0 })
        expectClose(letters, [0, 0.05 * em, -0.08 * em, 0, 0], "letters")
        expectClose(shadow, [-0.08 * em, -0.13 * em, 0, -0.08 * em, -0.08 * em], "shadow")
        // Their separation is the effect: widest at 18%, inverted at 35%.
        #expect(shadow[1] - letters[1] < shadow[0] - letters[0])
        #expect(shadow[2] - letters[2] > 0)
    }

    @Test("Gummy colours letters modulo the palette and staggers them 50ms apart")
    func gummyStagger() throws {
        let colors: [UInt32] = [0xEA_A9_D5, 0xA9_DD_F0, 0xB9_A7_EE, 0xB9_EA_CB]
        let layer = try build(.gummy, colors: colors, text: "abcdef")
        let letters = try #require(layer.sublayers as? [CAShapeLayer])
        #expect(letters.count == 6)
        // The fifth letter wraps onto the first colour.
        #expect(letters[0].fillColor == letters[4].fillColor)
        #expect(letters[1].fillColor == letters[5].fillColor)
        #expect(letters[0].fillColor != letters[1].fillColor)

        let begins = letters.compactMap { $0.animation(forKey: "transform.scale.y")?.beginTime }
        #expect(begins.count == 6)
        for (index, (earlier, later)) in zip(begins, begins.dropFirst()).enumerated() {
            #expect(abs((later - earlier) - 0.05) < 1e-9, "letter \(index) stagger")
        }
        let squish = try #require(
            letters[0].animation(forKey: "transform.scale.y") as? CAKeyframeAnimation
        )
        #expect(squish.values as? [Double] == [1.0, 0.72, 1.18, 0.9, 1.04, 1.0, 1.0])
    }

    /// The tile is a count of character *slots*, so the rainbow reads the same
    /// in a wide face and a narrow one.
    @Test("Prism's tile is characterCount x the digit advance")
    func prismTileWidth() throws {
        let text = "robinresting"
        let laid = try run(text)
        let layer = try build(.prism, colors: [0xFE_92_42, 0x35_ED_7E, 0xFF_E0_47], text: text)
        let scroll = try #require(descendants(of: layer).compactMap { $0 as? CAGradientLayer }.first)
        let tile = CGFloat(text.utf16.count) * laid.zeroAdvance
        let slide = try #require(scroll.animation(forKey: "scroll") as? CABasicAnimation)
        let from = try #require(slide.fromValue as? CGFloat)
        let to = try #require(slide.toValue as? CGFloat)
        #expect(abs((from - to) - tile) < 0.01)
        #expect(slide.duration == 2)
        // Linear, or the rainbow visibly slows at each wrap.
        #expect(slide.timingFunction == CAMediaTimingFunction(name: .linear))
        // The tile closes on its own first colour, which is what makes the
        // repeat seamless.
        let stops = try #require(scroll.colors as? [CGColor])
        #expect(stops.first == stops.last)
    }

    /// A name with an emoji is worth two slots, because Discord counts UTF-16
    /// and `String.count` would answer one.
    @Test("Prism counts UTF-16 units, not grapheme clusters")
    func prismCountsUTF16() throws {
        let text = "hi👍"
        #expect(text.count == 3)
        #expect(text.utf16.count == 4)
        let laid = try run(text)
        let layer = try build(.prism, colors: [0xFE_92_42, 0x35_ED_7E], text: text)
        let scroll = try #require(descendants(of: layer).compactMap { $0 as? CAGradientLayer }.first)
        let slide = try #require(scroll.animation(forKey: "scroll") as? CABasicAnimation)
        let travel = try #require(slide.fromValue as? CGFloat) - (try #require(slide.toValue as? CGFloat))
        #expect(abs(travel - 4 * laid.zeroAdvance) < 0.01)
    }

    /// **`CAShapeLayer` paints fill then stroke; CSS `paint-order: stroke fill`
    /// is the other way round.** A layer carrying both therefore draws the
    /// outline *over* the fill and eats half the stroke width inward from every
    /// edge — which cost Pop its white letters in every face but the heaviest,
    /// where enough stem survived to look deliberate.
    ///
    /// So no shape may carry two different colours: an outline and a fill are
    /// two layers, stroke underneath. Toon is the one exception the rule allows,
    /// because its fill and stroke are the same colour and the order cannot
    /// matter.
    @Test("No shape layer strokes over its own fill")
    func paintOrderIsNotInverted() throws {
        for (effect, colors) in [
            (DisplayNameEffect.solid, [0x58_65_F2]),
            (.gradient, [0x2A_AE_A6, 0xFF_C4_90]),
            (.neon, [0x99_65_F3]),
            (.toon, [0xF4_20_98]),
            (.pop, [0x23_A5_5A]),
            (.gummy, [0xEA_A9_D5, 0xA9_DD_F0]),
            (.prism, [0xFE_92_42, 0x35_ED_7E]),
        ] as [(DisplayNameEffect, [UInt32])] {
            let layer = try build(effect, colors: colors)
            for shape in ([layer] + descendants(of: layer)).compactMap({ $0 as? CAShapeLayer }) {
                guard let fill = shape.fillColor, let stroke = shape.strokeColor else { continue }
                #expect(fill == stroke, "\(effect) strokes \(stroke) over a different fill \(fill)")
            }
        }
    }

    /// Pop's letters are white with a dark outline *under* them, and the two
    /// move as one — so they are separate shapes inside a layer that carries the
    /// animation, not one shape carrying both colours.
    @Test("Pop's outline and fill are separate layers that move together")
    func popPaintsInTwoLayers() throws {
        let layer = try build(.pop, colors: [0x23_A5_5A])
        let letters = try #require(layer.sublayers?.last)
        let shapes = try #require(letters.sublayers as? [CAShapeLayer])
        #expect(shapes.count == 2)
        // Stroke first, fill over it.
        #expect(shapes[0].strokeColor != nil && shapes[0].fillColor == nil)
        #expect(shapes[1].fillColor == CGColor.white && shapes[1].strokeColor == nil)
        #expect(letters.animation(forKey: "lift") != nil, "both must move as one")
    }

    // MARK: Reduce Motion

    /// Not a frozen frame of the animation: every effect's resting state *is*
    /// its own first keyframe, so leaving the animation off draws the design.
    @Test("Reduce Motion builds the same layers and adds no animation")
    func reduceMotionDrawsTheStillDesign() throws {
        for (effect, colors) in [
            (DisplayNameEffect.neon, [0x99_65_F3]),
            (.toon, [0xF4_20_98]),
            (.pop, [0x23_A5_5A]),
            (.gummy, [0xEA_A9_D5, 0xA9_DD_F0]),
            (.prism, [0xFE_92_42, 0x35_ED_7E]),
        ] as [(DisplayNameEffect, [UInt32])] {
            let still = try build(effect, colors: colors, animates: false)
            let moving = try build(effect, colors: colors, animates: true)
            #expect(animations(in: still).isEmpty, "\(effect) still animates")
            #expect(
                descendants(of: still).count == descendants(of: moving).count,
                "\(effect) draws a different picture when parked"
            )
        }
    }

    /// Solid with no colours is a real state, and drawing nothing for it is the
    /// bug the fallback exists to prevent.
    @Test("A style with no colours still paints the name")
    func emptyColoursStillPaint() throws {
        let layer = DisplayNameEffectLayers.build(
            run: try run("alex"),
            style: DisplayNameStyle(font: .journal, effect: .solid, colors: []),
            pointSize: 24,
            fallback: CGColor.white,
            animates: true,
            characterCount: 4
        )
        let shape = try #require(layer.sublayers?.first as? CAShapeLayer)
        #expect(shape.fillColor == CGColor.white)
        #expect(shape.path != nil)
    }
}
