import CoreGraphics
import Foundation
import Testing
@testable import Wingcord

/// The rule that decides how often a scroll costs anything.
///
/// **The most important test here is `staysPutWhileBuffered`.** The canvas is
/// only cheap because it does *not* move for most of a scroll — the clip view
/// slides over a static layer and the compositor does the work. An
/// implementation that repositions on every scroll tick would pass every other
/// test in this file and be an order of magnitude slower.
@Suite("Timeline viewport policy")
struct TimelineViewportPolicyTests {

    private let viewportHeight: CGFloat = 800
    private let width: CGFloat = 900
    private let documentHeight: CGFloat = 20_000

    private func viewport(at y: CGFloat) -> CGRect {
        CGRect(x: 0, y: y, width: width, height: viewportHeight)
    }

    private var canvasHeight: CGFloat {
        viewportHeight + TimelineMetrics.overscan * 2
    }

    /// **The composer's content inset makes the viewport hang past the
    /// content**, and the canvas must not react to it.
    ///
    /// The transcript runs UNDER the composer and pays for it with a bottom
    /// content inset, so a clip view scrolled fully down reports a viewport
    /// whose foot is one composer-height past the end of the document. There is
    /// nothing to draw down there — the canvas is clamped to the document — so
    /// the overhang must change neither the canvas's size nor its position.
    ///
    /// The size is the half that broke: deriving the canvas height from a
    /// viewport clipped to the document shrinks it as the reader reaches the
    /// foot of a channel, and a canvas that changes size is re-laid-out and
    /// fully repainted — on every scroll tick, in exactly the region people
    /// read in.
    @Test("A viewport hanging past the document changes neither size nor position")
    func viewportPastTheDocumentStaysPut() {
        let shortDocument: CGFloat = 4_000
        let composerInset: CGFloat = 90

        // Settle the canvas at the foot of the document.
        let settled = TimelineViewportPolicy.geometry(
            viewport: viewport(at: shortDocument - viewportHeight),
            documentHeight: shortDocument,
            currentFrame: .zero
        )
        #expect(settled.frame.height == canvasHeight)

        // Now scroll into the inset: the viewport's foot runs past the content.
        let overhanging = CGRect(
            x: 0,
            y: shortDocument + composerInset - viewportHeight,
            width: width,
            height: viewportHeight
        )
        let after = TimelineViewportPolicy.geometry(
            viewport: overhanging,
            documentHeight: shortDocument,
            currentFrame: settled.frame
        )
        #expect(after.frame.height == canvasHeight)
        #expect(after.frame == settled.frame)
    }

    @Test("The canvas is viewport-sized plus overscan, never document-sized")
    func canvasIsBounded() {
        let geometry = TimelineViewportPolicy.geometry(
            viewport: viewport(at: 5_000),
            documentHeight: documentHeight,
            currentFrame: .zero
        )
        #expect(geometry.frame.height == canvasHeight)
        #expect(geometry.frame.height < documentHeight)
    }

    @Test("Bounds origin equals frame origin, so drawing stays in document space")
    func boundsTrackFrame() {
        let geometry = TimelineViewportPolicy.geometry(
            viewport: viewport(at: 5_000),
            documentHeight: documentHeight,
            currentFrame: .zero
        )
        #expect(geometry.bounds.origin.y == geometry.frame.origin.y)
        #expect(geometry.bounds.size == geometry.frame.size)
    }

    /// The whole point of the design.
    @Test("It stays put while the buffer holds")
    func staysPutWhileBuffered() {
        let settled = TimelineViewportPolicy.geometry(
            viewport: viewport(at: 5_000),
            documentHeight: documentHeight,
            currentFrame: .zero
        )

        // Scroll by less than the overscan minus the retained buffer. Nothing
        // should move: this is the case that makes a scroll free.
        let travel = TimelineMetrics.overscan - TimelineMetrics.minimumRetainedBuffer - 10
        let after = TimelineViewportPolicy.geometry(
            viewport: viewport(at: 5_000 + travel),
            documentHeight: documentHeight,
            currentFrame: settled.frame
        )
        #expect(after.frame == settled.frame)
    }

    @Test("It repositions once the buffer runs out")
    func repositionsWhenBufferExhausted() {
        let settled = TimelineViewportPolicy.geometry(
            viewport: viewport(at: 5_000),
            documentHeight: documentHeight,
            currentFrame: .zero
        )
        let travel = TimelineMetrics.overscan + 100
        let after = TimelineViewportPolicy.geometry(
            viewport: viewport(at: 5_000 + travel),
            documentHeight: documentHeight,
            currentFrame: settled.frame
        )
        #expect(after.frame != settled.frame)
        #expect(after.frame.minY <= 5_000 + travel)
        #expect(after.frame.maxY >= 5_000 + travel + viewportHeight)
    }

