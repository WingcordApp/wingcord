import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import Wingcord
@testable import WingcordCore

/// The picture pipeline after "images may be bugged" (REDESIGN.md D11–D16):
/// pictures show as each lands, they are fetched ahead of a reader and not of
/// a fling, the viewer cannot empty the transcript's cache, and a covered
/// spoiler is Discord's blur rather than a flat plate.
@MainActor
@Suite("Image pipeline")
struct ImagePipelineTests {

    /// What a batch reported, in order.
    @MainActor
    final class Reports {
        var batches: [[Int]] = []
    }

    // MARK: D11 — shown as they land

    @Test("A slow picture does not hold the others back")
    func slowDoesNotHoldBack() async throws {
        let reports = Reports()
        // The slow picture lands only when the test says so — no clock in the
        // assertion, so a busy machine cannot make it pass or fail.
        let slow = Latch()
        let batch = Task {
            await ImageBatch.load(
                [1, 2],
                using: { item in
                    if item == 2 { await slow.wait() }
                    return true
                },
                landed: { reports.batches.append($0) }
            )
        }
        // The fast one is reported while the slow one is still on its way.
        // Awaiting the whole batch, nothing at all would be reported until
        // `slow` opens — which this waits ten seconds for before giving up.
        let fastReported = await Self.eventually { reports.batches.count == 1 }
        #expect(fastReported)
        #expect(reports.batches == [[1]])
        slow.open()
        await batch.value
        #expect(await Self.eventually { reports.batches.count == 2 })
        #expect(reports.batches == [[1], [2]])
    }

    /// Opens once; everything waiting on it resumes, and anything after it
    /// passes straight through.
    final class Latch: Sendable {
        private let state = Mutex<(isOpen: Bool, waiting: [CheckedContinuation<Void, Never>])>((false, []))

        func wait() async {
            await withCheckedContinuation { continuation in
                let passes = state.withLock { state -> Bool in
                    if state.isOpen { return true }
                    state.waiting.append(continuation)
                    return false
                }
                if passes { continuation.resume() }
            }
        }

