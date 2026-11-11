import AppKit
import Foundation
import Lottie
import Testing
@testable import Wingcord

/// A Lottie sticker stays fitted to its cell when its root layer is replaced.
///
/// **Doggo Replies, 2026-11-10.** One of that pack's stickers cannot be played
/// by Lottie's Core Animation engine, so the automatic engine rebuilds it on
/// the other one the first time it is displayed — and the new root arrived at
/// the composition's own 320 points, six times its cell. Lottie's callback for
/// "the layer loaded" fires before the new root is stored, so fitting from
/// there did nothing; the fit now runs from the layer's own layout, which Lottie
/// asks for right after the swap.
@MainActor
@Suite("Lottie sticker fit")
struct LottieStickerFitTests {

    /// A red square, 320 points a side: the smallest sticker there is.
    private static let square = Data("""
    {"v":"5.6.2","fr":60,"ip":0,"op":60,"w":320,"h":320,"nm":"square","ddd":0,"assets":[],
     "layers":[{"ddd":0,"ind":1,"ty":1,"nm":"solid","sr":1,
      "ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[160,160,0]},
            "a":{"a":0,"k":[160,160,0]},"s":{"a":0,"k":[100,100,100]}},
      "ao":0,"sw":320,"sh":320,"sc":"#ff0000","ip":0,"op":60,"st":0,"bm":0}]}
    """.utf8)

    private func scale(of layer: LottieAnimationLayer) -> CGFloat? {
        layer.animationLayer.map { CATransform3DGetAffineTransform($0.transform).a }
    }

    @Test("Laying the layer out is what fits it — no call from its owner needed")
    func layoutFits() throws {
        let animation = try LottieAnimation.from(data: Self.square)
        let layer = LottieStickerLayer.make(animation, scale: 2)
        #expect(layer.layoutManager is LottieStickerFitter)

        layer.frame = CGRect(x: 0, y: 0, width: 96, height: 96)
        layer.setNeedsLayout()
        layer.layoutIfNeeded()
        #expect(abs((scale(of: layer) ?? 0) - 0.3) < 0.0001)
        let root = try #require(layer.animationLayer)
        #expect(root.position == CGPoint(x: 48, y: 48))

        // The cell changed size: the same pass fits it again.
        layer.frame = CGRect(x: 0, y: 0, width: 160, height: 160)
        layer.setNeedsLayout()
        layer.layoutIfNeeded()
        #expect(abs((scale(of: layer) ?? 0) - 0.5) < 0.0001)
    }

    @Test("A root that was put back to its own size is fitted by the next layout")
    func replacedRootIsFitted() throws {
        let animation = try LottieAnimation.from(data: Self.square)
        let layer = LottieStickerLayer.make(animation, scale: 2)
        layer.frame = CGRect(x: 0, y: 0, width: 96, height: 96)
        layer.layoutIfNeeded()

        // What an engine swap leaves behind: the composition at its own size,
        // centred on the corner — and Lottie's `setNeedsLayout()` after it.
        let root = try #require(layer.animationLayer)
        root.transform = CATransform3DIdentity
        root.position = .zero
        layer.setNeedsLayout()
        layer.layoutIfNeeded()

        #expect(abs((scale(of: layer) ?? 0) - 0.3) < 0.0001)
        #expect(root.position == CGPoint(x: 48, y: 48))
    }
}
