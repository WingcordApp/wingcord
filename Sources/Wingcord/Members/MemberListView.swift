import AppKit
import Foundation
import SwiftUI
import WingcordCore

/// The member list, hosted in SwiftUI.
struct MemberListView: NSViewRepresentable {
    var sections: [MemberSection]
    /// See `TimelineView.presentationRevision`.
    var presentationRevision: UInt64 = 0
    /// The window's chrome, measured by the pane above and paid for as a content
    /// inset — so the roster runs under the toolbar the way the transcript does,
    /// and AppKit's scroll pocket across the window's top is one continuous edge
    /// rather than a band that stops at a column boundary.
    var topInset: CGFloat = 0
    var openProfile: (UserID, CGRect) -> Void = { _, _ in }
    var openMenu: (UserID, CGRect) -> Void = { _, _ in }
    /// Whose card is open over this roster. See
    /// `MemberListCanvas.profiledUserID`.
    var profiledUserID: UserID?
    /// Whether a floating layer is drawn over the roster. See
    /// `MemberListCanvas.apply(isCovered:)`.
    var isCovered: Bool = false

    @Environment(\.motion) private var motion

    func makeCoordinator() -> MemberListCoordinator {
        MemberListCoordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.openProfile = openProfile
        context.coordinator.openMenu = openMenu
        // The one environment value a drawn canvas cannot read for itself. See
        // `MemberListCanvas.animatesPlate`.
        context.coordinator.setAnimatesPlate(!motion.reduceMotion)
        context.coordinator.setProfiledUser(profiledUserID)
        context.coordinator.setCovered(isCovered)
        context.coordinator.update(
            sections: sections,
            presentationRevision: presentationRevision,
            topInset: topInset
        )
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: MemberListCoordinator) {
        coordinator.tearDown()
        scrollView.documentView = nil
    }
}

@MainActor
final class MemberListCoordinator: NSObject {
    private var scrollView: NSScrollView?
    private var documentView: TimelineDocumentView?
    private var canvas: MemberListCanvas?

    private var sections: [MemberSection] = []
    private var boundsObserver: NSObjectProtocol?
    private var frameObserver: NSObjectProtocol?
    /// The width the rows were last laid out against.
    private var layoutWidth: CGFloat = 0
    private var scrollBeganObserver: NSObjectProtocol?
    private var scrollEndedObserver: NSObjectProtocol?
    private var prefetchTask: Task<Void, Never>?
    private var liveScrollTimeout: Task<Void, Never>?
    private var isTornDown = false

    var openProfile: (UserID, CGRect) -> Void = { _, _ in }
    var openMenu: (UserID, CGRect) -> Void = { _, _ in }

    func makeScrollView() -> NSScrollView {
        let canvas = MemberListCanvas(style: MessageTextStyle.current())
        canvas.onOpenProfile = { [weak self] userID, frame in
            self?.openProfile(userID, frame)
        }
        canvas.onOpenMenu = { [weak self] userID, frame in
            self?.openMenu(userID, frame)
        }
        canvas.onWidthChange = { [weak self] _ in
            self?.applyRows()
        }
        // **What puts a picture back after the cache dropped it.**
        //
        // The painter only ever *peeks* at the image caches — it cannot start a
        // fetch from inside a draw — so an asset nobody prefetches is an asset
        // that never arrives. Prefetching ran on the viewport moving and on the
        // roster being rebuilt, and neither happens while somebody is reading a
        // settled list: `update(sections:)` returns early when the sections are
        // unchanged, so an `NSCache` that evicted a nameplate left the plate
        // blank until the next scroll.
        //
        // Hovering is what made that visible, and not by coincidence — it is
        // the one thing in this list that allocates megabytes, because it
        // decodes a filmstrip. The pointer crossing a row is also the cheapest
        // honest moment to re-check: the walk below finds every key already
        // cached and stops without starting anything.
        canvas.onHoveredRowChange = { [weak self] in
            self?.schedulePrefetch()
        }

        let document = TimelineDocumentView(frame: .zero)
        document.addSubview(canvas)

        let scrollView = NSScrollView()
        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        scrollView.automaticallyAdjustsContentInsets = false

        self.canvas = canvas
        self.documentView = document
        self.scrollView = scrollView
        observe(scrollView)
        return scrollView
    }

