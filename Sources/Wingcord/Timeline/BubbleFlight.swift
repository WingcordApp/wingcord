import AppKit
import QuartzCore
import WingcordCore

/// A sent message's bubble, flying from the composer into its place.
///
/// **A layer, not a repaint** — §2's media stage, for the reason it gives:
/// every frame of the spring is a property write on the render server, and the
/// canvas paints nothing until the bubble lands. The outline and the words are
/// drawn once, by the painter that draws them in the row, so the landing swaps
/// a layer for the same pixels.
///
/// **The sample's two moves.** The bubble opens out of the field — as wide as
/// the field for a message that fits on one line, narrowing to its own width on
/// the way, and as wide as itself otherwise — and it is pushed down and back as
/// it leaves. The travel is `Motion.momentum`'s spring: Messages' send has a
/// bounce in it, and that class is the one that carries one (§3 says why it
/// starts at rest here).
///
/// **Under the composer's glass, not over it.** It lives in the canvas, which
/// runs under the bar, exactly as the sample's bubble lives in a scroll view
/// under its field — so it leaves through the glass. And because it is in the
/// canvas's own space, a scroll moves it with the rows it is landing among.
@MainActor
final class BubbleFlight {
    /// The send's nonce — see `SendFlight.nonce`.
    let nonce: MessageID
    /// The row it lands in: the echo, then Discord's copy of it.
    var messageID: MessageID
    /// What the canvas lays over its rows, and takes away on the landing.
    let layer = CALayer()
    /// Called once, when the bubble is where the row paints it.
    var onLanded: (() -> Void)?

    private let shape = CAShapeLayer()
    private let words = CALayer()
    /// The wallpaper's frost through the body, on a frosted bubble — the
    /// picture under `frostClip`, which the body's outline masks.
    private let frostClip = CALayer()
    private let frostMask = CAShapeLayer()
    private let frostPicture = CALayer()
    /// The window's content, in canvas space: where the frost's picture sits.
    private var window: CGRect?
    /// Where the body's top-leading corner is headed, in canvas space.
    private var target: CGPoint
    /// Moves with every retarget, so only the newest spring's end lands it.
    private var generation = 0
    private let reducesMotion: Bool

    /// How far the push takes the bubble down, as a share of the field's
    /// height, and how long each half lasts — the sample's own numbers.
    private static let pushShare: CGFloat = 0.55
    private static let pushHalf: CFTimeInterval = 0.15

    /// Where the bubble is going, and what it is.
    struct Landing {
        /// The body, in canvas space.
        var body: CGRect
        var radius: CGFloat
        var tail: BubbleRow.Side?
        var fill: CGColor
        /// The glass's edge, on a frosted bubble.
        var rim: CGColor?
        /// The wallpaper's frost, on a frosted bubble, and the window's
        /// content in canvas space — the picture is laid over that.
        var frost: CGImage?
        var window: CGRect?
        /// The words, drawn once, and where they sit in the body.
        var words: CGImage?
        var wordsFrame: CGRect
        /// The words' first baseline, from their top.
        var firstBaseline: CGFloat
    }

    /// Where the words leave from, in canvas space.
    struct TakeOff {
        var firstBaseline: CGPoint
        var field: CGRect
        /// The field's type size over the bubble's — the words grow by its
        /// inverse on the way, when the reader set the two apart.
        var fontScale: CGFloat
        var isOneLine: Bool
    }

