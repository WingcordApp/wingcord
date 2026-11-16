import AppKit
import QuartzCore
import WingcordCore

/// The transcript's bubble faces, as layers that ride the scroll: Telegram's
/// sticky face (Alex, 2026-11-16; decisions in BETA2 §7, see
/// `StickyFaceRun`).
///
/// **A layer per face, moved on every scroll step.** The canvas only redraws
/// when it runs out of buffer, and a scroll between those moves is the
/// compositor sliding a still picture (`TimelineCanvasView`'s note), so a face
/// that has to move against its rows can't be painted into them. Its row
/// leaves the place empty (`TimelineRowPainter.State.drawsFace`) and the face
/// is a small layer here, in the canvas's own document space: the timeline
/// places it from the clip view's bounds change, which AppKit posts inside the
/// scroll's own transaction, so it never trails its bubbles by a frame.
///
/// **Only the faces near the viewport have a layer**, rendered once through
/// the painter's own face drawing and again only when what it shows changes:
/// the picture arriving, the hover film's next frame, the theme.
@MainActor
final class StickyFaces {

    /// Between a riding face and the composer's glass.
    static let composerGap: CGFloat = 8

    /// Holds the faces. Sits at the canvas's origin, so a face's frame is its
    /// place in the document.
    let container = CALayer()

    /// The paint state a face is drawn with: the transcript's text style, and
    /// the hover film's frames for a run's last message.
    var style: MessageTextStyle
    var filmFrames: (MessageID) -> (avatar: CGImage?, decoration: CGImage?) = { _ in (nil, nil) }

    private(set) var runs: [StickyFaceRun] = []
    /// What is on screen, by the run's first message, for hit testing.
    private(set) var shown: [MessageID: (run: StickyFaceRun, frame: CGRect)] = [:]
    private var layers: [MessageID: CALayer] = [:]
    private var drawn: [MessageID: ContentKey] = [:]
    private var asked: Set<ImageStore.Key> = []
    private var scale: CGFloat = 2

    /// What a face's picture depends on. Rendered again only when it changes.
    private struct ContentKey: Equatable {
        var url: URL?
        var monogram: String
        var decorationURL: URL?
        var hasPicture: Bool
        var hasDecoration: Bool
        var film: ObjectIdentifier?
        var decorationFilm: ObjectIdentifier?
        var plate: CGColor
        var ink: NSColor
        var scale: CGFloat
    }

    init(style: MessageTextStyle) {
        self.style = style
        container.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        container.actions = ["sublayers": NSNull(), "position": NSNull(), "bounds": NSNull()]
    }

    /// The rows changed: their runs, and every face drawn again.
    func update(runs: [StickyFaceRun]) {
        self.runs = runs
        drawn.removeAll()
    }

    /// Puts each face where this viewport wants it.
    ///
    /// - Parameters:
    ///   - visible: the clip view's bounds, in document space.
    ///   - readableBottom: the bottom a face may ride, above the composer.
    func place(visible: CGRect, readableBottom: CGFloat, scale: CGFloat) {
        self.scale = scale
        var wanted: [MessageID: (run: StickyFaceRun, frame: CGRect)] = [:]
        // Runs are in document order and don't overlap: start at the first
        // whose own place reaches the viewport, stop at the first that begins
        // below it.
        var low = 0, high = runs.count
        while low < high {
            let middle = (low + high) / 2
            if runs[middle].natural.maxY < visible.minY { low = middle + 1 } else { high = middle }
        }
        var index = low
        while index < runs.count, runs[index].top <= visible.maxY {
            let run = runs[index]
            let frame = CGRect(
                x: run.natural.minX, y: run.y(readableBottom: readableBottom),
                width: run.natural.width, height: run.natural.height
            )
            if frame.intersects(visible) { wanted[run.headID] = (run, frame) }
            index += 1
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, layer) in layers where wanted[id] == nil {
            layer.removeFromSuperlayer()
            layers[id] = nil
            drawn[id] = nil
        }
        for (id, face) in wanted {
            let layer = layers[id] ?? makeLayer()
            layers[id] = layer
            let outset = face.frame.width * (Metrics.decorationScale - 1) / 2
            let frame = face.frame.insetBy(dx: -outset, dy: -outset)
            if layer.frame != frame { layer.frame = frame }
            if layer.contentsScale != scale { layer.contentsScale = scale }
            draw(face.run, side: face.frame.width, outset: outset, into: layer, id: id)
        }
        CATransaction.commit()
        shown = wanted
    }

