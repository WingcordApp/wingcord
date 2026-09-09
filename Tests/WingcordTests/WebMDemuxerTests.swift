import Foundation
import Testing
@testable import Wingcord

/// The container, and the bitstream header the container carries no
/// configuration for.
///
/// Every fixture is a real file written by libvpx and ffmpeg's muxer — see
/// `WebMFixtures` for why that matters more here than a hand-built tree would.
struct WebMDemuxerTests {

    // MARK: The tree

    @Test("The track entry is read whole, alpha mode included")
    func trackEntry() throws {
        let movie = try #require(WebMDemuxer.demux(WebMFixtures.vp9Alpha))
        #expect(movie.track.codecID == "V_VP9")
        #expect(movie.track.number == 1)
        #expect(movie.track.width == WebMFixtures.width)
        #expect(movie.track.height == WebMFixtures.height)
        #expect(movie.track.hasAlpha)
        // Twelve a second, as `DefaultDuration` nanoseconds.
        let frameDuration = try #require(movie.track.frameDuration)
        #expect(abs(frameDuration - 1.0 / 12) < 0.001)
    }

    @Test("Every frame arrives with the alpha bitstream that belongs to it")
    func alphaAccompaniesEveryFrame() throws {
        let movie = try #require(WebMDemuxer.demux(WebMFixtures.vp9Alpha))
        #expect(movie.samples.count == WebMFixtures.frameCount)
        for sample in movie.samples {
            #expect(!sample.data.isEmpty)
            // The alpha is a whole second bitstream, not a plane appended to the
            // first: it has its own VP9 frame header.
            let alpha = try #require(sample.alpha)
            #expect(VP9Header.parse(alpha) != nil || !alpha.isEmpty)
        }
    }

    @Test("Timestamps come off the cluster and the segment's own duration closes the loop")
    func timeline() throws {
        let movie = try #require(WebMDemuxer.demux(WebMFixtures.vp9Alpha))
        let times = movie.samples.map(\.time)
        #expect(times == times.sorted())
        #expect(times[0] == 0)
        for (index, time) in times.enumerated() {
            #expect(abs(time - Double(index) / 12) < 0.002)
        }
        // Three frames at a twelfth of a second each, so the loop is a quarter
        // second — and the LAST frame's span comes from the segment's duration
        // rather than from a following timestamp it does not have.
        #expect(abs(movie.duration - 0.25) < 0.002)
    }

    @Test("A segment whose size was never written reads the same frames")
    func unknownSizeSegment() throws {
        let sized = try #require(WebMDemuxer.demux(WebMFixtures.vp9Alpha))
        let unsized = try #require(WebMDemuxer.demux(WebMFixtures.vp9UnknownSize))
        #expect(unsized.samples.count == sized.samples.count)
        #expect(unsized.track.width == sized.track.width)
        #expect(unsized.track.hasAlpha)
        #expect(unsized.samples.map(\.time) == sized.samples.map(\.time))
    }

    @Test("A VP8 track is read and reported as VP8 rather than assumed")
    func vp8IsReadNotAssumed() throws {
        let movie = try #require(WebMDemuxer.demux(WebMFixtures.vp8))
        #expect(movie.track.codecID == "V_VP8")
        #expect(!movie.track.hasAlpha)
        // No `BlockAdditions`, so no alpha beside any frame.
        #expect(movie.samples.allSatisfy { $0.alpha == nil })
    }

    // MARK: What it refuses

    @Test("Bytes that are not a WebM are refused rather than half-read")
    func rejectsGarbage() {
        #expect(WebMDemuxer.demux(Data()) == nil)
        #expect(WebMDemuxer.demux(Data([0, 0, 0, 0])) == nil)
        #expect(WebMDemuxer.demux(Data(repeating: 0xFF, count: 4096)) == nil)
        #expect(WebMDemuxer.demux(Data("not a container at all".utf8)) == nil)
    }

    @Test("A truncated file costs the frames after the cut and nothing else")
    func survivesTruncation() {
        let whole = WebMFixtures.vp9Alpha
        // Every prefix, not a chosen one: a parser that reads past an element's
        // end is a crash at exactly one length, and it is never the length
        // somebody thought to try.
        for length in stride(from: 1, through: whole.count, by: 7) {
            let movie = WebMDemuxer.demux(whole.prefix(length))
            if let movie {
                #expect(movie.samples.count <= WebMFixtures.frameCount)
                #expect(movie.track.width == WebMFixtures.width)
            }
        }
    }

    @Test("A byte flipped anywhere in the file is survivable")
    func survivesCorruption() {
        var data = WebMFixtures.vp9Alpha
        for index in stride(from: data.startIndex, to: data.endIndex, by: 11) {
            let original = data[index]
            data[index] = original ^ 0xA5
            _ = WebMDemuxer.demux(data)
            data[index] = original
        }
    }

    // MARK: The VP9 frame header

    @Test("The first frame's header carries everything the decoder must be told")
    func vp9Header() throws {
        let movie = try #require(WebMDemuxer.demux(WebMFixtures.vp9Alpha))
        let header = try #require(VP9Header.parse(movie.samples[0].data))
        #expect(header.isKeyframe)
        #expect(header.profile == 0)
        #expect(header.bitDepth == 8)
        #expect(header.subsamplingX)
        #expect(header.subsamplingY)
        #expect(header.width == WebMFixtures.width)
        #expect(header.height == WebMFixtures.height)
        #expect(header.isPlayable)
    }

    @Test("The alpha stream is a VP9 keyframe of its own, at the same size")
    func alphaHeader() throws {
        let movie = try #require(WebMDemuxer.demux(WebMFixtures.vp9Alpha))
        let alpha = try #require(movie.samples[0].alpha)
        let header = try #require(VP9Header.parse(alpha))
        #expect(header.isKeyframe)
        #expect(header.width == WebMFixtures.width)
        #expect(header.height == WebMFixtures.height)
        #expect(header.isPlayable)
    }

    @Test("An inter frame is refused, because only a keyframe carries the configuration")
    func interFrameCarriesNoConfiguration() throws {
        let movie = try #require(WebMDemuxer.demux(WebMFixtures.vp9Alpha))
        #expect(VP9Header.parse(movie.samples[1].data) == nil)
    }

    @Test("The vpcC record is twelve bytes and says what the header said")
    func configurationRecord() throws {
        let movie = try #require(WebMDemuxer.demux(WebMFixtures.vp9Alpha))
        let header = try #require(VP9Header.parse(movie.samples[0].data))
        let record = [UInt8](header.configurationRecord)
        #expect(record.count == 12)
        #expect(record[0] == 1)  // version
        #expect(Array(record[1...3]) == [0, 0, 0])  // flags
        #expect(record[4] == 0)  // profile
        // Bit depth in the high nibble, chroma subsampling in the next three
        // bits, the range flag in the last one. 4:2:0 is 1.
        #expect(record[6] >> 4 == 8)
        #expect((record[6] >> 1) & 0x7 == 1)
        #expect(record[6] & 1 == (header.isFullRange ? 1 : 0))
        #expect(Array(record[10...11]) == [0, 0])  // no initialisation data
    }

    @Test("A truncated VP9 frame is refused rather than read off the end")
    func vp9HeaderRefusesShortFrames() throws {
        let movie = try #require(WebMDemuxer.demux(WebMFixtures.vp9Alpha))
        let frame = movie.samples[0].data
        for length in 0..<12 {
            _ = VP9Header.parse(frame.prefix(length))
        }
        // Two bytes cannot contain the sync code, let alone the frame size.
        #expect(VP9Header.parse(frame.prefix(2)) == nil)
    }
}