    init(
        nonce: MessageID,
        landing: Landing,
        takeOff: TakeOff,
        scale: CGFloat,
        reducesMotion: Bool
    ) {
        self.nonce = nonce
        messageID = nonce
        target = landing.body.origin
        self.reducesMotion = reducesMotion

        let endBody = CGRect(origin: .zero, size: landing.body.size)
        let endPath = BubbleShape.path(body: endBody, radius: landing.radius, tail: landing.tail)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let generation = generation
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.settled(generation) }
        }

        layer.anchorPoint = .zero
        layer.bounds = endBody
        layer.position = landing.body.origin
        if let frost = landing.frost, let window = landing.window {
            // The frost the row will show once it lands — the bubble carries
            // its own patch of the picture the whole way, so the landing swaps
            // the same pixels.
            self.window = window
            frostClip.frame = endBody
            frostMask.frame = endBody
            frostMask.path = endPath
            frostMask.contentsScale = scale
            frostClip.mask = frostMask
            frostPicture.contents = frost
            frostPicture.contentsGravity = .resizeAspectFill
            frostPicture.frame = window.offsetBy(dx: -target.x, dy: -target.y)
            frostClip.addSublayer(frostPicture)
            layer.addSublayer(frostClip)
        }
        shape.frame = endBody
        shape.path = endPath
        shape.fillColor = landing.fill
        if let rim = landing.rim {
            shape.strokeColor = rim
            shape.lineWidth = 1
        }
        shape.contentsScale = scale
        words.anchorPoint = .zero
        words.bounds = CGRect(origin: .zero, size: landing.wordsFrame.size)
        words.position = landing.wordsFrame.origin
        words.contents = landing.words
        words.contentsScale = scale
        layer.addSublayer(shape)
        layer.addSublayer(words)

        if reducesMotion {
            // No travel and no bounce: the bubble fades in where it lands.
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = Motion.reducedDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "fade")
        } else {
            Self.fly(
                layer: layer, shapes: landing.frost == nil ? [shape] : [shape, frostMask], words: words,
                landing: landing, takeOff: takeOff, endPath: endPath
            )
        }
        CATransaction.commit()
    }

    /// Adds the take-off's animations. Every travelling value is **additive
    /// from an offset to zero over the landing**, so a retarget mid-flight is
    /// one more offset rather than a restart — the flight bends toward the
    /// new place from wherever it is, as §3 asks of every motion.
    private static func fly(
        layer: CALayer,
        shapes: [CAShapeLayer],
        words: CALayer,
        landing: Landing,
        takeOff: TakeOff,
        endPath: CGPath
    ) {
        let spring = Motion.momentum
        let fontScale = takeOff.fontScale
        // The words' top-leading corner at take-off, with their baseline on the
        // field's, and the body around them as the row will hold it.
        let wordsTop = CGPoint(
            x: takeOff.firstBaseline.x,
            y: takeOff.firstBaseline.y - landing.firstBaseline * fontScale
        )
        let start = CGPoint(
            x: wordsTop.x - landing.wordsFrame.minX,
            y: wordsTop.y - landing.wordsFrame.minY
        )
        let travel = spring.layerSpring(keyPath: "position")
        travel.fromValue = NSValue(point: CGPoint(
            x: start.x - landing.body.minX, y: start.y - landing.body.minY
        ))
        travel.toValue = NSValue(point: .zero)
        travel.isAdditive = true
        layer.add(travel, forKey: "travel")

        let push = CAKeyframeAnimation(keyPath: "position.y")
        push.values = [0, takeOff.field.height * pushShare, 0]
        push.keyTimes = [0, 0.5, 1]
        push.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        push.duration = pushHalf * 2
        push.isAdditive = true
        layer.add(push, forKey: "push")

        // A message that fits on a line opens out of the whole field.
        let wordsHeight = landing.wordsFrame.height
        let startSize = CGSize(
            width: takeOff.isOneLine
                ? max(landing.body.width, takeOff.field.width + landing.wordsFrame.minX * 2)
                : landing.body.width,
            height: landing.body.height - wordsHeight * (1 - fontScale)
        )
        if startSize != landing.body.size {
            let morph = spring.layerSpring(keyPath: "path")
            morph.fromValue = BubbleShape.path(
                body: CGRect(origin: .zero, size: startSize), radius: landing.radius, tail: landing.tail
            )
            morph.toValue = endPath
            for shape in shapes { shape.add(morph, forKey: "morph") }
        }
        if abs(fontScale - 1) > 0.01 {
            let grow = spring.layerSpring(keyPath: "transform.scale")
            grow.fromValue = fontScale
            grow.toValue = 1
            words.add(grow, forKey: "grow")
        }
    }

    /// Bends the flight toward a new place — the row moved under it, or
    /// Discord's copy replaced the echo somewhere else.
    func retarget(to destination: CGPoint) {
        let offset = CGPoint(x: target.x - destination.x, y: target.y - destination.y)
        guard abs(offset.x) > 0.5 || abs(offset.y) > 0.5 else { return }
        target = destination
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = destination
        placeFrost()
        if !reducesMotion {
            generation += 1
            let generation = generation
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated { self?.settled(generation) }
            }
            let follow = Motion.momentum.layerSpring(keyPath: "position")
            follow.fromValue = NSValue(point: offset)
            follow.toValue = NSValue(point: .zero)
            follow.isAdditive = true
            layer.add(follow, forKey: "follow-\(generation)")
        }
        CATransaction.commit()
    }

    /// The window moved over the canvas — a scroll, a resize: the frost's
    /// picture follows, so it is where the row's will be when the bubble lands.
    func alignFrost(window: CGRect) {
        guard self.window != nil, self.window != window else { return }
        self.window = window
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeFrost()
        CATransaction.commit()
    }

    /// Lays the picture so the patch inside the body is the one under the
    /// landing place.
    private func placeFrost() {
        guard let window else { return }
        frostPicture.frame = window.offsetBy(dx: -target.x, dy: -target.y)
    }

    /// Takes the flight off the canvas, at once and without a fade — the row
    /// under it is painting the same bubble in the same transaction.
    func remove() {
        onLanded = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeFromSuperlayer()
        CATransaction.commit()
    }

    private func settled(_ generation: Int) {
        guard generation == self.generation else { return }
        onLanded?()
    }

    /// The words, drawn once by the painter that draws them in the row — the
    /// same plates, the same ink — at the window's scale.
    static func wordsImage(
        _ block: TimelineTextBlock,
        style: MessageTextStyle,
        plates: TextPlateInk?,
        scale: CGFloat
    ) -> CGImage? {
        let width = Int((block.size.width * scale).rounded(.up))
        let height = Int((block.size.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        // Top-down, as the canvas is.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        TimelineRowPainter.drawTextBlock(
            block,
            at: .zero,
            context: context,
            style: style,
            images: ImageStore.shared,
            scale: scale,
            time: AnimationClock.shared.time,
            state: TimelineRowPainter.TextState(revealedSpoilers: [], plates: plates)
        )
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
