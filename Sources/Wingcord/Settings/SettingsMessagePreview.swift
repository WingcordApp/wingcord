import AppKit
import SwiftUI
import WingcordCore

// MARK: - The message preview
//
// Two messages, drawn by the transcript's OWN painter.
//
// That is the whole point and it is not a shortcut: a preview built out of
// SwiftUI text would agree with the transcript only for as long as somebody kept
// the two in step, and the first time they diverged the preview would be
// confidently wrong about the thing it exists to show. `TimelineRowPainter.draw`
// is `nonisolated` and takes its style and settings as values — the render tests
// already drive it the same way — so the preview is the real thing at a smaller
// size, and it cannot drift.
//
// It costs a layout and a paint when the presentation revision moves, and
// nothing at all in between.

struct SettingsMessagePreview: View {
    /// Redraw is keyed on this. Reading the revision here rather than inside the
    /// representable is what makes SwiftUI call `updateNSView` at all.
    @State private var revision = PresentationRevision.shared

    var body: some View {
        PreviewCanvas(presentationRevision: revision.value)
            .frame(height: PreviewCanvas.height)
            .frame(maxWidth: .infinity)
            // The real ground, not `Palette.canvas`: under a gradient theme the
            // flat token is a colour the window never shows, and a preview on
            // it would be confidently wrong about the one thing the reader is
            // choosing a theme for.
            .readingSurface()
            .clipShape(.settingsRect(SettingsMetrics.cardRadius))
            .accessibilityHidden(true)
    }
}

private struct PreviewCanvas: NSViewRepresentable {
    var presentationRevision: UInt64

    /// Two runs at the comfortable density, with room for the compact one to
    /// shrink into. Fixed rather than measured: a preview that resized as the
    /// setting changed would move the card under the pointer that is changing it.
    static let height: CGFloat = 132

    func makeNSView(context: Context) -> PreviewView { PreviewView() }

    func updateNSView(_ view: PreviewView, context: Context) {
        view.presentationRevision = presentationRevision
    }
}

/// A flipped view that lays out and paints the fixture once per revision.
private final class PreviewView: NSView {
    var presentationRevision: UInt64 = 0 {
        didSet {
            guard presentationRevision != oldValue else { return }
            rows = nil
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    /// Laid-out rows, discarded when the revision or the width moves. Held so a
    /// resize drag does not re-frameset the fixture on every intermediate width.
    private var rows: [TimelineRow]?
    private var laidOutWidth: CGFloat = 0

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if abs(newSize.width - laidOutWidth) > 0.5 { rows = nil }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, bounds.width > 40 else { return }

        let style = PresentationRevision.shared.style
        let settings = PresentationRevision.shared.timeline
        let resolved = rows ?? layout(style: style, settings: settings)
        rows = resolved
        laidOutWidth = bounds.width

        var y: CGFloat = 0
        let scale = window?.backingScaleFactor ?? 2
        for row in resolved {
            let frame = CGRect(x: 0, y: y, width: bounds.width, height: row.height)
            guard frame.intersects(dirtyRect) else { y += row.height; continue }
            TimelineRowPainter.draw(
                row: row,
                in: frame,
                context: context,
                style: style,
                state: TimelineRowPainter.State(),
                images: ImageStore.shared,
                scale: scale
            )
            y += row.height
        }
    }

    private func layout(style: MessageTextStyle, settings: TimelineSettings) -> [TimelineRow] {
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        return TimelineLayoutEngine(presentationRevision: presentationRevision).layout(
            TimelineLayoutEngine.Input(
                items: Self.items,
                width: bounds.width,
                style: style,
                mentions: MentionContext(),
                channelName: "general",
                authors: Self.authors,
                calendar: .current,
                settings: settings
            ),
            cache: &cache
        )
    }

    // MARK: The fixture
    //
    // Two authors so the run gap is visible — which is the whole of what the
    // density control changes — and one line of markdown, so the text size
    // control has something with weight in it to scale.

    private static let firstAuthor = UserID(rawValue: 1)
    private static let secondAuthor = UserID(rawValue: 2)

    /// A snowflake carrying a chosen instant.
    ///
    /// A message's `sentAt` is DERIVED from its id — the snowflake already holds
    /// a millisecond timestamp, so there is no field to set — which means the
    /// preview picks its times by choosing ids. Fixed and safely in the past, so
    /// the row reads "12/11/2023 at 09:33" rather than "Today at": the clock is
    /// the thing being previewed, and "Today" would hide it half the time.
    private static func snowflake(at unixSeconds: Double) -> MessageID {
        let millis = UInt64(unixSeconds * 1000) - MessageID.epochMilliseconds
        return MessageID(rawValue: millis << 22)
    }

    private static let items: [TimelineItem] = [
        .message(TimelineMessage(
            message: Message(
                id: snowflake(at: 1_700_000_000),
                channelID: ChannelID(rawValue: 1),
                authorID: firstAuthor,
                content: "This is how a message will look — **bold**, *italic* and `code`."
            ),
            flags: [.head, .tail]
        )),
        .message(TimelineMessage(
            message: Message(
                id: snowflake(at: 1_700_003_600),
                channelID: ChannelID(rawValue: 1),
                authorID: secondAuthor,
                content: "And this is the gap between two people talking."
            ),
            flags: [.head, .tail]
        )),
    ]

    private static let authors: [UserID: TimelineLayoutEngine.AuthorInfo] = [
        firstAuthor: .init(
            name: "Wren", colorValue: 0x5865F2, avatarURL: nil,
            monogram: "W", decorationURL: nil, isBot: false
        ),
        secondAuthor: .init(
            name: "Alder", colorValue: 0x23A55A, avatarURL: nil,
            monogram: "A", decorationURL: nil, isBot: false
        ),
    ]
}
