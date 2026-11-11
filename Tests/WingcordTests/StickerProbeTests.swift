import AppKit
import Foundation
import Lottie
import Testing
@testable import Wingcord

/// A look at real sticker files, for a pack that draws wrong. Runs only with
/// `WINGCORD_STICKER_DIR` (a folder of `.json` stickers) and
/// `WINGCORD_RENDER_DIR` set; says what each engine makes of each file.
@MainActor
@Suite("Sticker probe")
struct StickerProbeTests {

    @Test("Each sticker, through both paths")
    func probe() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let source = environment["WINGCORD_STICKER_DIR"],
              let output = environment["WINGCORD_RENDER_DIR"]
        else { return }
        let files = try FileManager.default.contentsOfDirectory(atPath: source).filter { $0.hasSuffix(".json") }.sorted()
        for file in files {
            let data = try Data(contentsOf: URL(fileURLWithPath: source).appendingPathComponent(file))
            // The still and the film the lists draw.
            let film = await LottieFilmstrip.decode(data, maximumPixelSize: 160)
            if let frame = film?.frames.first {
                let rep = NSBitmapImageRep(cgImage: frame)
                try rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: output).appendingPathComponent("still-\(file).png"))
            }
            // The live layer a card plays.
            let animation = try LottieAnimation.from(data: data)
            let layer = LottieStickerLayer.make(animation, scale: 2)
            layer.frame = CGRect(x: 0, y: 0, width: 96, height: 96)
            let host = CALayer()
            host.frame = CGRect(x: 0, y: 0, width: 96, height: 96)
            host.addSublayer(layer)
            LottieStickerLayer.fit(layer)
            layer.play()
            // The Core Animation engine decides whether it can play a file when
            // it is first displayed, which a layer in no window never is.
            layer.animationLayer?.setNeedsDisplay()
            layer.animationLayer?.displayIfNeeded()
            layer.displayIfNeeded()
            layer.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(400))
            let root = layer.animationLayer
            let transform = root.map { CATransform3DGetAffineTransform($0.transform) }
            print("STICKER \(file) film=\(film?.frames.count ?? -1) engine=\(String(describing: layer.currentRenderingEngine)) root=\(root.map { String(describing: type(of: $0)) } ?? "nil") scale=\(transform?.a ?? -1) rootFrame=\(root?.frame ?? .zero) sublayers=\(layer.sublayers?.count ?? 0)")
        }
    }
}
