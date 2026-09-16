import CoreGraphics
import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// How several pictures in one message are arranged.
///
/// **The numbers are Discord's, and one capture pins them.** Every expectation
/// below is either read out of its bundle — module `394839` for the shapes,
/// `838541` for `MAX_WIDTH = 550` and `MAX_HEIGHT = 350`, and module `293612`'s
/// stylesheet for the per-shape heights — or measured off a screenshot of a
/// real four-picture message, which came out 550 across in two 273-wide columns
/// either side of a 4-point gap, rows 173 tall. The two agree exactly, which is
/// why they are worth writing down twice.
///
/// The heights are the part that is not guessable and that a first pass got
/// wrong: a two-picture row is capped at **280**, not 350 and not the 273 its
/// cells are wide.
@MainActor
@Suite("Attachment mosaic")
struct AttachmentMosaicTests {

    private let wide: CGFloat = 900

    /// Pictures of a given shape, big enough that nothing is capped by its own
    /// pixels.
    private func sizes(_ ratios: CGFloat...) -> [CGSize?] {
        ratios.map { CGSize(width: 2000 * $0, height: 2000) }
    }

    /// Square pictures, which is the simplest thing to reason about a grid with.
    private func squares(_ count: Int) -> [CGSize?] {
        Array(repeating: CGSize(width: 2000, height: 2000), count: count)
    }

    // MARK: The five shapes

    @Test("One picture keeps its shape, inside 550 by 350")
    func single() {
        // The whole of "the images are way too big": this used to take the
        // column, which on a wide window is a thousand points.
        let frames = AttachmentMosaic.frames(sizes: sizes(16.0 / 9), width: wide)
        #expect(frames.count == 1)
        #expect(frames[0].width == 550)
        #expect(frames[0].height == (550 * 9.0 / 16).rounded())
        #expect(frames[0].height <= AttachmentMosaic.maxHeight)
    }

    @Test("A tall picture is capped by height and keeps its ratio")
    func singleTall() {
        let frames = AttachmentMosaic.frames(sizes: sizes(9.0 / 16), width: wide)
        #expect(frames[0].height == AttachmentMosaic.maxHeight)
        #expect(abs(frames[0].width / frames[0].height - 9.0 / 16) < 0.01)
    }

    @Test("Two sit side by side in squares, and the row is exactly 550")
    func two() {
        let frames = AttachmentMosaic.frames(sizes: squares(2), width: wide)
        #expect(frames.count == 2)
        #expect(frames[0] == CGRect(x: 0, y: 0, width: 273, height: 273))
        #expect(frames[1] == CGRect(x: 277, y: 0, width: 273, height: 273))
        #expect(frames[1].maxX == 550)
        #expect(frames[0].minY == frames[1].minY)
    }

    @Test("Three are a tall cell and two stacked, and both axes add up")
    func three() {
        let frames = AttachmentMosaic.frames(sizes: squares(3), width: wide)
        #expect(frames.count == 3)
        // 364 + 4 + 182 = 550 across, 173 + 4 + 173 = 350 down.
        #expect(frames[0] == CGRect(x: 0, y: 0, width: 364, height: 350))
        #expect(frames[1] == CGRect(x: 368, y: 0, width: 182, height: 173))
        #expect(frames[2] == CGRect(x: 368, y: 177, width: 182, height: 173))
        #expect(frames[1].maxX == 550)
        #expect(frames[2].maxY == frames[0].maxY)
    }

    @Test("Four are the grid the screenshot measures")
    func four() {
        // Measured off a real Discord message at 2x: the grid spans 1103 device
        // pixels (551.5pt), each column 546 (273pt), the gutter 9 (4.5pt), each
        // row 344 (172pt). These are those numbers.
        let frames = AttachmentMosaic.frames(sizes: squares(4), width: wide)
        #expect(frames.count == 4)
        #expect(frames[0] == CGRect(x: 0, y: 0, width: 273, height: 173))
        #expect(frames[1] == CGRect(x: 277, y: 0, width: 273, height: 173))
        #expect(frames[2] == CGRect(x: 0, y: 177, width: 273, height: 173))
        #expect(frames[3] == CGRect(x: 277, y: 177, width: 273, height: 173))
        #expect(frames[3].maxX == 550)
        #expect(frames[3].maxY == 350)
    }

