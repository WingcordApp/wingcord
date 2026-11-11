import AppKit
import QuartzCore
import WingcordCore

/// Builds the layer tree for one styled display name.
///
/// **Core Animation, not a per-frame clock, and that is the decision the whole
/// feature's cost rests on.** These are fixed, declarative, looping animations:
/// added to a layer once, they are interpolated on the render server with no
/// body evaluation, no layout, no tick and no main-thread work at all. That is
/// why `AnimationClock` is deliberately not used here — it exists for
/// filmstrips, where each frame is a *different bitmap* and something has to
/// swap `contents`. Nothing here swaps anything.
///
/// Five of the seven effects never move ink; they animate a fill under a static
/// glyph mask. Only Pop translates and only Gummy transforms per letter, and
/// both do it with `transform`, so no glyph is ever re-shaped.
///
/// Every duration and keyframe below is Discord's own, read out of its
/// stylesheet rather than measured. **Each keyframe set carries its own hold** —
/// the movement occupies about half the cycle and the rest is deliberately
/// still. Easing across the whole period instead reads as continuously restless.
@MainActor
enum DisplayNameEffectLayers {

    /// The cycle every effect but Prism runs on.
    ///
    /// Exposed so a surface that plays an effect *once* — the DM list's rows do,
    /// on a click — knows how long once is. A duration invented at the call site
    /// would cut an effect off mid-movement.
    static let cycle: CFTimeInterval = DisplayNameEffectSpec.cycle
    /// Prism scrolls one tile per two seconds, linearly.
    private static let prismCycle: CFTimeInterval = DisplayNameEffectSpec.prismCycle

    private static let ease = DisplayNameEffectSpec.ease.timingFunction
    private static let neonEase = DisplayNameEffectSpec.neonEase.timingFunction

    /// - Parameters:
    ///   - animates: false under Reduce Motion. **No animation is added at
    ///     all** — every effect's resting state is its own first keyframe, so
    ///     the still picture is the design rather than a frozen frame of it.
    ///   - characterCount: the name's **UTF-16** length, which is what Prism's
    ///     tile is counted in. See `StyledDisplayName` for why that matters.
    static func build(
        run: DisplayNameGlyphRun,
        style: DisplayNameStyle,
        pointSize: CGFloat,
        fallback: CGColor,
        animates: Bool,
        characterCount: Int
    ) -> CALayer {
        let root = CALayer()
        root.bounds = CGRect(origin: .zero, size: run.size)
        root.anchorPoint = .zero
        root.masksToBounds = false
        // Whatever the effect, the name's emoji go over it and stay as they
        // are — Discord's `.emoji`, `z-index: 1`.
        defer {
            if !run.colorGlyphs.isEmpty {
                root.addSublayer(DisplayNameColorGlyphLayer(run: run))
            }
        }

        guard let palette = style.palette else {
            // Solid with no colours: the account chose a face and left the
            // colour alone. Drawing nothing here is the bug this branch exists
            // to prevent.
            root.addSublayer(fill(run.path, color: fallback))
            return root
        }

        // `painted` is what collapses Glow onto Gradient — Discord's own
        // renderer groups the two, and doing it here means neither this
        // switch nor the painter's needs a case that draws nothing.
        switch style.effect.painted {
        case .solid:
            root.addSublayer(fill(run.path, color: color(palette.main)))
        case .gradient:
            root.addSublayer(gradient(run: run, colors: style.colors, fallback: palette))
        case .neon:
            neon(into: root, run: run, palette: palette, em: pointSize, animates: animates)
        case .toon:
            toon(into: root, run: run, palette: palette, em: pointSize, animates: animates)
        case .pop:
            pop(into: root, run: run, palette: palette, em: pointSize, animates: animates)
        case .gummy:
            gummy(into: root, run: run, colors: style.colors, fallback: palette, animates: animates)
        case .glow:
            // Unreachable: `painted` maps it to `.gradient` above. Stated
            // rather than defaulted so a new effect cannot land here silently.
            root.addSublayer(gradient(run: run, colors: style.colors, fallback: palette))
        case .prism:
            prism(
                into: root, run: run, colors: style.colors, fallback: palette,
                characterCount: characterCount, animates: animates
            )
        }
        return root
    }

    // MARK: Static effects

