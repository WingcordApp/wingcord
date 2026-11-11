import CoreText
import QuartzCore

/// The emoji in a styled name, over whatever the effect is doing.
///
/// A layer of its own because nothing else in `DisplayNameEffectLayers` draws:
/// every other layer there is a shape or a gradient, and an emoji is neither —
/// it is a bitmap the font paints itself. Drawn once, at the layer's scale, and
/// never again while the name animates under it.
/// `nonisolated`, as `CALayer` itself is: Core Animation calls `draw(in:)` and
/// makes its presentation copies wherever it likes.
nonisolated final class DisplayNameColorGlyphLayer: CALayer {
    private let run: DisplayNameGlyphRun?

    init(run: DisplayNameGlyphRun) {
        self.run = run
        super.init()
        frame = CGRect(origin: .zero, size: run.size)
        // An emoji's ink reaches past the line box in the taller faces.
        masksToBounds = false
        needsDisplayOnBoundsChange = true
        setNeedsDisplay()
    }

    /// Core Animation's own copy, made for a presentation layer.
    override init(layer: Any) {
        run = (layer as? DisplayNameColorGlyphLayer)?.run
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// The host sets this after the layer is built, and a bitmap drawn at 1×
    /// and shown at 2× is a blurred emoji beside sharp letters.
    override var contentsScale: CGFloat {
        didSet {
            guard contentsScale != oldValue else { return }
            setNeedsDisplay()
        }
    }

    override func draw(in context: CGContext) {
        run?.drawColorGlyphs(in: context)
    }
}
