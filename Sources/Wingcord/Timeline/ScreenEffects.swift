import AppKit
import QuartzCore
import WingcordCore

/// The Messages app's screen effects, on its keywords (REDESIGN.md R14):
/// balloons for a happy birthday, confetti for congratulations, fireworks for a
/// happy new year.
///
/// **On this Mac only.** Discord has no message effects; nothing is sent, and
/// nobody else's client shows them. They are this reader's transcript
/// celebrating what it was just told — so they play for what arrives while the
/// reader is watching the present, never for history scrolled into, and never
/// under Reduce Motion (`AppSettings.playsScreenEffects` is the other half).
nonisolated enum ScreenEffect: Equatable, Sendable {
    case balloons
    case confetti
    case fireworks

    /// The effect a message's words ask for — the Messages app's own phrases,
    /// as whole words in any case, with or without accents and punctuation.
    static func matching(_ text: String) -> ScreenEffect? {
        guard !text.isEmpty else { return nil }
        let words = normalized(text)
        if words.contains(" happy new year ") { return .fireworks }
        if words.contains(" happy birthday ") { return .balloons }
        if words.contains(" congratulations ") || words.contains(" congrats ")
            || words.contains(" selamat ") {
            return .confetti
        }
        return nil
    }

    /// Lowercased, accents folded, every run of anything but letters and
    /// digits one space, with a space at each end — so a phrase is found as
    /// whole words by a plain `contains`.
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var words = " "
        var spaced = true
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                words.unicodeScalars.append(scalar)
                spaced = false
            } else if !spaced {
                words.append(" ")
                spaced = true
            }
        }
        if !spaced { words.append(" ") }
        return words
    }

    /// How old a message may be and still celebrate as it lands: a page of
    /// newer history reconnecting the transcript to the present is not news.
    static let freshness: TimeInterval = 30

    /// The effect the newest arrivals ask for: messages newer than the
    /// transcript's newest before this update, sent within `freshness`. The
    /// newest one that asks wins.
    static func celebrated(
        in items: [TimelineItem],
        after previousNewest: MessageID?,
        now: Date = .now
    ) -> ScreenEffect? {
        guard let previousNewest else { return nil }
        for case .message(let row) in items.reversed() {
            guard row.id.rawValue > previousNewest.rawValue else { break }
            guard now.timeIntervalSince(row.message.sentAt) < freshness else { continue }
            if let effect = matching(row.message.content) { return effect }
        }
        return nil
    }

    /// How long new pieces keep coming.
    fileprivate var emitting: TimeInterval {
        switch self {
        case .balloons: 2.2
        case .confetti: 1.8
        case .fireworks: 2.6
        }
    }

    /// How far into the effect it starts. A slow emitter's first piece is
    /// born a whole interval after it starts — a balloon a second in, from
    /// under the edge — so a slow one opens already under way.
    fileprivate var preroll: TimeInterval {
        switch self {
        case .balloons: 2
        case .confetti: 0
        case .fireworks: 0.6
        }
    }

    /// How long until the last piece has left the screen.
    fileprivate var lasting: TimeInterval {
        switch self {
        case .balloons: 9
        case .confetti: 6.5
        case .fireworks: 5
        }
    }
}

/// Plays one screen effect at a time over a transcript.
///
/// **The render server does the work.** Each effect is one `CAEmitterLayer`;
/// once it is in the tree the main thread does nothing per frame, and the
/// whole layer is taken away when its last piece has gone.
@MainActor
final class ScreenEffectPlayer {
    private var view: ScreenEffectView?
    private var playing: ScreenEffect?
    /// Which play the scheduled clean-up belongs to, so an old one cannot
    /// take away a newer effect.
    private var generation = 0

    /// Starts `effect` over `host`. One that is already playing is left to
    /// finish: the echo of a send and Discord's copy of it are one message.
    func play(_ effect: ScreenEffect, over host: NSView) {
        guard playing != effect || view == nil else { return }
        stop()
        let view = ScreenEffectView(frame: host.bounds)
        view.autoresizingMask = [.width, .height]
        host.addSubview(view)
        view.start(effect)
        self.view = view
        playing = effect
        generation += 1
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + effect.emitting) { [weak self] in
            guard let self, self.generation == current else { return }
            self.view?.stopEmitting()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + effect.lasting) { [weak self] in
            guard let self, self.generation == current else { return }
            self.stop()
        }
    }

    /// Takes the effect away now — the reader left the conversation.
    func stop() {
        view?.removeFromSuperview()
        view = nil
        playing = nil
    }
}

