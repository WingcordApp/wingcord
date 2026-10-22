import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import Foundation
import Metal
import WingcordCore

// MARK: - Drawing an edited clip's frames
//
// docs/CLIPS-PRESENCE.md, Phases 4.3 and 5.2 — Slice's shape (§2.5), our own
// code: a Core Image renderer inside an `AVVideoComposition`, the same for the
// editor's preview and the export. One frame at a time, at the edit's own
// time: back to the source's moment through the cuts and speeds, then
//
//   the source → blurred regions → the cursor drawn again → the crop and the
//   zoom → placed on the canvas (corners, shadow, background) → the camera
//   bubble → every word, picture, caption and face whose stretch it is.
//
// The overlays arrive already drawn — words need AppKit's type, which this
// package does not have.

/// One drawn overlay and where it goes: in the canvas's 0…1 frame, top-left
/// origin — so it lands right whatever size the export settles on — for a
/// stretch of the **source's** time, so it stays on its moment through cuts.
public struct RenderedOverlay: @unchecked Sendable {
    public var image: CGImage
    public var frame: CGRect
    public var start: Double
    public var end: Double

    public init(image: CGImage, frame: CGRect, start: Double, end: Double) {
        self.image = image
        self.frame = frame
        self.start = start
        self.end = end
    }
}

/// A cursor's picture, as the system draws it: the image, the point it
/// clicks with (in the image's pixels, from its top left), and its size in
/// points.
public struct CursorSprite: @unchecked Sendable {
    public var image: CGImage
    public var hotspot: CGPoint
    public var pointSize: CGSize

    public init(image: CGImage, hotspot: CGPoint, pointSize: CGSize) {
        self.image = image
        self.hotspot = hotspot
        self.pointSize = pointSize
    }
}

/// What every frame of one render is drawn with.
struct ClipRenderPlan: @unchecked Sendable {
    var screenTrack: CMPersistentTrackID
    var cameraTrack: CMPersistentTrackID?
    var sequence: ClipSequence
    var sourceSize: CGSize
    /// The box kept, in the source's pixels, top-left origin.
    var crop: CGRect
    var renderSize: CGSize
    /// Where the picture sits on the canvas, in its 0…1 frame.
    var content: CGRect
    var canvas: ClipCanvas
    var zooms: [ZoomBlock]
    var blurs: [BlurRegion]
    var cursor: (log: CursorLog, style: CursorStyle, sprites: [CursorLog.Kind: CursorSprite], pointScale: CGFloat)?
    /// The bubble's centre and diameter, in the canvas's 0…1 frame (diameter
    /// a share of its height).
    var camera: (x: CGFloat, y: CGFloat, diameter: CGFloat)?
    var overlays: [(image: CIImage, frame: CGRect, start: Double, end: Double)]
}

/// The instruction AVFoundation hands back with each frame request — it
/// carries the plan.
final class ClipRenderInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let plan: ClipRenderPlan

    init(timeRange: CMTimeRange, plan: ClipRenderPlan) {
        self.timeRange = timeRange
        self.plan = plan
        requiredSourceTrackIDs = ([plan.screenTrack] + (plan.cameraTrack.map { [$0] } ?? []))
            .map { NSNumber(value: $0) }
        super.init()
    }
}

