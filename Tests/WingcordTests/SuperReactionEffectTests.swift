import AppKit
import Foundation
import Lottie
import Testing
import WingcordCore
@testable import Wingcord

/// The eighteen bundled effects, and the canvas they play over.
///
/// **A bundled file nobody opens is a file that can be wrong for ever.** Each
/// effect is read the way the app reads it — decompressed, recoloured, fitted,
/// parsed — and then handed to the Core Animation engine, which is the engine
/// that makes an effect cost the main thread nothing per frame. An effect that
/// engine refuses still plays, on the main thread's engine, and this suite is
/// where that would first be seen.
@MainActor
@Suite("Super reaction effects")
struct SuperReactionEffectTests {

    /// The one effect the Core Animation engine cannot render.
    ///
    /// **StarBlast's sparks are strokes mirrored with a separate x and y scale**
    /// — `-100 %` by `100 %` — which that engine has no way to express. The
    /// app's `.automatic` configuration plays it on the main thread's engine
    /// instead, so it is also the one effect that costs main-thread time while
    /// it runs. Measured, not assumed: the other seventeen set up with no
    /// issue at all.
    static let mainThreadOnly: Set<String> = ["StarBlast"]

    @Test("Every effect is bundled, parses, and plays", arguments: SuperReactionEffect.names.indices)
    func effectPlays(_ index: Int) async throws {
        let name = SuperReactionEffect.names[index]
        let played = try await Self.play(index, pictureWidth: 64, pictureHeight: 64)
        #expect(played.size == CGSize(width: 300, height: 300))
        #expect(played.framerate == 60)
        // The engine sets its timeline up the first time the layer displays and
        // reports there anything it cannot render.
        if Self.mainThreadOnly.contains(name) {
            #expect(!played.issues.isEmpty, "\(name) now plays on the Core Animation engine")
            #expect(played.automaticEngine == .mainThread)
        } else {
            #expect(played.issues.isEmpty, "\(name): \(played.issues)")
        }
        // Every picture it draws is the emoji, in Discord's 128-unit slot —
        // some draw it in a dozen layers at once, and all of them ask for the
        // one asset.
        #expect(!played.slots.isEmpty)
        #expect(played.slots.allSatisfy { $0 == CGSize(width: 128, height: 128) })
    }

    @Test("A wide emoji's slot keeps the emoji's shape", arguments: [0, 8, 17])
    func wideEmojiIsFitted(_ index: Int) async throws {
        let played = try await Self.play(index, pictureWidth: 128, pictureHeight: 64)
        #expect(!played.slots.isEmpty)
        #expect(played.slots.allSatisfy { $0 == CGSize(width: 128, height: 64) })
    }

    /// Loads an effect the way the app does and puts it on the Core Animation
    /// engine, reporting what it asked for and what it complained about.
    private static func play(
        _ index: Int,
        pictureWidth: Int,
        pictureHeight: Int
    ) async throws -> (
        size: CGSize, framerate: Double, issues: [String], slots: [CGSize],
        automaticEngine: RenderingEngine?
    ) {
        let animation = try #require(
            await SuperReactionArt.animation(
                index: index, accent: 0xD3_8E_87,
                pictureWidth: pictureWidth, pictureHeight: pictureHeight
            ),
            "\(SuperReactionEffect.names[index]) did not load"
        )
        let issues = IssueLog()
        let logger = LottieLogger(
            assert: { condition, message, _, _ in
                if !condition() { issues.record(message()) }
            },
            assertionFailure: { message, _, _ in issues.record(message()) },
            warn: { message, _, _ in issues.record(message()) }
        )
        let provider = RecordingImageProvider()
        let layer = LottieAnimationLayer(
            animation: animation,
            imageProvider: provider,
            configuration: LottieConfiguration(renderingEngine: .coreAnimation),
            logger: logger
        )
        layer.frame = CGRect(x: 0, y: 0, width: 142.5, height: 142.5)
        layer.play()
        layer.animationLayer?.display()

        // And what the app's own configuration settles on for it.
        let automatic = LottieAnimationLayer(
            animation: animation,
            imageProvider: RecordingImageProvider(),
            configuration: LottieConfiguration(renderingEngine: .automatic),
            logger: LottieLogger(warn: { _, _, _ in })
        )
        automatic.frame = layer.frame
        automatic.play()
        automatic.animationLayer?.display()

