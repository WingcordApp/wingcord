import AppKit
import Foundation
import SwiftUI
import WingcordCore

/// The member list, hosted in SwiftUI.
struct MemberListView: NSViewRepresentable {
    var roster: Roster
    /// See `TimelineView.presentationRevision`.
    var presentationRevision: UInt64 = 0
    /// The window's chrome, measured by the pane above and paid for as a content
    /// inset — so the roster runs under the toolbar the way the transcript does,
    /// and AppKit's scroll pocket across the window's top is one continuous edge
    /// rather than a band that stops at a column boundary.
    var topInset: CGFloat = 0
    var openProfile: (UserID, CGRect) -> Void = { _, _ in }
    var openMenu: (UserID, CGRect) -> Void = { _, _ in }
    /// The rows on screen and half a viewport of rows, once the scroll settles
    /// — what the list's subscription follows.
    var showRows: (ClosedRange<Int>, Int) -> Void = { _, _ in }
    /// Whose card is open over this roster. See
    /// `MemberListCanvas.profiledUserID`.
    var profiledUserID: UserID?
    /// Whether a floating layer is drawn over the roster. See
    /// `MemberListCanvas.apply(isCovered:)`.
    var isCovered: Bool = false
    /// The Activity section at the head of the list, or nil for none.
    var activity: MemberActivityBlock?
    var openActivity: (String, CGRect) -> Void = { _, _ in }
    var toggleActivity: () -> Void = {}
    var activityMenu: (CGRect) -> Void = { _ in }
    /// Cards that stayed on screen long enough to count as seen.
    var noteActivityShown: ([String]) -> Void = { _ in }

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
        context.coordinator.showRows = showRows
        context.coordinator.openActivity = openActivity
        context.coordinator.toggleActivity = toggleActivity
        context.coordinator.activityMenu = activityMenu
        context.coordinator.noteActivityShown = noteActivityShown
        context.coordinator.update(activity: activity)
        // The one environment value a drawn canvas cannot read for itself. See
        // `MemberListCanvas.animatesPlate`.
        context.coordinator.setAnimatesPlate(!motion.reduceMotion)
        context.coordinator.setProfiledUser(profiledUserID)
        context.coordinator.setCovered(isCovered)
        context.coordinator.update(
            roster: roster,
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

    private var roster = Roster.empty
    private var boundsObserver: NSObjectProtocol?
    private var frameObserver: NSObjectProtocol?
    /// The width the rows were last laid out against.
    private var layoutWidth: CGFloat = 0
    private var scrollBeganObserver: NSObjectProtocol?
    private var scrollEndedObserver: NSObjectProtocol?
    private var prefetchTask: Task<Void, Never>?
    private var liveScrollTimeout: Task<Void, Never>?
    private var rowReport: Task<Void, Never>?
    private var isTornDown = false

    var openProfile: (UserID, CGRect) -> Void = { _, _ in }
    var openMenu: (UserID, CGRect) -> Void = { _, _ in }
    var showRows: (ClosedRange<Int>, Int) -> Void = { _, _ in }
    var openActivity: (String, CGRect) -> Void = { _, _ in }
    var toggleActivity: () -> Void = {}
    var activityMenu: (CGRect) -> Void = { _ in }
    var noteActivityShown: ([String]) -> Void = { _ in }

    private var activity: MemberActivityBlock?
    /// Waits three seconds of a section on screen before counting its cards
    /// as seen — Discord's `eg` (`946228`).
    private var impressionTask: Task<Void, Never>?

    func makeScrollView() -> NSScrollView {
        let canvas = MemberListCanvas(style: MessageTextStyle.current())
        canvas.onOpenProfile = { [weak self] userID, frame in
            self?.openProfile(userID, frame)
        }
        canvas.onOpenActivity = { [weak self] id, frame in
            self?.openActivity(id, frame)
        }
        canvas.onToggleActivity = { [weak self] in
            self?.toggleActivity()
        }
        canvas.onActivityMenu = { [weak self] frame in
            self?.activityMenu(frame)
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
        impressionTask?.cancel()
        impressionTask = nil
        liveScrollTimeout?.cancel()
        liveScrollTimeout = nil
        rowReport?.cancel()
        rowReport = nil
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
        canvas?.onOpenActivity = nil
        canvas?.onToggleActivity = nil
        canvas?.onActivityMenu = nil
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

    /// Takes a new Activity section. Its height moves every row below it, so
    /// a change of height lays the list out again.
    func update(activity: MemberActivityBlock?) {
        guard !isTornDown, activity != self.activity else { return }
        let heightChanged = (activity?.height ?? 0) != (self.activity?.height ?? 0)
        let shownBefore = Set(self.activity?.cards.map(\.id) ?? [])
        self.activity = activity
        canvas?.apply(activity: activity)
        if heightChanged { applyRows() } else { schedulePrefetch() }
        let shown = activity?.cards.map(\.id) ?? []
        if Set(shown) != shownBefore { countImpressions(of: shown) }
    }

    private func countImpressions(of ids: [String]) {
        impressionTask?.cancel()
        guard !ids.isEmpty else { return }
        impressionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, !self.isTornDown,
                  self.canvas?.window?.isKeyWindow == true
            else { return }
            self.noteActivityShown(ids)
        }
    }

    func update(roster: Roster, presentationRevision: UInt64, topInset: CGFloat) {
        guard !isTornDown else { return }
        if let scrollView, abs(scrollView.contentInsets.top - topInset) > 0.5 {
            let insets = NSEdgeInsets(top: max(0, topInset), left: 0, bottom: 0, right: 0)
            scrollView.contentInsets = insets
            scrollView.scrollerInsets = insets
        }
        // **A different list starts at the top**, as Discord's does — its list
        // view is keyed on the list's id. The same list seen from another
        // channel keeps its place.
        let isNewList = roster.identity != self.roster.identity
        if presentationRevision != self.presentationRevision {
            self.presentationRevision = presentationRevision
            canvas?.style = PresentationRevision.shared.style
            self.roster = roster
            applyRows(scrollingToTop: isNewList)
            return
        }
        // A presence flush that moved nobody settles here, because the roster
        // comes from a memo and hands back the same value.
        guard roster != self.roster else { return }
        let before = isNewList ? [:] : visibleMemberTops()
        self.roster = roster
        applyRows(scrollingToTop: isNewList)
        holdPlace(from: before)
    }

    /// Where each member on screen sits, by person.
    private func visibleMemberTops() -> [UserID: CGFloat] {
        guard let canvas else { return [:] }
        var tops: [UserID: CGFloat] = [:]
        for index in canvas.visibleRowRange() {
            guard let entry = canvas.roster.members[index] else { continue }
            tops[entry.userID] = canvas.rowFrame(at: index).minY
        }
        return tops
    }

    /// Keeps the people on screen where they were when the list changes above
    /// them — a browser's scroll anchoring, for the same reason browsers do it.
    ///
    /// **A busy server moves its list all the time.** Every member who comes
    /// online or goes offline above the viewport moves every row below them by
    /// one, so in a server of a hundred thousand the names under a still
    /// pointer slid up and down a row at a time, several times a second. Here
    /// the scroll moves by however far the people on screen were carried, and
    /// the names stay put.
    ///
    /// **The median displacement, not the first person's**, because one of
    /// them may be the member who moved: somebody going offline jumps to
    /// another group, and following them would throw the reader across the
    /// list. Nothing is held at the very top, where new rows arriving above
    /// are rows the reader should see.
    private func holdPlace(from before: [UserID: CGFloat]) {
        guard !before.isEmpty, let canvas, let scrollView, let documentView else { return }
        let clip = scrollView.contentView
        let top = -scrollView.contentInsets.top
        guard clip.bounds.minY > top + 0.5 else { return }
        var moved: [CGFloat] = []
        for (index, entry) in canvas.roster.members {
            guard let old = before[entry.userID] else { continue }
            moved.append(canvas.rowFrame(at: index).minY - old)
        }
        guard !moved.isEmpty else { return }
        moved.sort()
        let shift = moved[moved.count / 2]
        guard abs(shift) >= 0.5 else { return }
        let bottom = max(top, documentView.frame.height + scrollView.contentInsets.bottom - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(bottom, max(top, clip.bounds.minY + shift))))
        scrollView.reflectScrolledClipView(clip)
    }

    private func applyRows(scrollingToTop: Bool = false) {
        guard let canvas, let scrollView, !isTornDown else { return }
        let viewport = scrollView.contentView.bounds
        if viewport.width > 0 { layoutWidth = viewport.width }
        let height = canvas.apply(roster: roster)
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
        if scrollingToTop {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        positionCanvas()
        schedulePrefetch()
        scheduleRowReport()
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
        if canvas.roster.rowCount == 0, roster.rowCount > 0, width > 0 {
            applyRows()
            return
        }
        positionCanvas()
        schedulePrefetch()
        scheduleRowReport()
    }

    /// Reports the rows on screen fifty milliseconds after the viewport stops
    /// moving — Discord's own debounce on the same call — so a scroll through
    /// thousands of rows asks for the pages it stops at, not every page it
    /// passes.
    private func scheduleRowReport() {
        rowReport?.cancel()
        rowReport = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, let self, !self.isTornDown,
                  let canvas = self.canvas, let scrollView = self.scrollView
            else { return }
            let visible = canvas.visibleRowRange()
            guard let last = visible.last else { return }
            // Half a viewport of rows either side, as Discord pads it.
            let margin = Int(
                (scrollView.contentView.bounds.height / 2 / MemberRowGeometry.rowHeight).rounded(.up)
            )
            self.showRows(visible.lowerBound...last, margin)
        }
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
            guard let entry = canvas.roster.members[index] else { continue }
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
        // The Activity cards' faces and pictures, at the painter's sizes.
        for card in canvas.activity?.cards ?? [] {
            let faceKeys = card.faces.compactMap(\.url).map {
                ImageStore.Key(url: $0, maximumPixelSize: Int((MemberActivityGeometry.face * scale).rounded(.up)))
            }
            for key in faceKeys where seen.insert(key).inserted && ImageStore.shared.cached(key) == nil {
                requests.append((key, .thumbnail))
            }
            if let url = card.artURL {
                let key = ImageStore.Key(url: url, maximumPixelSize: Int((MemberActivityGeometry.art * scale).rounded(.up)))
                if seen.insert(key).inserted, ImageStore.shared.cached(key, bucket: .thumbnail) == nil {
                    requests.append((key, .thumbnail))
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
