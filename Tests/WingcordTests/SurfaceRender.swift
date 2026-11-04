import AppKit
import SwiftUI
import Testing

/// Lays a surface out on the app's dark ground, offscreen — and, with
/// `WINGCORD_RENDER_DIR` set, writes it there as a PNG at 2× to look at.
///
/// Shared by the render suites, so the ground, the appearance and the file
/// naming are one decision. Glass does not composite offscreen, so a control
/// on it reads darker here than on screen.
@MainActor
enum SurfaceRender {

    static let ground = Color(white: 0.11)

    struct Result {
        var size: CGSize
        /// How much of the surface is not the ground — a pane that lays out
        /// and draws nothing scores zero.
        var ink: Double
    }

    @discardableResult
    static func render(_ view: some View, named name: String, width: CGFloat? = nil) throws -> Result {
        let host = NSHostingView(rootView: view.frame(width: width).padding(12).background(ground))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return Result(size: host.bounds.size, ink: 0)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let directory = ProcessInfo.processInfo.environment["WINGCORD_RENDER_DIR"] {
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        return Result(size: host.bounds.size, ink: ink(in: rep))
    }

    /// Every seventh pixel against the ground, for speed: a pane is tall.
    private static func ink(in rep: NSBitmapImageRep) -> Double {
        guard let data = rep.bitmapData, rep.samplesPerPixel >= 3 else { return 0 }
        let groundByte = Int((0.11 * 255).rounded())
        let pixels = rep.pixelsWide * rep.pixelsHigh
        var differing = 0, sampled = 0
        for index in stride(from: 0, to: pixels, by: 7) {
            let row = index / rep.pixelsWide, column = index % rep.pixelsWide
            let offset = row * rep.bytesPerRow + column * rep.bitsPerPixel / 8
            sampled += 1
            if abs(Int(data[offset]) - groundByte) > 6 { differing += 1 }
        }
        return sampled == 0 ? 0 : Double(differing) / Double(sampled)
    }
}