    @Test("Five lead with a pair, then a row of three")
    func five() {
        // 5 % 3 == 2.
        let frames = AttachmentMosaic.frames(sizes: squares(5), width: wide)
        #expect(frames.count == 5)
        #expect(frames[0].minY == frames[1].minY)
        #expect(frames[0].height == 273)
        // Then three across, all on one row below the pair.
        #expect(frames[2].minY == frames[3].minY)
        #expect(frames[3].minY == frames[4].minY)
        #expect(frames[2].minY == 277)
        #expect(frames[4].maxX == 550)
    }

    @Test("Six are two rows of three and nothing leads")
    func six() {
        let frames = AttachmentMosaic.frames(sizes: squares(6), width: wide)
        #expect(frames.count == 6)
        #expect(frames[0].minY == 0)
        #expect(frames[0].width == 181)
        #expect(frames[2].maxX == 550)
        #expect(frames[3].minY == frames[0].maxY + AttachmentMosaic.gap)
        #expect(frames[5].maxX == 550)
    }

    @Test("Seven lead with one full-width picture of its own shape")
    func seven() {
        // 7 % 3 == 1, and that leading picture is the only one in the whole
        // arrangement whose height is a fact about the picture.
        let frames = AttachmentMosaic.frames(
            sizes: [CGSize(width: 2000, height: 1000)] + squares(6), width: wide
        )
        #expect(frames.count == 7)
        #expect(frames[0] == CGRect(x: 0, y: 0, width: 550, height: 275))
        #expect(frames[1].minY == 279)
        #expect(frames[1].minY == frames[3].minY)
        #expect(frames[4].minY == frames[6].minY)
        #expect(frames[6].maxX == 550)
    }

    @Test("Every row ends exactly where the last began plus its width")
    func rowsAreFlush() {
        // Rounding a third of 546 leaves a point over; the trailing cell takes
        // it so a row is never a point short of the column it sits in.
        for count in 2...10 {
            let frames = AttachmentMosaic.frames(sizes: squares(count), width: 550)
            #expect(frames.count == count)
            let rightmost = frames.map(\.maxX).max() ?? 0
            #expect(rightmost == 550, "count \(count) ended at \(rightmost)")
        }
    }

