import CoreGraphics
import Foundation

/// Cropping a picked avatar or banner before it goes up — docs/CLIPS-PRESENCE.md,
/// Phase 9, after Discord's own "Edit Image" step.
///
/// **The arithmetic, apart from the view.** A picture is drawn filling a fixed
/// viewport — a square for an avatar, a strip for a banner — zoomed and dragged;
/// what is uploaded is the part of the picture under the viewport. Getting the
/// two out of step is a crop that is not what the reader saw, so the one
/// derivation lives here and is tested.
public struct PictureCrop: Hashable, Sendable {
    /// The shape cut out.
    public enum Shape: Hashable, Sendable {
        /// A square, shown through a circle — Discord's avatar.
        case avatar
        /// A strip — Discord's banner, 680 by 240.
        case banner

        public var aspect: CGFloat {
            switch self {
            case .avatar: 1
            case .banner: 680.0 / 240.0
            }
        }

        /// The largest picture worth sending, in pixels — Discord resizes past
        /// it anyway.
        public var outputSize: CGSize {
            switch self {
            case .avatar: CGSize(width: 1024, height: 1024)
            case .banner: CGSize(width: 1360, height: 480)
            }
        }
    }

    public var shape: Shape
    /// The picture's own size, in pixels.
    public var imageSize: CGSize
    /// The viewport it is shown through, in points.
    public var viewport: CGSize
    /// 1 fills the viewport; more zooms in.
    public var zoom: CGFloat = 1
    /// How far the picture has been dragged from centred, in points.
    public var offset: CGSize = .zero

    public static let maximumZoom: CGFloat = 4

    public init(shape: Shape, imageSize: CGSize, viewport: CGSize, zoom: CGFloat = 1, offset: CGSize = .zero) {
        self.shape = shape
        self.imageSize = imageSize
        self.viewport = viewport
        self.zoom = min(max(zoom, 1), Self.maximumZoom)
        self.offset = offset
        self.offset = clamped(offset)
    }

    /// Points per pixel at this zoom — the picture filling the viewport at 1.
    public var scale: CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        return max(viewport.width / imageSize.width, viewport.height / imageSize.height) * zoom
    }

    /// The picture's drawn size, in points.
    public var drawnSize: CGSize {
        CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    /// An offset kept where the picture still covers the whole viewport — no
    /// empty edge can be dragged into view.
    public func clamped(_ proposed: CGSize) -> CGSize {
        let slackX = max(0, (drawnSize.width - viewport.width) / 2)
        let slackY = max(0, (drawnSize.height - viewport.height) / 2)
        return CGSize(
            width: min(max(proposed.width, -slackX), slackX),
            height: min(max(proposed.height, -slackY), slackY)
        )
    }

    /// Whether the picture is already the shape and the crop would take nothing.
    public var isIdentity: Bool {
        zoom == 1 && offset == .zero
            && abs(imageSize.width / max(imageSize.height, 1) - shape.aspect) < 0.01
    }

    /// The part of the picture under the viewport, in the picture's pixels.
    public var cropRect: CGRect {
        let s = scale
        let x = ((drawnSize.width - viewport.width) / 2 - offset.width) / s
        let y = ((drawnSize.height - viewport.height) / 2 - offset.height) / s
        let rect = CGRect(x: x, y: y, width: viewport.width / s, height: viewport.height / s)
        return rect.intersection(CGRect(origin: .zero, size: imageSize)).integral
    }

    /// What the cut-out is scaled to: the output ceiling, never larger than
    /// the pixels it was cut from.
    public var outputSize: CGSize {
        let rect = cropRect
        let ceiling = shape.outputSize
        let factor = min(1, ceiling.width / max(rect.width, 1), ceiling.height / max(rect.height, 1))
        return CGSize(width: (rect.width * factor).rounded(), height: (rect.height * factor).rounded())
    }
}
