import AppKit
import Foundation
import SwiftUI
import WingcordCore

/// The transcript, hosted in SwiftUI.
///
/// Everything expensive happens in the coordinator; this struct is a value that
/// carries the current inputs across. It deliberately holds **no closures over
/// the model** other than the store reference itself, so SwiftUI comparing two
/// of these compares ids and arrays rather than always-unequal function values.
struct TimelineView: NSViewRepresentable {
    var channelID: ChannelID
    var rows: [TimelineItem]
    /// Moves when the appearance or the text size changes. Carried as an INPUT
    /// so a change re-runs `updateNSView`, which is the only place the
    /// coordinator can be told about it.
    var presentationRevision: UInt64
    /// An invitation card's colour, by application. Packed 24-bit, as every
    /// other themed value in this store is; the canvas converts.
    var activityAccents: [ApplicationID: UInt32] = [:]
    /// What each invitation card paints. Observed by the container so presence
    /// moving reaches the canvas; see `TimelineCanvasView.apply(activityInviteStatuses:)`.
    var activityInviteStatuses: [ApplicationID: ActivityInviteStatus] = [:]
    /// How much of the scroll view's foot the composer covers.
    ///
    /// The transcript deliberately extends UNDERNEATH the composer so messages
    /// pass beneath its glass and it has something to refract — a floating bar
    /// over an opaque surface is just a panel. The inset is what keeps the
    /// newest message reachable rather than parked behind the bar.
    var topInset: CGFloat
    var bottomInset: CGFloat
    /// The message the transcript has been asked to go to, if any. An INPUT
    /// rather than a call, so a jump raised from anywhere in the app — a link, a
    /// reply header — reaches the one object that owns the scroll view.
    /// Moves when a Spotify card lands.
    ///
    /// **A prop rather than a store read inside the coordinator**, because the
    /// canvas is a drawn `NSView` and only what SwiftUI re-evaluates ever
    /// reaches it — the same reason `activityAccents` is read by the container.
    /// A card that resolved without this would sit in the store and never be
    /// drawn.
    var spotifyRevision: UInt64
    /// The clip playing anywhere in the app, so the chip that started it offers
    /// to stop it. Read by the container for the reason the accents are.
    var playingPreview: URL?
    var jump: MessageJump?
    var model: AppModel

    func makeCoordinator() -> TimelineCoordinator {
        TimelineCoordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            channelID: channelID,
            items: rows,
            presentationRevision: presentationRevision,
            activityAccents: activityAccents,
            activityInviteStatuses: activityInviteStatuses,
            topInset: topInset,
            bottomInset: bottomInset,
            jump: jump,
            spotifyRevision: spotifyRevision,
            playingPreview: playingPreview
        )
    }

    /// **Teardown is explicit and complete.** A representable that leaves its
    /// coordinator holding a scroll view, an observer and a running task keeps
    /// the whole transcript — text blocks, decoded images, the row cache — alive
    /// for the life of the process, once per channel ever opened. That is the
    /// classic leak in a view like this and it is invisible until a memory graph
    /// is taken.
    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: TimelineCoordinator) {
        coordinator.tearDown()
        scrollView.documentView = nil
    }
}

/// Owns the scroll view, the canvas, the row cache and the layout task.
@MainActor
final class TimelineCoordinator: NSObject {
    private unowned let model: AppModel

    private var scrollView: NSScrollView?
    /// The ground and the scroll-edge strip. See `CanvasChrome`.
    private var chrome: CanvasChrome?
    private var documentView: TimelineDocumentView?
    private var canvas: TimelineCanvasView?

    private var channelID: ChannelID?
    private var items: [TimelineItem] = []
    private var layoutWidth: CGFloat = 0
    /// The viewport height the transcript was last positioned against.
    ///
    /// **A viewport that GROWS while somebody is at the bottom has to be put
    /// back at the bottom**, which is the same rule the content inset already
    /// states and a different moment. It is the geometry change, not the inset
    /// change, that actually lands last: the inset is written during
    /// `updateNSView`, and the clip view is not resized until the layout pass
    /// after it — so a `scrollToBottom` fired from the inset is measured against
    /// the viewport the bar had not yet been carved out of.
    ///
    /// Nobody could see it in the window because the composer is measured while
    /// the first page is still in flight. The overlay's chat window opens onto a
    /// transcript that is already resident, so both landed in the same pass and
    /// the newest message sat behind the composer.
    private var lastViewportHeight: CGFloat = 0
    private var style: MessageTextStyle
    /// The settings half of the presentation, refreshed with the style — they
    /// move together and are invalidated by the same counter.
    private var settings: TimelineSettings = PresentationRevision.shared.timeline
    private var presentationRevision: UInt64 = 0
    /// What the Spotify table was at when the rows were last laid out.
    private var spotifyRevision: UInt64 = 0

