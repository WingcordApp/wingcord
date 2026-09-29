import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Wingcord

/// A one-shot asset inside a slot longer than itself.
///
/// **The profile-effect catalogue's `duration` is the SLOT; the APNG's own is
/// the playback, and they are not the same number.** SpongeBob's entry gives him
/// 6000 ms and the file is 4125 ms with `acTL num_plays: 1`. Fed through the
/// looping lookup, the last 1875 ms of the slot replayed the opening 1875 ms of
/// the animation — he walked on, flew away, and walked on again before being cut
/// off mid-stride. Measured off the real asset, not guessed.
@Suite("One-shot playback")
struct OneShotPlaybackTests {

    /// Four frames of `delays` seconds each, as a real GIF the decoder reads.
    private func source(delays: [Double]) throws -> FilmSource {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data, UTType.gif.identifier as CFString, delays.count, nil
        ))
        for (index, delay) in delays.enumerated() {
            let context = try #require(CGContext(
                data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(gray: CGFloat(index) / 4, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                ],
            ] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return try #require(FilmSource(data: data as Data, maximumPixelSize: 4))
    }

    @Test("A one-shot asset holds its last frame instead of starting over")
    func holdsTheLastFrame() throws {
        let film = try source(delays: [0.25, 0.25, 0.25, 0.25])
        // Inside its own duration it plays normally.
        #expect(film.index(at: 0.1, looping: false) == 0)
        #expect(film.index(at: 0.6, looping: false) == 2)
        // **Past the end it holds**, for as long as the slot runs on.
        #expect(film.index(at: 1.2, looping: false) == 3)
        #expect(film.index(at: 5.9, looping: false) == 3)
    }

    @Test("A looping asset still wraps")
    func loopingStillWraps() throws {
        let film = try source(delays: [0.25, 0.25, 0.25, 0.25])
        // The other half of the same rule: a layer Discord marks `loop: true`
        // carries `num_plays: 0` and must keep going.
        #expect(film.index(at: 1.1, looping: true) == 0)
        #expect(film.index(at: 2.6, looping: true) == 2)
    }

    @Test("SpongeBob's own numbers, as captured")
    func spongebobSlot() throws {
        // The catalogue: 6000 ms, loop false. The APNG: 4125 ms — here four
        // frames that add up to it, as a GIF's centiseconds can.
        let film = try source(delays: [1.03, 1.03, 1.03, 1.04])
        #expect(abs(film.duration - 4.13) < 0.001)
        // At 5.0 s the slot is still running and the looping lookup would be
        // most of a second into a *second* performance — frame 0.
        #expect(film.index(at: 5.0, looping: true) == 0)
        // One-shot holds the final frame instead, which is what the reader sees
        // on Discord: he is gone, and stays gone.
        #expect(film.index(at: 5.0, looping: false) == 3)
    }
}
