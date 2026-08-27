import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Wingcord

/// The canvases must keep their coordinate system at 1:1 with their frame.
///
/// **This is here because the failure was invisible and self-correcting.** An
/// `NSView`'s `bounds` is not a passive mirror of its `frame`: assigning a
/// bounds whose *size* differs from the frame's defines a scale between the two,
/// and AppKit remembers it. Both canvases used to assign `bounds` before
/// `frame`, so at every step where the two disagreed — the zero-sized bootstrap,
/// and every column resize — a scale was installed and every row was drawn
/// stretched or microscopic.
///
/// It looked like it fixed itself because the *next* call arrived with the sizes
/// already matching, which reset the scale. So the symptom was "the member list
/// and the transcript are sized wrong until I scroll", it never reproduced in a
/// screenshot taken a second later, and nothing in a layout test caught it:
/// every row rect was correct, and it was the transform underneath them that
/// was wrong.
///
/// Measured before the fix, from a zero-sized bootstrap: a 300x800 frame
/// produced a bounds of 90000x640000 and a scale of 0.003; a 300 -> 240 resize
/// produced a 1.25x horizontal stretch.
@MainActor
struct CanvasViewportScaleTests {

    /// The scale between a view's own space and its superview's.
    private func scale(of view: NSView) -> CGSize {
        let unit = view.convert(CGRect(x: 0, y: 0, width: 100, height: 100), to: view.superview)
        return CGSize(width: unit.width / 100, height: unit.height / 100)
    }

    /// Drives one canvas through the sequence that used to break it.
    private func assertUnscaled(
        install: (CGRect) -> Void,
        view: NSView,
        _ comment: Comment
    ) {
        // The frames a real session hands over, in order: a zero-sized
        // bootstrap, the first real layout, a scroll, and a column resize.
        let steps = [
            CGRect(x: 0, y: 0, width: 1, height: 1),
            CGRect(x: 0, y: 0, width: 300, height: 800),
            CGRect(x: 0, y: 600, width: 300, height: 800),
            CGRect(x: 0, y: 600, width: 240, height: 800),
            CGRect(x: 0, y: 120, width: 240, height: 700),
        ]
        for step in steps {
            install(step)
            let resolved = scale(of: view)
            // Hoisted out of `#expect`, which is a known trap with inline
            // arithmetic — it can fail on correct code.
            let horizontal = abs(resolved.width - 1)
            let vertical = abs(resolved.height - 1)
            #expect(horizontal < 0.001, comment)
            #expect(vertical < 0.001, comment)
            // And the bounds must stay the same SIZE as the frame, which is the
            // property the scale is derived from.
            let widthGap = abs(view.bounds.width - view.frame.width)
            let heightGap = abs(view.bounds.height - view.frame.height)
            #expect(widthGap < 0.001, comment)
            #expect(heightGap < 0.001, comment)
        }
    }

    @Test("The transcript canvas never picks up a scale")
    func timelineCanvasStaysUnscaled() {
        let document = TimelineDocumentView(frame: CGRect(x: 0, y: 0, width: 400, height: 4000))
        let canvas = TimelineCanvasView(style: MessageTextStyle.current())
        document.addSubview(canvas)
        assertUnscaled(
            install: { canvas.installViewport(frame: $0, bounds: $0) },
            view: canvas,
            "the transcript canvas installed a scale"
        )
    }

    @Test("The member canvas never picks up a scale")
    func memberCanvasStaysUnscaled() {
        let document = TimelineDocumentView(frame: CGRect(x: 0, y: 0, width: 400, height: 4000))
        let canvas = MemberListCanvas(style: MessageTextStyle.current())
        document.addSubview(canvas)
        assertUnscaled(
            install: { canvas.installViewport(frame: $0, bounds: $0) },
            view: canvas,
            "the member canvas installed a scale"
        )
    }

    /// The origin still has to move, or the canvas draws the wrong slice.
    ///
    /// Guarding only against scale would be satisfied by a canvas that ignores
    /// its inputs entirely, so the other half of the contract is asserted here:
    /// bounds origin tracks frame origin, which is what keeps drawing in
    /// document coordinates.
    @Test("Bounds origin still follows the frame")
    func originStillTracks() {
        let document = TimelineDocumentView(frame: CGRect(x: 0, y: 0, width: 400, height: 4000))
        let canvas = TimelineCanvasView(style: MessageTextStyle.current())
        document.addSubview(canvas)

        let frame = CGRect(x: 0, y: 940, width: 300, height: 800)
        canvas.installViewport(frame: frame, bounds: frame)

        let originGap = abs(canvas.bounds.minY - frame.minY)
        #expect(originGap < 0.001)
    }
}
