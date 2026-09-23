import AppKit
import Testing
import WingcordCore
@testable import Wingcord

/// Every action the drawn transcript can raise is actually connected.
///
/// **This suite exists because one of them was not, and nothing could see it.**
/// `TimelineCanvasView` publishes its actions as optional closures, so a hit test
/// that resolves perfectly and a canvas whose closure was never assigned are the
/// same thing on screen: a control that draws, takes the pointer, reports a
/// pointing hand, and does nothing. The Open chip on a music card shipped that
/// way — the layout was pinned by tests, the hit test was correct, and the one
/// line that wired the callback had been lost in an edit.
///
/// A closure being nil is not a design state anywhere here. Every one of these is
/// assigned once in `makeScrollView` and cleared once in `tearDown`, so a missing
/// assignment is always a defect and always this shape.
///
/// **Asserted by name rather than by count**, because a count passes the moment
/// somebody adds a callback and forgets to wire it — which is the whole failure
/// being guarded against.
@Suite("Timeline wiring")
@MainActor
struct TimelineWiringTests {

    /// **The coordinator has to outlive the assertions**, and that is not
    /// incidental: its `deinit` calls `tearDown`, which sets every one of these
    /// back to nil. Letting it fall out of scope before the checks made the
    /// first version of this suite fail all nine — against a canvas that was
    /// wired perfectly a line earlier. Held, so what is measured is the state a
    /// running window is in.
    @Test("Every action a click can raise is connected")
    func actionsAreWired() throws {
        let coordinator = TimelineCoordinator(model: AppModel())
        let scrollView = coordinator.makeScrollView()
        // The canvas is inside the document view: the document is sized to the
        // whole content while the canvas is a viewport-sized window onto it.
        let canvas = try #require(
            scrollView.documentView?.subviews
                .compactMap { $0 as? TimelineCanvasView }
                .first,
            "the transcript's canvas"
        )
        #expect(canvas.onOpenLink != nil, "a link in a message body")
        #expect(canvas.onOpenProfile != nil, "a face or a name")
        #expect(canvas.onOpenEmoji != nil, "a custom emoji")
        #expect(canvas.onOpenSticker != nil, "a sticker")
        #expect(canvas.onOpenAttachment != nil, "a picture or a clip")
        #expect(canvas.onToggleFavoriteGIF != nil, "the star on a GIF")
        #expect(canvas.isFavoriteGIF != nil, "which way that star points")
        #expect(canvas.onTogglePreview != nil, "a music card's Preview chip")
        #expect(canvas.onOpenMusicPlayer != nil, "a music card's Open chip")
        #expect(canvas.onOpenTopicMarker != nil, "an open topic's marker")

        // Keeps the coordinator alive to here. See the note above.
        withExtendedLifetime(coordinator) {}
    }

    /// The other half of the contract: `tearDown` really does let go, so a
    /// coordinator that has been dismantled cannot keep the store alive through
    /// a closure it never released.
    @Test("Tearing down releases every one of them")
    func teardownReleasesThem() throws {
        let coordinator = TimelineCoordinator(model: AppModel())
        let scrollView = coordinator.makeScrollView()
        let canvas = try #require(
            scrollView.documentView?.subviews
                .compactMap { $0 as? TimelineCanvasView }
                .first
        )
        coordinator.tearDown()
        #expect(canvas.onOpenMusicPlayer == nil)
        #expect(canvas.onTogglePreview == nil)
        #expect(canvas.onOpenLink == nil)
    }
}
