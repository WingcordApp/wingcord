import CoreGraphics
import Foundation
import WingcordCore

/// Paints one styled display name into a context, at a moment in its cycle.
///
/// **The Core Graphics twin of `DisplayNameEffectLayers`, and it exists because
/// the transcript has nothing to hang a layer tree on.** That surface is one
/// painted `NSView` — `TimelineCanvasView` draws every row into a single
/// viewport-sized layer, which is the whole of its virtualisation — so a name
/// there cannot be a sublayer of anything. A representable per run head would be
/// a view per message, which is precisely the arrangement the canvas replaced.
///
/// So the design is stated once, in `DisplayNameEffectSpec`, and rendered twice.
/// Every number below comes from there; nothing in this file is a second
/// opinion about what Discord's effects look like.
///
/// **Split into `prepare` and `draw`, and the split is the cost argument.** A
/// layer tree is built once and interpolated on the render server; a painter is
/// called sixty times a second, so anything it builds per call it builds sixty
/// times a second — for a name that cannot change while somebody is pointing at
/// it. `prepare` does the shaping and every gradient; `draw` does arithmetic and
/// blits. The only object a frame allocates is Neon's one interpolated core
/// colour, and Neon is the one effect whose colour is genuinely per-frame.
///
/// It is `nonisolated` for the reason `TimelineRowPainter` is: a render test can
/// drive it, and nothing here reaches a main-actor singleton inside a draw loop.
nonisolated enum DisplayNameEffectPainter {

    // MARK: The gate

    /// Whether this style is worth painting at all, as opposed to drawing the
    /// name in the ordinary way.
    ///
    /// **A styled *face* is not a styled name.** Nearly every account with a
    /// style has chosen a font and left the colours alone, and those already
    /// draw correctly through `authorFace` — sending them down this path would
    /// cost a glyph run and a clip to produce the same flat label.
    ///
    /// One test rather than two: a palette exists exactly when `colors` is
    /// non-empty, and `isPlain` requires `colors` to be empty, so a style with a
    /// palette is already not plain. Asking both would read as two conditions
    /// where there is one.
    static func paints(_ style: DisplayNameStyle) -> Bool {
        style.palette != nil
    }

    /// Whether the effect moves, and so whether the surface showing it needs a
    /// clock at all.
    static func animates(_ style: DisplayNameStyle) -> Bool {
        paints(style) && style.effect.isAnimated
    }

    // MARK: Prepared

    /// Everything about one styled name that does not change while it is being
    /// looked at.
    ///
    /// Built when the pointer arrives on a row and held until it leaves. The
    /// gradients are the point: Prism's ramp is a colour and a stop per
    /// character slot per repeat — around thirty of each — and rebuilding it per
    /// frame is two arrays and thirty `CGColor`s a tick to describe a rainbow
    /// that is the same rainbow it was last tick. Only where it is *drawn*
    /// moves.
    struct Prepared {
        let run: DisplayNameGlyphRun
        let effect: DisplayNameEffect
        let pointSize: CGFloat
        /// Nil when the account chose a face and no colour, which `draw` fills
        /// with the caller's own ink rather than drawing nothing.
        let ink: Ink?
        /// The ramp this effect paints through, or nil for the ones that paint
        /// flat colours.
        let ramp: CGGradient?
        /// Prism's tile width, and the whole repeated ramp's, in points.
        let tile: CGFloat
        let span: CGFloat
        /// How far the effect paints outside the text's own box, in points.
        ///
        /// **Neon's glow, Toon's and Pop's strokes and Gummy's squash all draw
        /// outside the layout box**, the same way Discord's negative margins let
        /// them — so a surface repainting only the name's rectangle has to
        /// repaint this much more, or the glow is cut off at a hard edge.
        let bleed: CGFloat
    }

    /// The shades one effect paints with, resolved once.
    struct Ink {
        let main: CGColor
        let light1: CGColor
        let light2: CGColor
        let dark2: CGColor
        let toonStroke: CGColor
        let neonStroke: CGColor
        let flickerOff: CGColor
        /// Gummy's per-letter cycle, already taken modulo the palette so a draw
        /// is an index rather than a remainder.
        let letters: [CGColor]

        init(palette: DisplayNamePalette, colors: [UInt32], glyphs: Int) {
            main = Self.color(palette.main)
            light1 = Self.color(palette.light1)
            light2 = Self.color(palette.light2)
            dark2 = Self.color(palette.dark2)
            toonStroke = Self.color(palette.toonStroke)
            neonStroke = Self.color(palette.neonStroke)
            flickerOff = Self.color(palette.flickerOff)
            let cycle = colors.isEmpty ? [palette.main] : colors
            letters = (0..<max(0, glyphs)).map { Self.color(cycle[$0 % cycle.count]) }
        }

        static func color(_ value: UInt32) -> CGColor {
            CGColor(
                srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        }
    }

    /// Shapes nothing and measures nothing — the run arrives laid out, because
    /// whoever holds this memo also holds the text.
    ///
    /// - Parameter characterCount: the name's **UTF-16** length, which is what
    ///   Prism's tile is counted in. Discord counts them the way JavaScript
    ///   does, so an emoji in a name is worth two.
    static func prepare(
        run: DisplayNameGlyphRun,
        style: DisplayNameStyle,
        pointSize: CGFloat,
        characterCount: Int
    ) -> Prepared {
        guard let palette = style.palette else {
            return Prepared(
                run: run, effect: style.effect.painted, pointSize: pointSize,
                ink: nil, ramp: nil, tile: 0, span: 0, bleed: 0
            )
        }
        let ink = Ink(palette: palette, colors: style.colors, glyphs: run.glyphs.count)
        var ramp: CGGradient?
        var tile: CGFloat = 0
        var span: CGFloat = 0

        switch style.effect.painted {
        case .solid, .neon, .gummy:
            // Flat fills, every one of them. A gradient built here would be an
            // object held for the life of a hover and never drawn.
            break
        case .glow, .gradient:
            if style.colors.count >= 2 {
                ramp = gradient(
                    [Ink.color(style.colors[0]), Ink.color(style.colors[1])],
                    at: DisplayNameEffectSpec.Gradient.stops
                )
            }
        case .toon:
            ramp = gradient(
                [
                    white, ink.light2, ink.light1, ink.main, ink.light2,
                    ink.main, white, ink.light2, ink.light1, ink.main,
                ],
                at: DisplayNameEffectSpec.Toon.stops
            )
        case .pop:
            ramp = gradient(
                [
                    ink.light1, ink.light1, ink.main, ink.main,
                    ink.light1, ink.main, ink.main,
                ],
                at: DisplayNameEffectSpec.Pop.sweepStops
            )
        case .prism:
            let stops = style.colors.isEmpty ? [palette.main] : style.colors
            // `--prism-cycle` is `characterCount * 1ch` — a count of character
            // *slots*, not a measured width, which is what makes the rainbow
            // read the same in a wide face and a narrow one.
            tile = max(1, CGFloat(characterCount)) * run.zeroAdvance
            let repeats = max(2, Int((run.size.width / tile).rounded(.up)) + 1)
            span = tile * CGFloat(repeats)

            var colors: [CGColor] = []
            var locations: [CGFloat] = []
            colors.reserveCapacity(repeats * stops.count + 1)
            locations.reserveCapacity(repeats * stops.count + 1)
            for repeat_ in 0..<repeats {
                for (index, value) in stops.enumerated() {
                    colors.append(Ink.color(value))
                    let within = CGFloat(index) / CGFloat(stops.count)
                    locations.append((CGFloat(repeat_) + within) / CGFloat(repeats))
                }
            }
            // The tile closes on its own first colour, which is what makes the
            // scroll seamless rather than snapping at every repeat.
            colors.append(Ink.color(stops[0]))
            locations.append(1)
            ramp = gradient(colors, at: locations)
        }

        return Prepared(
            run: run,
            effect: style.effect.painted,
            pointSize: pointSize,
            ink: ink,
            ramp: ramp,
            tile: tile,
            span: span,
            bleed: bleed(effect: style.effect, em: pointSize)
        )
    }

    /// How far outside the text's box an effect paints.
    ///
    /// Solid, Gradient and Prism paint strictly inside the outlines and answer
    /// zero; the other four reach out, and by different amounts, which is why
    /// this is a function of the effect rather than one padding constant.
    private static func bleed(effect: DisplayNameEffect, em: CGFloat) -> CGFloat {
        let spec = DisplayNameEffectSpec.self
        return switch effect {
        case .solid, .gradient, .glow, .prism: 0
        // A letter scales to 1.28 about its own box centre, so it reaches out by
        // fourteen per cent of that box — bounded here by the em, which is at
        // least as wide as any single glyph's box.
        case .gummy: ((spec.Gummy.scaleX.max() ?? 1) - 1) * em / 2
        // Half the stroke falls outside the glyph, and the glow is cast from the
        // silhouette on top of that.
        case .neon: spec.Neon.glowRadius(em: em) + spec.Neon.strokeWidth(em: em) / 2
        case .toon: spec.Toon.strokeWidth(em: em) / 2
        case .pop:
            spec.Pop.outlineWidth(em: em) / 2
                + (spec.Pop.shadow.map { abs($0) }.max() ?? 0) * em
        }
    }

    // MARK: Draw

    /// Draws `prepared` at `point` in the **flipped** space the transcript
    /// paints in.
    ///
    /// - Parameter point: the top of the line's ascent, which is exactly what
    ///   `TimelineRowPainter.drawText` takes. **The two conventions have to
    ///   match**: a run head draws its name one way at rest and the other under
    ///   the pointer, and a name that shifts by a point as the pointer arrives
    ///   reads as a rendering fault rather than as an effect.
    /// - Parameter time: seconds on the shared clock, or nil for the resting
    ///   picture. **Nil is not "hidden"** — every effect's rest is its own first
    ///   keyframe, so Reduce Motion and a row nobody is pointing at both get the
    ///   design rather than a blank.
    static func draw(
        _ prepared: Prepared,
        fallback: CGColor,
        time: Double?,
        at point: CGPoint,
        context: CGContext
    ) {
        let run = prepared.run
        context.saveGState()
        defer { context.restoreGState() }
        // Through the baseline, not through the box: `size.height` is the ascent
        // and descent rounded up together, so landing the box's top on the
        // caller's point would put the letters up to a point off the baseline
        // `CTLineDraw` uses for the same name — visible as a twitch the instant
        // the pointer arrives.
        context.translateBy(x: point.x, y: point.y + run.ascent)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: 0, y: -run.descent)

        guard let ink = prepared.ink else {
            // Solid with no colours: the account chose a face and left the
            // colour alone. Drawing nothing here is the bug this branch exists
            // to prevent — the same one the layer renderer guards.
            return fill(run.path, with: fallback, context: context)
        }

        switch prepared.effect {
        case .glow:
            // `prepare` stored `painted`, so this cannot arrive. Stated for
            // the reason the layer renderer states it.
            gradient(prepared, ink: ink, context: context)
        case .solid:
            fill(run.path, with: ink.main, context: context)
        case .gradient:
            gradient(prepared, ink: ink, context: context)
        case .neon:
            neon(prepared, ink: ink, time: time, context: context)
        case .toon:
            toon(prepared, ink: ink, time: time, context: context)
        case .pop:
            pop(prepared, ink: ink, time: time, context: context)
        case .gummy:
            gummy(prepared, ink: ink, time: time, context: context)
        case .prism:
            prism(prepared, time: time, context: context)
        }
    }

    // MARK: Static effects

    private static func gradient(_ prepared: Prepared, ink: Ink, context: CGContext) {
        guard let ramp = prepared.ramp else {
            return fill(prepared.run.path, with: ink.main, context: context)
        }
        let size = prepared.run.size
        clipped(to: prepared.run.path, context: context) {
            // y-up: top-left to bottom-right, which is `to bottom right`.
            context.drawLinearGradient(
                ramp,
                start: CGPoint(x: 0, y: size.height),
                end: CGPoint(x: size.width, y: 0),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
    }

    // MARK: Neon

    private static func neon(
        _ prepared: Prepared,
        ink: Ink,
        time: Double?,
        context: CGContext
    ) {
        let path = prepared.run.path
        let em = prepared.pointSize

        // The glow casts from the glyph silhouette and never changes — only the
        // core's colour animates. A zero-offset shadow rather than a second
        // blurred copy of the text, which is the same halo for one draw.
        context.saveGState()
        context.setShadow(
            offset: .zero,
            blur: DisplayNameEffectSpec.Neon.glowRadius(em: em),
            color: ink.main
        )
        fill(path, with: ink.main, context: context)
        context.restoreGState()

        // `paint-order: stroke fill` — the stroke is laid down first and the
        // fill covers its inner half, so a centred line of the full width shows
        // exactly half of itself outside the glyph, as WebKit draws it.
        stroke(
            path,
            with: ink.neonStroke,
            width: DisplayNameEffectSpec.Neon.strokeWidth(em: em),
            context: context
        )
        fill(path, with: flickerColor(ink: ink, time: time), context: context)
    }

    /// The core's colour at this moment, interpolated the way Core Animation
    /// interpolates a `fillColor` keyframe: between the two shades the segment
    /// spans, on the segment's own easing.
    private static func flickerColor(ink: Ink, time: Double?) -> CGColor {
        let table = DisplayNameEffectSpec.Neon.isOff
        guard let time else { return table[0] ? ink.flickerOff : white }
        let (index, t) = DisplayNameEffectSpec.segment(
            at: progress(time, cycle: DisplayNameEffectSpec.cycle),
            keyTimes: DisplayNameEffectSpec.Neon.keyTimes,
            easing: DisplayNameEffectSpec.neonEase
        )
        let from = table[index] ? ink.flickerOff : white
        let to = table[index + 1] ? ink.flickerOff : white
        return blend(from, to, t)
    }

    // MARK: Toon

    private static func toon(
        _ prepared: Prepared,
        ink: Ink,
        time: Double?,
        context: CGContext
    ) {
        let path = prepared.run.path
        let size = prepared.run.size

        // Base copy: stroked *and* filled in the dark shade, which is what shows
        // through as the cartoon outline once the gradient copy sits over it.
        context.saveGState()
        context.addPath(path)
        context.setFillColor(ink.toonStroke)
        context.setStrokeColor(ink.toonStroke)
        context.setLineWidth(DisplayNameEffectSpec.Toon.strokeWidth(em: prepared.pointSize))
        context.setLineJoin(.round)
        context.drawPath(using: .fillStroke)
        context.restoreGState()

        guard let ramp = prepared.ramp else { return }

        // The sheen is four line boxes tall and slides three of them. Its
        // centre, in multiples of the line height, is the keyframe table.
        let travel = DisplayNameEffectSpec.Toon.travel
        let centre = time.map {
            DisplayNameEffectSpec.interpolate(
                travel,
                keyTimes: DisplayNameEffectSpec.Toon.keyTimes,
                at: progress($0, cycle: DisplayNameEffectSpec.cycle),
                easing: DisplayNameEffectSpec.ease
            )
        } ?? travel[0]

        let half = size.height * DisplayNameEffectSpec.Toon.scale / 2
        let middle = centre * size.height
        clipped(to: path, context: context) {
            // Stop 0 at the top, as `startPoint (0.5, 1)` puts it.
            context.drawLinearGradient(
                ramp,
                start: CGPoint(x: size.width / 2, y: middle + half),
                end: CGPoint(x: size.width / 2, y: middle - half),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
    }

    // MARK: Pop

    private static func pop(
        _ prepared: Prepared,
        ink: Ink,
        time: Double?,
        context: CGContext
    ) {
        let path = prepared.run.path
        let size = prepared.run.size
        let em = prepared.pointSize
        let phase = time.map { progress($0, cycle: DisplayNameEffectSpec.cycle) }

        func offset(_ table: [CGFloat]) -> CGFloat {
            guard let phase else { return table[0] * em }
            return DisplayNameEffectSpec.interpolate(
                table,
                keyTimes: DisplayNameEffectSpec.Pop.keyTimes,
                at: phase,
                easing: DisplayNameEffectSpec.ease
            ) * em
        }

        // The extrusion, below the letters. Its own gradient sweeps diagonally
        // while it moves. **The two translations below move in opposite
        // directions and their separation IS the effect** — the letters lift off
        // the extrusion and slap back onto it.
        if let sweep = prepared.ramp {
            let travelled = phase.map {
                DisplayNameEffectSpec.interpolate(
                    [0, 1, 1],
                    keyTimes: DisplayNameEffectSpec.Pop.sweepKeyTimes,
                    at: $0,
                    easing: DisplayNameEffectSpec.ease
                )
            } ?? 0
            context.saveGState()
            context.translateBy(x: 0, y: offset(DisplayNameEffectSpec.Pop.shadow))
            context.addPath(path)
            context.clip()
            // Bounds twice the box, centred on the sweep's travelling position,
            // running top-right to bottom-left as `startPoint (1, 1)` does.
            let x = travelled * size.width
            let y = travelled * size.height
            context.drawLinearGradient(
                sweep,
                start: CGPoint(x: x + size.width, y: y + size.height),
                end: CGPoint(x: x - size.width, y: y - size.height),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
            context.restoreGState()
        }

        // **Stroke then fill, because CSS `paint-order: stroke fill` is the
        // opposite of what one `drawPath(.fillStroke)` does.** Filling first and
        // stroking over it puts the dark outline on top of the white, eating
        // half the stroke width inward from every edge — which swallows a light
        // face whole and leaves only the heaviest ones legible.
        context.saveGState()
        context.translateBy(x: 0, y: offset(DisplayNameEffectSpec.Pop.letters))
        stroke(
            path,
            with: ink.dark2,
            width: DisplayNameEffectSpec.Pop.outlineWidth(em: em),
            context: context
        )
        fill(path, with: white, context: context)
        context.restoreGState()
    }

    // MARK: Gummy

    private static func gummy(
        _ prepared: Prepared,
        ink: Ink,
        time: Double?,
        context: CGContext
    ) {
        let spec = DisplayNameEffectSpec.Gummy.self
        for (index, glyph) in prepared.run.glyphs.enumerated() {
            // A space owns a box and no outline — nothing to fill, and the box
            // is only there to keep the wave's phase across a two-word name.
            guard !glyph.path.isEmpty, index < ink.letters.count else { continue }
            let letter = ink.letters[index]
            guard let time else {
                fill(glyph.path, with: letter, context: context)
                continue
            }

            // Each letter lags the one before it. The layer renderer holds a
            // letter on its first keyframe until its turn comes round the first
            // time; here the cycle simply wraps, which is the same picture from
            // the second cycle on and differs only in a letter's first 50 ms.
            let local = progress(
                time - Double(index) * spec.stagger,
                cycle: DisplayNameEffectSpec.cycle
            )
            let scaleX = DisplayNameEffectSpec.interpolate(
                spec.scaleX, keyTimes: spec.keyTimes, at: local,
                easing: DisplayNameEffectSpec.ease
            )
            let scaleY = DisplayNameEffectSpec.interpolate(
                spec.scaleY, keyTimes: spec.keyTimes, at: local,
                easing: DisplayNameEffectSpec.ease
            )

            // Scaled about the centre of the *layout* box, which is what CSS
            // pivots an inline-block about — the ink box would swing a
            // descender around the wrong point.
            context.saveGState()
            context.translateBy(x: glyph.box.midX, y: glyph.box.midY)
            context.scaleBy(x: scaleX, y: scaleY)
            context.translateBy(x: -glyph.box.midX, y: -glyph.box.midY)
            fill(glyph.path, with: letter, context: context)
            context.restoreGState()
        }
    }

    // MARK: Prism

    private static func prism(_ prepared: Prepared, time: Double?, context: CGContext) {
        guard let ramp = prepared.ramp else { return }
        // One whole tile per cycle, linearly — Prism is the one effect with no
        // easing and no hold in it.
        let travelled = time.map {
            prepared.tile * progress($0, cycle: DisplayNameEffectSpec.prismCycle)
        } ?? 0
        let middle = prepared.run.size.height / 2

        clipped(to: prepared.run.path, context: context) {
            context.drawLinearGradient(
                ramp,
                start: CGPoint(x: -travelled, y: middle),
                end: CGPoint(x: prepared.span - travelled, y: middle),
                // The glyphs run the full width, so both ends have to keep
                // painting past the last stop or the first and last letters
                // come out unfilled.
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
    }

    // MARK: Plumbing

    private static func fill(_ path: CGPath, with ink: CGColor, context: CGContext) {
        guard !path.isEmpty else { return }
        context.addPath(path)
        context.setFillColor(ink)
        context.fillPath()
    }

    private static func stroke(
        _ path: CGPath,
        with ink: CGColor,
        width: CGFloat,
        context: CGContext
    ) {
        guard !path.isEmpty else { return }
        context.saveGState()
        context.addPath(path)
        context.setStrokeColor(ink)
        context.setLineWidth(width)
        context.setLineJoin(.round)
        context.strokePath()
        context.restoreGState()
    }

    /// Clips to the glyph outlines and runs `body`.
    ///
    /// **A path clip, which is exactly what `CTLineDraw` could not be given.**
    /// `TimelineRowPainter.drawText` has to draw its glyphs into a transparency
    /// layer and composite the ramp in with `.sourceIn`, because Core Text puts
    /// the text drawing mode back from each run's own attributes and the clip
    /// recipe silently paints into an empty region. Nothing here asks Core Text
    /// for anything — the outlines are already `CGPath`s — so the ordinary clip
    /// works and costs no layer.
    private static func clipped(to path: CGPath, context: CGContext, _ body: () -> Void) {
        guard !path.isEmpty else { return }
        context.saveGState()
        context.addPath(path)
        context.clip()
        body()
        context.restoreGState()
    }

    private static func gradient(_ colors: [CGColor], at locations: [CGFloat]) -> CGGradient? {
        guard colors.count == locations.count, colors.count >= 2 else { return nil }
        return CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: colors as CFArray,
            locations: locations
        )
    }

    /// Where the clock stands in a cycle, `0..<1`, for a time that may be
    /// negative — which a staggered letter's is before its turn comes round.
    private static func progress(_ time: Double, cycle: Double) -> CGFloat {
        guard cycle > 0 else { return 0 }
        let turns = time / cycle
        return CGFloat(turns - turns.rounded(.down))
    }

    private static func blend(_ from: CGColor, _ to: CGColor, _ t: CGFloat) -> CGColor {
        guard t > 0 else { return from }
        guard t < 1 else { return to }
        guard let a = from.components, let b = to.components,
              a.count >= 4, b.count >= 4
        else { return t < 0.5 ? from : to }
        return CGColor(
            srgbRed: a[0] + (b[0] - a[0]) * t,
            green: a[1] + (b[1] - a[1]) * t,
            blue: a[2] + (b[2] - a[2]) * t,
            alpha: a[3] + (b[3] - a[3]) * t
        )
    }

    /// White, in sRGB.
    ///
    /// **Not `CGColor.white`, which is in the generic grey space.** Its
    /// `components` answer two numbers rather than four, so `blend` above would
    /// fall through to a step and Neon's flicker would snap between shades
    /// instead of easing — a difference from the profile card's rendering of
    /// the same effect, in the one place it is most visible.
    private static let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
}
