import CoreGraphics
import Foundation
import Lottie
import QuartzCore

/// Turns a Lottie animation into the same filmstrip every other moving picture
/// in this app is.
///
/// **A rasteriser, not a player.** Nothing in the running UI is a Lottie view:
/// the JSON is rendered once into `AnimatedImage`'s array of `CGImage`s, cached
/// beside every GIF and APNG in `AnimatedImageStore`, and drawn by the same
/// canvas that draws those. So a screenful of Lottie stickers costs exactly what
/// a screenful of GIFs costs — one bitmap swap per frame off the shared clock —
/// rather than a vector engine per cell evaluating shapes every frame.
///
/// **It runs on the main actor, and that is not a preference.** Lottie's
/// main-thread engine drives a `CAShapeLayer` tree, and mutating one off the
/// main thread races Core Animation's own transactions: it crashed the app in
/// `CA::Layer::setter` inside `-[CAShapeLayer setPath:]`, from a background
/// rasterise that had passed a standalone test perfectly. An isolated probe
/// cannot see that race because there is no other thread committing
/// transactions; only the running app can.
///
/// So the cost is paid where it has to be paid, and **time-sliced so it is never
/// a dropped frame**: measured at about 3 ms a frame — dominated by evaluating
/// the vectors, not by the output size, so a 72pt cell costs the same as a 320pt
/// one — the loop hands the run loop back every few milliseconds. A sticker is
/// roughly 70 ms of work spread across a dozen turns, paid once and then cached
/// for the session like every other filmstrip.
///
/// Three details were each wrong before they were right, and all three are
/// invisible in code that merely compiles:
///
///  1. **The engine must be `.mainThread`.** The Core Animation engine builds
///     `CAAnimation`s, and `render(in:)` cannot evaluate those — it produced an
///     almost empty frame.
///  2. **The context must be flipped.** A `CALayer` renders top-left down; a
///     `CGContext` is bottom-up.
///  3. **The inner layer must be placed by hand.** The aspect-fit sizing a
///     `LottieAnimationView` does lives in the *view*; headless, the animation
///     layer keeps its default anchor and lands cropped and off-centre.
@MainActor
enum LottieFilmstrip {

    /// The most frames a sticker is rasterised to.
    ///
    /// **A frame count, chosen against the clock rather than the source.**
    /// Discord's stickers are authored at 60 fps over two seconds — a hundred
    /// and twenty frames — and the app's clock never runs faster than 24, so
    /// rasterising all of them would be five times the memory for pictures
    /// nobody can see. Twenty-four frames spread across the loop is 12 fps for a
    /// two-second sticker, and at a 72pt cell it is about 2 MB.
    static let maximumFrames = 24

    /// How long one uninterrupted run of rasterising may take before the run
    /// loop gets its turn back. A quarter of a 60 Hz frame.
    private static let slice: Double = 0.004

    /// Whether a URL is one of these at all. The CDN serves Lottie as `.json`
    /// and nothing else does.
    nonisolated static func handles(_ url: URL) -> Bool { url.pathExtension == "json" }

    /// Rasterises, or nil when the data is not a Lottie animation.
    ///
    /// - Parameter maximumPixelSize: The longest side, in pixels, the frames are
    ///   drawn at — the size the cell will actually show, never the source's.
    static func decode(_ data: Data, maximumPixelSize: Int) async -> AnimatedImage? {
        guard let animation = try? LottieAnimation.from(data: data) else { return nil }

        let side = max(maximumPixelSize, 1)
        let size = animation.size
        guard size.width > 0, size.height > 0 else { return nil }

        let layer = LottieAnimationLayer(
            animation: animation,
            configuration: LottieConfiguration(renderingEngine: .mainThread)
        )
        layer.frame = CGRect(origin: .zero, size: size)
        layer.contentsScale = 1
        layer.layoutIfNeeded()
        // See (3) above: without this the animation renders cropped into a
        // corner, because the sizing that would place it lives in the view.
        if let root = layer.sublayers?.first {
            root.anchorPoint = .zero
            root.position = .zero
            root.transform = CATransform3DIdentity
            root.bounds = CGRect(origin: .zero, size: size)
        }

        // Fitted, so a non-square animation keeps its shape inside the box.
        let scale = Double(side) / max(size.width, size.height)
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }

        let count = min(maximumFrames, max(Int(animation.endFrame - animation.startFrame), 1))
        guard count > 1 else { return nil }

        var frames: [CGImage] = []
        frames.reserveCapacity(count)
        var sliceStarted = CFAbsoluteTimeGetCurrent()

        for step in 0..<count {
            // Hand the run loop back whenever this has held the main actor long
            // enough to matter. Yielding per frame would be a suspension every
            // three milliseconds for no gain; yielding never would be a
            // seventy-millisecond stall, which is four dropped frames.
            if CFAbsoluteTimeGetCurrent() - sliceStarted > slice {
                await Task.yield()
                if Task.isCancelled { return nil }
                sliceStarted = CFAbsoluteTimeGetCurrent()
            }

            layer.currentProgress = Double(step) / Double(count)
            layer.forceDisplayUpdate()

            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            ) else { return nil }

            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            layer.render(in: context)
            guard let frame = context.makeImage() else { return nil }
            frames.append(frame)
        }

        // The samples are evenly spaced across the loop, so each one holds the
        // loop's duration divided by the count — exactly, with no accumulated
        // rounding, because the ends are summed rather than multiplied.
        let step = max(animation.duration, 0.001) / Double(count)
        var clock: Double = 0
        var ends: [Double] = []
        ends.reserveCapacity(count)
        var bytes = 0
        for frame in frames {
            clock += step
            ends.append(clock)
            bytes += frame.height * frame.bytesPerRow
        }
        return AnimatedImage(frames: frames, ends: ends, duration: clock, cost: bytes)
    }
}
