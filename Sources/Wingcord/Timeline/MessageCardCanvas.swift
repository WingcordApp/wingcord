import AppKit
import Foundation
import SwiftUI
import WingcordCore

/// One message, drawn by the transcript's own painter.
///
/// **The real renderer at a smaller width, not a second one.** Every surface in
/// this app that shows a message outside the transcript — the pinned pane today,
/// a search result tomorrow — used to build its own SwiftUI approximation out of
/// a name, a timestamp and one line of text. That approximation agrees with the
/// transcript only for as long as somebody keeps the two in step, and it is
/// silently wrong the moment a message is anything but words: a forward, an
/// embed, a video, a poll, a sticker, a file. The pinned pane drew a *blank line*
/// for every one of those, because `excerpt(of:)` had nothing to say about them.
///
/// `TimelineLayoutEngine` and `TimelineRowPainter` are `nonisolated` and take
/// their style and settings as values — the render tests already drive them this
/// way — so this is the transcript, at 300 points wide, and it cannot drift.
///
/// **The layout is done by the caller, once.** A representable that laid out
/// inside `updateNSView` would re-frameset on every SwiftUI pass, and the height
/// has to be known before the row is placed or the list measures itself twice.
/// See `MessageCard`.
struct MessageCard: Identifiable, Sendable {
    let id: MessageID
    /// The laid-out rows — one message is one row, but the engine's unit is a
    /// list and taking its output whole is what keeps this a projection rather
    /// than a re-implementation.
    let rows: [TimelineRow]
    let height: CGFloat
    /// One plain string for one accessibility node, exactly as a transcript row
    /// carries. See `MessageRow.accessibilityLabel`.
    let accessibilityLabel: String

    /// The message rows inside, for the picture prefetch.
    var messageRows: [MessageRow] {
        rows.compactMap { if case .message(let row) = $0.kind { row } else { nil } }
    }

    /// Lays one message out at `width`.
    ///
    /// - Parameter engine: Shared across a batch so the caller pays for one
    ///   engine per pass rather than one per message.
    static func card(
        for message: Message,
        width: CGFloat,
        engine: TimelineLayoutEngine,
        style: MessageTextStyle,
        settings: TimelineSettings,
        mentions: MentionContext,
        channelName: String,
        authors: [UserID: TimelineLayoutEngine.AuthorInfo]
    ) -> MessageCard {
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        let rows = engine.layout(
            TimelineLayoutEngine.Input(
                // **`[.head, .tail]`, always.** A card stands alone: there is no
                // message above it to continue from, so the run flags that make
                // a transcript group consecutive messages would hide the author
                // and the avatar on any card whose neighbour happened to share
                // an author.
                items: [.message(TimelineMessage(message: message, flags: [.head, .tail]))],
                width: width,
                style: style,
                mentions: mentions,
                channelName: channelName,
                authors: authors,
                calendar: .current,
                settings: settings
            ),
            cache: &cache
        )
        let label: String
        if case .message(let row)? = rows.first?.kind {
            label = row.accessibilityLabel
        } else {
            label = ""
        }
        return MessageCard(
            id: message.id,
            rows: rows,
            height: rows.reduce(0) { $0 + $1.height },
            accessibilityLabel: label
        )
    }