    /// Draws again whatever changed on the faces on screen: a picture that
    /// arrived, the film's next frame, the theme.
    func refreshContents() {
        guard !shown.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, face) in shown {
            guard let layer = layers[id] else { continue }
            let outset = face.frame.width * (Metrics.decorationScale - 1) / 2
            draw(face.run, side: face.frame.width, outset: outset, into: layer, id: id)
        }
        CATransaction.commit()
    }

    /// The face under a point in the document, if any.
    func face(at point: CGPoint) -> (run: StickyFaceRun, frame: CGRect)? {
        shown.values.first { $0.frame.contains(point) }
    }

    /// Takes every face away (a channel switch, the canvas going).
    func removeAll() {
        for layer in layers.values { layer.removeFromSuperlayer() }
        layers.removeAll()
        drawn.removeAll()
        shown.removeAll()
    }

    // MARK: Drawing

    private func makeLayer() -> CALayer {
        let layer = CALayer()
        layer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "hidden": NSNull()]
        layer.contentsGravity = .resize
        container.addSublayer(layer)
        return layer
    }

    private func draw(_ run: StickyFaceRun, side: CGFloat, outset: CGFloat, into layer: CALayer, id: MessageID) {
        let images = ImageStore.shared
        let pictureKey = run.avatarURL.map {
            ImageStore.Key(url: $0, maximumPixelSize: Int((Metrics.avatarMessage * scale).rounded(.up)))
        }
        let decorationKey = run.decorationURL.map {
            ImageStore.Key(
                url: $0,
                maximumPixelSize: Int((Metrics.avatarMessage * Metrics.decorationScale * scale).rounded(.up))
            )
        }
        let film = filmFrames(run.tailID)
        let key = ContentKey(
            url: run.avatarURL,
            monogram: run.monogram,
            decorationURL: run.decorationURL,
            hasPicture: pictureKey.map { images.cached($0) != nil } ?? false,
            hasDecoration: decorationKey.map { images.cached($0) != nil } ?? false,
            film: film.avatar.map(ObjectIdentifier.init),
            decorationFilm: film.decoration.map(ObjectIdentifier.init),
            plate: ThemeInk.current.surfaceRaised,
            ink: style.secondaryColor,
            scale: scale
        )
        if drawn[id] != key {
            drawn[id] = key
            layer.contents = render(run, side: side, outset: outset, film: film)
        }
        // A face whose row is out of the prefetch's reach (a long run, riding
        // the bottom) asks for its own picture once.
        for (wanted, has) in [(pictureKey, key.hasPicture), (decorationKey, key.hasDecoration)] {
            guard let wanted, !has, asked.insert(wanted).inserted else { continue }
            Task { [weak self] in
                _ = await ImageStore.shared.image(for: wanted, bucket: .thumbnail)
                self?.refreshContents()
            }
        }
    }

    private func render(
        _ run: StickyFaceRun, side: CGFloat, outset: CGFloat, film: (avatar: CGImage?, decoration: CGImage?)
    ) -> CGImage? {
        let size = side + outset * 2
        let pixels = Int((size * scale).rounded(.up))
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Flipped, as the canvas draws, so the painter's face lands the same.
        context.translateBy(x: 0, y: CGFloat(pixels))
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        TimelineRowPainter.drawBubbleFace(
            url: run.avatarURL,
            monogram: run.monogram,
            decorationURL: run.decorationURL,
            in: CGRect(x: outset, y: outset, width: side, height: side),
            context: context,
            style: style,
            images: ImageStore.shared,
            scale: scale,
            avatarFrame: film.avatar,
            decorationFrame: film.decoration
        )
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