    /// `linear-gradient(to bottom right, colors[0] 10%, colors[1] 90%)`.
    ///
    /// **The stops are 10% and 90%, not 0 and 100.** Each endpoint colour is
    /// held across a tenth of the diagonal, so a short name still shows both
    /// rather than reading as one muddy midpoint.
    private static func gradient(
        run: DisplayNameGlyphRun,
        colors: [UInt32],
        fallback: DisplayNamePalette
    ) -> CALayer {
        guard colors.count >= 2 else { return fill(run.path, color: color(fallback.main)) }
        let layer = CAGradientLayer()
        layer.frame = CGRect(origin: .zero, size: run.size)
        layer.colors = colors.map(color)
        layer.locations = DisplayNameEffectSpec.Gradient.stops(count: colors.count)
            .map { NSNumber(value: $0) }
        // y-up: top-left to bottom-right.
        layer.startPoint = CGPoint(x: 0, y: 1)
        layer.endPoint = CGPoint(x: 1, y: 0)
        layer.mask = mask(run.path, size: run.size)
        return layer
    }

    // MARK: Neon

    private static func neon(
        into root: CALayer,
        run: DisplayNameGlyphRun,
        palette: DisplayNamePalette,
        em: CGFloat,
        animates: Bool
    ) {
        // The glow casts from the glyph silhouette and never changes — only the
        // core's colour animates. Blurring this once instead of per frame is
        // what keeps a flicker from costing a Gaussian every tick.
        let glow = fill(run.path, color: color(palette.main))
        glow.shadowColor = color(palette.main)
        glow.shadowOffset = .zero
        glow.shadowRadius = DisplayNameEffectSpec.Neon.glowRadius(em: em)
        glow.shadowOpacity = 1
        glow.shadowPath = run.path
        root.addSublayer(glow)

        // `paint-order: stroke fill` — the stroke is laid down first and the
        // fill covers its inner half, so a centred line of the full width shows
        // exactly half of itself outside the glyph, as WebKit draws it.
        let stroke = CAShapeLayer()
        stroke.path = run.path
        stroke.fillColor = nil
        stroke.strokeColor = color(palette.neonStroke)
        stroke.lineWidth = DisplayNameEffectSpec.Neon.strokeWidth(em: em)
        stroke.lineJoin = .round
        root.addSublayer(stroke)

        let core = fill(run.path, color: .white)
        root.addSublayer(core)
        guard animates else { return }

        let off = color(palette.flickerOff)
        let white = CGColor.white
        let flicker = keyframes(
            "fillColor",
            values: DisplayNameEffectSpec.Neon.isOff.map { $0 ? off : white },
            keyTimes: DisplayNameEffectSpec.Neon.keyTimes.map { NSNumber(value: $0) },
            duration: Self.cycle,
            timing: neonEase
        )
        core.add(flicker, forKey: "flicker")
    }

    // MARK: Toon

    private static func toon(
        into root: CALayer,
        run: DisplayNameGlyphRun,
        palette: DisplayNamePalette,
        em: CGFloat,
        animates: Bool
    ) {
        // Base copy: stroked *and* filled in the dark shade, which is what shows
        // through as the cartoon outline once the gradient copy sits over it.
        let base = CAShapeLayer()
        base.path = run.path
        base.fillColor = color(palette.toonStroke)
        base.strokeColor = color(palette.toonStroke)
        base.lineWidth = DisplayNameEffectSpec.Toon.strokeWidth(em: em)
        base.lineJoin = .round
        root.addSublayer(base)

        let height = run.size.height
        let window = CALayer()
        window.frame = CGRect(origin: .zero, size: run.size)
        window.masksToBounds = false
        window.mask = mask(run.path, size: run.size)

        // `background-size: 100% 400%` — the gradient is four times the line box
        // and slides three of them.
        let sheen = CAGradientLayer()
        sheen.bounds = CGRect(
            x: 0, y: 0,
            width: run.size.width, height: height * DisplayNameEffectSpec.Toon.scale
        )
        sheen.startPoint = CGPoint(x: 0.5, y: 1)
        sheen.endPoint = CGPoint(x: 0.5, y: 0)
        sheen.colors = [
            CGColor.white, color(palette.light2), color(palette.light1), color(palette.main),
            color(palette.light2), color(palette.main), CGColor.white, color(palette.light2),
            color(palette.light1), color(palette.main),
        ]
        sheen.locations = DisplayNameEffectSpec.Toon.stops.map { NSNumber(value: $0) }

        // Rest is the gradient's top quarter aligned with the box. **The loop is
        // seamless by construction**: the last quarter of that stop list mirrors
        // the first, so the wrap from 100% back to 0% shows the same colours.
        // The keyframe table is the whole travel, so the rest position is its
        // own first entry rather than a second copy of the same number.
        let travel = DisplayNameEffectSpec.Toon.travel.map { $0 * height }
        sheen.position = CGPoint(x: run.size.width / 2, y: travel[0])
        window.addSublayer(sheen)
        root.addSublayer(window)
        guard animates else { return }

        sheen.add(
            keyframes(
                "position.y",
                values: travel,
                keyTimes: DisplayNameEffectSpec.Toon.keyTimes.map { NSNumber(value: $0) },
                duration: Self.cycle,
                timing: ease
            ),
            forKey: "sheen"
        )
    }