    /// Several messages as **one continuous excerpt**, run-grouped.
    ///
    /// **Not `card(for:)` in a loop, and the difference is most of the height of
    /// the inbox's Unreads tab.** A card stands alone, so it forces
    /// `[.head, .tail]` and draws the avatar, the author and the full timestamp
    /// on every message. Four consecutive lines from one person then repeat that
    /// header four times — which is what shipped, and what "the padding sucks"
    /// was looking at.
    ///
    /// `TimelineReducer` is the app's single definition of a run, shared with
    /// the transcript so the two cannot disagree. Its framing rows are dropped
    /// here: an excerpt has no beginning-of-conversation marker and no history
    /// runway, because it is a window onto the middle of a channel rather than
    /// the channel itself.
    ///
    /// - Parameter unreadAnchor: the reader's cursor, so the excerpt carries the
    ///   same unread divider the channel does.
    static func excerpt(
        of messages: [Message],
        unreadAnchor: MessageID?,
        width: CGFloat,
        engine: TimelineLayoutEngine,
        style: MessageTextStyle,
        settings: TimelineSettings,
        mentions: MentionContext,
        mentionedIDs: Set<UInt64>,
        channelName: String,
        authors: [UserID: TimelineLayoutEngine.AuthorInfo]
    ) -> MessageCard? {
        guard let first = messages.first else { return nil }
        let items = TimelineReducer.rows(
            messages: messages,
            unreadAnchor: unreadAnchor,
            mentionedIDs: mentionedIDs,
            hasMoreHistory: false
        )
        .filter { item in
            switch item {
            case .message, .daySeparator, .unreadDivider: true
            // `conversationStart`, the skeletons, the loading row and the
            // failure row are all statements about a whole channel's history.
            // In an excerpt they are false.
            case .conversationStart, .historySkeleton, .loadingFirstPage,
                 .historyUnavailable, .marker: false
            }
        }
        guard !items.isEmpty else { return nil }

        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        let rows = engine.layout(
            TimelineLayoutEngine.Input(
                items: items,
                width: width,
                style: style,
                mentions: mentions,
                channelName: channelName,
                authors: authors,
                calendar: .current,
                settings: settings
            ),
            cache: &cache
        )
        // One node for the whole excerpt. Reading four messages out as four
        // unrelated nodes is worse for VoiceOver than one that says what the
        // block is, and the group's header already names the channel.
        let label = rows.compactMap { row -> String? in
            if case .message(let message) = row.kind { return message.accessibilityLabel }
            return nil
        }.joined(separator: ". ")

        return MessageCard(
            // The oldest message in the excerpt: what clicking it jumps to, and
            // what the canvas compares against to decide it need not repaint.
            id: first.id,
            rows: rows,
            height: rows.reduce(0) { $0 + $1.height },
            accessibilityLabel: label
        )
    }

    /// A long run of messages as several excerpts, cut only where a run
    /// begins — for a list that shows a whole topic.
    ///
    /// **Not `excerpt(of:)` per slice.** Each slice would open on its own day
    /// heading and re-decide its runs; reduced once and then cut, the headings
    /// fall where the day changes and every author line is where the
    /// transcript would draw it.
    ///
    /// **Several cards rather than one**, because each card is a canvas with
    /// a backing store the height of its content: a fifty-message topic as one
    /// card is a bitmap ten thousand points tall, where a lazy list of slices
    /// only holds the ones on screen.
    static func excerpts(
        of messages: [Message],
        rowsPerCard: Int,
        width: CGFloat,
        engine: TimelineLayoutEngine,
        style: MessageTextStyle,
        settings: TimelineSettings,
        mentions: MentionContext,
        mentionedIDs: Set<UInt64>,
        channelName: String,
        authors: [UserID: TimelineLayoutEngine.AuthorInfo]
    ) -> [MessageCard] {
        let items = TimelineReducer.rows(messages: messages, mentionedIDs: mentionedIDs)
            .filter { if case .conversationStart = $0 { false } else { true } }
        var slices: [[TimelineItem]] = []
        var slice: [TimelineItem] = []
        for item in items {
            // A day heading belongs to the message after it, so it opens a new
            // slice rather than closing one.
            let opensRun = switch item {
            case .message(let message): message.isRunHead
            case .daySeparator: true
            default: false
            }
            if opensRun, slice.count >= rowsPerCard, !(slice.last.map(isDayHeading) ?? false) {
                slices.append(slice)
                slice = []
            }
            slice.append(item)
        }
        if !slice.isEmpty { slices.append(slice) }

        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        return slices.compactMap { slice in
            guard let first = slice.lazy.compactMap(\.messageID).first else { return nil }
            let rows = engine.layout(
                TimelineLayoutEngine.Input(
                    items: slice,
                    width: width,
                    style: style,
                    mentions: mentions,
                    channelName: channelName,
                    authors: authors,
                    calendar: .current,
                    settings: settings
                ),
                cache: &cache
            )
            return MessageCard(
                id: first,
                rows: rows,
                height: rows.reduce(0) { $0 + $1.height },
                accessibilityLabel: rows.compactMap { row -> String? in
                    if case .message(let message) = row.kind { return message.accessibilityLabel }
                    return nil
                }.joined(separator: ". ")
            )
        }

        func isDayHeading(_ item: TimelineItem) -> Bool {
            if case .daySeparator = item { true } else { false }
        }
    }
}