    @Test("The canvas always covers the viewport after a reposition")
    func alwaysCoversViewport() {
        var frame = CGRect.zero
        for offset in stride(from: 0.0, through: documentHeight - viewportHeight, by: 137) {
            let box = viewport(at: offset)
            let geometry = TimelineViewportPolicy.geometry(
                viewport: box,
                documentHeight: documentHeight,
                currentFrame: frame
            )
            frame = geometry.frame
            #expect(frame.minY <= box.minY + 0.5)
            #expect(frame.maxY >= box.maxY - 0.5)
        }
    }

    @Test("It never runs past either end of the document")
    func staysInsideDocument() {
        let atTop = TimelineViewportPolicy.geometry(
            viewport: viewport(at: 0),
            documentHeight: documentHeight,
            currentFrame: .zero
        )
        #expect(atTop.frame.minY >= 0)

        let atBottom = TimelineViewportPolicy.geometry(
            viewport: viewport(at: documentHeight - viewportHeight),
            documentHeight: documentHeight,
            currentFrame: .zero
        )
        #expect(atBottom.frame.maxY <= documentHeight + 0.5)
    }

    @Test("A document shorter than the viewport gives a canvas the document's height")
    func shortDocument() {
        let geometry = TimelineViewportPolicy.geometry(
            viewport: viewport(at: 0),
            documentHeight: 200,
            currentFrame: .zero
        )
        #expect(geometry.frame.height == 200)
    }

    @Test("A width change forces a reposition even when the buffer holds")
    func widthChangeForcesReposition() {
        let settled = TimelineViewportPolicy.geometry(
            viewport: viewport(at: 5_000),
            documentHeight: documentHeight,
            currentFrame: .zero
        )
        let narrower = CGRect(x: 0, y: 5_000, width: width - 100, height: viewportHeight)
        let after = TimelineViewportPolicy.geometry(
            viewport: narrower,
            documentHeight: documentHeight,
            currentFrame: settled.frame
        )
        #expect(after.frame.width == narrower.width)
    }
}

@Suite("Timeline scroll decisions")
struct TimelineScrollDecisionTests {

    @Test("Near-bottom has hysteresis in both directions")
    func hysteresis() {
        let documentHeight: CGFloat = 10_000
        func viewport(at maxY: CGFloat) -> CGRect {
            CGRect(x: 0, y: maxY - 800, width: 900, height: 800)
        }

        // Entering: has to get properly close.
        #expect(!TimelineViewportPolicy.isNearBottom(
            viewport: viewport(at: documentHeight - 60),
            documentHeight: documentHeight,
            wasNearBottom: false
        ))
        #expect(TimelineViewportPolicy.isNearBottom(
            viewport: viewport(at: documentHeight - 10),
            documentHeight: documentHeight,
            wasNearBottom: false
        ))

        // Leaving: the band keeps it latched, so a rubber-band or a late
        // relayout does not flip it — every flip is a state change the whole
        // window observes.
        #expect(TimelineViewportPolicy.isNearBottom(
            viewport: viewport(at: documentHeight - 60),
            documentHeight: documentHeight,
            wasNearBottom: true
        ))
        #expect(!TimelineViewportPolicy.isNearBottom(
            viewport: viewport(at: documentHeight - 400),
            documentHeight: documentHeight,
            wasNearBottom: true
        ))
    }

    @Test("History is requested far before the content runs out")
    func historyPrefetchIsEarly() {
        let near = CGRect(x: 0, y: 500, width: 900, height: 800)
        let far = CGRect(x: 0, y: 40_000, width: 900, height: 800)
        #expect(TimelineViewportPolicy.shouldLoadEarlier(
            viewport: near, hasMore: true, isLoading: false
        ))
        #expect(!TimelineViewportPolicy.shouldLoadEarlier(
            viewport: far, hasMore: true, isLoading: false
        ))
    }

    @Test("It does not ask twice, and does not ask when there is nothing more")
    func prefetchGuards() {
        let near = CGRect(x: 0, y: 500, width: 900, height: 800)
        #expect(!TimelineViewportPolicy.shouldLoadEarlier(
            viewport: near, hasMore: true, isLoading: true
        ))
        #expect(!TimelineViewportPolicy.shouldLoadEarlier(
            viewport: near, hasMore: false, isLoading: false
        ))
    }
}