final class ClipCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
    ]

    private let context: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? ClipRenderInstruction,
              let output = try? request.renderContext.makeMutablePixelBuffer()
        else {
            request.finish(with: NSError(domain: "ClipCompositor", code: 1))
            return
        }
        let plan = instruction.plan
        let screen = request.sourceReadOnlyPixelBuffer(byTrackID: plan.screenTrack)
            .map { buffer in buffer.withUnsafeBuffer { CIImage(cvPixelBuffer: $0) } }
        let camera = plan.cameraTrack.flatMap { request.sourceReadOnlyPixelBuffer(byTrackID: $0) }
            .map { buffer in buffer.withUnsafeBuffer { CIImage(cvPixelBuffer: $0) } }
        let composed = Self.compose(plan: plan, screen: screen, camera: camera, at: request.compositionTime.seconds)
        let bounds = CGRect(origin: .zero, size: plan.renderSize)
        output.withUnsafeBuffer { context.render(composed, to: $0, bounds: bounds, colorSpace: colorSpace) }
        request.finish(withComposedPixelBuffer: CVReadOnlyPixelBuffer(output))
    }

    func cancelAllPendingVideoCompositionRequests() {}

    // MARK: One frame

    /// The frame at `time` seconds of the edit. Static and pure, so a test
    /// can draw one without a composition.
    static func compose(plan: ClipRenderPlan, screen: CIImage?, camera: CIImage?, at time: Double) -> CIImage {
        let size = plan.renderSize
        let bounds = CGRect(origin: .zero, size: size)
        let source = plan.sequence.sourceTime(atOutput: time)
        let width = plan.sourceSize.width
        let height = plan.sourceSize.height

        var canvas = background(plan.canvas, in: bounds)
        if var picture = screen {
            // What belongs to the screen, on the screen.
            for blur in plan.blurs where source >= blur.start && source < blur.end {
                picture = blurred(picture, region: blur, sourceSize: plan.sourceSize)
            }
            var cursorPoint: CGPoint?
            if let cursor = plan.cursor, cursor.style.isVisible,
               let point = cursor.log.position(at: source, smoothing: cursor.style.smoothing)
            {
                cursorPoint = point
                picture = drawCursor(over: picture, at: point, kind: cursor.log.kind(at: source), plan: cursor,
                                     rings: cursor.style.showsClicks ? cursor.log.rings(at: source) : [],
                                     sourceSize: plan.sourceSize)
            }

            // The crop and the zoom: which box of the source fills the
            // picture's place on the canvas.
            let crop = plan.crop
            let zoom = plan.zooms.state(at: source, cursor: cursorPoint)
            var visible = crop
            if zoom.scale > 1.001, crop.width > 0, crop.height > 0 {
                let inCrop = ZoomState(
                    scale: zoom.scale,
                    x: (zoom.x * width - crop.minX) / crop.width,
                    y: (zoom.y * height - crop.minY) / crop.height
                ).visibleRect
                visible = CGRect(
                    x: crop.minX + inCrop.minX * crop.width, y: crop.minY + inCrop.minY * crop.height,
                    width: inCrop.width * crop.width, height: inCrop.height * crop.height
                )
            }
            let ciVisible = CGRect(x: visible.minX, y: height - visible.maxY, width: visible.width, height: visible.height)
            let place = CGRect(
                x: plan.content.minX * size.width, y: size.height - plan.content.maxY * size.height,
                width: plan.content.width * size.width, height: plan.content.height * size.height
            )
            var content = picture
                .clampedToExtent()
                .cropped(to: ciVisible)
                .transformed(by: CGAffineTransform(translationX: -ciVisible.minX, y: -ciVisible.minY))
                .transformed(by: CGAffineTransform(
                    scaleX: place.width / max(ciVisible.width, 1), y: place.height / max(ciVisible.height, 1)
                ))
                .transformed(by: CGAffineTransform(translationX: place.minX, y: place.minY))
                .cropped(to: place)

            let radius = plan.canvas.cornerRadius * min(place.width, place.height)
            if radius > 0.5 {
                let mask = CIFilter.roundedRectangleGenerator()
                mask.extent = place
                mask.radius = Float(radius)
                mask.color = .white
                if let shape = mask.outputImage {
                    content = content.applyingFilter("CIBlendWithAlphaMask", parameters: [
                        kCIInputBackgroundImageKey: CIImage.empty(),
                        kCIInputMaskImageKey: shape,
                    ])
                }
            }
            if plan.canvas.shadow > 0, !plan.canvas.isPlain {
                canvas = shadow(under: place, radius: radius, strength: plan.canvas.shadow).composited(over: canvas)
            }
            canvas = content.composited(over: canvas)
        }

        if let placement = plan.camera, let camera {
            canvas = bubble(camera, placement: placement, in: size).composited(over: canvas)
        }
        for overlay in plan.overlays where source >= overlay.start && source < overlay.end {
            let frame = CGRect(
                x: overlay.frame.minX * size.width, y: overlay.frame.minY * size.height,
                width: overlay.frame.width * size.width, height: overlay.frame.height * size.height
            )
            let placed = overlay.image
                .transformed(by: CGAffineTransform(
                    scaleX: frame.width / max(overlay.image.extent.width, 1),
                    y: frame.height / max(overlay.image.extent.height, 1)
                ))
                .transformed(by: CGAffineTransform(translationX: frame.minX, y: size.height - frame.maxY))
            canvas = placed.composited(over: canvas)
        }
        return canvas.cropped(to: bounds)
    }

    // MARK: The canvas

    private static func color(_ rgb: UInt32, alpha: CGFloat = 1) -> CIColor {
        CIColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha
        )
    }

    private static func background(_ canvas: ClipCanvas, in bounds: CGRect) -> CIImage {
        switch canvas.background {
        case .none:
            return CIImage(color: .black).cropped(to: bounds)
        case .solid(let rgb):
            return CIImage(color: color(rgb)).cropped(to: bounds)
        case .gradient(let from, let to, let angle):
            // The angle as CSS's: 0 points up, 90 to the right.
            let radians = angle * .pi / 180
            let direction = CGPoint(x: sin(radians), y: cos(radians))
            let half = max(bounds.width, bounds.height) / 2
            let centre = CGPoint(x: bounds.midX, y: bounds.midY)
            let gradient = CIFilter.linearGradient()
            gradient.point0 = CGPoint(x: centre.x - direction.x * half, y: centre.y - direction.y * half)
            gradient.point1 = CGPoint(x: centre.x + direction.x * half, y: centre.y + direction.y * half)
            gradient.color0 = color(from)
            gradient.color1 = color(to)
            return (gradient.outputImage ?? CIImage(color: color(from))).cropped(to: bounds)
        }
    }

    private static func shadow(under place: CGRect, radius: CGFloat, strength: Double) -> CIImage {
        let shape = CIFilter.roundedRectangleGenerator()
        shape.extent = place.offsetBy(dx: 0, dy: -place.height * 0.012)
        shape.radius = Float(max(radius, 1))
        shape.color = CIColor(red: 0, green: 0, blue: 0, alpha: 0.55 * strength)
        let sigma = max(2, min(place.width, place.height) * 0.035 * strength)
        return (shape.outputImage ?? .empty()).applyingGaussianBlur(sigma: sigma)
    }

    // MARK: The screen

    /// A region of the source blurred or pixelated, in place.
    private static func blurred(_ picture: CIImage, region: BlurRegion, sourceSize: CGSize) -> CIImage {
        let rect = CGRect(
            x: region.rect.minX * sourceSize.width,
            y: sourceSize.height - region.rect.maxY * sourceSize.height,
            width: region.rect.width * sourceSize.width,
            height: region.rect.height * sourceSize.height
        )
        let scale = sourceSize.height / 1_080
        let hidden: CIImage
        switch region.style {
        case .blur:
            hidden = picture.clampedToExtent().applyingGaussianBlur(sigma: (8 + 40 * region.strength) * scale)
        case .pixelate:
            let pixellate = CIFilter.pixellate()
            pixellate.inputImage = picture.clampedToExtent()
            pixellate.center = CGPoint(x: rect.midX, y: rect.midY)
            pixellate.scale = Float((10 + 50 * region.strength) * scale)
            hidden = pixellate.outputImage ?? picture
        }
        return hidden.cropped(to: rect).composited(over: picture)
    }

    /// The cursor drawn again where the log says it was, at the style's size,
    /// with a ring where a click landed.
    private static func drawCursor(
        over picture: CIImage, at point: CGPoint, kind: CursorLog.Kind,
        plan: (log: CursorLog, style: CursorStyle, sprites: [CursorLog.Kind: CursorSprite], pointScale: CGFloat),
        rings: [(click: CursorLog.Click, progress: Double)], sourceSize: CGSize
    ) -> CIImage {
        var result = picture
        let scale = plan.pointScale * plan.style.size
        for ring in rings {
            let centre = CGPoint(x: ring.click.x * sourceSize.width, y: sourceSize.height - ring.click.y * sourceSize.height)
            let radius = (10 + 22 * ring.progress) * scale
            let width = 2.5 * scale
            let alpha = 0.85 * (1 - ring.progress)
            // A ring as the smaller of two ramps: clear inside rising to the
            // edge, and the edge falling away outside it. Either alone fills
            // its square past where it ends.
            let rising = CIFilter.radialGradient()
            rising.center = centre
            rising.radius0 = Float(radius - width)
            rising.radius1 = Float(radius)
            rising.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
            rising.color1 = CIColor(red: alpha, green: alpha, blue: alpha, alpha: alpha)
            let falling = CIFilter.radialGradient()
            falling.center = centre
            falling.radius0 = Float(radius)
            falling.radius1 = Float(radius + width)
            falling.color0 = CIColor(red: alpha, green: alpha, blue: alpha, alpha: alpha)
            falling.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
            let box = CGRect(x: centre.x - radius - width * 2, y: centre.y - radius - width * 2,
                             width: 2 * (radius + width * 2), height: 2 * (radius + width * 2))
            if let inner = rising.outputImage, let outer = falling.outputImage {
                let ring = inner.applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: outer])
                result = ring.cropped(to: box).composited(over: result)
            }
        }
        guard let sprite = plan.sprites[kind] ?? plan.sprites[.arrow] else { return result }
        let image = CIImage(cgImage: sprite.image)
        let imageWidth = CGFloat(sprite.image.width)
        let imageHeight = CGFloat(sprite.image.height)
        let drawn = sprite.pointSize.width * scale
        let factor = drawn / max(imageWidth, 1)
        let tip = CGPoint(x: point.x * sourceSize.width, y: sourceSize.height - point.y * sourceSize.height)
        let origin = CGPoint(x: tip.x - sprite.hotspot.x * factor, y: tip.y - (imageHeight - sprite.hotspot.y) * factor)
        let placed = image
            .transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
        return placed.composited(over: result)
    }

    /// The camera, filled into a circle at its place — a mirror, as the
    /// bubble on screen was.
    private static func bubble(_ camera: CIImage, placement: (x: CGFloat, y: CGFloat, diameter: CGFloat), in size: CGSize)
        -> CIImage
    {
        let diameter = placement.diameter * size.height
        let side = min(camera.extent.width, camera.extent.height)
        let square = camera
            .cropped(to: CGRect(
                x: camera.extent.midX - side / 2, y: camera.extent.midY - side / 2, width: side, height: side
            ))
            .transformed(by: CGAffineTransform(translationX: -(camera.extent.midX - side / 2), y: -(camera.extent.midY - side / 2)))
            .transformed(by: CGAffineTransform(scaleX: -diameter / side, y: diameter / side))
            .transformed(by: CGAffineTransform(translationX: diameter, y: 0))
        let center = CGPoint(x: placement.x * size.width, y: size.height - placement.y * size.height)
        let placed = square.transformed(by: CGAffineTransform(translationX: center.x - diameter / 2, y: center.y - diameter / 2))
        let mask = CIFilter.radialGradient()
        mask.center = center
        mask.radius0 = Float(diameter / 2 - 1)
        mask.radius1 = Float(diameter / 2)
        mask.color0 = .white
        mask.color1 = .clear
        let blend = CIFilter.blendWithAlphaMask()
        blend.inputImage = placed
        blend.backgroundImage = CIImage.empty()
        blend.maskImage = mask.outputImage?.cropped(to: placed.extent)
        return blend.outputImage ?? placed
    }
}