/// The pictures a set of cards draws, asked for once.
///
/// **The painter only peeks** (`INVARIANTS.md` §2), so a surface that draws
/// cards has to ask for their pictures itself — and three do: the pinned pane,
/// a topic's preview and a topic's panel. One loop, behind the scroll gate like
/// every other optional fetch, over the one request builder the transcript
/// uses.
enum MessageCardArtwork {
    /// - Returns: whether anything was fetched, so the caller repaints once for
    ///   the batch rather than once per picture.
    static func prefetch(_ cards: [MessageCard]) async -> Bool {
        let requests = TimelineImageRequests.requests(
            for: cards.flatMap(\.messageRows),
            scale: 2,
            loadsArtwork: AppSettings.shared.loadsImagesAutomatically,
            playsAnimatedEmoji: AnimationClock.playsAnimatedEmoji
        )
        guard !requests.isEmpty else { return false }
        await ScrollWorkGate.waitUntilInactive()
        guard !Task.isCancelled else { return false }
        await withTaskGroup(of: Void.self) { group in
            for request in requests {
                group.addTask {
                    switch request.source {
                    case .still(let bucket):
                        _ = await ImageStore.shared.image(for: request.key, bucket: bucket)
                    case .film:
                        _ = await AnimatedImageStore.shared.image(
                            for: AnimatedImageStore.Key(
                                url: request.key.url,
                                maximumPixelSize: request.key.maximumPixelSize
                            )
                        )
                    }
                }
            }
        }
        return !Task.isCancelled
    }
}

/// Paints a `MessageCard`.
///
/// A flipped `NSView` holding the laid-out rows and nothing else: no hit
/// testing, no pointer state, no scroll view. Whatever wraps it owns the click —
/// which is what lets the pinned pane put a `Button` around one and the media
/// viewer put nothing around another.
struct MessageCardCanvas: NSViewRepresentable {
    var card: MessageCard
    /// Moves when the appearance or the text size changes. Carried as an input
    /// so a change re-runs `updateNSView`, which is the only place the view can
    /// be told about it.
    var presentationRevision: UInt64
    /// Moves when a picture this card draws has landed.
    ///
    /// **The caller's counter, not a global one.** The app-wide presentation
    /// revision discards every laid-out row in every surface; an avatar arriving
    /// in a flyout is a repaint of one card. See `PinnedMessagesPane`.
    var artworkGeneration: UInt64 = 0

    func makeNSView(context: Context) -> MessageCardView { MessageCardView() }

    func updateNSView(_ view: MessageCardView, context: Context) {
        view.apply(
            rows: card.rows,
            revision: presentationRevision,
            generation: artworkGeneration
        )
    }
}

/// The flipped canvas a `MessageCard` paints into.
final class MessageCardView: NSView {
    private var rows: [TimelineRow] = []
    private var revision: UInt64 = 0
    private var generation: UInt64 = 0
    /// What the rows on screen were laid out from, so an update carrying an
    /// identical card is a comparison rather than a repaint. The rows array is
    /// rebuilt by SwiftUI on every pass and is not `Equatable`; its identity
    /// and its height are.
    private var drawnID: MessageID?
    private var drawnHeight: CGFloat = -1
    private var style = MessageTextStyle.current()

    // MARK: Moving pictures
    //
    // **The card read the clock and never subscribed to it**, so a GIF, an
    // animated sticker and an animated custom emoji all sat on whichever frame
    // happened to be decoded when the card was last laid out. `draw` took
    // `AnimationClock.shared.time` and the policy is `.onSetNeedsDisplay`, so
    // nothing ever asked for the next frame. Every surface built on this — the
    // pinned pane, and now the inbox — was still.
    //
    // The transcript's own canvas invalidates per box because it is a viewport
    // over hundreds of rows. A card is one message or one short excerpt, so it
    // repaints whole; what it keeps from that design is the **gate**: the clock
    // runs at up to 24 fps and film is authored at 10-20, so most ticks resolve
    // to the pictures already on screen and must cost a few dictionary lookups
    // rather than a repaint.

    /// The frame index each filmstrip in this card is currently showing.
    private var shownFilmFrames: [FilmSlot: Int] = [:]
    private var isAnimating = false
    private var animationToken: ObjectIdentifier { ObjectIdentifier(self) }

    /// Names one moving picture inside the card. The message plus its position,
    /// never the asset's own id — the same GIF twice is two boxes.
    private struct FilmSlot: Hashable {
        enum Kind: UInt8 { case sticker, attachment, embed, emoji }
        var messageID: MessageID
        var kind: Kind
        var index: Int
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // The card is repainted only when its rows or the presentation change,
        // never on a scroll — so the layer keeps its contents through every
        // slide of the list above it.
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.drawsAsynchronously = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func apply(rows: [TimelineRow], revision: UInt64, generation: UInt64) {
        // **Guarded, because SwiftUI hands this an identical card on every
        // pass.** A hover on a neighbouring row, a scroll, a window resize —
        // each re-runs `updateNSView` for every card on screen, and an
        // unconditional `needsDisplay` would re-frameset the whole pane's ink
        // for a pointer moving.
        let id = rows.first?.messageID
        let height = rows.reduce(0) { $0 + $1.height }
        let changed = revision != self.revision
            || generation != self.generation
            || id != drawnID
            || height != drawnHeight
        self.rows = rows
        guard changed else { return }
        if revision != self.revision {
            self.revision = revision
            style = MessageTextStyle.current()
        }
        self.generation = generation
        drawnID = id
        drawnHeight = height
        needsDisplay = true
        refreshAnimation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A card that outlives its window as a clock subscriber is a retain
        // cycle with a display link in it.
        refreshAnimation()
    }