    /// Laid-out message rows, reused across passes. Swept by the engine.
    private var rowCache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]

    private var layoutTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var boundsObserver: NSObjectProtocol?
    private var frameObserver: NSObjectProtocol?
    private var scrollBeganObserver: NSObjectProtocol?
    private var scrollEndedObserver: NSObjectProtocol?
    /// Fires the acknowledgement that was withheld while the app was behind
    /// another one. See `acknowledgeIfRead`.
    private var activationObserver: NSObjectProtocol?
    private var liveScrollTimeout: Task<Void, Never>?
    /// Clears the landing mark after a jump. Cancelled by the next jump, so two
    /// in quick succession leave one mark lit rather than the first clearing the
    /// second.
    private var highlightTask: Task<Void, Never>?
    /// The jump already performed, so re-running `updateNSView` for an unrelated
    /// input does not scroll the reader back.
    private var appliedJumpToken: UInt64 = 0
    /// A jump asked for before its message had been laid out.
    private var pendingJump: MessageJump?

    private var isNearBottom = true
    private var isApplyingUpdate = false
    /// A one-way latch. Every async continuation checks it, so a task that
    /// resumes after the view is gone writes nothing.
    private var isTornDown = false

    /// What the viewport was anchored to before a prepend, so history landing
    /// above does not move what the reader is looking at.
    private struct Anchor {
        var messageID: MessageID
        var offsetFromViewportTop: CGFloat
    }

    init(model: AppModel) {
        self.model = model
        style = MessageTextStyle.current()
        super.init()
    }

    // MARK: Construction

    func makeScrollView() -> NSScrollView {
        let canvas = TimelineCanvasView(style: style)
        canvas.onWidthChange = { [weak self] width in
            self?.relayout(forWidth: width)
        }
        canvas.onOpenLink = { [weak self] target, rect in
            self?.open(target, from: rect)
        }
        canvas.onOpenProfile = { [weak self] userID, rect in
            guard let self, let canvas = self.canvas else { return }
            self.model.openProfile(userID, anchor: canvas.anchorInHostingRoot(rect))
        }
        canvas.onOpenEmoji = { [weak self] emoji, rect in
            guard let self, let canvas = self.canvas else { return }
            self.model.openExpressionInfo(
                .emoji(emoji),
                anchor: canvas.anchorInHostingRoot(rect)
            )
        }
        canvas.onToggleFavoriteGIF = { [weak self] gif in
            self?.model.sessionController.toggleFavorite(gif)
        }
        canvas.onTogglePreview = { [weak self] url in
            self?.model.spotifyPreview.toggle(url)
        }
        canvas.onOpenMusicPlayer = { [weak self] card, rect in
            guard let self, let canvas = self.canvas else { return }
            self.model.openSpotifyPlayer(card, anchor: canvas.anchorInHostingRoot(rect))
        }
        canvas.isFavoriteGIF = { [weak self] gif in
            self?.model.sessionController.isFavorite(gif) ?? false
        }
        canvas.onVote = { [weak self] messageID, answerID in
            guard let self, let channelID = self.channelID else { return }
            self.model.vote(for: answerID, on: messageID, in: channelID)
        }
        canvas.onPressComponent = { [weak self] messageID, customID in
            guard let self, let channelID = self.channelID,
                  let message = self.model.messages(in: channelID)?
                      .messages.first(where: { $0.id == messageID }),
                  // Resolved from the message rather than carried through the
                  // canvas: the slot knows the id it must echo, and the store
                  // knows the flags, the application and whether the control is
                  // still live. A canvas that carried all of that would be
                  // carrying a snapshot that can go stale between the draw and
                  // the click.
                  let component = message.pressableComponent(customID: customID)
            else { return }
            Task { await self.model.sessionController.pressComponent(component, on: message) }
        }
        canvas.onDismissEphemeral = { [weak self] messageID in
            guard let self, let channelID = self.channelID else { return }
            // **A removal, not a hide.** The message is delivered over the
            // socket to this session and exists nowhere else, so this is the
            // whole of what "dismiss" can mean — and it does not come back:
            // `messageUpdated` merges onto a message it can find and returns
            // when it cannot.
            self.model.mutateBox(channelID) { $0.remove(messageID) }
            self.model.messageContentRevision &+= 1
        }
        canvas.onPlayActivity = { [weak self] messageID in
            guard let self, let channelID = self.channelID,
                  let invite = self.model.messages(in: channelID)?
                      .messages.first(where: { $0.id == messageID })?.activityInvite
            else { return }
            Task { await self.model.sessionController.joinActivity(invite, in: channelID) }
        }
        canvas.onOpenSticker = { [weak self] sticker, rect in
            guard let self, let canvas = self.canvas else { return }
            self.model.openExpressionInfo(
                .sticker(sticker),
                anchor: canvas.anchorInHostingRoot(rect)
            )
        }
        canvas.onToggleReaction = { [weak self] messageID, emoji in
            guard let self, let channelID = self.channelID else { return }
            self.model.toggleReaction(emoji, on: messageID, in: channelID)
        }
        canvas.onOpenThread = { [weak self] threadID in
            // The store decides between the panel and the whole column, on the
            // thread's parent — see `AppModel.openThread`.
            self?.model.openThread(threadID)
        }
        canvas.onOpenReplyTarget = { [weak self] messageID in
            guard let self, let channelID = self.channelID else { return }
            // The same jump a message link takes, so a quote and a link land
            // the reader in one place with one flash rather than two.
            self.model.sessionController.jumpToMessage(messageID, in: channelID)
        }
        canvas.onHoverMessage = { [weak self] messageID, rowFrame in
            guard let self else { return }
            let hover = messageID.map { MessageHover(messageID: $0, rowFrame: rowFrame) }
            // A write of an equal value still publishes, and the pointer
            // generates these at the pace a person moves a mouse.
            guard self.model.messageHover != hover else { return }
            self.model.messageHover = hover
        }
        canvas.onOpenMenu = { [weak self] messageID, rect in
            guard let self, let channelID = self.channelID, let canvas = self.canvas else {
                return
            }
            self.model.openMessageMenu(
                for: messageID,
                in: channelID,
                anchor: canvas.anchorInHostingRoot(rect)
            )
        }
        canvas.onOpenAttachment = { [weak self] messageID, index, widths in
            guard let self, let channelID = self.channelID else { return }
            self.model.openMedia(
                messageID: messageID,
                in: channelID,
                attachmentIndex: index,
                posterWidths: widths
            )
        }

        let document = TimelineDocumentView(frame: .zero)
        document.addSubview(canvas)

        let scrollView = TimelineScrollView()
        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        // The transcript has no horizontal travel. AppKit's automatic policy
        // enables sideways rubber-banding whenever a relayout briefly leaves the
        // document wider than the viewport, which reads as the whole column
        // wobbling on a fast scroll.
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .allowed
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        // The canvas owns its own top and bottom padding, so a second reservation
        // here would create scroll range below short conversations that nothing
        // occupies.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        // A wheel over a lightbox must not scroll the transcript underneath it.
        // Read at event time rather than published as state: this is not
        // something a view has to be invalidated for, and a `@State` mirror of a
        // store property is a second copy that can disagree with the first.
        scrollView.acceptsScrollInput = { [weak self] in
            guard let self else { return true }
            return self.model.mediaViewer == nil
        }

        self.canvas = canvas
        self.documentView = document
        self.scrollView = scrollView
        // The reading surface's ground, and the strip where rows pass under the
        // window's chrome. The transcript's strip needs no pointer: a reader
        // looking at a channel is looking at exactly the content going under
        // the bar, and the treatment is what tells them it continues up there.
        chrome = CanvasChrome(
            installedIn: scrollView,
            role: .reading,
            trigger: .contentBehind
        )

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
        // These are different events and only one of them is the first one: at
        // `makeNSView` the scroll view has no size at all, so the first real
        // width arrives as a frame change. Observing only bounds means the very
        // first layout never runs and the transcript stays blank until something
        // unrelated scrolls it.
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
        // **Reading is what marks a channel read, and reading needs the app to
        // be in front.** A channel left open behind another window is not being
        // read, so the acknowledgement waits — and the moment the reader comes
        // back to it, this is what sends the one that was withheld. Without it
        // an account that switches away and back keeps a channel unread until
        // the next message arrives in it.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.acknowledgeIfRead() }
        }
    }

    /// Marks the channel read, when the reader is actually reading it.
    ///
    /// Three conditions, and each is a different way of not reading: the app has
    /// to be in front, the transcript has to be at the foot of the channel — a
    /// reader scrolled up in history has *not* seen what arrived below them —
    /// and there has to be a channel. `AppModel.markRead` and
    /// `SessionController.acknowledge` settle the rest: the newest id, the
    /// suppression latch behind Mark Unread, and the guard that makes a repeat
    /// call free.
    ///
    /// Called from every place those three can change, because there is no
    /// single event that covers them: a channel opening, a page landing, a
    /// scroll reaching the bottom, and the app coming forward.
    private func acknowledgeIfRead() {
        guard !isTornDown, isNearBottom, NSApp.isActive, let channelID else { return }
        model.markRead(channelID)
    }

    /// Releases everything. Idempotent.
    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        layoutTask?.cancel()
        layoutTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        liveScrollTimeout?.cancel()
        liveScrollTimeout = nil
        let center = NotificationCenter.default
        for observer in [
            boundsObserver, frameObserver, scrollBeganObserver, scrollEndedObserver,
            activationObserver,
        ] {
            if let observer { center.removeObserver(observer) }
        }
        boundsObserver = nil
        frameObserver = nil
        scrollBeganObserver = nil
        scrollEndedObserver = nil
        activationObserver = nil
        rowCache.removeAll(keepingCapacity: false)
        canvas?.onWidthChange = nil
        canvas?.onOpenLink = nil
        canvas?.onVisibleRangeChange = nil
        canvas?.onActivateMessage = nil
        canvas?.onOpenProfile = nil
        canvas?.onOpenEmoji = nil
        canvas?.onOpenSticker = nil
        canvas?.onOpenAttachment = nil
        canvas?.onToggleFavoriteGIF = nil
        canvas?.onTogglePreview = nil
        canvas?.onOpenMusicPlayer = nil
        canvas?.isFavoriteGIF = nil
        canvas?.onVote = nil
        canvas?.onPlayActivity = nil
        canvas?.onPressComponent = nil
        canvas?.onDismissEphemeral = nil
        (scrollView as? TimelineScrollView)?.acceptsScrollInput = { true }
        // The clock holds a closure over the canvas; a subscriber that outlives
        // its transcript is a display link running for a channel nobody is
        // looking at.
        canvas?.stopStickerAnimation()
        highlightTask?.cancel()
        highlightTask = nil
        canvas = nil
        chrome?.tearDown()
        chrome = nil
        documentView = nil
        scrollView = nil
        ScrollWorkGate.endIfOwned(by: ObjectIdentifier(self))
    }

    deinit {
        // `tearDown` is called from `dismantleNSView`; this is the backstop for
        // the paths that do not go through it.
        MainActor.assumeIsolated {
            if !isTornDown { tearDown() }
        }
    }

    // MARK: Updating

    func update(
        channelID: ChannelID,
        items: [TimelineItem],
        presentationRevision: UInt64,
        activityAccents: [ApplicationID: UInt32],
        activityInviteStatuses: [ApplicationID: ActivityInviteStatus],
        topInset: CGFloat,
        bottomInset: CGFloat,
        jump: MessageJump?,
        spotifyRevision: UInt64,
        playingPreview: URL?
    ) {
        canvas?.apply(activityAccents: activityAccents)
        canvas?.apply(playingPreview: playingPreview)
        canvas?.apply(activityInviteStatuses: activityInviteStatuses)
        if let scrollView,
           abs(scrollView.contentInsets.bottom - bottomInset) > 0.5
            || abs(scrollView.contentInsets.top - topInset) > 0.5 {
            // Set on the SCROLL VIEW, not reserved in the canvas: an inset keeps
            // the content scrollable under the bar, where extra canvas padding
            // would leave dead space that can never hold a message.
            //
            // **The top one is what gives the toolbar something to treat.** The
            // transcript used to stop at the toolbar's foot, so the strip across
            // the top of the window had nothing behind it but the ground and
            // read as a painted slab. Running underneath and paying for it with
            // an inset is the same trade the composer's end already makes, and
            // it is the whole of what a scroll-edge effect needs to exist.
            //
            // The bottom arithmetic elsewhere in this file is unaffected: an
            // `NSClipView` scrolled fully down still sits at
            // `documentHeight + insets.bottom - viewportHeight`, and a top inset
            // moves the *minimum* to `-insets.top` rather than the maximum.
            scrollView.contentInsets = NSEdgeInsets(
                top: max(0, topInset), left: 0, bottom: max(0, bottomInset), right: 0
            )
            scrollView.scrollerInsets = NSEdgeInsets(
                top: max(0, topInset), left: 0, bottom: max(0, bottomInset), right: 0
            )
            // The treatment is the chrome's height, so it is told the same
            // number the inset is — not a constant of its own that can drift
            // from it.
            chrome?.chromeHeight = max(0, topInset)
            // The scrollable range just changed by the delta. A reader sitting
            // at the bottom has to stay there, or growing the composer by a line
            // silently scrolls the newest message out from under them.
            if isNearBottom, !isTornDown { scrollToBottom() }
        }
        guard !isTornDown else { return }

        // An appearance or text-size change invalidates every laid-out row: the
        // `CTFrame`s were built against fonts that no longer apply. Nothing
        // about the MESSAGES changed, so no other key can see it — which is the
        // whole reason this revision exists.
        if presentationRevision != self.presentationRevision {
            self.presentationRevision = presentationRevision
            style = PresentationRevision.shared.style
            settings = PresentationRevision.shared.timeline
            canvas?.style = style
            rowCache.removeAll(keepingCapacity: true)
            if !items.isEmpty { runLayout(preservingPosition: true) }
        }

        // A card landing changes a row's HEIGHT, so it is a relayout rather than
        // a repaint — and only the rows carrying that link are rebuilt, because
        // the cache matches on the revision and everything else still hits.
        if spotifyRevision != self.spotifyRevision {
            self.spotifyRevision = spotifyRevision
            if !items.isEmpty { runLayout(preservingPosition: true) }
        }

        let channelChanged = channelID != self.channelID
        if channelChanged {
            // A different conversation shares nothing with the previous one, and
            // keeping its layouts would hold every text block and decoded image
            // of a channel nobody is looking at.
            rowCache.removeAll(keepingCapacity: true)
            layoutTask?.cancel()
            // **A clip does not follow the reader out of the channel.** The chip
            // that started it is about to stop existing, so the only way to stop
            // the sound would be to come back and find it.
            model.spotifyPreview.stop()
            // And neither does a panel anchored to a row that is about to stop
            // existing — it would hang over the new channel pointing at nothing.
            model.closeSpotifyPlayer()
            isNearBottom = true
            // A jump aimed at the channel the reader has just left is stale.
            // Cleared BEFORE the block below records a new one, so a jump that
            // caused this very change is still honoured.
            pendingJump = nil
        }
        self.channelID = channelID

        if let jump, jump.channelID == channelID, jump.token != appliedJumpToken {
            appliedJumpToken = jump.token
            // Recorded before the layout below, so a jump asked for while the
            // page it points at is still arriving is performed the moment that
            // page lands rather than dropped.
            pendingJump = jump
        }

        if channelChanged || items != self.items {
            self.items = items
            runLayout(preservingPosition: !channelChanged)
        }
        applyPendingJump()
    }

    // MARK: Jumping

    /// Scrolls to the message a link asked for and lights it.
    ///
    /// **Nothing happens when the row is not laid out yet**, and that is the
    /// common case: following a link into an unloaded part of a channel
    /// re-anchors the transcript, and the page arrives one round trip after the
    /// request. The jump is held and retried on the pass that installs the rows,
    /// so the reader lands exactly once — on the frame the messages appear.
    private func applyPendingJump() {
        guard let jump = pendingJump, let canvas, let scrollView, !isTornDown else { return }
        guard let index = canvas.rows.firstIndex(where: { $0.messageID == jump.messageID })
        else { return }
        pendingJump = nil

        let rowFrame = canvas.rowFrame(at: index)
        let viewport = scrollView.contentView.bounds
        // A third of the way down rather than at the top: a message with nothing
        // above it reads as the start of the channel, and the lines before it
        // are most of what makes a quoted message make sense.
        let target = rowFrame.minY - viewport.height / 3
        let maximum = max(
            0,
            (documentView?.frame.height ?? 0) + scrollView.contentInsets.bottom - viewport.height
        )
        // Landing anywhere is a jump, so `isNearBottom` has to be recomputed
        // from where the reader actually ends up — otherwise the next inbound
        // message drags them back to the foot of a channel they just left.
        isApplyingUpdate = true
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(maximum, max(0, target))))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        isApplyingUpdate = false
        // The scroll that just happened raised its bounds notification inside
        // the suppression window above, so the strip has not been told.
        chrome?.refreshEngagement()
        isNearBottom = TimelineViewportPolicy.isNearBottom(
            viewport: scrollView.contentView.bounds,
            documentHeight: canvas.contentHeight,
            wasNearBottom: false
        )
        positionCanvas()

        canvas.highlight(jump.messageID)
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: MessageJump.highlightDuration)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !self.isTornDown else { return }
                self.canvas?.highlight(nil)
                // Cleared on the store too, so the value cannot re-fire a jump
                // after an unrelated update — and so a second link to the same
                // message is a fresh request rather than a no-op.
                if self.model.pendingJump?.token == jump.token { self.model.pendingJump = nil }
            }
        }
    }

    private func relayout(forWidth width: CGFloat) {
        guard !isTornDown, abs(width - layoutWidth) >= 1 else { return }
        layoutWidth = width
        runLayout(preservingPosition: true)
    }

    /// Builds the row layouts and installs them.
    ///
    /// Synchronous, and deliberately so. The layout is incremental — a live
    /// message lays out one row and a page of history lays out a hundred — so
    /// the common case is well inside a frame, and doing it on a task instead
    /// would mean the transcript is briefly wrong (or blank) on every channel
    /// switch while the hop completes. The width is the only input that can make
    /// this expensive, and a width change is already a resize.
    private func runLayout(preservingPosition: Bool) {
        guard let canvas, let scrollView, !isTornDown else { return }
        let width = canvas.bounds.width > 0 ? canvas.bounds.width : scrollView.contentView.bounds.width
        guard width > 0 else { return }
        layoutWidth = width

        let anchor = preservingPosition ? currentAnchor() : nil
        let wasNearBottom = isNearBottom

        let engine = TimelineLayoutEngine(
            presentationRevision: presentationRevision,
            spotifyRevision: spotifyRevision
        )
        let channel = channelID.flatMap { model.channelIndex[$0] }
        let input = TimelineLayoutEngine.Input(
            items: items,
            width: width,
            style: style,
            mentions: model.mentionContext(),
            channelName: channel.map { model.displayName(of: $0) } ?? "",
            channelSymbol: channel?.kind.symbolName ?? "number",
            channelTopic: channel?.topic,
            // **The channel being drawn, not the one that is selected.** See
            // `AppModel.authorInfo` — an overlay chat window is open while a
            // server is selected, and that is what exposed it.
            authors: model.authorInfo(
                for: items,
                inGuild: channelID.flatMap { model.channelIndex.guildID(of: $0) },
                authorFont: style.authorFont
            ),
            calendar: .current,
            settings: settings,
            spotify: model.spotifyUnfurls
        )

        isApplyingUpdate = true
        let rows = engine.layout(input, cache: &rowCache)
        let height = canvas.apply(rows: rows)
        resizeDocument(to: height)

        if wasNearBottom {
            scrollToBottom()
        } else if let anchor {
            restore(anchor)
        }
        isApplyingUpdate = false
        chrome?.refreshEngagement()

        positionCanvas()
        schedulePrefetch()
        // A page landing is the moment a channel's newest message becomes
        // known, so it is the moment the channel can be acknowledged at all.
        acknowledgeIfRead()
    }

    private func resizeDocument(to height: CGFloat) {
        guard let documentView, let scrollView else { return }
        // The strip is gated on how much content is under the chrome, which the
        // document's own height cannot answer — it is padded out to the
        // viewport below. See `CanvasChrome.overlap(in:)`.
        chrome?.contentHeight = height
        let viewport = scrollView.contentView.bounds
        let size = NSSize(
            // The document is pinned to the viewport's width. A transient wider
            // backing during a resize would otherwise become a real horizontal
            // scroll range.
            width: max(1, viewport.width),
            height: max(1, max(height, TimelineViewportPolicy.readableHeight(
                viewport: viewport.height,
                topInset: scrollView.contentInsets.top,
                bottomInset: scrollView.contentInsets.bottom
            )))
        )
        if documentView.frame.size != size {
            documentView.setFrameSize(size)
        }
    }

    // MARK: Scrolling

    private func viewportDidChange() {
        guard !isTornDown, !isApplyingUpdate, let scrollView, let canvas else { return }
        // **Before the early returns below.** Both of them are the first-layout
        // path, which is exactly when the ground and the strip have never been
        // sized — and a strip that misses it stays at zero width for the life of
        // the window.
        chrome?.viewportDidChange()
        let viewport = scrollView.contentView.bounds

        // The bootstrap case, and the resize case, are the same case: the width
        // the rows were laid out against is no longer the width on screen.
        //
        // `runLayout` needs a width, and the width only exists once the scroll
        // view has been laid out — which happens after `makeNSView`. Without
        // this the first layout never runs at all.
        if viewport.width > 0, abs(viewport.width - layoutWidth) >= 1 {
            runLayout(preservingPosition: !canvas.rows.isEmpty)
            return
        }
        // Rows arrived while there was no width to lay them out against.
        if canvas.rows.isEmpty, !items.isEmpty, viewport.width > 0 {
            runLayout(preservingPosition: false)
            return
        }
        isNearBottom = TimelineViewportPolicy.isNearBottom(
            viewport: viewport,
            documentHeight: canvas.contentHeight,
            wasNearBottom: isNearBottom
        )
        // See `lastViewportHeight`. Not while a gesture is in flight: the
        // reader's own hand owns the position then, and the height does not
        // change during one anyway.
        if abs(viewport.height - lastViewportHeight) > 0.5 {
            let grew = viewport.height > lastViewportHeight
            lastViewportHeight = viewport.height
            if grew, isNearBottom, !canvas.isScrolling { scrollToBottom() }
        }
        positionCanvas()
        requestEarlierHistoryIfNeeded(viewport: viewport)
        schedulePrefetch()
        // Scrolling down to the end is the reader saying they have seen what
        // was below them, and it is the one path a layout cannot cover.
        acknowledgeIfRead()
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
            // A gesture that ends without AppKit posting its end notification —
            // a fling interrupted by a window change, a scroll that becomes a
            // drag — would otherwise leave the gate held forever, and with it
            // every piece of optional work in the app.
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

    /// Puts the newest message at the foot of the SCROLLABLE range, not at the
    /// foot of the document.
    ///
    /// **The composer's content inset is part of that range and was missing
    /// here.** The transcript deliberately extends underneath the composer and
    /// pays for it with a bottom inset, so an `NSClipView` scrolled fully down
    /// sits at `documentHeight + inset - viewportHeight`. Targeting
    /// `documentHeight - viewportHeight` therefore stopped one composer-height
    /// short of the end — and every new message landed in exactly the strip that
    /// was left hidden behind the bar.
    ///
    /// It presented as the worst possible symptom: the transcript looked like it
    /// had not moved at all when somebody wrote to you, because the row it
    /// scrolled to reveal was the one under the composer.
    private func scrollToBottom() {
        guard let scrollView, let documentView else { return }
        // **Floored at `-contentInsets.top`, which is where the top IS.** A top
        // inset moves the clip view's minimum below zero, so a channel with less
        // in it than one screenful — whose foot is already above the composer —
        // was clamped to zero and left sitting one inset down from its own
        // first message, with that message scrolled up behind the toolbar and no
        // way to be told apart from a channel with history above it.
        let target = max(
            -scrollView.contentInsets.top,
            documentView.frame.height
                + scrollView.contentInsets.bottom
                - scrollView.contentView.bounds.height
        )
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// What the viewport is looking at, so a prepend can put it back.
    private func currentAnchor() -> Anchor? {
        guard let scrollView, let canvas else { return nil }
        let viewportTop = scrollView.contentView.bounds.minY
        guard let index = canvas.rowIndex(at: viewportTop),
              canvas.rows.indices.contains(index),
              let messageID = canvas.rows[index].messageID
        else { return nil }
        return Anchor(
            messageID: messageID,
            offsetFromViewportTop: canvas.rowFrame(at: index).minY - viewportTop
        )
    }

    private func restore(_ anchor: Anchor) {
        guard let scrollView, let canvas else { return }
        guard let index = canvas.rows.firstIndex(where: { $0.messageID == anchor.messageID })
        else { return }
        let target = canvas.rowFrame(at: index).minY - anchor.offsetFromViewportTop
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, target)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func requestEarlierHistoryIfNeeded(viewport: CGRect) {
        guard let channelID,
              let box = model.messages(in: channelID),
              TimelineViewportPolicy.shouldLoadEarlier(
                  viewport: viewport,
                  hasMore: box.hasMoreHistory,
                  isLoading: box.isLoadingHistory
              )
        else { return }
        model.loadEarlierHistory(in: channelID)
    }

    // MARK: Image prefetch

    /// Requests the images the visible rows need.
    ///
    /// **Once per viewport change, not once per row per frame.** The painter only
    /// peeks; this is the one place a request is started, so a scroll across a
    /// hundred rows issues one pass rather than a hundred tasks per display
    /// cycle.
    ///
    /// It waits behind the scroll gate: a fling should not spend its frames
    /// starting network requests for rows it is about to pass, and the images
    /// are wanted at the moment the gesture stops rather than during it.
    private func schedulePrefetch() {
        guard !isTornDown, let canvas else { return }
        prefetchTask?.cancel()
        let urls = visibleImageRequests(canvas: canvas)
        guard !urls.isEmpty else { return }

        prefetchTask = Task { [weak self] in
            await ScrollWorkGate.waitUntilInactive()
            guard !Task.isCancelled else { return }
            await withTaskGroup(of: Bool.self) { group in
                for request in urls {
                    group.addTask {
                        switch request.source {
                        case .still(let bucket):
                            await ImageStore.shared.image(
                                for: request.key, bucket: bucket
                            ) != nil
                        case .film:
                            await AnimatedImageStore.shared.image(
                                for: AnimatedImageStore.Key(
                                    url: request.key.url,
                                    maximumPixelSize: request.key.maximumPixelSize
                                )
                            ) != nil
                        }
                    }
                }
                var landed = false
                for await didLoad in group where didLoad { landed = true }
                guard landed else { return }
                await MainActor.run {
                    guard let self, !self.isTornDown else { return }
                    // One invalidation for the batch. Invalidating per image
                    // would repaint the viewport once per avatar.
                    self.canvas?.needsDisplay = true
                    // Film that has just landed may be the first moving thing on
                    // screen, and the canvas only subscribes to the clock when
                    // there is one.
                    self.canvas?.refreshStickerAnimation()
                }
            }
        }
    }

    /// The pictures the visible rows need, asked for once per viewport change.
    ///
    /// The set itself is built by `TimelineImageRequests`, which every surface
    /// that draws messages shares — see the note there for why there is only one
    /// of these.
    private func visibleImageRequests(canvas: TimelineCanvasView) -> [TimelineImageRequests.Request] {
        var rows: [MessageRow] = []
        for index in canvas.visibleRowRange() {
            guard case .message(let row) = canvas.rows[index].kind else { continue }
            rows.append(row)
        }
        return TimelineImageRequests.requests(
            for: rows,
            scale: canvas.window?.backingScaleFactor ?? 2,
            loadsArtwork: AppSettings.shared.loadsImagesAutomatically,
            playsAnimatedEmoji: AnimationClock.playsAnimatedEmoji,
            onActivityIcon: { [weak model] in model?.sessionController.deriveActivityAccent($0) }
        )
    }

    // MARK: Actions

    private func open(_ target: MessageText.LinkTarget, from rect: CGRect) {
        switch target {
        case .url(let string):
            // **The store's opener, not a copy of it here.** It resolves a
            // message link against the whole account — the renderer only has the
            // selected guild's channels plus the DMs, so a link into a third
            // server arrives here as an ordinary URL — and it re-checks the
            // scheme at the boundary rather than trusting the parser upstream.
            // Every surface that follows a link somebody wrote goes through it.
            model.openLink(string)
        case .channel(let channelID):
            model.selectChannel(channelID)
        case .message(let link):
            model.openMessageLink(link)
        case .user(let userID):
            guard let canvas else { return }
            model.openProfile(userID, anchor: canvas.anchorInHostingRoot(rect))
        case .role:
            break
        }
    }
}

/// A scroll view that refuses wheel events while a modal surface is up.
///
/// Without this a lightbox or a sheet over the transcript still scrolls it
/// underneath, which is disorienting and also relayouts a surface nobody can
/// see.
final class TimelineScrollView: NSScrollView {
    var acceptsScrollInput: () -> Bool = { true }

    override func scrollWheel(with event: NSEvent) {
        guard acceptsScrollInput() else { return }
        super.scrollWheel(with: event)
    }
}

/// The link-scheme check, exposed so the opener can repeat it at the boundary.
nonisolated enum InlineScannerSchemeCheck {
    static func isSafe(_ url: String) -> Bool {
        let lowered = url.lowercased()
        return lowered.hasPrefix("https://") || lowered.hasPrefix("http://")
    }
}
