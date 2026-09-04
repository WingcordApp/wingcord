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