    deinit {
        MainActor.assumeIsolated { AnimationClock.shared.unsubscribe(animationToken) }
    }

    /// Subscribes while something in the card is moving, and stops the moment
    /// nothing is. Idempotent, so every caller may call it freely.
    private func refreshAnimation() {
        let wanted = window != nil && hasFilm
        guard wanted != isAnimating else { return }
        isAnimating = wanted
        if wanted {
            AnimationClock.shared.subscribe(animationToken) { [weak self] in
                self?.advanceFilm()
            }
        } else {
            AnimationClock.shared.unsubscribe(animationToken)
            shownFilmFrames.removeAll(keepingCapacity: true)
        }
    }

    /// Whether anything here is a filmstrip. Four kinds, and the message says
    /// which it is without a fetch or a decode.
    private var hasFilm: Bool {
        for row in rows {
            guard case .message(let message) = row.kind else { continue }
            if message.stickers.contains(where: \.isAnimated) { return true }
            if message.attachments.contains(where: \.isAnimated) { return true }
            for embed in message.embeds where embed.images.contains(where: \.isAnimated) {
                return true
            }
            if AnimationClock.playsAnimatedEmoji,
               message.textBlock?.emojiRects.contains(where: { $0.emoji.isAnimated }) == true
            {
                return true
            }
        }
        return false
    }

    /// One clock tick: repaint only if a frame actually moved.
    private func advanceFilm() {
        let time = AnimationClock.shared.time
        let scale = window?.backingScaleFactor ?? 2
        var moved = false

        func advance(url: URL?, decodeWidth: CGFloat, key: FilmSlot) {
            guard let url else { return }
            let film = AnimatedImageStore.Key(
                url: url, maximumPixelSize: Int((decodeWidth * scale).rounded(.up))
            )
            guard let strip = AnimatedImageStore.shared.cached(film) else { return }
            let next = strip.index(at: time)
            guard shownFilmFrames[key] != next else { return }
            shownFilmFrames[key] = next
            moved = true
        }

        for row in rows {
            guard case .message(let message) = row.kind else { continue }
            for (offset, slot) in message.stickers.enumerated() where slot.isAnimated {
                advance(
                    url: slot.url,
                    decodeWidth: slot.rect.width,
                    key: FilmSlot(messageID: message.id, kind: .sticker, index: offset)
                )
            }
            for (offset, slot) in message.attachments.enumerated() where slot.isAnimated {
                advance(
                    url: slot.url,
                    decodeWidth: slot.decodeWidth,
                    key: FilmSlot(messageID: message.id, kind: .attachment, index: offset)
                )
            }
            var embedImage = 0
            for embed in message.embeds {
                for slot in embed.images {
                    defer { embedImage += 1 }
                    guard slot.isAnimated else { continue }
                    advance(
                        url: slot.url,
                        decodeWidth: slot.decodeWidth,
                        key: FilmSlot(messageID: message.id, kind: .embed, index: embedImage)
                    )
                }
            }
            if let block = message.textBlock {
                for (offset, entry) in block.emojiRects.enumerated()
                where entry.emoji.isAnimated {
                    advance(
                        url: entry.emoji.id.flatMap {
                            CDN.emoji(id: $0, animated: true, side: entry.rect.width)
                        },
                        decodeWidth: entry.rect.width,
                        key: FilmSlot(messageID: message.id, kind: .emoji, index: offset)
                    )
                }
            }
        }
        if moved { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, bounds.width > 40 else {
            return
        }
        let scale = window?.backingScaleFactor ?? 2
        let clock = AnimationClock.shared.time
        var y: CGFloat = 0
        for row in rows {
            let frame = CGRect(x: 0, y: y, width: bounds.width, height: row.height)
            y += row.height
            guard frame.intersects(dirtyRect) else { continue }
            TimelineRowPainter.draw(
                row: row,
                in: frame,
                context: context,
                style: style,
                state: TimelineRowPainter.State(animationTime: clock),
                images: ImageStore.shared,
                scale: scale
            )
        }
    }
}
