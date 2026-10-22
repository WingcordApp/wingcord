import AppKit
import ImageIO
import UniformTypeIdentifiers
import WingcordCore

/// The GIFs `--demo` offers — the composer's GIF tab and the profile editor's
/// Choose GIF — **drawn here, once, into the caches folder**.
///
/// `--demo` makes no requests, and Discord's `/gifs` routes are requests: the
/// tab used to ask anyway, unauthenticated, and show "GIFs are unavailable".
/// These are small loops made from system symbols on a moving gradient — a
/// wave, a laugh, a heart — enough to pick one, crop it and wear it.
enum DemoGIFs {
    private struct Loop {
        var name: String
        var symbol: String
        var colours: (NSColor, NSColor)
        var motion: Motion
    }

    private enum Motion { case wave, bounce, pulse, pop, spin, float, shake, slide }

    private static let loops: [Loop] = [
        Loop(name: "hello", symbol: "hand.wave.fill", colours: (.systemOrange, .systemPink), motion: .wave),
        Loop(name: "lol", symbol: "face.smiling.inverse", colours: (.systemYellow, .systemOrange), motion: .bounce),
        Loop(name: "love", symbol: "heart.fill", colours: (.systemPink, .systemPurple), motion: .pulse),
        Loop(name: "yes", symbol: "checkmark.seal.fill", colours: (.systemGreen, .systemTeal), motion: .pop),
        Loop(name: "wow", symbol: "star.fill", colours: (.systemIndigo, .systemBlue), motion: .spin),
        Loop(name: "sleepy", symbol: "moon.zzz.fill", colours: (.systemBlue, .systemPurple), motion: .float),
        Loop(name: "party", symbol: "party.popper.fill", colours: (.systemRed, .systemYellow), motion: .shake),
        Loop(name: "cool", symbol: "sunglasses.fill", colours: (.systemTeal, .systemCyan), motion: .slide),
    ]

    /// Every loop, as the routes would answer them.
    static var all: [GIF] {
        loops.compactMap { loop in
            file(for: loop).map { url in
                GIF(url: url, previewURL: url, width: Int(size.width), height: Int(size.height))
            }
        }
    }

    static var landing: GIFLanding {
        let gifs = all
        return GIFLanding(
            categories: zip(loops, gifs).map { GIFCategory(name: $0.name, previewURL: $1.previewURL) },
            trending: gifs
        )
    }

    /// A search: the loops whose name matches first, then the rest, so a
    /// query never comes back empty in the demo.
    static func search(_ query: String) -> [GIF] {
        let lowered = query.lowercased()
        let pairs = Array(zip(loops, all))
        let matching = pairs.filter { $0.0.name.contains(lowered) || lowered.contains($0.0.name) }.map(\.1)
        let rest = pairs.filter { pair in !matching.contains(pair.1) }.map(\.1)
        return matching + rest
    }

    private static let size = CGSize(width: 200, height: 150)
    private static let frames = 18

    private static func file(for loop: Loop) -> URL? {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wingcord Demo GIFs", isDirectory: true)
        let file = folder.appendingPathComponent("\(loop.name).gif")
        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) { return file }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.gif.identifier as CFString, frames, nil)
        else { return nil }
        CGImageDestinationSetProperties(
            destination,
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        )
        let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.06]] as CFDictionary
        for index in 0..<frames {
            guard let frame = draw(loop, phase: Double(index) / Double(frames)) else { return nil }
            CGImageDestinationAddImage(destination, frame, delay)
        }
        return CGImageDestinationFinalize(destination) ? file : nil
    }

    /// One frame: the gradient turned a little further, the symbol moved by
    /// its motion at `phase` (0…1 round the loop).
    private static func draw(_ loop: Loop, phase: Double) -> CGImage? {
        let width = Int(size.width), height = Int(size.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let angle = phase * 2 * .pi
        let colours = [loop.colours.0.cgColor, loop.colours.1.cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colours, locations: [0, 1]) {
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let reach = max(size.width, size.height)
            let start = CGPoint(x: centre.x + cos(angle) * reach / 2, y: centre.y + sin(angle) * reach / 2)
            let end = CGPoint(x: centre.x - cos(angle) * reach / 2, y: centre.y - sin(angle) * reach / 2)
            context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 58, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let symbol = NSImage(systemSymbolName: loop.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration),
            let glyph = symbol.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return context.makeImage() }

        let wave = sin(angle)
        var scale = 1.0, rotation = 0.0, dx = 0.0, dy = 0.0
        switch loop.motion {
        case .wave: rotation = wave * 0.35
        case .bounce: dy = abs(wave) * 18
        case .pulse: scale = 1 + 0.16 * (0.5 + 0.5 * wave)
        case .pop: scale = 0.8 + 0.3 * abs(sin(angle / 2))
        case .spin: rotation = angle
        case .float: dy = wave * 10; dx = cos(angle) * 6
        case .shake: rotation = sin(angle * 3) * 0.18
        case .slide: dx = wave * 26
        }
        let glyphSize = CGSize(width: CGFloat(glyph.width) / 2 * scale, height: CGFloat(glyph.height) / 2 * scale)
        context.saveGState()
        context.translateBy(x: size.width / 2 + dx, y: size.height / 2 + dy)
        context.rotate(by: rotation)
        context.setShadow(offset: CGSize(width: 0, height: -3), blur: 6, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        context.draw(glyph, in: CGRect(x: -glyphSize.width / 2, y: -glyphSize.height / 2, width: glyphSize.width, height: glyphSize.height))
        context.restoreGState()
        return context.makeImage()
    }
}
