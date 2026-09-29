import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Wingcord

/// The filmstrip: its decode, its frame budget, and its timeline lookup.
///
/// The fixtures are **real animated images**, written in-process with
/// `CGImageDestination` and read back through the same ImageIO path the app
/// uses. A hand-built `AnimatedImage` would test the arithmetic and skip the
/// only part that can actually be wrong about a container format — which delay
/// key it reports under, and whether the frames come back at all.
struct AnimatedImageTests {

    // MARK: Fixtures

    private static func solidImage(_ level: UInt8, side: Int = 32) -> CGImage {
        var pixels = [UInt8](repeating: level, count: side * side * 4)
        let context = CGContext(
            data: &pixels,
            width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    /// An animated GIF with `count` frames, each `delay` seconds long.
    private static func animatedGIF(count: Int, delay: Double) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, UTType.gif.identifier as CFString, count, nil
        )!
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        for index in 0..<count {
            let level = UInt8(truncatingIfNeeded: 20 + index * 7)
            CGImageDestinationAddImage(destination, solidImage(level), [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                    kCGImagePropertyGIFDelayTime: delay,
                ],
            ] as CFDictionary)
        }
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private static func stillPNG() -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, solidImage(128), nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    // MARK: Decoding

    @Test("An animated asset decodes to every frame, with its real duration")
    func decodesFrames() throws {
        let data = Self.animatedGIF(count: 8, delay: 0.05)
        let image = try #require(AnimatedImage.decode(data, maximumPixelSize: 32))
        #expect(image.frameCount == 8)
        let expected = 8 * 0.05
        let drift = abs(image.duration - expected)
        #expect(drift < 0.01)
    }

    @Test("A single-frame asset is not animated, and says so with nil")
    func stillReturnsNil() {
        // Load-bearing: nil is what sends the caller down the ordinary static
        // path, so a still avatar never pays for a filmstrip, a clock
        // subscription or a layer of its own.
        #expect(AnimatedImage.decode(Self.stillPNG(), maximumPixelSize: 32) == nil)
    }

    @Test("Bytes that are not an image decode to nil rather than crashing")
    func garbageReturnsNil() {
        #expect(AnimatedImage.decode(Data([0x00, 0x01, 0x02, 0x03]), maximumPixelSize: 32) == nil)
    }

    @Test("Frames are decoded at the requested size, not the source's")
    func decodesDownsampled() throws {
        let data = Self.animatedGIF(count: 4, delay: 0.1)
        let image = try #require(AnimatedImage.decode(data, maximumPixelSize: 16))
        // The whole memory argument rests on this: 33 KB a frame at 92px is only
        // true if the decode honours the drawn size instead of the source's.
        let widest = image.frames.map(\.width).max() ?? 0
        #expect(widest <= 16)
    }

    // MARK: The byte budget

    @Test("A long loop that fits keeps every frame")
    func longLoopKeepsEveryFrame() throws {
        // A hundred and forty-four frames at 16 pixels is 150 KB — the
        // forty-eight-frame cap this used to have would have kept a third.
        let data = Self.animatedGIF(count: 144, delay: 0.02)
        let image = try #require(AnimatedImage.decode(data, maximumPixelSize: 16))
        #expect(image.frameCount == 144)
        #expect(abs(image.shortestFrame - 0.02) < 0.001)
    }

    @Test("A loop past the byte budget is sampled down, never truncated")
    func longAssetIsSampled() throws {
        let count = 144
        let data = Self.animatedGIF(count: count, delay: 0.02)
        // Room for forty-eight frames of 16x16 and no more.
        let image = try #require(AnimatedImage.decode(
            data, maximumPixelSize: 16, byteBudget: 48 * 16 * 16 * 4
        ))

        #expect(image.frameCount <= 48)
        // **The cycle still takes as long as it should.** Truncating would end
        // the loop early and jump; sampling keeps the duration and lets the kept
        // frames absorb the time of the dropped ones.
        let expected = Double(count) * 0.02
        let drift = abs(image.duration - expected)
        #expect(drift < 0.05)
    }

    @Test("Sampling keeps the first frame, stays in order, and never repeats")
    func samplingIsWellFormed() {
        let indices = AnimatedImage.sampleIndices(count: 500, budget: 48)
        #expect(indices.first == 0)
        #expect(indices.count <= 48)
        let isSorted = indices == indices.sorted()
        #expect(isSorted)
        // A repeated index would give some frame a zero-length slot, which the
        // lookup below would then be unable to ever land on.
        let unique = Set(indices).count
        #expect(unique == indices.count)
    }

    @Test("Sampling spans the WHOLE asset, which truncation does not")
    func samplingSpansTheAsset() {
        // The property that actually separates sampling from truncation.
        //
        // Duration does not: with `[0..<48]` the last kept frame simply absorbs
        // every dropped delay after it, so the cycle still totals the right
        // length — it just spends two thirds of that length frozen on frame 47.
        // Coverage is what catches it, and this assertion was written only after
        // watching the duration-based one pass against a truncating build.
        let count = 500
        let budget = 48
        let indices = AnimatedImage.sampleIndices(count: count, budget: budget)
        let stride = count / budget
        #expect((indices.last ?? 0) >= count - stride - 1)
    }

    @Test("A short asset is kept whole")
    func shortAssetIsUntouched() {
        let indices = AnimatedImage.sampleIndices(count: 6, budget: 48)
        #expect(indices == [0, 1, 2, 3, 4, 5])
    }

    // MARK: The timeline

    @Test("Lookup lands on the right frame, and wraps")
    func lookupWraps() throws {
        let data = Self.animatedGIF(count: 4, delay: 0.25)   // 1.0s total
        let image = try #require(AnimatedImage.decode(data, maximumPixelSize: 16))

        #expect(image.index(at: 0.0) == 0)
        #expect(image.index(at: 0.3) == 1)
        #expect(image.index(at: 0.6) == 2)
        #expect(image.index(at: 0.9) == 3)
        // Second cycle: the same phase, the same frame. This is what lets the
        // clock keep counting through a scroll and resume in step.
        #expect(image.index(at: 1.3) == 1)
        #expect(image.index(at: 41.3) == 1)
    }

    @Test("A negative time is still a valid phase")
    func negativeTimeWraps() throws {
        // The clock starts at zero and a view can be told a time before its own
        // first tick. Landing out of bounds here would trap on an array index.
        let data = Self.animatedGIF(count: 4, delay: 0.25)
        let image = try #require(AnimatedImage.decode(data, maximumPixelSize: 16))
        let index = image.index(at: -0.3)
        #expect(index >= 0)
        #expect(index < image.frameCount)
    }

    @Test("The reported cost is the real resident size")
    func costIsReal() throws {
        let data = Self.animatedGIF(count: 6, delay: 0.1)
        let image = try #require(AnimatedImage.decode(data, maximumPixelSize: 32))
        // The cache's byte ceiling is only a ceiling if this is honest.
        var summed = 0
        for frame in image.frames { summed += frame.height * frame.bytesPerRow }
        #expect(image.cost == summed)
        #expect(image.cost > 0)
    }
}