        return (
            animation.size, animation.framerate, issues.messages, provider.slots,
            automatic.currentRenderingEngine
        )
    }

    @Test("An effect is drawn the right way up over the transcript")
    func canvasIsGeometryFlipped() {
        // **Every effect is authored top-left down**, as Lottie's engines
        // assume, and they are added as sublayers of the canvas's own layer —
        // so they are upright only because a flipped, layer-backed view flips
        // its layer's geometry. Pinned, because a canvas that stopped being
        // flipped would still draw its rows correctly and turn every effect on
        // its head.
        let canvas = TimelineCanvasView(style: MessageTextStyle.current())
        #expect(canvas.isFlipped)
        #expect(canvas.layer?.isGeometryFlipped == true)
    }

    @Test("The shake is Discord's keyframes, and it ends")
    func shake() throws {
        let start = try #require(SuperReactionShake.offset(at: 0))
        #expect(start.dx == 1 && start.dy == 1 && start.radians == 0)
        // Halfway is the 50 % stop exactly: translate(-1px, 1px) rotate(-1deg).
        let middle = try #require(SuperReactionShake.offset(at: 0.25))
        #expect(abs(middle.dx - -1) < 1e-9 && abs(middle.dy - 1) < 1e-9)
        #expect(abs(middle.radians - -.pi / 180) < 1e-9)
        #expect(SuperReactionShake.offset(at: 0.5) == nil)
        #expect(SuperReactionShake.offset(at: -0.1) == nil)
    }

    @Test("CSS ease is the curve it names")
    func ease() {
        #expect(abs(SuperReactionShake.ease(0)) < 1e-6)
        #expect(abs(SuperReactionShake.ease(1) - 1) < 1e-6)
        // `ease` is front-loaded: well past half its travel at half its time.
        // 0.8024 is cubic-bezier(0.25, 0.1, 0.25, 1) at x = 0.5.
        #expect(abs(SuperReactionShake.ease(0.5) - 0.8024) < 1e-3)
    }

    @Test("The picker switch's mark parses, both halves of it")
    func glyphParses() throws {
        // `VectorPath` answers nil for anything malformed, and a nil outline
        // draws nothing — a switch with no mark on it and no failure anywhere.
        let face = try #require(VectorPath.parse(SuperReactionGlyph.face))
        let sparkles = try #require(VectorPath.parse(SuperReactionGlyph.sparkles))
        // Both on the 24-unit grid Discord draws the icon on — to within the
        // hundredth by which Discord's own edge sparkles bulge past it.
        let grid = CGRect(x: 0, y: 0, width: 24, height: 24).insetBy(dx: -0.01, dy: -0.01)
        for path in [face, sparkles] {
            #expect(grid.contains(path.boundingBoxOfPath), "\(path.boundingBoxOfPath)")
        }
    }

    @Test("A Unicode emoji becomes a square picture with its ink in it")
    func glyphPicture() throws {
        let image = try #require(SuperReactionArt.glyphImage("🔥", pixels: 64))
        #expect(image.width == 64 && image.height == 64)
        // Something was drawn: a transparent square here would hand every
        // Unicode super reaction's effect an empty emoji.
        let data = try #require(image.dataProvider?.data as Data?)
        #expect(data.contains { $0 != 0 })
    }
}

/// Answers every image asset with a blank square, and remembers each slot it
/// was asked to fill.
private final class RecordingImageProvider: AnimationImageProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [CGSize] = []
    private let blank: CGImage? = CGContext(
        data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )?.makeImage()

    var cacheEligible: Bool { false }

    func imageForAsset(asset: ImageAsset) -> CGImage? {
        lock.withLock { asked.append(CGSize(width: asset.width, height: asset.height)) }
        return blank
    }

    var slots: [CGSize] { lock.withLock { asked } }
}

/// Collects what a `LottieLogger` reports, from whatever thread it reports on.
private final class IssueLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func record(_ message: String) {
        lock.withLock { stored.append(message) }
    }

    var messages: [String] { lock.withLock { stored } }
}
