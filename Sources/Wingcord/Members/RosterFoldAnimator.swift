import AppKit
import QuartzCore
import WingcordCore

/// The rows of a section rolling up under its heading, or down from it.
///
/// **Two pictures and one spring, not a draw per frame.** The list is one drawn
/// canvas: moving its rows for real would repaint a screenful of avatars and text
/// at the display's rate, for a third of a second. So what's under the heading is
/// rendered once — the section's rows, and whatever comes after them — and the
/// compositor slides that, with the canvas drawing only what's above until it lands.
///
/// **Under the heading, clipped to its foot**, the way a disclosure opens: the rows
/// never ride over the heading that owns them, and what comes after them travels
/// with them instead of the two crossing.
@MainActor
final class RosterFoldAnimator {
    /// Sits over the clip view, and answers no clicks.
    private final class Stage: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private var stage: Stage?
    private var track: CALayer?
    private var rowsLayer: CALayer?
    private var finish: (() -> Void)?
    /// Which section is in flight, so folding it back mid-way carries on from
    /// where it is instead of jumping.
    private var key: MemberSectionKey?
    /// How far the track can travel: the height of the rows' picture.
    private var travel: CGFloat = 0

    /// How open the section in flight is right now, 0 to 1, or nil if it isn't
    /// `key`. Read off the presentation layer: what's on screen, not where it's going.
    func openness(of key: MemberSectionKey) -> CGFloat? {
        guard self.key == key, let track, travel > 0 else { return nil }
        let y = (track.presentation() ?? track).position.y
        return min(1, max(0, 1 + y / travel))
    }

    /// Ends what's in flight, leaving the canvas in charge of what it draws.
    func end() {
        guard let finish else { return }
        self.finish = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        finish()
        stage?.removeFromSuperview()
        CATransaction.commit()
        stage = nil
        track = nil
        rowsLayer = nil
        key = nil
    }

    /// Plays one fold.
    ///
    /// - Parameters:
    ///   - top: the heading's foot, in the scroll view's own space.
    ///   - rows: the section's rows, as far as they'd show.
    ///   - below: what comes after them.
    ///   - from: how open it starts: 1 when folding, 0 when opening, or wherever
    ///     the last one had got to.
    ///   - finish: hands the area back to the canvas when it lands.
    func play(
        key: MemberSectionKey,
        over scrollView: NSScrollView,
        top: CGFloat,
        rows: CGImage?,
        rowsHeight: CGFloat,
        below: CGImage?,
        isOpening: Bool,
        from: CGFloat,
        scale: CGFloat,
        finish: @escaping () -> Void
    ) {
        let size = scrollView.contentView.frame.size
        let stage = Stage(frame: scrollView.contentView.frame)
        stage.wantsLayer = true
        scrollView.addSubview(stage)

        // The clip's top is the heading's foot.
        let clip = CALayer()
        clip.frame = CGRect(x: 0, y: top, width: size.width, height: max(0, size.height - top))
        clip.masksToBounds = true

        // The track holds the rows, then what's after them. Its origin sits at
        // `-rowsHeight` when the section is shut and at `0` when it's open.
        let track = CALayer()
        track.anchorPoint = .zero
        track.bounds = CGRect(x: 0, y: 0, width: size.width, height: rowsHeight + size.height)
        let rowsLayer = CALayer()
        rowsLayer.frame = CGRect(x: 0, y: 0, width: size.width, height: rowsHeight)
        rowsLayer.contents = rows
        rowsLayer.contentsScale = scale
        let belowLayer = CALayer()
        belowLayer.frame = CGRect(x: 0, y: rowsHeight, width: size.width, height: size.height)
        belowLayer.contents = below
        belowLayer.contentsScale = scale
        track.addSublayer(rowsLayer)
        track.addSublayer(belowLayer)
        clip.addSublayer(track)
        stage.layer?.addSublayer(clip)

        self.stage = stage
        self.track = track
        self.rowsLayer = rowsLayer
        self.key = key
        self.travel = rowsHeight
        self.finish = finish

        let target: CGFloat = isOpening ? 0 : -rowsHeight
        let start = -rowsHeight * (1 - from)
        track.position = CGPoint(x: 0, y: target)
        rowsLayer.opacity = isOpening ? 1 : 0

        let slide = CASpringAnimation(
            perceptualDuration: Motion.reposition.response,
            bounce: 0
        )
        slide.keyPath = "position.y"
        slide.fromValue = start
        slide.toValue = target
        slide.duration = slide.settlingDuration

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = isOpening ? 1 : 0
        fade.duration = slide.settlingDuration * (isOpening ? 0.8 : 0.5)
        fade.timingFunction = CAMediaTimingFunction(name: isOpening ? .easeIn : .easeOut)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak track] in
            // A newer fold has taken over if this isn't the track on stage.
            guard let self, let track, self.track === track else { return }
            self.end()
        }
        track.add(slide, forKey: "fold")
        rowsLayer.add(fade, forKey: "fold")
        CATransaction.commit()
    }
}
