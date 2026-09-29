import CoreGraphics
import Foundation
import ImageIO
import QuartzCore
import Testing
import UniformTypeIdentifiers
@testable import Wingcord

/// The player behind every moving picture on a layer, driven with real files.
///
/// **The report**: a "GIF" of one frame drew as an empty plate in the
/// transcript. They are common — a caption meme saved as a GIF so it can be
/// favourited, a still WebP under a `.gif` name — and the painter leaves a
/// moving picture's box to its layer, which gave up on anything under two
/// frames.
@MainActor
@Suite("Film player")
struct FilmPlayerTests {

    /// A GIF of `count` flat frames, written where the player can fetch it.
    /// A fresh name each time, so no test finds another's frames in memory.
    private func gif(frames count: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "film-\(UUID().uuidString).gif")
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, count, nil
        ))
        for index in 0..<count {
            let context = try #require(CGContext(
                data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            let level = CGFloat(index + 1) / CGFloat(count + 1)
            context.setFillColor(CGColor(red: level, green: level, blue: level, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05],
            ] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// Waits for a load, bounded so a regression fails rather than hangs.
    private func settle(until done: () -> Bool) async {
        for _ in 0..<150 where !done() {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("A layer its owner left empty draws a one-frame GIF as a still")
    func drawsTheStill() async throws {
        let url = try gif(frames: 1)
        let player = FilmPlayer(key: .init(url: url, maximumPixelSize: 64), drawsStills: true)
        defer { player.tearDown() }
        await settle { player.layer.contents != nil }
        #expect(player.layer.contents != nil)
        // A still is shown, not played: nothing on the render server runs.
        #expect(player.layer.animationKeys()?.isEmpty ?? true)
    }

    @Test("An owner that draws its own still is told there is nothing to play")
    func reportsAStill() async throws {
        let url = try gif(frames: 1)
        let player = FilmPlayer(key: .init(url: url, maximumPixelSize: 64))
        defer { player.tearDown() }
        var reports: [Bool] = []
        player.onPlayback = { reports.append($0) }
        await settle { !reports.isEmpty }
        #expect(reports == [false])
        #expect(player.layer.contents == nil)
    }

    @Test("A still shown once is shown again from memory, with no fetch")
    func stillIsRemembered() async throws {
        let url = try gif(frames: 1)
        let key = FilmPlayer.Key(url: url, maximumPixelSize: 64)
        let first = FilmPlayer(key: key, drawsStills: true)
        await settle { first.layer.contents != nil }
        first.tearDown()
        // The row scrolls back: a new layer, and the file is gone.
        try FileManager.default.removeItem(at: url)
        let second = FilmPlayer(key: key, drawsStills: true)
        defer { second.tearDown() }
        #expect(second.layer.contents != nil)
    }

    /// **A loop already held is shown from `init`**, before any owner can have
    /// attached a listener. Dropped there, `AnimatedDecoration` never heard
    /// that frames were up and left its still under the film — two copies of
    /// a decoration on every show after the first.
    @Test("A loop shown from memory still tells an owner who starts listening late")
    func lateListenerHearsTheCachedLoop() async throws {
        let url = try gif(frames: 3)
        let key = FilmPlayer.Key(url: url, maximumPixelSize: 64)
        let first = FilmPlayer(key: key)
        var firstReports: [Bool] = []
        first.onPlayback = { firstReports.append($0) }
        await settle { firstReports.contains(true) && FilmFrames.shared.cached(key) != nil }
        first.tearDown()

        let second = FilmPlayer(key: key)
        defer { second.tearDown() }
        var reports: [Bool] = []
        second.onPlayback = { reports.append($0) }
        #expect(reports == [true])
    }
}
