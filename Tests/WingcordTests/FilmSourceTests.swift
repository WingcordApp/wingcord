import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Wingcord

/// The decoder moving pictures play from: every frame, at the asset's own
/// timing and the drawn size.
///
/// **The report**: stickers at a fraction of their frame rate, GIFs choppy, and
/// every loop past forty-eight frames sampled down to forty-eight.
@Suite("Film source")
struct FilmSourceTests {

    /// A GIF of `count` frames, each a flat grey a step lighter than the last,
    /// alternating 20 ms and 60 ms delays.
    private func gif(frames count: Int, side: Int = 64) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data, UTType.gif.identifier as CFString, count, nil
        ))
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        for index in 0..<count {
            let context = try #require(CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            let level = CGFloat(index % 200) / 200
            context.setFillColor(CGColor(red: level, green: level, blue: level, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let delay = index.isMultiple(of: 2) ? 0.02 : 0.06
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                ],
            ] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test("Every frame, past the old forty-eight")
    func everyFrame() async throws {
        let source = try #require(FilmSource(data: try gif(frames: 120), maximumPixelSize: 64))
        #expect(source.frameCount == 120)
        let frames = await withCheckedContinuation { continuation in
            source.decodeAll { continuation.resume(returning: $0) }
        }
        #expect(frames?.count == 120)
    }

    @Test("At the asset's own timing")
    func ownTiming() throws {
        let source = try #require(FilmSource(data: try gif(frames: 4), maximumPixelSize: 64))
        #expect(abs(source.duration - 0.16) < 0.001)
        #expect(abs(source.shortestFrame - 0.02) < 0.001)
        #expect(source.index(at: 0.01) == 0)
        #expect(source.index(at: 0.03) == 1)
        #expect(source.index(at: 0.09) == 2)
        // Looping: one cycle later is the same frame.
        #expect(source.index(at: 0.16 + 0.03) == 1)
    }

    @Test("At the size it is drawn, not the size it was made")
    func drawnSize() throws {
        let source = try #require(FilmSource(data: try gif(frames: 3, side: 256), maximumPixelSize: 64))
        #expect(source.firstFrame.width == 64)
        #expect(source.bytesPerFrame == source.firstFrame.height * source.firstFrame.bytesPerRow)
    }

    @Test("A still is not a film")
    func stillIsNotAFilm() throws {
        #expect(FilmSource(data: try gif(frames: 1), maximumPixelSize: 64) == nil)
    }
}