    private func observe(_ scrollView: NSScrollView) {
        let center = NotificationCenter.default
        boundsObserver = center.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.viewportDidChange() }
        }
        // The clip view's FRAME as well as its bounds.
        //
        // At `makeNSView` the scroll view has no size, so the first real width
        // arrives as a frame change and not as a bounds change. Observing only
        // bounds means the list is laid out against a zero width and stays blank
        // until the reader happens to scroll it — which is exactly the symptom
        // that led here.
        frameObserver = center.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.viewportDidChange() }
        }
        scrollBeganObserver = center.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setScrolling(true) }
        }
        scrollEndedObserver = center.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setScrolling(false) }
        }
    }

    func setAnimatesPlate(_ animates: Bool) {
        canvas?.animatesPlate = animates
    }

    func setProfiledUser(_ userID: UserID?) {
        canvas?.profiledUserID = userID
    }

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        prefetchTask?.cancel()
        prefetchTask = nil
        liveScrollTimeout?.cancel()
        liveScrollTimeout = nil
        let center = NotificationCenter.default
        for observer in [boundsObserver, frameObserver, scrollBeganObserver, scrollEndedObserver] {
            if let observer { center.removeObserver(observer) }
        }
        boundsObserver = nil
        frameObserver = nil
        scrollBeganObserver = nil
        scrollEndedObserver = nil
        canvas?.tearDown()
        canvas?.onOpenProfile = nil
        canvas?.onOpenMenu = nil
        canvas?.onWidthChange = nil
        canvas?.onHoveredRowChange = nil
        canvas = nil
        documentView = nil
        scrollView = nil
        ScrollWorkGate.endIfOwned(by: ObjectIdentifier(self))
    }

    deinit {
        MainActor.assumeIsolated {
            if !isTornDown { tearDown() }
        }
    }

    private var presentationRevision: UInt64 = 0

    func setCovered(_ isCovered: Bool) {
        canvas?.apply(isCovered: isCovered)
    }

    func update(sections: [MemberSection], presentationRevision: UInt64, topInset: CGFloat) {
        guard !isTornDown else { return }
        if let scrollView, abs(scrollView.contentInsets.top - topInset) > 0.5 {
            let insets = NSEdgeInsets(top: max(0, topInset), left: 0, bottom: 0, right: 0)
            scrollView.contentInsets = insets
            scrollView.scrollerInsets = insets
        }
        if presentationRevision != self.presentationRevision {
            self.presentationRevision = presentationRevision
            canvas?.style = PresentationRevision.shared.style
            self.sections = sections
            applyRows()
            return
        }
        // `Array ==` short-circuits on buffer identity, so a presence flush that
        // moved nobody settles here in a pointer comparison — which is the whole
        // reason the roster comes from a memo.
        guard sections != self.sections else { return }
        self.sections = sections
        applyRows()
    }

    private func applyRows() {
        guard let canvas, let scrollView, !isTornDown else { return }
        let viewport = scrollView.contentView.bounds
        if viewport.width > 0 { layoutWidth = viewport.width }
        let height = canvas.apply(rows: sections.flattened())
        let size = NSSize(
            width: max(1, viewport.width),
            // The readable band rather than the clip view: see
            // `TimelineViewportPolicy.readableHeight`. A roster shorter than its
            // column would otherwise carry a scroll range one toolbar deep and
            // let its first section be dragged up behind the chrome.
            height: max(1, max(height, TimelineViewportPolicy.readableHeight(
                viewport: viewport.height,
                topInset: scrollView.contentInsets.top,
                bottomInset: scrollView.contentInsets.bottom
            )))
        )
        if documentView?.frame.size != size { documentView?.setFrameSize(size) }
        positionCanvas()
        schedulePrefetch()
    }

    private func viewportDidChange() {
        guard !isTornDown, let scrollView, let canvas else { return }
        let width = scrollView.contentView.bounds.width
        // The bootstrap case and the resize case are the same case: the width
        // the rows were laid out against is no longer the width on screen.
        if width > 0, abs(width - layoutWidth) >= 1 {
            layoutWidth = width
            applyRows()
            return
        }
        if canvas.rows.isEmpty, !sections.isEmpty, width > 0 {
            applyRows()
            return
        }
        positionCanvas()
        schedulePrefetch()
    }

    private func positionCanvas() {
        guard let scrollView, let canvas, let documentView else { return }
        let geometry = TimelineViewportPolicy.geometry(
            viewport: scrollView.contentView.bounds,
            documentHeight: documentView.frame.height,
            currentFrame: canvas.frame
        )
        canvas.installViewport(frame: geometry.frame, bounds: geometry.bounds)
    }

    private func setScrolling(_ scrolling: Bool) {
        guard !isTornDown else { return }
        canvas?.isScrolling = scrolling
        let owner = ObjectIdentifier(self)
        if scrolling {
            ScrollWorkGate.begin(owner: owner)
            liveScrollTimeout?.cancel()
            liveScrollTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.setScrolling(false) }
            }
        } else {
            liveScrollTimeout?.cancel()
            liveScrollTimeout = nil
            ScrollWorkGate.endIfOwned(by: owner)
            schedulePrefetch()
        }
    }

    /// Fetches the avatars and plates the visible rows need, once per viewport
    /// change and behind the scroll gate.
    private func schedulePrefetch() {
        guard !isTornDown, let canvas else { return }
        let scale = canvas.window?.backingScaleFactor ?? 2
        var requests: [(ImageStore.Key, ImageStore.Bucket)] = []
        var seen = Set<ImageStore.Key>()
        for index in canvas.visibleRowRange() {
            guard case .member(let entry) = canvas.rows[index] else { continue }
            if let url = entry.avatarURL {
                let key = ImageStore.Key(
                    url: url,
                    maximumPixelSize: Int((Metrics.avatarRow * scale).rounded(.up))
                )
                if seen.insert(key).inserted, ImageStore.shared.cached(key) == nil {
                    requests.append((key, .thumbnail))
                }
            }
            // **The avatar decoration, which was decoded and never asked
            // for.** `MemberEntry.decorationURL` has been on the wire and in
            // the presentation since the roster was written, and no surface
            // ever requested the bytes — so every decoration in this list drew
            // as nothing at all. Same rule as the badge below: the painter only
            // peeks, and the key has to match the one it peeks with.
            if let url = entry.decorationURL {
                let side = Metrics.avatarRow * Metrics.decorationScale
                let key = ImageStore.Key(
                    url: url,
                    maximumPixelSize: Int((side * scale).rounded(.up))
                )
                if seen.insert(key).inserted, ImageStore.shared.cached(key) == nil {
                    requests.append((key, .thumbnail))
                }
            }
            // The guild badge inside a clan tag. Missing from this loop is how
            // every tag in the list drew as bare letters: the painter only ever
            // *peeks* at the cache — it cannot start a fetch from inside a draw
            // — so an asset nobody prefetches is an asset that never arrives.
            // The key has to match the painter's exactly, or the picture lands
            // in a slot the draw never looks in.
            if let url = entry.tagBadgeURL {
                let key = ImageStore.Key(
                    url: url,
                    maximumPixelSize: Int(
                        (MemberRowGeometry.tagBadgeSide * scale).rounded(.up)
                    )
                )
                if seen.insert(key).inserted, ImageStore.shared.cached(key) == nil {
                    requests.append((key, .thumbnail))
                }
            }
            if let url = entry.nameplateURL {
                let key = ImageStore.Key(
                    url: url,
                    maximumPixelSize: Int(
                        (MemberRowGeometry.nameplateArtWidth * scale).rounded(.up)
                    )
                )
                if seen.insert(key).inserted,
                   ImageStore.shared.cached(key, bucket: .artwork) == nil
                {
                    requests.append((key, .artwork))
                }
            }
            // A custom status's own emoji, at the size and in the slot
            // `TimelineRowPainter.drawEmojiInBox` peeks at. A Unicode emoji is
            // a glyph and needs nothing.
            if let emoji = entry.activityLine?.statusEmoji, let id = emoji.id {
                let side = MemberRowGeometry.statusEmojiSide
                if let url = CDN.emoji(id: id, animated: emoji.isAnimated, side: side) {
                    let key = ImageStore.Key(
                        url: url,
                        maximumPixelSize: Int((side * scale).rounded(.up))
                    )
                    if seen.insert(key).inserted, ImageStore.shared.cached(key) == nil {
                        requests.append((key, .thumbnail))
                    }
                }
            }
        }
        // **Cancelled only when there is something new to ask for.** This runs
        // on every viewport change and on every row the pointer crosses, and a
        // cancel at the top would let a sweep down the column repeatedly kill
        // the batch it had just started.
        guard !requests.isEmpty else { return }
        prefetchTask?.cancel()

        prefetchTask = Task { [weak self] in
            await ScrollWorkGate.waitUntilInactive()
            guard !Task.isCancelled else { return }
            var landed = false
            await withTaskGroup(of: Bool.self) { group in
                for (key, bucket) in requests {
                    group.addTask {
                        await ImageStore.shared.image(for: key, bucket: bucket) != nil
                    }
                }
                for await didLoad in group where didLoad { landed = true }
            }
            guard landed else { return }
            await MainActor.run {
                guard let self, !self.isTornDown else { return }
                self.canvas?.needsDisplay = true
            }
        }
    }
}
