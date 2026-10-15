import AppKit
import QuartzCore

/// The frosted glass behind the transcript's bubbles: the wallpaper's blurred
/// copy, showing through every bubble's outline and nowhere else.
///
/// **One layer for the whole transcript, not a view per bubble** (REDESIGN.md
/// R6). It sits under the canvas in the document view and mirrors the canvas's
/// frame and bounds, so the bubble outlines it is masked to are in the same
/// document coordinates the canvas lays rows out in — it scrolls with the rows
/// for free. Only the picture inside it is pinned to the window, by moving one
/// sublayer on each scroll tick: no repaint, no backdrop sampling, and the
/// frost lines up with the wallpaper behind it.
///
/// The tint over the frost and the words are the canvas's own paint
/// (`BubbleTint`); this draws only the frost.
@MainActor
final class BubbleFrostView: NSView {
    private let imageLayer = CALayer()
    private let outlineMask = CAShapeLayer()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.actions = Self.noActions
        outlineMask.actions = Self.noActions
        outlineMask.fillColor = CGColor(gray: 0, alpha: 1)
        layer?.addSublayer(imageLayer)
        layer?.mask = outlineMask
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    /// Takes no events: it is a picture under the canvas, never a target.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Implicit animations off by name — a scroll tick moving the picture must
    /// not ease a quarter of a second behind the rows (§2's media-stage rule).
    private static let noActions: [String: any CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "frame": NSNull(),
        "contents": NSNull(), "path": NSNull(), "hidden": NSNull(),
    ]

    /// The frost to show, or nil when the background is not a picture.
    func setImage(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
        isHidden = image == nil
        alignToWindow()
    }

    /// Follows the canvas: the same frame and the same bounds origin, so both
    /// work in document coordinates.
    func mirror(frame canvasFrame: CGRect, boundsOrigin: CGPoint) {
        if frame != canvasFrame { frame = canvasFrame }
        if bounds.origin != boundsOrigin { setBoundsOrigin(boundsOrigin) }
    }

    /// The bubbles' outlines, in document coordinates.
    func setOutlines(_ path: CGPath) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outlineMask.frame = layer?.bounds ?? bounds
        outlineMask.bounds = layer?.bounds ?? bounds
        outlineMask.path = path
        CATransaction.commit()
    }

    /// Pins the picture to the window, so the frost in a bubble is the blurred
    /// copy of exactly the patch of wallpaper behind it. Called on every scroll
    /// tick and resize — one frame write.
    func alignToWindow() {
        guard !isHidden, let content = window?.contentView else { return }
        let rect = convert(content.bounds, from: content)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = rect
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        alignToWindow()
    }
}