    // MARK: Pop

    private static func pop(
        into root: CALayer,
        run: DisplayNameGlyphRun,
        palette: DisplayNamePalette,
        em: CGFloat,
        animates: Bool
    ) {
        let lift = DisplayNameEffectSpec.Pop.lift * em
        let width = run.size.width
        let height = run.size.height

        // The extrusion, below the letters. Its own gradient sweeps diagonally
        // while it moves.
        let shadow = CALayer()
        shadow.frame = CGRect(origin: .zero, size: run.size)
        shadow.masksToBounds = false
        shadow.mask = mask(run.path, size: run.size)

        let sweep = CAGradientLayer()
        sweep.bounds = CGRect(x: 0, y: 0, width: width * 2, height: height * 2)
        sweep.startPoint = CGPoint(x: 1, y: 1)
        sweep.endPoint = CGPoint(x: 0, y: 0)
        sweep.colors = [
            color(palette.light1), color(palette.light1), color(palette.main),
            color(palette.main), color(palette.light1), color(palette.main),
            color(palette.main),
        ]
        sweep.locations = DisplayNameEffectSpec.Pop.sweepStops.map { NSNumber(value: $0) }
        sweep.position = .zero
        shadow.addSublayer(sweep)
        shadow.transform = CATransform3DMakeTranslation(0, -lift, 0)
        root.addSublayer(shadow)

        // **Two layers, because `CAShapeLayer` paints fill THEN stroke and CSS
        // `paint-order: stroke fill` is the other way round.** One layer with
        // both set puts the dark outline on top of the white, eating half the
        // stroke width inward from every edge — which swallows a light face
        // whole and leaves only the heaviest ones legible.
        let letters = CALayer()
        letters.frame = CGRect(origin: .zero, size: run.size)
        letters.masksToBounds = false
        let outline = CAShapeLayer()
        outline.path = run.path
        outline.fillColor = nil
        outline.strokeColor = color(palette.dark2)
        outline.lineWidth = DisplayNameEffectSpec.Pop.outlineWidth(em: em)
        outline.lineJoin = .round
        letters.addSublayer(outline)
        letters.addSublayer(fill(run.path, color: .white))
        root.addSublayer(letters)
        guard animates else { return }

        // y-up, so CSS's downward translations come back negated. The two
        // layers move in opposite directions and **their separation is the
        // effect** — the letters lift off the extrusion and slap back onto it.
        letters.add(
            keyframes(
                "transform.translation.y",
                // Typed, not inferred: a bare `0` in an `[Any]` literal is an
                // `Int`, and a keyframe list that mixes Int with Double hands
                // Core Animation a value it has to coerce per frame.
                values: DisplayNameEffectSpec.Pop.letters.map { $0 * em } as [CGFloat],
                keyTimes: DisplayNameEffectSpec.Pop.keyTimes.map { NSNumber(value: $0) },
                duration: Self.cycle,
                timing: ease
            ),
            forKey: "lift"
        )
        shadow.add(
            keyframes(
                "transform.translation.y",
                values: DisplayNameEffectSpec.Pop.shadow.map { $0 * em } as [CGFloat],
                keyTimes: DisplayNameEffectSpec.Pop.keyTimes.map { NSNumber(value: $0) },
                duration: Self.cycle,
                timing: ease
            ),
            forKey: "lift"
        )
        sweep.add(
            keyframes(
                "position",
                values: [
                    CGPoint.zero, CGPoint(x: width, y: height), CGPoint(x: width, y: height),
                ],
                keyTimes: DisplayNameEffectSpec.Pop.sweepKeyTimes.map { NSNumber(value: $0) },
                duration: Self.cycle,
                timing: ease
            ),
            forKey: "sweep"
        )
    }

    // MARK: Gummy

