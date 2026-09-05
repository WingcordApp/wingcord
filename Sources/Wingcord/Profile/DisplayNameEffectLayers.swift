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
    static let cycle: CFTimeInterval = 4
    /// Prism scrolls one tile per two seconds, linearly.
    private static let prismCycle: CFTimeInterval = 2

    private static let ease = CAMediaTimingFunction(controlPoints: 0.44, 0.29, 0.48, 1)
    private static let neonEase = CAMediaTimingFunction(controlPoints: 0.24, 0.31, 0.36, 0.93)

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

        guard let palette = style.palette else {
            // Solid with no colours: the account chose a face and left the
            // colour alone. Drawing nothing here is the bug this branch exists
            // to prevent.
            root.addSublayer(fill(run.path, color: fallback))
            return root
        }

        switch style.effect {
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
        layer.colors = [color(colors[0]), color(colors[1])]
        layer.locations = [0.1, 0.9]
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
        glow.shadowRadius = 4 + 0.12 * em
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
        stroke.lineWidth = 1 + 0.04 * em
        stroke.lineJoin = .round
        root.addSublayer(stroke)

        let core = fill(run.path, color: .white)
        root.addSublayer(core)
        guard animates else { return }

        let off = color(palette.flickerOff)
        let white = CGColor.white
        let flicker = keyframes(
            "fillColor",
            values: [white, white, off, white, white, off, white, white, off, white, white],
            keyTimes: [0, 0.15, 0.16, 0.18, 0.20, 0.22, 0.23, 0.25, 0.28, 0.50, 1],
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
        base.lineWidth = 1.6 + 0.04 * em
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
        sheen.bounds = CGRect(x: 0, y: 0, width: run.size.width, height: height * 4)
        sheen.startPoint = CGPoint(x: 0.5, y: 1)
        sheen.endPoint = CGPoint(x: 0.5, y: 0)
        sheen.colors = [
            CGColor.white, color(palette.light2), color(palette.light1), color(palette.main),
            color(palette.light2), color(palette.main), CGColor.white, color(palette.light2),
            color(palette.light1), color(palette.main),
        ]
        sheen.locations = [0, 0.08, 0.15, 0.25, 0.45, 0.55, 0.75, 0.83, 0.90, 1]

        // Rest is the gradient's top quarter aligned with the box. **The loop is
        // seamless by construction**: the last quarter of that stop list mirrors
        // the first, so the wrap from 100% back to 0% shows the same colours.
        let top = -height
        let bottom = height * 2
        sheen.position = CGPoint(x: run.size.width / 2, y: top)
        window.addSublayer(sheen)
        root.addSublayer(window)
        guard animates else { return }

        sheen.add(
            keyframes(
                "position.y",
                values: [top, top, bottom, bottom],
                keyTimes: [0, 0.05, 0.55, 1],
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
        let lift = 0.08 * em
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
        sweep.locations = [0, 0.06, 0.20, 0.50, 0.56, 0.70, 1]
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
        outline.lineWidth = 1.2 + 0.04 * em
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
                values: [0, 0.05 * em, -0.08 * em, 0, 0] as [CGFloat],
                keyTimes: [0, 0.18, 0.35, 0.50, 1],
                duration: Self.cycle,
                timing: ease
            ),
            forKey: "lift"
        )
        shadow.add(
            keyframes(
                "transform.translation.y",
                values: [-lift, -0.13 * em, 0, -lift, -lift] as [CGFloat],
                keyTimes: [0, 0.18, 0.35, 0.50, 1],
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
                keyTimes: [0, 0.5, 1],
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

        for (index, glyph) in run.glyphs.enumerated() {
            let letter = CAShapeLayer()
            letter.bounds = CGRect(origin: .zero, size: glyph.box.size)
            letter.position = CGPoint(x: glyph.box.midX, y: glyph.box.midY)
            var intoBox = CGAffineTransform(translationX: -glyph.box.minX, y: -glyph.box.minY)
            letter.path = glyph.path.copy(using: &intoBox)
            letter.fillColor = color(palette[index % palette.count])
            root.addSublayer(letter)
            guard animates, !glyph.path.isEmpty else { continue }

            // Scaled about the centre of the *layout* box, which is what CSS
            // pivots an inline-block about — the ink box would swing a
            // descender around the wrong point.
            for (keyPath, values) in [
                ("transform.scale.x", [1.0, 1.28, 0.82, 1.1, 0.96, 1.0, 1.0]),
                ("transform.scale.y", [1.0, 0.72, 1.18, 0.9, 1.04, 1.0, 1.0]),
            ] {
                let squish = keyframes(
                    keyPath,
                    values: values,
                    keyTimes: [0, 0.07, 0.14, 0.21, 0.28, 0.35, 1],
                    duration: Self.cycle,
                    timing: ease
                )
                squish.beginTime = start + Double(index) * 0.05
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
        let tile = max(1, CGFloat(characterCount)) * run.zeroAdvance
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
