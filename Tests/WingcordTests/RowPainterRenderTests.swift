import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// Render tests for the drawn surfaces.
///
/// **A render test is the only real check on a canvas.** A painter that draws
/// nothing compiles, lays out, reports the right size and renders a perfectly
/// empty view — every other kind of test passes on it.
///
/// **And the first version of a test like this is usually wrong in the same
/// way**: black ink on a black ground asserts nothing. So everything here draws
/// over MID-GREY and asserts that the result *differs from the ground*, rather
/// than asserting brightness — which would only catch ink that happens to be
/// lighter than what it is drawn on.
@MainActor
@Suite("Row painter rendering")
struct RowPainterRenderTests {

    private static let ground = CGFloat(0.5)

    /// Draws into a bitmap and returns the fraction of pixels that differ from
    /// the mid-grey ground.
    private func inkFraction(
        width: Int = 240,
        height: Int = 48,
        _ draw: (CGContext, CGRect) -> Void
    ) -> Double {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let grey = UInt8(Self.ground * 255)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = grey
            pixels[index + 1] = grey
            pixels[index + 2] = grey
            pixels[index + 3] = 255
        }

        var differing = 0
        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else {
                Issue.record("could not create a bitmap context")
                return
            }
            // The canvases are flipped (top-left origin); a bitmap context is
            // not. Flipping here means the painter draws exactly as it does on
            // screen rather than upside down, which would still produce ink and
            // hide a real geometry bug.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)

            let frame = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            draw(context, frame)
            NSGraphicsContext.restoreGraphicsState()
        }

        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index] != grey {
            differing += 1
        }
        return Double(differing) / Double(width * height)
    }

    private var style: MessageTextStyle { MessageTextStyle.current() }

    private func entry(
        name: String = "Blåhaj",
        colorValue: UInt32? = 0xE67E22,
        status: PresenceStatus = .online,
        subtitle: String? = nil,
        isBot: Bool = false,
        tag: String? = nil
    ) -> MemberEntry {
        MemberEntry(
            userID: UserID(rawValue: 1),
            name: name,
            colorValue: colorValue,
            avatarURL: nil,
            monogram: "B",
            decorationURL: nil,
            status: status,
            isOnMobile: false,
            subtitle: subtitle,
            isBot: isBot,
            tag: tag,
            nameplateURL: nil
        )
    }

    // MARK: Member rows

    @Test("A member row paints something")
    func memberRowDrawsInk() {
        let ink = inkFraction { context, frame in
            MemberRowPainter.drawMember(
                self.entry(),
                in: frame,
                context: context,
                style: self.style,
                isHovered: false,
                images: ImageStore.shared,
                scale: 1
            )
        }
        // A name, a monogram plate and a presence dot in a 240x48 box is a few
        // per cent of the pixels. Anything near zero means the row is blank.
        #expect(ink > 0.01)
    }

    @Test("An offline member is dimmed but still visible")
    func offlineMemberIsStillDrawn() {
        let online = inkFraction { context, frame in
            MemberRowPainter.drawMember(
                self.entry(status: .online),
                in: frame, context: context, style: self.style,
                isHovered: false, images: ImageStore.shared, scale: 1
            )
        }
        let offline = inkFraction { context, frame in
            MemberRowPainter.drawMember(
                self.entry(status: .offline),
                in: frame, context: context, style: self.style,
                isHovered: false, images: ImageStore.shared, scale: 1
            )
        }
        #expect(online > 0.01)
        #expect(offline > 0.01)
    }

    @Test("A two-line member row paints more than a one-line one")
    func subtitleAddsInk() {
        let plain = inkFraction(height: 46) { context, frame in
            MemberRowPainter.drawMember(
                self.entry(),
                in: frame, context: context, style: self.style,
                isHovered: false, images: ImageStore.shared, scale: 1
            )
        }
        let withSubtitle = inkFraction(height: 46) { context, frame in
            MemberRowPainter.drawMember(
                self.entry(subtitle: "Playing Xcode"),
                in: frame, context: context, style: self.style,
                isHovered: false, images: ImageStore.shared, scale: 1
            )
        }
        #expect(withSubtitle > plain)
    }

    @Test("A section header paints something")
    func headerDrawsInk() {
        let ink = inkFraction(height: 34) { context, frame in
            MemberRowPainter.drawHeader(
                title: "Main Dev",
                count: 3,
                colorValue: 0xE67E22,
                in: frame,
                context: context,
                style: self.style
            )
        }
        #expect(ink > 0.005)
    }

    // MARK: Timeline rows

    @Test("A message row paints something")
    func messageRowDrawsInk() {
        let row = Self.messageRow(style: style, width: 480)
        let ink = inkFraction(width: 480, height: 80) { context, frame in
            TimelineRowPainter.draw(
                row: row,
                in: frame,
                context: context,
                style: self.style,
                state: TimelineRowPainter.State(),
                images: ImageStore.shared,
                scale: 1
            )
        }
        #expect(ink > 0.01)
    }

    @Test("A day separator paints its rule and its label")
    func daySeparatorDrawsInk() {
        let row = TimelineRow(
            height: TimelineMetrics.daySeparatorHeight,
            kind: .daySeparator(label: "Yesterday")
        )
        let ink = inkFraction(width: 480, height: 34) { context, frame in
            TimelineRowPainter.draw(
                row: row, in: frame, context: context, style: self.style,
                state: TimelineRowPainter.State(), images: ImageStore.shared, scale: 1
            )
        }
        #expect(ink > 0.005)
    }

    @Test("A history skeleton paints its placeholder bars")
    func skeletonDrawsInk() {
        let row = TimelineRow(
            height: TimelineMetrics.skeletonHeight,
            kind: .skeleton(index: 0)
        )
        let ink = inkFraction(width: 480, height: 56) { context, frame in
            TimelineRowPainter.draw(
                row: row, in: frame, context: context, style: self.style,
                state: TimelineRowPainter.State(), images: ImageStore.shared, scale: 1
            )
        }
        #expect(ink > 0.005)
    }

    @Test("A hovered row paints more than an unhovered one")
    func hoverAddsInk() {
        let row = Self.messageRow(style: style, width: 480)
        let plain = inkFraction(width: 480, height: 80) { context, frame in
            TimelineRowPainter.draw(
                row: row, in: frame, context: context, style: self.style,
                state: TimelineRowPainter.State(), images: ImageStore.shared, scale: 1
            )
        }
        var hovered = TimelineRowPainter.State()
        hovered.isHovered = true
        let lit = inkFraction(width: 480, height: 80) { context, frame in
            TimelineRowPainter.draw(
                row: row, in: frame, context: context, style: self.style,
                state: hovered, images: ImageStore.shared, scale: 1
            )
        }
        #expect(lit > plain)
    }

    /// Builds one laid-out message row through the real engine, so the test
    /// exercises the same path the app does rather than a hand-made value that
    /// could be geometrically impossible.
    static func messageRow(style: MessageTextStyle, width: CGFloat) -> TimelineRow {
        let message = Message(
            id: MessageID(rawValue: 1 << 22),
            channelID: ChannelID(rawValue: 1),
            authorID: UserID(rawValue: 7),
            content: "the sidebar column is painted with **nothing**"
        )
        let items: [TimelineItem] = [
            .message(TimelineMessage(message: message, flags: [.head, .tail]))
        ]
        let engine = TimelineLayoutEngine(presentationRevision: 0)
        var cache: [TimelineLayoutEngine.CacheKey: MessageRow] = [:]
        let rows = engine.layout(
            TimelineLayoutEngine.Input(
                items: items,
                width: width,
                style: style,
                mentions: MentionContext(),
                channelName: "general",
                authors: [
                    UserID(rawValue: 7): TimelineLayoutEngine.AuthorInfo(
                        name: "Blåhaj",
                        colorValue: 0xE67E22,
                        avatarURL: nil,
                        monogram: "B",
                        decorationURL: nil,
                        isBot: false
                    )
                ],
                calendar: .current
            ),
            cache: &cache
        )
        return rows[0]
    }
}