        func open() {
            let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.isOpen = true
                defer { state.waiting.removeAll() }
                return state.waiting
            }
            for continuation in waiting { continuation.resume() }
        }
    }

    /// Whether `condition` holds within ten seconds, checked every 20 ms.
    static func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test("What lands within a moment is one report")
    func coalesces() async {
        let reports = Reports()
        let reporter = LandingReporter<Int> { reports.batches.append($0) }
        // Three landings back to back, as a burst of avatars arrives.
        reporter.add(1)
        reporter.add(2)
        reporter.add(3)
        #expect(await Self.eventually { !reports.batches.isEmpty })
        #expect(reports.batches == [[1, 2, 3]])
    }

    @Test("A picture that failed is never reported")
    func failuresAreNotReported() async {
        let reports = Reports()
        await ImageBatch.load([1, 2, 3], using: { $0 != 2 }, landed: { reports.batches.append($0) })
        #expect(await Self.eventually { Set(reports.batches.joined()) == [1, 3] })
        #expect(!reports.batches.joined().contains(2))
    }

    @Test("A picture two rows share is asked for once, and repaints both rows")
    func sharedPictureOwners() throws {
        let avatar = try #require(URL(string: "file:///tmp/avatar-\(UUID().uuidString).png"))
        let rows = Self.rows(
            [MessageID(rawValue: 11 << 22), MessageID(rawValue: 12 << 22)],
            author: avatar
        )
        #expect(rows.count == 2)
        let wanted = TimelineImageRequests.requestsByMessage(for: rows, scale: 2, loadsArtwork: true)
        let asked = wanted.requests.filter { $0.key.url == avatar }
        #expect(asked.count == 1)
        let key = try #require(asked.first?.key)
        #expect(wanted.owners[key] == rows.map(\.id))
    }

    // MARK: D12 — ahead of a reader, not of a fling

    @Test("Pictures are asked for a screen past each edge of the viewport")
    func reach() {
        let reach = TimelineViewportPolicy.pictureReach(viewport: CGRect(x: 0, y: 1000, width: 800, height: 600))
        #expect(reach == 400...2200)
    }

    @Test("A reader's scroll fetches as it goes; a fling waits for the gesture to end")
    func readingNotFlinging() {
        #expect(TimelineViewportPolicy.fetchesDuringScroll(isScrolling: true, speed: 600, viewportHeight: 800))
        #expect(!TimelineViewportPolicy.fetchesDuringScroll(isScrolling: true, speed: 4000, viewportHeight: 800))
        #expect(TimelineViewportPolicy.fetchesDuringScroll(isScrolling: false, speed: 4000, viewportHeight: 800))
    }

    @Test("Rows on screen are asked for first, then the nearest")
    func order() {
        let bands: [(CGFloat, CGFloat)] = [(0, 500), (500, 900), (900, 1100), (1100, 1500), (1500, 1700), (1700, 1800), (1800, 2600)]
        let frames = bands.map { CGRect(x: 0, y: $0.0, width: 10, height: $0.1 - $0.0) }
        let viewport = CGRect(x: 0, y: 1000, width: 10, height: 600)
        let order = TimelineViewportPolicy.pictureOrder(0..<frames.count, frame: { frames[$0] }, viewport: viewport)
        #expect(order == [2, 3, 4, 1, 5, 6, 0])
    }

    @Test("A scroll's speed is smoothed over ticks and starts again after a pause")
    func speed() {
        // Ten points in a 120 Hz tick is 1,200 points a second; half of it the first time.
        let first = TimelineViewportPolicy.smoothedSpeed(previous: 0, movement: 10, elapsed: 1.0 / 120)
        #expect(abs(first - 600) < 0.5)
        let second = TimelineViewportPolicy.smoothedSpeed(previous: first, movement: -10, elapsed: 1.0 / 120)
        #expect(abs(second - 900) < 0.5)
        let afterPause = TimelineViewportPolicy.smoothedSpeed(previous: second, movement: 10, elapsed: 0.5)
        #expect(abs(afterPause - 20) < 0.5)
    }

    // MARK: D14 — the viewer's own cache

    @Test("The viewer's pictures have their own cache, and it empties when the viewer closes")
    func stageBucket() async throws {
        // **Its own cache, so it cannot evict the transcript's.** Asserted on
        // identity rather than by filling one and watching the other: the app
        // model sheds every cache under memory pressure, and a test of the
        // shared store that waits on anything races whoever else is running.
        let store = ImageStore.shared
        #expect(store.cacheIdentity(for: .stage) != store.cacheIdentity(for: .attachment))
        #expect(store.cacheIdentity(for: .stage) != store.cacheIdentity(for: .thumbnail))
        #expect(store.cacheIdentity(for: .stage) != store.cacheIdentity(for: .artwork))
        // And bigger than the close-up it is for: a 12-megapixel photograph at
        // 4,096 pixels is 50 MB, more than the transcript's whole budget.
        #expect(ImageStore.Budget.stage > 4096 * 3072 * 4)

        let picture = try Self.png(side: 64)
        defer { try? FileManager.default.removeItem(at: picture) }
        let key = ImageStore.Key(url: picture, maximumPixelSize: 64)
        #expect(await store.image(for: key, bucket: .stage) != nil)
        store.emptyStage()
        #expect(store.cached(key, bucket: .stage) == nil)
    }

    // MARK: D16 — the spoiler's cover

    /// A solid orange, as Discord's `placeholder` (ThumbHash) for it.
    static let orange = "Y+0CBICXl4h4d4iPh3eHh394+A=="

    @Test("A covered spoiler is Discord's blur at 55 % brightness, never a flat plate")
    func spoilerCover() throws {
        // Neither picture exists, so both draw their stand-in: the plain one
        // as it loads, the spoiler as its cover.
        let loading = try #require(Self.attachmentRow(named: "photo.png", placeholder: Self.orange))
        let covered = try #require(Self.attachmentRow(named: "SPOILER_photo.png", placeholder: Self.orange))
        let plain = try Self.sample(loading)
        let cover = try Self.sample(covered)
        // The stand-in is the orange itself…
        #expect(plain.red > 200 && plain.green > 100 && plain.blue < 80)
        // …and the cover is that orange at 55 %.
        #expect(abs(Double(cover.red) - Double(plain.red) * 0.55) < 12)
        #expect(abs(Double(cover.green) - Double(plain.green) * 0.55) < 12)
    }

    // MARK: Fixtures

    private static func rows(_ ids: [MessageID], author avatar: URL) -> [MessageRow] {
        let author = UserID(rawValue: 7)
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        let laid = TimelineLayoutEngine(presentationRevision: 1).layout(
            TimelineLayoutEngine.Input(
                items: ids.map { id in
                    .message(TimelineMessage(
                        message: Message(id: id, channelID: ChannelID(rawValue: 1), authorID: author, content: "hello"),
                        flags: [.head, .tail]
                    ))
                },
                width: 480,
                style: MessageTextStyle.current(),
                mentions: MentionContext(),
                channelName: "general",
                authors: [
                    author: TimelineLayoutEngine.AuthorInfo(
                        name: "ada", colorValue: nil, avatarURL: avatar,
                        monogram: "A", decorationURL: nil, isBot: false
                    )
                ],
                calendar: .current,
                settings: PresentationRevision.shared.timeline
            ),
            cache: &cache
        )
        return laid.compactMap { row in
            if case .message(let message) = row.kind { message } else { nil }
        }
    }

    /// A row holding one 400 × 300 picture that is not on this Mac.
    private static func attachmentRow(named name: String, placeholder: String) -> TimelineRow? {
        let url = "file:///tmp/\(UUID().uuidString)-\(name)"
        let attachment = WingcordCore.Attachment(
            id: AttachmentID(rawValue: 3), filename: name, url: url, proxyURL: url,
            contentType: "image/png", size: 1024, width: 400, height: 300, placeholder: placeholder
        )
        let message = Message(
            id: MessageID(rawValue: 21 << 22), channelID: ChannelID(rawValue: 1), authorID: UserID(rawValue: 7),
            content: "", payload: MessagePayload(attachments: [attachment])
        )
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        return TimelineLayoutEngine(presentationRevision: 1).layout(
            TimelineLayoutEngine.Input(
                items: [.message(TimelineMessage(message: message, flags: [.head, .tail]))],
                width: 520,
                style: MessageTextStyle.current(),
                mentions: MentionContext(),
                channelName: "general",
                authors: [:],
                calendar: .current,
                settings: PresentationRevision.shared.timeline
            ),
            cache: &cache
        ).first
    }

    /// The colour a fifth of the way across the row's picture, at its middle —
    /// clear of the SPOILER chip in its centre.
    private static func sample(_ row: TimelineRow) throws -> (red: UInt8, green: UInt8, blue: UInt8) {
        guard case .message(let message) = row.kind else {
            Issue.record("expected a message row")
            return (0, 0, 0)
        }
        let slot = try #require(message.attachments.first)
        let width = 560
        let height = Int(row.height.rounded(.up))
        let pixels = RenderProbe.pixels(width: width, height: height) { context, _ in
            TimelineRowPainter.draw(
                row: row,
                in: CGRect(x: 0, y: 0, width: CGFloat(width), height: row.height),
                context: context,
                style: MessageTextStyle.current(),
                state: TimelineRowPainter.State(),
                images: ImageStore.shared,
                scale: 1
            )
        }
        let x = Int(slot.rect.minX + slot.rect.width * 0.2)
        let y = Int(slot.rect.midY)
        let index = (y * width + x) * 4
        return (pixels[index], pixels[index + 1], pixels[index + 2])
    }

    /// A square PNG of one colour, under a fresh name.
    private static func png(side: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "pipeline-\(UUID().uuidString).png")
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }
}
