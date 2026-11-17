import AVFoundation
import AppKit
import CoreImage
import QuartzCore

/// Cinema mode (decision 25): a blurred, enlarged copy of what's on stage
/// glowing behind it, as a room around a screen does.
///
/// **For a video, a second layer on the same player**: the same frames as
/// they're decoded, blurred on the GPU, so the light follows the picture with
/// nothing decoded twice. For a picture, the picture. The glow is drawn small
/// and scaled up: a blur of an eighth-size layer is the same light for a
/// sixty-fourth of the work.
@MainActor
final class ViewerAmbientLight {
    let layer = CALayer()
    private var playerLayer: AVPlayerLayer?
    private var stillLayer: CALayer?

    /// How much larger than the picture the light spills.
    static let spill: CGFloat = 1.22
    /// The size it's drawn at, before it's scaled up.
    static let reduction: CGFloat = 8

    init() {
        layer.actions = ["sublayers": NSNull(), "position": NSNull(), "bounds": NSNull(), "transform": NSNull()]
        layer.opacity = 0
        layer.compositingFilter = nil
        layer.filters = [
            CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 7]),
            CIFilter(name: "CIColorControls", parameters: [kCIInputSaturationKey: 1.6]),
        ].compactMap { $0 }
        layer.masksToBounds = false
    }

    /// The video, or nil for a picture.
    func setPlayer(_ player: AVPlayer?) {
        if let player {
            stillLayer?.removeFromSuperlayer()
            stillLayer = nil
            if playerLayer == nil {
                let created = AVPlayerLayer(player: player)
                created.videoGravity = .resizeAspectFill
                created.actions = ["bounds": NSNull(), "position": NSNull()]
                layer.addSublayer(created)
                playerLayer = created
            } else if playerLayer?.player !== player {
                playerLayer?.player = player
            }
        } else {
            playerLayer?.player = nil
            playerLayer?.removeFromSuperlayer()
            playerLayer = nil
        }
    }

    /// The picture's pixels, for a still or a GIF's frame.
    func setImage(_ image: Any?) {
        guard playerLayer == nil else { return }
        if stillLayer == nil {
            let created = CALayer()
            created.contentsGravity = .resizeAspectFill
            created.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer.addSublayer(created)
            stillLayer = created
        }
        stillLayer?.contents = image
    }

    /// Lays the light behind `content`, or fades it out.
    func layout(around content: CGRect, visible: Bool, animated: Bool) {
        let target: Float = visible && content.width > 1 ? (playerLayer != nil ? 0.75 : 0.6) : 0
        if layer.opacity != target {
            if animated {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
                fade.toValue = target
                fade.duration = target > 0 ? 0.45 : 0.2
                layer.add(fade, forKey: "fade")
            }
            layer.opacity = target
        }
        guard content.width > 1, content.height > 1 else { return }
        let size = CGSize(
            width: content.width * Self.spill / Self.reduction,
            height: content.height * Self.spill / Self.reduction
        )
        layer.bounds = CGRect(origin: .zero, size: size)
        layer.position = CGPoint(x: content.midX, y: content.midY)
        layer.transform = CATransform3DMakeScale(Self.reduction, Self.reduction, 1)
        for sublayer in [playerLayer as CALayer?, stillLayer].compactMap({ $0 }) {
            sublayer.frame = layer.bounds
        }
    }

    func tearDown() {
        setPlayer(nil)
        stillLayer?.removeFromSuperlayer()
        stillLayer = nil
        layer.removeFromSuperlayer()
    }
}