    private static func gummy(
        into root: CALayer,
        run: DisplayNameGlyphRun,
        colors: [UInt32],
        fallback: DisplayNamePalette,
        animates: Bool
    ) {
        let palette = colors.isEmpty ? [fallback.main] : colors
        // One clock reading for the whole word, so the stagger is a fixed
        // 50 ms per letter rather than however long the loop below took.
        let start = CACurrentMediaTime()

        // **Letters are counted, and a space is not one** — Discord gives a
        // colour and a place in the wave to each letter it wraps, and it wraps
        // neither a space nor an emoji.
        var index = -1
        for glyph in run.glyphs where !glyph.path.isEmpty {
            index += 1
            let letter = CAShapeLayer()
            letter.bounds = CGRect(origin: .zero, size: glyph.box.size)
            letter.position = CGPoint(x: glyph.box.midX, y: glyph.box.midY)
            var intoBox = CGAffineTransform(translationX: -glyph.box.minX, y: -glyph.box.minY)
            letter.path = glyph.path.copy(using: &intoBox)
            letter.fillColor = color(palette[index % palette.count])
            root.addSublayer(letter)
            guard animates else { continue }

            // Scaled about the centre of the *layout* box, which is what CSS
            // pivots an inline-block about — the ink box would swing a
            // descender around the wrong point.
            // **`Double`, not the spec's `CGFloat`.** The two are the same
            // bits on every platform this ships to, and `[Any]` does not care —
            // but a keyframe list is read back by the tests that keep these
            // numbers from drifting, and an array cast is type-exact. Handing
            // Core Animation the type it has always been handed keeps that gate
            // pointed at the values rather than at the refactor.
            for (keyPath, values) in [
                ("transform.scale.x", DisplayNameEffectSpec.Gummy.scaleX.map(Double.init)),
                ("transform.scale.y", DisplayNameEffectSpec.Gummy.scaleY.map(Double.init)),
            ] {
                let squish = keyframes(
                    keyPath,
                    values: values,
                    keyTimes: DisplayNameEffectSpec.Gummy.keyTimes.map { NSNumber(value: $0) },
                    duration: Self.cycle,
                    timing: ease
                )
                squish.beginTime = start + Double(index) * DisplayNameEffectSpec.Gummy.stagger
                squish.fillMode = .backwards
                letter.add(squish, forKey: keyPath)
            }
        }
    }

    // MARK: Prism

    private static func prism(
        into root: CALayer,
        run: DisplayNameGlyphRun,
        colors: [UInt32],
        fallback: DisplayNamePalette,
        characterCount: Int,
        animates: Bool
    ) {
        let stops = colors.isEmpty ? [fallback.main] : colors
        // `--prism-cycle` is `characterCount * 1ch` — a count of character
        // *slots*, not a measured width, which is what makes the rainbow read
        // the same in a wide face and a narrow one.
        let tile = DisplayNameEffectSpec.Prism.tile(
            characterCount: characterCount, zeroAdvance: run.zeroAdvance
        )
        let repeats = max(2, Int((run.size.width / tile).rounded(.up)) + 1)

        var gradientColors: [CGColor] = []
        var locations: [NSNumber] = []
        gradientColors.reserveCapacity(repeats * stops.count + 1)
        locations.reserveCapacity(repeats * stops.count + 1)
        for repeat_ in 0..<repeats {
            for (index, value) in stops.enumerated() {
                gradientColors.append(color(value))
                let within = CGFloat(index) / CGFloat(stops.count)
                locations.append(NSNumber(value: Double((CGFloat(repeat_) + within) / CGFloat(repeats))))
            }
        }
        // The tile closes on its own first colour, which is what makes the
        // scroll seamless rather than snapping at every repeat.
        gradientColors.append(color(stops[0]))
        locations.append(1)

        let scroll = CAGradientLayer()
        scroll.bounds = CGRect(x: 0, y: 0, width: tile * CGFloat(repeats), height: run.size.height)
        scroll.startPoint = CGPoint(x: 0, y: 0.5)
        scroll.endPoint = CGPoint(x: 1, y: 0.5)
        scroll.colors = gradientColors
        scroll.locations = locations
        let restX = scroll.bounds.width / 2
        scroll.position = CGPoint(x: restX, y: run.size.height / 2)

        let window = CALayer()
        window.frame = CGRect(origin: .zero, size: run.size)
        window.masksToBounds = false
        window.mask = mask(run.path, size: run.size)
        window.addSublayer(scroll)
        root.addSublayer(window)
        guard animates else { return }

        let slide = CABasicAnimation(keyPath: "position.x")
        slide.fromValue = restX
        slide.toValue = restX - tile
        slide.duration = prismCycle
        slide.timingFunction = CAMediaTimingFunction(name: .linear)
        slide.repeatCount = .infinity
        slide.isRemovedOnCompletion = false
        scroll.add(slide, forKey: "scroll")
    }

    // MARK: Plumbing

    private static func fill(_ path: CGPath, color: CGColor) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.path = path
        layer.fillColor = color
        return layer
    }

    private static func mask(_ path: CGPath, size: CGSize) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.path = path
        layer.fillColor = .white
        layer.frame = CGRect(origin: .zero, size: size)
        return layer
    }

    private static func keyframes(
        _ keyPath: String,
        values: [Any],
        keyTimes: [NSNumber],
        duration: CFTimeInterval,
        timing: CAMediaTimingFunction
    ) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = keyTimes
        animation.duration = duration
        // One function per *segment*, which is how a browser eases between
        // keyframes. A single function on the animation would ease the whole
        // run and flatten every hold in it.
        animation.timingFunctions = Array(repeating: timing, count: keyTimes.count - 1)
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        return animation
    }

    private static func color(_ value: UInt32) -> CGColor {
        CGColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
