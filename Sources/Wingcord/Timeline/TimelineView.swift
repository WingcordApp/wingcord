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
    /// How far each of the reader's uploads has got — read by the container for
    /// the reason the statuses are, and painted. See `UploadCardSlot`.
    var uploadProgress: [MessageID: Double] = [:]
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
    var cardRevision: UInt64
    /// Which of Discord's heads the transcript opens with, and a forum post's
    /// bar — read by the container for the reason `cardRevision` is: the
    /// canvas only hears what SwiftUI re-evaluates.
    var head: ChannelHead = .channel
    var postActions: PostActions?
    /// The clip playing anywhere in the app, so the chip that started it offers
    /// to stop it. Read by the container for the reason the accents are.
    var playingPreview: URL?
    var jump: MessageJump?
    /// Whether the loaded window reaches the channel's newest message. False
    /// after a jump, or once scrolling up has trimmed the newest away — see
    /// `TranscriptWindow`. It decides whether the foot is the present: whether
    /// to stick there, acknowledge there, or page below it.
    var reachesPresent: Bool = true
    /// A request to go to the foot, for this channel only. An input for the
    /// reason `jump` is one.
    var present: PresentRequest?
    /// A send to fly into its bubble, for this channel only — see
    /// `SendFlight`. An input for the reason `jump` is one.
    var flight: SendFlight?
    /// Where this transcript tells the chrome over it what its position means.
    var scroll: TranscriptScrollState
    /// The channel's topics, so the coordinator can say which one the reader
    /// is in. Oldest first.
    var topics: [ConversationTopic] = []
    /// The channel's summaries, newest first, for the same question — empty
    /// where no bar is shown, which is also what switches the tracking off.
    var summaries: [ChannelSummary] = []
    /// The summary the reader last went to in this channel. See
    /// `TimelineCoordinator.highlightedSummary`.
    var selectedSummary: SelectedSummary?
    /// Whether a floating layer is drawn over the transcript.
    ///
    /// An INPUT for the reason every other one here is: the canvas is a drawn
    /// `NSView` and only what SwiftUI re-evaluates ever reaches it. See
    /// `TimelineCanvasView.apply(isCovered:)` for what it is for — a tracking
    /// area is not occlusion-tested, so without this the transcript hovers
    /// underneath an open profile.
    var isCovered: Bool
    /// The messages the reader has kept, so the bookmark control on each
    /// reaction row says which way a click goes. Read by the container for the
    /// reason the accents are — a drawn canvas is only told what SwiftUI
    /// re-evaluates.
    var bookmarks: Set<MessageID>
    /// Whether the reader can send super reactions — Nitro. A super reaction
    /// chip is a control only when this is true; see
    /// `TimelineCanvasView.apply(canSuperReact:)`.
    var canSuperReact: Bool
    /// Whether a new reaction may be started in this channel; see
    /// `TimelineCanvasView.apply(canAddReactions:)`.
    var canAddReactions: Bool
    /// The channel is a message request, laid out as Discord's restricted
    /// preview — see `Message.restrictedPreview`. Accepting it in front of the
    /// reader is a relayout, into the whole messages.
    var hidesMedia: Bool
    /// The listen-along cards' hosts, by party. Its keys are the parties still
    /// on, which is the one thing about a card the layout takes.
    var listenAlongCards: [String: ListenAlongCard]
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
            uploadProgress: uploadProgress,
            topInset: topInset,
            bottomInset: bottomInset,
            jump: jump,
            reachesPresent: reachesPresent,
            present: present,
            flight: flight,
            scroll: scroll,
            topics: topics,
            summaries: summaries,
            selectedSummary: selectedSummary,
            cardRevision: cardRevision,
            playingPreview: playingPreview,
            isCovered: isCovered,
            bookmarks: bookmarks,
            canSuperReact: canSuperReact,
            canAddReactions: canAddReactions,
            hidesMedia: hidesMedia,
            listenAlongCards: listenAlongCards,
            head: head,
            postActions: postActions
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
    /// See `TimelineView.hidesMedia`.
    private var hidesMedia = false
    /// See `TimelineView.listenAlongCards`.
    private var listenAlongLive: Set<String> = []
    /// What the Spotify table was at when the rows were last laid out.
    private var cardRevision: UInt64 = 0
    private var head: ChannelHead = .channel
    private var postActions: PostActions?
    /// The live profile cards over the rows in view — see `UserCardHosts`.
    private let userCardHosts = UserCardHosts()

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

    /// Whether the loaded window reaches the present. See
    /// `TimelineView.reachesPresent`.
    private var reachesPresent = true
    /// The request to go to the foot already taken, for `appliedJumpToken`'s
    /// reason.
    private var appliedPresentToken: UInt64 = 0
    /// The send already flown, for the same reason.
    private var appliedFlight: MessageID?
    /// Going to the foot, once the window reaches it. A request made while cut
    /// off from the present waits for the newest page to land.
    private var pendingPresent = false
    /// Where the viewport's top was on the last tick, so a page is asked for in
    /// the direction the reader is travelling. See `viewportDidChange`.
    private var lastViewportMinY: CGFloat = 0
    /// Where the chrome over the transcript reads its position from.
    private var scroll: TranscriptScrollState?
    /// What was last told to `scroll` — compared here, so an unchanged answer
    /// costs no deferred write at all.
    private var publishedShowsJump = false
    /// What was last told to the store about this transcript and its foot. Nil
    /// until the first report, so the first one is always made.
    private var reportedAwayFromFoot: Bool?
    /// The channel's topics, oldest first.
    private var topics: [ConversationTopic] = []
    /// The reader's place among them, as last reported. See `TopicPlace`.
    private var topicPlace: TopicPlace?
    /// The channel's summaries, newest first. Empty where no bar is shown.
    private var summaries: [ChannelSummary] = []
    /// The selection already taken, so an unrelated update does not name the
    /// summary again after the reader has scrolled away from it.
    private var appliedSummaryToken: UInt64 = 0
    /// The summary the reader just went to, named by the bar **until they
    /// scroll** — Discord's highlighted summary, cleared by the first move of
    /// its automatic anchor after the jump. Without it the bar would name
    /// whichever newer summary also overlaps the landing, since stretches
    /// interleave.
    private var highlightedSummary: ChannelSummaryID?
    /// The reader's place among the summaries, as last reported.
    private var summaryPlace: SummaryPlace?

    private var isNearBottom = true
    private var isApplyingUpdate = false
    /// A one-way latch. Every async continuation checks it, so a task that
    /// resumes after the view is gone writes nothing.
    private var isTornDown = false

    /// The video playing over an embed's thumbnail. One at a time, as a
    /// second Play ends the first.
    private var embedPlayer: EmbedPlayerView?

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
        canvas.onHeadAction = { [weak self] action, rect in
            guard let self, let channelID = self.channelID else { return }
            self.model.performHeadAction(action, in: channelID, anchor: rect)
        }
        canvas.onOpenCrosspostAuthor = { [weak self] messageID, rect in
            guard let self, let canvas = self.canvas, let channelID = self.channelID else { return }
            self.model.openCrosspostAuthor(messageID, in: channelID, anchor: canvas.anchorInHostingRoot(rect))
        }
        canvas.onOpenPersonMenu = { [weak self] userID, rect in
            guard let self, let canvas = self.canvas else { return }
            self.model.openUserMenu(
                for: userID,
                anchor: canvas.anchorInHostingRoot(rect),
                inGuild: self.channelID.flatMap { self.model.channelIndex.guildID(of: $0) }
            )
        }
        canvas.onOpenEmoji = { [weak self] emoji, rect in
            guard let self, let canvas = self.canvas else { return }
            self.model.openExpressionInfo(
                .emoji(emoji),
                anchor: canvas.anchorInHostingRoot(rect)
            )
        }
        canvas.onPlayVideo = { [weak self] messageID, player, rect in
            self?.playVideo(player, of: messageID, in: rect)
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
        canvas.onOpenSelect = { [weak self] messageID, customID, rect in
            guard let self, let channelID = self.channelID, let canvas = self.canvas else { return }
            self.model.openSelectMenu(
                customID, on: messageID, in: channelID, anchor: canvas.anchorInHostingRoot(rect)
            )
        }
        canvas.onCancelUpload = { [weak self] messageID in
            guard let self, let channelID = self.channelID else { return }
            self.model.sessionController.cancelUpload(messageID, in: channelID)
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
        canvas.onListenAlong = { [weak self] messageID in
            guard let self, let channelID = self.channelID,
                  let box = self.model.messages(in: channelID),
                  let invite = box.messages.first(where: { $0.id == messageID })?.listenAlong
                      ?? box.outbox.first(where: { $0.id == messageID })?.request.listenAlong
            else { return }
            self.model.pressListenAlong(invite)
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
        canvas.onToggleReaction = { [weak self] messageID, emoji, kind in
            guard let self, let channelID = self.channelID else { return }
            self.model.toggleReaction(
                emoji, kind: kind, location: .inlineButton, on: messageID, in: channelID
            )
        }
        // The same two acts the hover bar and the message menu already offer,
        // reached from the reaction row itself. Routed through the store rather
        // than re-implemented, so there is one place a reaction is added and one
        // place a message is kept.
        canvas.onAddReaction = { [weak self] messageID, anchor in
            guard let self, let channelID = self.channelID else { return }
            self.model.openReactionPicker(for: messageID, in: channelID, anchor: anchor)
        }
        canvas.onToggleBookmark = { [weak self] messageID in
            guard let self, let channelID = self.channelID else { return }
            self.model.toggleBookmark(of: messageID, in: channelID)
        }
        canvas.onOpenThread = { [weak self] threadID in
            // The store decides between the panel and the whole column, on the
            // thread's parent — see `AppModel.openThread`.
            self?.model.openThread(threadID)
        }
        canvas.onEditChannel = { [weak self] in
            // The channel's own settings — Discord's Edit Channel.
            guard let self, let channelID = self.channelID,
                  let guildID = self.model.channelIndex.guildID(of: channelID)
            else { return }
            ServerSettingsWindow.open(guildID, channel: channelID)
        }
        canvas.onOpenTopicMarker = { [weak self] in
            self?.model.reopenTopicPanel()
        }
        canvas.onToggleCollapsedGroup = { [weak self] group in
            guard let self, let channelID = self.channelID else { return }
            self.model.toggleCollapsedGroup(group, in: channelID)
        }
        canvas.onPostAction = { [weak self] action, anchor in
            guard let self, let channelID = self.channelID else { return }
            self.model.performPostAction(action, postID: channelID, anchor: anchor)
        }
        canvas.onOpenReplyTarget = { [weak self] messageID in
            guard let self, let channelID = self.channelID else { return }
            // The same jump a message link takes, so a quote and a link land
            // the reader in one place with one flash rather than two.
            self.model.sessionController.jumpToMessage(messageID, in: channelID)
        }
        canvas.onHoverMessage = { [weak self] hover in
            guard let self else { return }
            // A write of an equal value still publishes, and the pointer
            // generates these at the pace a person moves a mouse.
            guard self.model.messageHover != hover else { return }
            self.model.messageHover = hover
        }
        canvas.onHoverReaction = { [weak self] hover in
            guard let self, self.model.reactionHover != hover else { return }
            self.model.reactionHover = hover
        }
        canvas.onHoverMark = { [weak self] hover in
            guard let self, self.model.markHover != hover else { return }
            self.model.markHover = hover
        }
        canvas.onHoverAutoModAction = { [weak self] hover in
            guard let self, self.model.autoModActionHover != hover else { return }
            self.model.autoModActionHover = hover
        }
        canvas.onCardAction = { [weak self] messageID, action, anchor in
            guard let self, let channelID = self.channelID else { return }
            self.model.performCardAction(action, on: messageID, in: channelID, anchor: anchor)
        }
        canvas.onInviteButton = { [weak self] card in
            self?.model.openInvite(card)
        }
        canvas.onToggleInviteFold = { [weak self] fold in
            self?.model.toggleInviteFold(fold)
        }
        canvas.isInviteSettled = { [weak self] card in
            self?.model.isInviteSettled(card) ?? false
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
    /// reader scrolled up in history has *not* seen what arrived below them, and
    /// neither has one at the foot of a window cut off from the present — and
    /// there has to be a channel. `AppModel.markRead` and
    /// `SessionController.acknowledge` settle the rest: the newest id, the
    /// suppression latch behind Mark Unread, and the guard that makes a repeat
    /// call free.
    ///
    /// Called from every place those three can change, because there is no
    /// single event that covers them: a channel opening, a page landing, a
    /// scroll reaching the bottom, and the app coming forward.
    private func acknowledgeIfRead() {
        guard !isTornDown, isNearBottom, reachesPresent, NSApp.isActive, let channelID else {
            return
        }
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
        userCardHosts.removeAll()
        canvas?.onWidthChange = nil
        canvas?.onOpenLink = nil
        canvas?.onVisibleRangeChange = nil
        canvas?.onActivateMessage = nil
        canvas?.onOpenProfile = nil
        canvas?.onOpenCrosspostAuthor = nil
        canvas?.onHeadAction = nil
        canvas?.onOpenEmoji = nil
        canvas?.onOpenSticker = nil
        canvas?.onOpenAttachment = nil
        canvas?.onToggleFavoriteGIF = nil
        canvas?.onPlayVideo = nil
        embedPlayer?.stop()
        embedPlayer = nil
        canvas?.onTogglePreview = nil
        canvas?.onOpenMusicPlayer = nil
        canvas?.isFavoriteGIF = nil
        canvas?.onVote = nil
        canvas?.onPlayActivity = nil
        canvas?.onListenAlong = nil
        canvas?.apply(listenAlongCards: [:])
        canvas?.onPressComponent = nil
        canvas?.onOpenSelect = nil
        canvas?.onDismissEphemeral = nil
        canvas?.onCancelUpload = nil
        canvas?.onToggleReaction = nil
        canvas?.onHoverReaction = nil
        canvas?.onHoverMark = nil
        canvas?.onHoverAutoModAction = nil
        canvas?.onCardAction = nil
        canvas?.onInviteButton = nil
        canvas?.onToggleInviteFold = nil
        canvas?.isInviteSettled = nil
        canvas?.onOpenTopicMarker = nil
        canvas?.onEditChannel = nil
        canvas?.onToggleCollapsedGroup = nil
        canvas?.onPostAction = nil
        (scrollView as? TimelineScrollView)?.acceptsScrollInput = { true }
        // The clock holds a closure over the canvas; a subscriber that outlives
        // its transcript is a display link running for a channel nobody is
        // looking at.
        canvas?.stopStickerAnimation()
        highlightTask?.cancel()
        highlightTask = nil
        // A transcript that is gone is not away from anybody's foot, and one
        // that stayed on the record would keep that channel from ever trimming.
        if let channelID {
            model.setTranscript(channelID, isAwayFromFoot: false, viewer: ObjectIdentifier(self))
        }
        scroll = nil
        canvas = nil
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
        uploadProgress: [MessageID: Double],
        topInset: CGFloat,
        bottomInset: CGFloat,
        jump: MessageJump?,
        reachesPresent: Bool,
        present: PresentRequest?,
        flight: SendFlight?,
        scroll: TranscriptScrollState,
        topics: [ConversationTopic],
        summaries: [ChannelSummary],
        selectedSummary: SelectedSummary?,
        cardRevision: UInt64,
        playingPreview: URL?,
        isCovered: Bool,
        bookmarks: Set<MessageID>,
        canSuperReact: Bool,
        canAddReactions: Bool,
        hidesMedia: Bool,
        listenAlongCards: [String: ListenAlongCard],
        head: ChannelHead = .channel,
        postActions: PostActions? = nil
    ) {
        self.scroll = scroll
        canvas?.apply(listenAlongCards: listenAlongCards)
        self.topics = topics
        self.summaries = summaries
        canvas?.apply(isCovered: isCovered)
        canvas?.apply(bookmarks: bookmarks)
        canvas?.apply(canSuperReact: canSuperReact)
        canvas?.apply(canAddReactions: canAddReactions)
        canvas?.apply(activityAccents: activityAccents)
        canvas?.apply(playingPreview: playingPreview)
        canvas?.apply(activityInviteStatuses: activityInviteStatuses)
        canvas?.apply(uploadProgress: uploadProgress)
        if let scrollView,
           abs(scrollView.contentInsets.bottom - bottomInset) > 0.5
            || abs(scrollView.contentInsets.top - topInset) > 0.5 {
            // Set on the SCROLL VIEW, not reserved in the canvas: an inset keeps
            // the content scrollable under the bar, where extra canvas padding
            // would leave dead space that can never hold a message.
            //
            // **The top one is the whole scroll edge.** A scroll view that runs
            // under the toolbar with a top inset gets AppKit's own scroll pocket
            // across that inset — the soft blur the system draws wherever content
            // passes under a window's chrome. Nothing here draws it or gates it:
            // over an empty ground it is invisible, and over rows it is the edge.
            // Stopped at the toolbar's foot instead, the transcript had nothing
            // passing under the bar and there was no edge to draw.
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
            // The scrollable range just changed by the delta. A reader sitting
            // at the bottom has to stay there, or growing the composer by a line
            // silently scrolls the newest message out from under them.
            // A short channel's rows sit on the composer, so the band they
            // sit in just moved under them.
            refreshLeadingSpace()
            if isNearBottom, self.reachesPresent, !isTornDown { scrollToBottom() }
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
            canvas?.alwaysShowsTimestamps = settings.alwaysShowsTimestamps
            rowCache.removeAll(keepingCapacity: true)
            if !items.isEmpty { runLayout(preservingPosition: true) }
        }

        // Every row is a different height once a request's media is drawn, and
        // the row cache keys on the flag, so this is a relayout of the lot.
        if hidesMedia != self.hidesMedia {
            self.hidesMedia = hidesMedia
            if !items.isEmpty { runLayout(preservingPosition: true) }
        }

        // A party starting or ending changes its card's height.
        let live = Set(listenAlongCards.keys)
        if live != listenAlongLive {
            listenAlongLive = live
            if !items.isEmpty { runLayout(preservingPosition: true) }
        }

        // A card landing changes a row's HEIGHT, so it is a relayout rather than
        // a repaint — and only the rows that can carry a card are rebuilt; see
        // `CacheEntry.carriesCards`. Everything else still hits.
        if cardRevision != self.cardRevision {
            self.cardRevision = cardRevision
            if !items.isEmpty { runLayout(preservingPosition: true) }
        }

        // A thread's head and a post's bar are rows, so a change to either —
        // a follow, "Copied", a tag — is a relayout. Within one channel only:
        // a channel change lays out from scratch below.
        let headChanged = head != self.head || postActions != self.postActions
        self.head = head
        self.postActions = postActions
        if headChanged, channelID == self.channelID, !items.isEmpty { runLayout(preservingPosition: true) }

        let channelChanged = channelID != self.channelID
        if channelChanged {
            // The channel being left is no longer anybody's to trim around.
            if let previous = self.channelID {
                model.setTranscript(previous, isAwayFromFoot: false, viewer: ObjectIdentifier(self))
            }
            reportedAwayFromFoot = nil
            topicPlace = nil
            summaryPlace = nil
            highlightedSummary = nil
            pendingPresent = false
            // **The new channel's answer, before it is laid out.** There is no
            // move between two channels for the rule below to protect, and a
            // window left cut off from the present has to open as one.
            self.reachesPresent = reachesPresent
            // A different conversation shares nothing with the previous one, and
            // keeping its layouts would hold every text block and decoded image
            // of a channel nobody is looking at.
            rowCache.removeAll(keepingCapacity: true)
            userCardHosts.removeAll()
            // A clip does not play on in a channel the reader has left.
            embedPlayer?.stop()
            embedPlayer = nil
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
        canvas?.apply(channelID: channelID)

        if let selectedSummary, selectedSummary.token != appliedSummaryToken {
            appliedSummaryToken = selectedSummary.token
            highlightedSummary = selectedSummary.summaryID
        }

        if let jump, jump.channelID == channelID, jump.token != appliedJumpToken {
            appliedJumpToken = jump.token
            // Recorded before the layout below, so a jump asked for while the
            // page it points at is still arriving is performed the moment that
            // page lands rather than dropped.
            pendingJump = jump
        }
        // A request made while the window reaches the present glides there; one
        // made while it is cut off waits for the newest page and lands at once,
        // because the rows it would glide across are not the ones it lands on.
        var glides = false
        if let present, present.channelID == channelID, present.token != appliedPresentToken {
            appliedPresentToken = present.token
            pendingPresent = true
            glides = self.reachesPresent && reachesPresent
            consume(present)
        }

        if channelChanged || items != self.items {
            self.items = items
            // **Laid out against what the window reached BEFORE this update.**
            // A newer page that just reconnected it to the present lands while
            // the reader is at the old foot, and sticking to the new one would
            // skip them past a hundred messages they have not read.
            runLayout(preservingPosition: !channelChanged)
        }
        self.reachesPresent = reachesPresent
        if pendingPresent, reachesPresent {
            pendingPresent = false
            goToPresent(gliding: glides)
        }
        // After the layout above, which is what laid the echo out.
        if let flight, flight.channelID == channelID, flight.nonce != appliedFlight {
            appliedFlight = flight.nonce
            consume(flight)
            launch(flight)
        }
        applyPendingJump()
        publishPosition()
        trackTopicPlace()
        trackSummaryPlace()
    }

    /// Clears a jump the store is holding once it has been taken, for the
    /// present request's reason below.
    private func consume(_ jump: MessageJump) {
        Task { @MainActor [weak self] in
            guard let self, self.model.pendingJump?.token == jump.token else { return }
            self.model.pendingJump = nil
        }
    }

    /// Clears a flight once it has been taken, for the present request's
    /// reason below.
    private func consume(_ flight: SendFlight) {
        Task { @MainActor [weak self] in
            guard let self, self.model.sendFlight == flight else { return }
            self.model.sendFlight = nil
        }
    }

    /// Flies a send from the composer into its bubble — **only where the
    /// reader can watch it land**: a transcript scrolled away from its foot
    /// has nowhere on screen for it to go.
    private func launch(_ flight: SendFlight) {
        guard settings.usesBubbles, let canvas, let scrollView,
              let index = canvas.rows.lastIndex(where: { $0.messageID == flight.nonce }),
              canvas.rowFrame(at: index).intersects(scrollView.contentView.bounds)
        else { return }
        canvas.launchBubble(
            nonce: flight.nonce,
            from: flight.launch,
            reducesMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    /// Keeps the flights on their rows after the rows were reinstalled.
    ///
    /// **By the nonce, not the id**: Discord's copy replaces the echo under a
    /// new id, usually while the bubble is still in the air, and carries the
    /// nonce the echo was minted as.
    private func followFlights() {
        guard let canvas, !canvas.flyingNonces.isEmpty else { return }
        canvas.followFlights { nonce in
            let token = String(nonce.rawValue)
            for case .message(let message) in items.reversed()
            where message.id == nonce || message.message.payload?.nonce == token {
                return message.id
            }
            return nil
        }
    }

    /// Clears a request the store is holding once it has been taken, so a
    /// transcript built later for the same channel does not take it again.
    ///
    /// **Deferred**, because this runs inside `updateNSView`, and a store write
    /// there is a write in the middle of the pass that is reading the store.
    private func consume(_ present: PresentRequest) {
        Task { @MainActor [weak self] in
            guard let self, self.model.presentRequest == present else { return }
            self.model.presentRequest = nil
        }
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
        lastViewportMinY = scrollView.contentView.bounds.minY
        isNearBottom = TimelineViewportPolicy.isNearBottom(
            viewport: scrollView.contentView.bounds,
            documentHeight: canvas.contentHeight,
            wasNearBottom: false
        )
        positionCanvas()

        guard jump.highlights else {
            // Consumed all the same, for the reason the task below clears it.
            consume(jump)
            return
        }
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
            cardRevision: cardRevision
        )
        let channel = channelID.flatMap { model.channelIndex[$0] }
        let input = TimelineLayoutEngine.Input(
            items: items,
            width: width,
            style: style,
            mentions: model.mentionContext(),
            channelName: channel.map { model.displayName(of: $0) } ?? "",
            head: head,
            postActions: postActions,
            postOwnerID: { if case .post = head { channel?.ownerID } else { nil } }(),
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
            spotify: model.spotifyUnfurls,
            invites: model.inviteLookups,
            expandedInvites: model.expandedInviteCards,
            palettes: model.derivedPalettes,
            userCardSizes: model.userCardSizes,
            guildID: channelID.flatMap { model.channelIndex.guildID(of: $0) },
            canEditChannel: channelID.map {
                model.channelIndex.guildID(of: $0) != nil
                    && model.permissionGate.permissions(in: $0).contains(.manageChannels)
            } ?? false,
            canManageMessages: channelID.map {
                model.channelIndex.guildID(of: $0) != nil
                    && model.permissionGate.permissions(in: $0).contains(.manageMessages)
            } ?? false,
            uploads: channelID.map(model.uploadSummaries(in:)) ?? [:],
            hidesMedia: hidesMedia,
            listenAlongLive: listenAlongLive,
            // A one-to-one conversation has one other person in it, so their
            // bubbles carry neither a name nor a face — Messages' own rule.
            arrangement: settings.usesBubbles
                ? .bubbles(namesAuthors: channel?.kind != .directMessage)
                : .columns
        )

        isApplyingUpdate = true
        let rows = engine.layout(input, cache: &rowCache)
        let height = canvas.apply(
            rows: rows,
            leadingSpace: leadingSpace(forRowsHeight: rows.reduce(0) { $0 + $1.height })
        )
        followFlights()
        resizeDocument(to: height)

        // **The foot is only somewhere to stick when it is the present.** The
        // foot of a window cut off from it is a page boundary with a runway
        // under it, and sticking there would drag the reader into the runway
        // every time a page landed.
        if wasNearBottom, reachesPresent {
            scrollToBottom()
        } else if let anchor {
            restore(anchor)
            // Recomputed from where the reader actually is. An anchored pass
            // can leave somebody far from a foot they were near, and a stale
            // answer would stick the next live message to the wrong place.
            isNearBottom = TimelineViewportPolicy.isNearBottom(
                viewport: scrollView.contentView.bounds,
                documentHeight: canvas.contentHeight,
                wasNearBottom: false
            )
        } else if !preservingPosition, !reachesPresent {
            // A window cut off from the present opens on its newest loaded
            // message: the runway under it is where the next page lands, not
            // where the reader was.
            scrollToLastMessage()
            isNearBottom = false
        }
        isApplyingUpdate = false

        positionCanvas()
        reconcileUserCards()
        placeEmbedPlayer()
        schedulePrefetch()
        // A page landing is the moment a channel's newest message becomes
        // known, so it is the moment the channel can be acknowledged at all.
        acknowledgeIfRead()
    }

    /// The space that puts a short channel on the composer, for the window as
    /// it is now — see `TimelineViewportPolicy.leadingSpace`.
    private func leadingSpace(forRowsHeight rowsHeight: CGFloat) -> CGFloat {
        guard let scrollView else { return 0 }
        return TimelineViewportPolicy.leadingSpace(
            rowsHeight: rowsHeight,
            viewport: scrollView.contentView.bounds.height,
            topInset: scrollView.contentInsets.top,
            bottomInset: scrollView.contentInsets.bottom
        )
    }

    /// Moves a short channel's rows when the band they sit in changes height —
    /// the window resizing, the composer growing a line. **A shift, not a
    /// layout**: the rows are reinstalled as they are, over a new first offset.
    private func refreshLeadingSpace() {
        guard let canvas, !isTornDown else { return }
        let wanted = leadingSpace(forRowsHeight: canvas.contentHeight - canvas.leadingSpace)
        guard abs(wanted - canvas.leadingSpace) > 0.5 else { return }
        resizeDocument(to: canvas.apply(rows: canvas.rows, leadingSpace: wanted))
        followFlights()
        positionCanvas()
        reconcileUserCards()
        placeEmbedPlayer()
    }

    private func resizeDocument(to height: CGFloat) {
        guard let documentView, let scrollView else { return }
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
            refreshLeadingSpace()
            if grew, isNearBottom, reachesPresent, !canvas.isScrolling { scrollToBottom() }
        }
        positionCanvas()
        reconcileUserCards()
        // **Pages go the way the reader is travelling.** A trim leaves the far
        // edge of the window a page away, well inside the prefetch distance —
        // so asking in both directions on every tick would fetch back each page
        // a trim had just dropped, and a reader scrolling up would pay for two
        // pages per page. A still tick (a resize, a first layout) asks both.
        let current = scrollView.contentView.bounds
        let movement = current.minY - lastViewportMinY
        lastViewportMinY = current.minY
        // The reader moved: the summary they went to stops being named, and
        // the bar goes back to naming what is on screen. The jump's own scroll
        // never reaches here — it runs inside `isApplyingUpdate`.
        if movement != 0, highlightedSummary != nil, pendingJump == nil {
            highlightedSummary = nil
        }
        if movement <= 0 { requestEarlierHistoryIfNeeded(viewport: current) }
        if movement >= 0 { requestLaterHistoryIfNeeded(viewport: current) }
        schedulePrefetch()
        // Scrolling down to the end is the reader saying they have seen what
        // was below them, and it is the one path a layout cannot cover.
        acknowledgeIfRead()
        publishPosition()
        trackTopicPlace()
        trackSummaryPlace()
        clearTopicMarkerIfPassed(viewport: current)
    }

    /// Puts a live card over each profile link near the viewport. See
    /// `UserCardHosts`.
    private func reconcileUserCards() {
        guard let canvas, let scrollView else { return }
        userCardHosts.reconcile(in: canvas, visible: scrollView.contentView.bounds, model: model)
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
        lastViewportMinY = scrollView.contentView.bounds.minY
    }

    /// Puts the newest LOADED message at the foot of the readable band.
    ///
    /// For a window cut off from the present, whose document ends in a runway:
    /// `scrollToBottom` would land in the placeholders, below everything the
    /// reader was looking at.
    private func scrollToLastMessage() {
        guard let scrollView, let canvas,
              let index = canvas.rows.lastIndex(where: { $0.messageID != nil })
        else {
            scrollToBottom()
            return
        }
        let clip = scrollView.contentView
        let target = canvas.rowFrame(at: index).maxY
            + scrollView.contentInsets.bottom
            - clip.bounds.height
        clip.scroll(to: NSPoint(x: 0, y: max(-scrollView.contentInsets.top, target)))
        scrollView.reflectScrolledClipView(clip)
        lastViewportMinY = clip.bounds.minY
    }

    /// Takes the reader to the foot of a window that reaches the present.
    ///
    /// **A glide for a request made while already there** — the control, or
    /// Escape — and a cut for everything else: a window that was just replaced
    /// by the newest page has nothing in common with the rows a glide would
    /// cross. The glide is the `reposition` class's response with an ease-out,
    /// the nearest an `NSAnimationContext` comes to a critically damped spring,
    /// and it holds the scroll gate like any other scroll so optional work
    /// waits it out.
    ///
    /// **Far away, it cuts to a screen above the foot first.** Gliding across a
    /// few hundred rows repaints the canvas every time it runs out of overscan,
    /// for motion nobody can read at that speed.
    private func goToPresent(gliding: Bool) {
        guard let scrollView, let documentView, !isTornDown else { return }
        isNearBottom = true
        let clip = scrollView.contentView
        let target = max(
            -scrollView.contentInsets.top,
            documentView.frame.height + scrollView.contentInsets.bottom - clip.bounds.height
        )
        guard gliding, target - clip.bounds.minY > 1,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            scrollToBottom()
            positionCanvas()
            acknowledgeIfRead()
            return
        }
        if target - clip.bounds.minY > clip.bounds.height * 1.5 {
            clip.scroll(to: NSPoint(x: 0, y: target - clip.bounds.height))
            scrollView.reflectScrolledClipView(clip)
            positionCanvas()
        }
        setScrolling(true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.reposition.response
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(NSPoint(x: 0, y: target))
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isTornDown, let scrollView = self.scrollView else { return }
                scrollView.reflectScrolledClipView(scrollView.contentView)
                self.setScrolling(false)
                self.viewportDidChange()
            }
        }
    }

    /// Starts a video's player over its thumbnail. See `EmbedPlayerView`.
    private func playVideo(_ video: EmbedVideo, of messageID: MessageID, in rect: CGRect) {
        guard let canvas else { return }
        embedPlayer?.stop()
        let view = EmbedPlayerView(messageID: messageID, video: video)
        view.frame = rect
        canvas.addSubview(view)
        embedPlayer = view
    }

    /// Keeps the player on its thumbnail as the rows are laid out again, and
    /// ends it when its message is gone.
    private func placeEmbedPlayer() {
        guard let view = embedPlayer, let canvas else { return }
        guard let index = canvas.rows.firstIndex(where: { $0.messageID == view.messageID }),
              case .message(let row) = canvas.rows[index].kind,
              let image = row.embeds.lazy.flatMap(\.images).first(where: { $0.video == view.video })
        else {
            view.stop()
            embedPlayer = nil
            return
        }
        let origin = canvas.rowFrame(at: index).origin
        let frame = image.rect.offsetBy(dx: origin.x, dy: origin.y)
        if view.frame != frame { view.frame = frame }
    }

    /// What the viewport is looking at, so a prepend can put it back.
    ///
    /// **The first message at or below the viewport's top, not whatever row
    /// sits there.** That row is as often a day heading, a divider or a
    /// placeholder in the history runway, and a runway row keeps its place at
    /// the top of the document while a page lands beneath it. Anchoring on
    /// nothing left the viewport where it was as the page went in underneath:
    /// a reader who had scrolled into the runway went on looking at
    /// placeholders, each page landing out of sight below and the runway, still
    /// on screen, asking for the next. Anchored on the message under the
    /// placeholders, the page lands where they were.
    private func currentAnchor() -> Anchor? {
        guard let scrollView, let canvas,
              let first = canvas.rowIndex(at: scrollView.contentView.bounds.minY),
              let index = canvas.rows[first...].firstIndex(where: { $0.messageID != nil }),
              let messageID = canvas.rows[index].messageID
        else { return nil }
        return Anchor(
            messageID: messageID,
            offsetFromViewportTop: canvas.rowFrame(at: index).minY
                - scrollView.contentView.bounds.minY
        )
    }

    private func restore(_ anchor: Anchor) {
        guard let scrollView, let canvas else { return }
        guard let index = canvas.rows.firstIndex(where: { $0.messageID == anchor.messageID })
        else { return }
        let target = canvas.rowFrame(at: index).minY - anchor.offsetFromViewportTop
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, target)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        lastViewportMinY = scrollView.contentView.bounds.minY
    }

    /// Asks for the page below a window cut off from the present, when the
    /// reader is running out of it.
    private func requestLaterHistoryIfNeeded(viewport: CGRect) {
        guard let channelID, let canvas,
              let box = model.messages(in: channelID),
              TimelineViewportPolicy.shouldLoadLater(
                  viewport: viewport,
                  documentHeight: canvas.contentHeight,
                  hasMore: box.hasMoreNewer && !box.newerPageFailed,
                  isLoading: box.isLoadingNewer
              )
        else { return }
        model.loadLaterHistory(in: channelID)
    }

    /// Tells the chrome over the transcript whether to offer the way back to
    /// the present, and the store whether this transcript is away from its
    /// channel's foot. Each only when its answer changes.
    ///
    /// **The chrome's write is deferred**: this runs inside `updateNSView` as
    /// often as inside a scroll tick, and the control is a view the same pass
    /// may be reading. The store's is not — it is unobserved, and nothing
    /// redraws for it.
    private func publishPosition() {
        guard !isTornDown, let scrollView, let canvas, let channelID else { return }
        let away = !(isNearBottom && reachesPresent)
        if reportedAwayFromFoot != away {
            reportedAwayFromFoot = away
            model.setTranscript(channelID, isAwayFromFoot: away, viewer: ObjectIdentifier(self))
        }
        let shows = TimelineViewportPolicy.showsJumpToPresent(
            viewport: scrollView.contentView.bounds,
            documentHeight: canvas.contentHeight,
            bottomInset: scrollView.contentInsets.bottom,
            reachesPresent: reachesPresent,
            wasShowing: publishedShowsJump
        )
        guard shows != publishedShowsJump else { return }
        publishedShowsJump = shows
        Task { @MainActor [weak self] in
            // Only the latest answer lands: two flips in one pass must not
            // leave the first one showing.
            guard let self, self.publishedShowsJump == shows,
                  let scroll = self.scroll, scroll.showsJumpToPresent != shows
            else { return }
            scroll.showsJumpToPresent = shows
        }
    }

    /// Reports which topic the reader is in, and asks for topics when their
    /// place has left the ones loaded — each only when the place changes, which
    /// is once per topic boundary crossed rather than once per tick.
    ///
    /// Deferred, for `publishPosition`'s reason: this also runs inside
    /// `updateNSView`, and both answers are store and state writes.
    private func trackTopicPlace() {
        guard !isTornDown, let channelID, model.topicsApply(to: channelID) else { return }
        let anchor = isNearBottom && reachesPresent ? nil : currentAnchor()?.messageID
        let place = TopicPlace(anchor: anchor, topics: topics)
        guard place != topicPlace else { return }
        topicPlace = place
        Task { @MainActor [weak self] in
            guard let self, !self.isTornDown, self.topicPlace == place else { return }
            self.model.loadTopicsIfNeeded(in: channelID, anchor: anchor)
            if let scroll = self.scroll, scroll.topicIndex != place.index {
                scroll.topicIndex = place.index
            }
        }
    }

    /// Forgets the open topic once its marker has scrolled out of view —
    /// Discord's own rule — unless its panel is up or a jump is still landing.
    private func clearTopicMarkerIfPassed(viewport: CGRect) {
        guard let channelID, let canvas, pendingJump == nil,
              let open = model.openTopic, open.channelID == channelID, !open.showsPanel,
              let index = canvas.rows.firstIndex(where: {
                  if case .marker(.topic, _) = $0.kind { true } else { false }
              })
        else { return }
        let frame = canvas.rowFrame(at: index)
        guard frame.maxY < viewport.minY || frame.minY > viewport.maxY else { return }
        Task { @MainActor [weak self] in self?.model.clearOpenTopic(in: channelID) }
    }

    /// Reports where the reader is among the summaries — once per change,
    /// which is once per stretch boundary crossed rather than once per tick.
    ///
    /// Deferred, for `publishPosition`'s reason.
    private func trackSummaryPlace() {
        guard !isTornDown, !summaries.isEmpty else { return }
        let range = isNearBottom && reachesPresent ? nil : readableMessageRange()
        let place = SummaryPlace(
            top: range?.top,
            bottom: range?.bottom,
            highlighted: highlightedSummary,
            summaries: summaries
        )
        guard place != summaryPlace else { return }
        summaryPlace = place
        Task { @MainActor [weak self] in
            guard let self, !self.isTornDown, self.summaryPlace == place,
                  let scroll = self.scroll, scroll.summaryPlace != place
            else { return }
            scroll.summaryPlace = place
        }
    }

    /// The first and last messages that can be read: below the chrome over the
    /// transcript's top — the toolbar and the summaries bar — and above the
    /// composer. What Discord's anchors are, in this transcript's terms.
    private func readableMessageRange() -> (top: MessageID, bottom: MessageID)? {
        guard let scrollView, let canvas, !canvas.rows.isEmpty else { return nil }
        let viewport = scrollView.contentView.bounds
        guard var first = canvas.rowIndex(at: viewport.minY + scrollView.contentInsets.top),
              var last = canvas.rowIndex(at: viewport.maxY - scrollView.contentInsets.bottom)
        else { return nil }
        while first < last, canvas.rows[first].messageID == nil { first += 1 }
        while last > first, canvas.rows[last].messageID == nil { last -= 1 }
        guard let top = canvas.rows[first].messageID, let bottom = canvas.rows[last].messageID
        else { return nil }
        return (top, bottom)
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
                    group.addTask { await request.load() }
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
        let scale = canvas.window?.backingScaleFactor ?? 2
        var rows: [MessageRow] = []
        // A conversation's head is the one other row that draws faces.
        var head: [TimelineImageRequests.Request] = []
        for index in canvas.visibleRowRange() {
            switch canvas.rows[index].kind {
            case .message(let row): rows.append(row)
            case .conversationStart(let slot): head = TimelineImageRequests.requests(forHead: slot, scale: scale)
            default: continue
            }
        }
        return head + TimelineImageRequests.requests(
            for: rows,
            scale: scale,
            loadsArtwork: AppSettings.shared.loadsImagesAutomatically,
            playsAnimatedEmoji: AnimationClock.playsAnimatedEmoji,
            filmsOnLayers: true,
            onActivityIcon: { [weak model] in model?.sessionController.deriveActivityAccent($0) }
        )
    }

    // MARK: Actions

    private func open(_ target: MessageText.LinkTarget, from rect: CGRect) {
        switch target {
        case .url(let string):
            // **The store's opener, not a copy of it here.** It re-checks the
            // scheme at the boundary rather than trusting the parser upstream,
            // and every surface that follows a link somebody wrote goes
            // through it.
            model.openLink(string)
        case .channelLink(let link, let url):
            model.openChannelLink(link, fallbackURL: url)
        case .user(let userID):
            guard let canvas else { return }
            model.openProfile(userID, anchor: canvas.anchorInHostingRoot(rect))
        case .staticRoute(let route, let itemID):
            guard let canvas else { return }
            model.openStaticRoute(route, itemID: itemID, anchor: canvas.anchorInHostingRoot(rect))
        case .role(let roleID):
            // Discord's role popout: who holds it, beside the mention.
            guard let canvas,
                  let channelID,
                  let guildID = model.channelIndex.guildID(of: channelID)
            else { return }
            model.openRoleMembers(roleID, inGuild: guildID, anchor: canvas.anchorInHostingRoot(rect))
        case .game(let gameID):
            // Discord's chip opens the game's page (`266645`).
            model.openGameProfile(gameID)
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