    @Test("A narrower column scales the whole arrangement")
    func narrowColumn() {
        let frames = AttachmentMosaic.frames(sizes: squares(4), width: 300)
        #expect(frames[0].width == 148)
        #expect(frames[3].maxX == 300)
        // **173 is a ceiling, not a height.** A square picture in a 148-wide
        // cell wants 148, and `1fr` rows take what the content wants until the
        // 350 cap bites. At 550 the same four squares hit the ceiling instead.
        #expect(frames[0].height == 148)
        #expect(AttachmentMosaic.frames(sizes: squares(4), width: 550)[0].height
            == AttachmentMosaic.rowHeight)
    }

    @Test("A row of two is capped at 280, which is not the 350 a lone one gets")
    func pairHeightCap() {
        // The number the stylesheet gives `.oneByTwoGrid`, and the one a first
        // pass had as 273 — the cells' own width — which is a different number
        // that happens to be close.
        let tall = AttachmentMosaic.frames(sizes: sizes(0.5, 0.5), width: 550)
        #expect(tall[0].height == AttachmentMosaic.rowMaxHeight)
        #expect(tall[0].height == tall[1].height)
        // A landscape pair is shorter than the cap and both cells match the
        // taller of the two.
        let wide = AttachmentMosaic.frames(
            sizes: [CGSize(width: 1600, height: 900), CGSize(width: 1000, height: 1000)],
            width: 550
        )
        #expect(wide[0].height == 273)
        #expect(wide[0].height == wide[1].height)
    }

    // MARK: Covering

    @Test("A cell decodes wide enough to cover, never at the cell's own width")
    func coverWidth() {
        // A 16:9 picture in a 273 x 173 cell is scaled until its height covers,
        // which makes it 308 wide. Asking the CDN for 273 would fetch a
        // rendition that then has to be upscaled.
        let cell = CGSize(width: 273, height: 173)
        #expect(AttachmentMosaic.coverWidth(CGSize(width: 1600, height: 900), in: cell) == 308)
        // A portrait picture covers on width and needs no more than the cell.
        #expect(AttachmentMosaic.coverWidth(CGSize(width: 900, height: 1600), in: cell) == 273)
        // No dimensions on the wire is the cell's own width and nothing clever.
        #expect(AttachmentMosaic.coverWidth(nil, in: cell) == 273)
    }

    // MARK: Through the layout engine

    private func attachment(
        _ id: UInt64,
        name: String,
        type: String?,
        width: Int? = nil,
        height: Int? = nil
    ) -> WingcordCore.Attachment {
        WingcordCore.Attachment(
            id: AttachmentID(rawValue: id),
            filename: name,
            url: "https://cdn.discordapp.com/attachments/1/2/\(name)",
            proxyURL: "https://media.discordapp.net/attachments/1/2/\(name)",
            contentType: type,
            size: 1024,
            width: width,
            height: height
        )
    }

    private func slots(
        _ attachments: [WingcordCore.Attachment],
        width: CGFloat = 900
    ) -> [AttachmentSlot] {
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        let message = Message(
            id: MessageID(rawValue: 1 << 22),
            channelID: ChannelID(rawValue: 1),
            authorID: UserID(rawValue: 1),
            content: "",
            payload: MessagePayload(attachments: attachments)
        )
        let rows = TimelineLayoutEngine(presentationRevision: 1).layout(
            TimelineLayoutEngine.Input(
                items: [.message(TimelineMessage(message: message, flags: [.head, .tail]))],
                width: width,
                style: MessageTextStyle.current(),
                mentions: MentionContext(),
                channelName: "general",
                authors: [:],
                calendar: .current,
                settings: PresentationRevision.shared.timeline
            ),
            cache: &cache
        )
        guard case .message(let row)? = rows.first?.kind else { return [] }
        return row.attachments
    }

    @Test("Four screenshots are a grid, not a column four screens tall")
    func fourScreenshotsGrid() {
        let pictures = (1...4).map {
            attachment(UInt64($0), name: "shot\($0).png", type: "image/png", width: 2880, height: 1800)
        }
        let laid = slots(pictures)
        #expect(laid.count == 4)
        #expect(laid.allSatisfy { $0.cropsToFill })
        // Two rows, two columns, and the whole thing about 350 tall rather
        // than the four separate 350-tall pictures it used to be. 16:10 in a
        // 273-wide cell wants 171, which is inside the 173 ceiling.
        let top = laid.map(\.rect.minY).min() ?? 0
        let bottom = laid.map(\.rect.maxY).max() ?? 0
        #expect(bottom - top == 171 * 2 + AttachmentMosaic.gap)
        #expect(bottom - top <= AttachmentMosaic.maxHeight)
        #expect(Set(laid.map(\.rect.width)) == [273])
    }

    @Test("A lone picture is not cropped")
    func loneIsNotCropped() {
        let laid = slots([
            attachment(1, name: "shot.png", type: "image/png", width: 2880, height: 1800),
        ])
        #expect(laid.count == 1)
        #expect(laid[0].cropsToFill == false)
        #expect(laid[0].rect.width == 550)
    }

    @Test("A file between two pictures keeps its position in the array")
    func orderSurvivesPartitioning() {
        // **The lightbox indexes `posterWidths` against the message's own
        // attachment order** — see `AppModel.openMedia` — so sorting the
        // pictures to the front here would open the wrong one.
        let laid = slots([
            attachment(1, name: "a.png", type: "image/png", width: 800, height: 600),
            attachment(2, name: "notes.zip", type: "application/zip"),
            attachment(3, name: "b.png", type: "image/png", width: 800, height: 600),
        ])
        #expect(laid.count == 3)
        #expect(laid.map(\.kind) == [.image, .file, .image])
        // The two pictures are a pair on one row; the card is underneath both.
        #expect(laid[0].rect.minY == laid[2].rect.minY)
        #expect(laid[1].rect.minY >= laid[0].rect.maxY)
    }

    @Test("A voice note is never a grid cell")
    func voiceIsNotVisualMedia() {
        let laid = slots([
            attachment(1, name: "a.png", type: "image/png", width: 800, height: 600),
            WingcordCore.Attachment(
                id: AttachmentID(rawValue: 2),
                filename: "voice-message.ogg",
                url: "https://cdn.discordapp.com/attachments/1/2/voice-message.ogg",
                proxyURL: "https://media.discordapp.net/attachments/1/2/voice-message.ogg",
                contentType: "audio/ogg",
                size: 1024,
                waveform: "AAAA",
                durationSeconds: 12
            ),
        ])
        #expect(laid.map(\.kind) == [.image, .voice])
        // The picture is alone in its mosaic, so it keeps its own shape.
        #expect(laid[0].cropsToFill == false)
        #expect(laid[1].rect.height == TimelineMetrics.voiceNoteHeight)
    }
}