/// The layer an effect plays in: the transcript's size, never in the way of
/// a click.
private final class ScreenEffectView: NSView {
    private let emitter = CAEmitterLayer()
    private var veil: CALayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func start(_ effect: ScreenEffect) {
        guard let layer else { return }
        let bounds = self.bounds
        emitter.frame = bounds
        emitter.seed = UInt32.random(in: 0...UInt32.max)
        emitter.beginTime = CACurrentMediaTime()
        // Into its own timeline, not back in the parent's: a begin time in the
        // past leaves an emitter that never draws.
        emitter.timeOffset = effect.preroll
        switch effect {
        case .confetti:
            // From the top edge, falling and tumbling.
            emitter.emitterShape = .line
            emitter.emitterPosition = CGPoint(x: bounds.midX, y: bounds.maxY + 12)
            emitter.emitterSize = CGSize(width: bounds.width, height: 1)
            emitter.emitterCells = ScreenEffectArt.palette.flatMap { color in
                ScreenEffectArt.confettiPieces.map { piece in Self.confetti(piece, color: color) }
            }
        case .balloons:
            // From under the bottom edge, rising past the top.
            emitter.emitterShape = .line
            emitter.emitterPosition = CGPoint(x: bounds.midX, y: -ScreenEffectArt.balloonSize.height / 2)
            emitter.emitterSize = CGSize(width: bounds.width * 0.9, height: 1)
            emitter.emitterCells = ScreenEffectArt.palette.enumerated().map { index, color in
                // A rate of its own per colour, so the balloons come up one by
                // one rather than in rows.
                Self.balloon(color, rate: 0.62 + 0.09 * Float(index))
            }
        case .fireworks:
            // Rockets from the lower middle bursting in the upper half, over a
            // dimmed room, as the Messages app does.
            let veil = CALayer()
            veil.frame = bounds
            veil.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
            veil.opacity = 0
            layer.addSublayer(veil)
            fade(veil, to: 1, duration: 0.35)
            self.veil = veil
            emitter.emitterShape = .line
            emitter.emitterPosition = CGPoint(x: bounds.midX, y: 0)
            emitter.emitterSize = CGSize(width: bounds.width * 0.75, height: 1)
            emitter.renderMode = .additive
            emitter.emitterCells = [Self.rocket(height: bounds.height)]
        }
        layer.addSublayer(emitter)
    }

    /// No new pieces; those in the air finish their way out.
    func stopEmitting() {
        emitter.birthRate = 0
        if let veil { fade(veil, to: 0, duration: 1.2) }
    }

    private func fade(_ layer: CALayer, to opacity: Float, duration: TimeInterval) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = layer.presentation()?.opacity ?? layer.opacity
        animation.toValue = opacity
        animation.duration = duration
        layer.opacity = opacity
        layer.add(animation, forKey: "fade")
    }

    // MARK: Cells

    private static func confetti(_ piece: CGImage, color: NSColor) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = piece
        cell.contentsScale = ScreenEffectArt.scale
        cell.color = color.cgColor
        cell.birthRate = 5
        cell.lifetime = 7
        cell.velocity = 90
        cell.velocityRange = 60
        cell.emissionLongitude = ScreenEffectArt.down
        cell.emissionRange = .pi / 5
        cell.yAcceleration = -120
        cell.xAcceleration = 8
        cell.spin = 3
        cell.spinRange = 7
        cell.scale = 0.9
        cell.scaleRange = 0.35
        return cell
    }

    private static func balloon(_ color: NSColor, rate: Float) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = ScreenEffectArt.balloon
        cell.contentsScale = ScreenEffectArt.scale
        cell.color = color.cgColor
        cell.birthRate = rate
        cell.lifetime = 10
        cell.velocity = 200
        cell.velocityRange = 50
        cell.emissionLongitude = ScreenEffectArt.up
        cell.emissionRange = .pi / 16
        cell.yAcceleration = 18
        cell.spinRange = 0.35
        cell.scale = 1
        cell.scaleRange = 0.22
        return cell
    }

    /// A rocket that bursts where it stops climbing — the burst is its own
    /// cell, born from the rocket at the end of the rocket's life.
    private static func rocket(height: CGFloat) -> CAEmitterCell {
        let life: Float = 1.05
        let rocket = CAEmitterCell()
        rocket.contents = ScreenEffectArt.spark
        rocket.contentsScale = ScreenEffectArt.scale
        rocket.birthRate = 2.2
        rocket.lifetime = life
        // Fast enough to reach the upper half of a tall transcript, and no
        // further on a short one.
        rocket.velocity = CGFloat(min(520, max(300, height * 0.62)))
        rocket.velocityRange = 70
        rocket.emissionLongitude = ScreenEffectArt.up
        rocket.emissionRange = .pi / 9
        rocket.yAcceleration = -160
        rocket.scale = 0.7
        rocket.color = NSColor(white: 0.85, alpha: 1).cgColor
        rocket.redRange = 0.9
        rocket.greenRange = 0.9
        rocket.blueRange = 0.9

        let burst = CAEmitterCell()
        burst.contents = ScreenEffectArt.spark
        burst.contentsScale = ScreenEffectArt.scale
        burst.beginTime = CFTimeInterval(life - 0.04)
        burst.duration = 0.06
        burst.birthRate = 3200
        burst.lifetime = 1.7
        burst.lifetimeRange = 0.4
        burst.velocity = 200
        burst.velocityRange = 55
        burst.emissionRange = .pi * 2
        burst.yAcceleration = -80
        burst.alphaSpeed = -0.55
        burst.scale = 0.6
        burst.scaleSpeed = -0.15
        rocket.emitterCells = [burst]
        return rocket
    }
}

