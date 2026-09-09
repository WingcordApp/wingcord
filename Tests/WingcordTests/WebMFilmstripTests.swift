import CoreGraphics
import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// The pixels: VP9 through VideoToolbox, alpha out of the second bitstream, and
/// the filmstrip the rest of the app draws.
@Suite("WebM filmstrip")
struct WebMFilmstripTests {

    /// One frame's bytes, as premultiplied BGRA.
    private struct Frame {
        let bytes: Data
        let rowBytes: Int

        init(_ image: CGImage) throws {
            bytes = try #require(image.dataProvider?.data as Data?)
            rowBytes = image.bytesPerRow
        }

        /// Blue, green, red, alpha — the order they sit in memory.
        func pixel(_ x: Int, _ y: Int) -> (b: Int, g: Int, r: Int, a: Int) {
            let base = y * rowBytes + x * 4
            return (Int(bytes[base]), Int(bytes[base + 1]),
                    Int(bytes[base + 2]), Int(bytes[base + 3]))
        }
    }

    private func filmstrip(
        _ data: Data = WebMFixtures.vp9Alpha,
        maximumPixelSize: Int = WebMFixtures.width,
        byteBudget: Int = AnimatedImage.byteBudget
    ) throws -> AnimatedImage {
        try #require(
            WebMFilmstrip.decode(data, maximumPixelSize: maximumPixelSize, byteBudget: byteBudget)
        )
    }

    // MARK: The picture

    @Test("The alpha channel is the second bitstream's luma, at full range")
    func alphaComesFromTheSecondStream() throws {
        // The fixture's alpha ramps from nothing on the first row to opaque on
        // the last. Everything that can go wrong with a WebM's alpha shows up
        // here: dropped entirely (all 255), read as a plane of the first stream
        // (garbage), inverted (the ramp runs the other way), or range-converted
        // on the way out of VideoToolbox (0 and 255 never reached).
        let film = try filmstrip()
        let frame = try Frame(film.frames[0])
        #expect(frame.pixel(0, 0).a == 0)
        #expect(frame.pixel(WebMFixtures.width - 1, WebMFixtures.height - 1).a == 255)

        var previous = -1
        for y in 0..<WebMFixtures.height {
            let alpha = frame.pixel(64, y).a
            #expect(alpha >= previous)
            previous = alpha
        }
        // A rescaled 16-235 plane cannot span the ends; this one does, because
        // the pixel format asked for matches the stream's own range.
        #expect(previous == 255)
    }

    @Test("The frames are premultiplied, which is what every draw path wants")
    func framesArePremultiplied() throws {
        let film = try filmstrip()
        let frame = try Frame(film.frames[0])
        // The top row is fully transparent, so premultiplied colour there is
        // zero however bright the source was — and the source was a red ramp.
        for x in stride(from: 0, to: WebMFixtures.width, by: 11) {
            let pixel = frame.pixel(x, 0)
            #expect(pixel.r == 0 && pixel.g == 0 && pixel.b == 0)
        }
        let info = film.frames[0].bitmapInfo
        #expect(
            info.intersection(CGBitmapInfo(rawValue: CGBitmapInfo.alphaInfoMask.rawValue))
                == CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        #expect(info.contains(.byteOrder32Little))
    }

    @Test("Colour comes back the way it went in")
    func colourSurvivesTheConversion() throws {
        // The fixture's red ramps across the width. On the bottom row it is
        // fully opaque, so premultiplication leaves it alone and the values are
        // the conversion's own answer — a wrong matrix or a swapped permute map
        // moves them by tens.
        let film = try filmstrip()
        let frame = try Frame(film.frames[0])
        let bottom = WebMFixtures.height - 1
        let left = frame.pixel(0, bottom)
        let right = frame.pixel(WebMFixtures.width - 1, bottom)
        #expect(left.r < 12)
        #expect(right.r > 240)
        // Red, and only red.
        #expect(right.g < 12 && right.b < 12)
        // Monotonic across the row.
        var previous = -1
        for x in 0..<WebMFixtures.width {
            let red = frame.pixel(x, bottom).r
            #expect(red >= previous - 1)
            previous = red
        }
    }

    // MARK: The timeline

    @Test("Every frame is kept, in order, over the loop the container declares")
    func timeline() throws {
        let film = try filmstrip()
        #expect(film.frameCount == WebMFixtures.frameCount)
        #expect(abs(film.duration - 0.25) < 0.002)
        #expect(film.ends == film.ends.sorted())
        // Each frame shows for a twelfth of a second.
        #expect(film.index(at: 0) == 0)
        #expect(film.index(at: 0.1) == 1)
        #expect(film.index(at: 0.2) == 2)
        // And it loops rather than running off the end.
        #expect(film.index(at: 0.25) == 0)
    }

    @Test("A budget too small for the loop drops frames without shortening it")
    func budgetDropsFramesAndKeepsTheClock() throws {
        // 128x64 is 32 KB a frame, so this affords two of the three. The frame
        // that is dropped hands its time to the one before it — a filmstrip
        // that truncated instead would loop in two thirds of the time and drift
        // out of step with everything else on the clock.
        let film = try filmstrip(byteBudget: 64 * 1024)
        #expect(film.frameCount == 2)
        #expect(abs(film.duration - 0.25) < 0.002)
    }

    @Test("Frames come back at the size asked for, and are never upscaled")
    func sizing() throws {
        let half = try filmstrip(maximumPixelSize: 64)
        #expect(half.frames[0].width == 64)
        #expect(half.frames[0].height == 32)

        // 128x64 asked for at 400 is still 128x64: a decode cannot invent
        // detail, and a surface that over-asks would pay for it in memory.
        let asked = try filmstrip(maximumPixelSize: 400)
        #expect(asked.frames[0].width == WebMFixtures.width)
        #expect(asked.frames[0].height == WebMFixtures.height)
    }

    // MARK: What it refuses

    @Test("A single-frame WebM is a still, which is nil")
    func singleFrameIsAStill() {
        #expect(
            WebMFilmstrip.decode(WebMFixtures.vp9SingleFrame, maximumPixelSize: 128) == nil
        )
    }

    @Test("A codec that is not VP9 is refused rather than attempted")
    func refusesOtherCodecs() {
        // The demuxer reads this file perfectly well — see `WebMDemuxerTests` —
        // and the filmstrip still refuses it, because the alpha convention, the
        // pixel format and the conversion are checked against VP9 and nothing
        // else.
        #expect(WebMFilmstrip.decode(WebMFixtures.vp8, maximumPixelSize: 128) == nil)
    }

    @Test("Anything that is not a WebM at all is refused")
    func refusesGarbage() {
        #expect(WebMFilmstrip.decode(Data(), maximumPixelSize: 128) == nil)
        #expect(WebMFilmstrip.decode(Data(repeating: 0x7F, count: 8192), maximumPixelSize: 128) == nil)
    }

    @Test("A truncated download costs frames, never a crash")
    func survivesTruncation() {
        let whole = WebMFixtures.vp9Alpha
        for length in stride(from: 1, through: whole.count, by: 13) {
            if let film = WebMFilmstrip.decode(whole.prefix(length), maximumPixelSize: 32) {
                #expect(film.frameCount > 1)
            }
        }
    }

    // MARK: The wiring

    @Test("Only a WebM takes the WebM path")
    func handles() {
        #expect(WebMFilmstrip.handles(URL(string: "https://example.com/a/asset.webm")!))
        #expect(!WebMFilmstrip.handles(URL(string: "https://example.com/a/static.png")!))
        #expect(!WebMFilmstrip.handles(URL(string: "https://example.com/a/sticker.json")!))
        #expect(!WebMFilmstrip.handles(URL(string: "https://example.com/a/icon.gif")!))
    }

    @Test("A nameplate's moving form is the asset beside its still")
    func animatedNameplateURL() throws {
        let plate = Nameplate(asset: "nameplates/dark_roses/1526656194121568256/")
        let still = try #require(plate.artworkURL)
        let animated = try #require(plate.animatedArtworkURL)
        #expect(
            animated.absoluteString
                == "https://cdn.discordapp.com/assets/collectibles/"
                + "nameplates/dark_roses/1526656194121568256/asset.webm"
        )
        // The two are siblings under one path prefix, and only one of them
        // takes the filmstrip path.
        #expect(still.deletingLastPathComponent() == animated.deletingLastPathComponent())
        #expect(WebMFilmstrip.handles(animated))
        #expect(!WebMFilmstrip.handles(still))
        #expect(CDN.animatedNameplate(asset: "") == nil)
    }

    @Test("The roster and the composed surfaces ask for one decode, not two")
    func filmKeyMatchesTheDecorationView() {
        // `AnimatedDecoration` builds its own key from the same three inputs;
        // the store's slot is the URL, the pixel size AND the budget, so a
        // surface computing any of the three differently gets a second decode
        // of the same asset and a second copy of it resident.
        let url = URL(string: "https://cdn.discordapp.com/a/asset.webm")!
        let key = NameplateFilm.key(url: url, width: 235, scale: 2)
        #expect(key.url == url)
        #expect(key.maximumPixelSize == 470)
        #expect(key.byteBudget == NameplateFilm.byteBudget)
        // A scale below one is the unset case, never a shrink.
        #expect(NameplateFilm.key(url: url, width: 235, scale: 0).maximumPixelSize == 235)
    }

    @Test("The width a plate is fetched at is the width it is drawn at")
    func fetchWidthMatchesTheDrawnRect() {
        // The trap `TimelineImageRequests` exists for, one layer down: the
        // painter peeks at a slot keyed on a size, and a size that does not
        // match the rectangle the strip lands in is either a soft plate or a
        // second decode nobody asked for.
        let row = CGRect(x: 0, y: 0, width: Proportions.memberColumnIdeal,
                         height: MemberRowGeometry.rowHeight)
        let art = MemberRowGeometry.nameplateArtRect(
            in: MemberRowGeometry.plateRect(in: row),
            imagePixelSize: CGSize(width: 672, height: 126)
        )
        #expect(abs(art.width - MemberRowGeometry.nameplateArtWidth) <= 1)
    }
}