/// The layout engine's geometry, which the painter depends on.
@MainActor
@Suite("Timeline layout")
struct TimelineLayoutTests {

    @Test("A laid-out row has a positive height and a text block")
    func rowHasGeometry() {
        let row = RowPainterRenderTests.messageRow(
            style: MessageTextStyle.current(),
            width: 480
        )
        #expect(row.height > 20)
        guard case .message(let message) = row.kind else {
            Issue.record("expected a message row")
            return
        }
        #expect(message.avatarRect != nil)
        #expect(message.textBlock != nil)
        #expect((message.textBlock?.size.height ?? 0) > 0)
        #expect(!message.accessibilityLabel.isEmpty)
    }

    @Test("The cache is a hit on the second pass at the same width")
    func layoutCacheHits() {
        let style = MessageTextStyle.current()
        let message = Message(
            id: MessageID(rawValue: 1 << 22),
            channelID: ChannelID(rawValue: 1),
            authorID: UserID(rawValue: 7),
            content: "hello"
        )
        let items: [TimelineItem] = [
            .message(TimelineMessage(message: message, flags: [.head, .tail]))
        ]
        let engine = TimelineLayoutEngine(presentationRevision: 0)
        var cache: [TimelineLayoutEngine.CacheKey: MessageRow] = [:]
        let input = TimelineLayoutEngine.Input(
            items: items,
            width: 480,
            style: style,
            mentions: MentionContext(),
            channelName: "general",
            authors: [:],
            calendar: .current
        )
        _ = engine.layout(input, cache: &cache)
        #expect(cache.count == 1)

        // The same text block instance comes back, which is what makes an
        // incremental relayout a pointer copy rather than a re-framesetting.
        let firstBlock = cache.values.first?.textBlock
        _ = engine.layout(input, cache: &cache)
        #expect(cache.count == 1)
        #expect(cache.values.first?.textBlock === firstBlock)
    }

    @Test("A width change is a miss, because wrapping changes")
    func widthChangeMisses() {
        let style = MessageTextStyle.current()
        let message = Message(
            id: MessageID(rawValue: 1 << 22),
            channelID: ChannelID(rawValue: 1),
            authorID: UserID(rawValue: 7),
            content: "a message long enough that its wrapping genuinely depends on the width it is laid out against"
        )
        let items: [TimelineItem] = [
            .message(TimelineMessage(message: message, flags: [.head, .tail]))
        ]
        let engine = TimelineLayoutEngine(presentationRevision: 0)
        var cache: [TimelineLayoutEngine.CacheKey: MessageRow] = [:]

        func layout(width: CGFloat) -> TimelineRow {
            engine.layout(
                TimelineLayoutEngine.Input(
                    items: items, width: width, style: style,
                    mentions: MentionContext(), channelName: "general",
                    authors: [:], calendar: .current
                ),
                cache: &cache
            )[0]
        }

        let wide = layout(width: 700)
        let narrow = layout(width: 260)
        #expect(narrow.height > wide.height)
    }
}