/// The pictures the pieces are made of, drawn once in white so a cell's colour
/// tints them.
private enum ScreenEffectArt {
    static let scale: CGFloat = 2

    /// An emitter's longitude is measured from straight DOWN, a quarter turn
    /// to the right at π/2 — not from the x-axis, as its documentation reads.
    /// Measured: π/2 sent the balloons sideways along the bottom edge.
    static let down: CGFloat = 0
    static let up: CGFloat = .pi

    /// The Messages app's party colours — the system's own hues.
    static let palette: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemTeal, .systemBlue, .systemPurple, .systemPink,
    ]

    static let balloonSize = CGSize(width: 54, height: 92)

    /// A strip, a square and a dot — confetti that is all one shape reads as
    /// a pattern rather than a handful thrown.
    static let confettiPieces: [CGImage] = [
        image(CGSize(width: 12, height: 5)) { context, rect in
            context.fill(rect)
        },
        image(CGSize(width: 7, height: 7)) { context, rect in
            context.fill(rect)
        },
        image(CGSize(width: 6, height: 6)) { context, rect in
            context.fillEllipse(in: rect)
        },
    ].compactMap { $0 }

    /// A balloon: the body a shade under white so its highlight stays the
    /// brightest part once tinted, a knot, and a string.
    static let balloon: CGImage? = image(balloonSize) { context, rect in
        let body = CGRect(x: 3, y: rect.height - 3 - 60, width: rect.width - 6, height: 60)
        context.setFillColor(gray: 0.82, alpha: 1)
        context.fillEllipse(in: body)
        context.setFillColor(gray: 1, alpha: 0.85)
        context.fillEllipse(in: CGRect(x: body.minX + 9, y: body.maxY - 24, width: 11, height: 15))
        let knot = CGMutablePath()
        knot.move(to: CGPoint(x: body.midX - 4, y: body.minY - 5))
        knot.addLine(to: CGPoint(x: body.midX + 4, y: body.minY - 5))
        knot.addLine(to: CGPoint(x: body.midX, y: body.minY + 1))
        knot.closeSubpath()
        context.setFillColor(gray: 0.82, alpha: 1)
        context.addPath(knot)
        context.fillPath()
        let string = CGMutablePath()
        string.move(to: CGPoint(x: body.midX, y: body.minY - 5))
        string.addCurve(
            to: CGPoint(x: body.midX + 2, y: 0),
            control1: CGPoint(x: body.midX + 6, y: body.minY - 12),
            control2: CGPoint(x: body.midX - 5, y: body.minY - 20)
        )
        context.setStrokeColor(gray: 0.82, alpha: 0.8)
        context.setLineWidth(1)
        context.addPath(string)
        context.strokePath()
    }

    /// A soft dot for rockets and sparks.
    static let spark: CGImage? = image(CGSize(width: 14, height: 14)) { context, rect in
        let colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0)] as CFArray
        guard let gradient = CGGradient(colorsSpace: nil, colors: colors, locations: [0, 1]) else { return }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        context.drawRadialGradient(
            gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: rect.width / 2,
            options: []
        )
    }

    /// Draws `size` points at `scale`, in white unless the drawing says
    /// otherwise.
    private static func image(_ size: CGSize, draw: (CGContext, CGRect) -> Void) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: Int(size.width * scale),
                  height: Int(size.height * scale),
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(gray: 1, alpha: 1)
        draw(context, CGRect(origin: .zero, size: size))
        return context.makeImage()
    }
}
