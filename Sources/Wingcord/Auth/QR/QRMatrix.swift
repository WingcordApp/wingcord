import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// A QR code as modules, so it can be drawn as Wingcord's rather than as a
/// bitmap (docs/LOGIN-ONBOARDING.md D7).
///
/// **Core Image does the encoding** — `CIQRCodeGenerator` is the system's own,
/// and nothing about Reed–Solomon is worth owning — and this reads its output
/// back one module per pixel.
///
/// **Quartile error correction, and the version that buys is the point.** The
/// login link is 66 bytes, which at Q is version 6: 41 modules, whose only
/// alignment pattern sits in the bottom-right corner. At H it would be version
/// 8, with an alignment pattern dead in the centre — exactly where the wings
/// cover the code. Q still carries a quarter of the code as redundancy, several
/// times what the wings take; `QRCodeScanTests` decodes every drawing to keep
/// that true.
nonisolated struct QRMatrix: Equatable, Sendable {
    let size: Int
    private let bits: [Bool]

    enum Correction: String, Sendable {
        case low = "L", medium = "M", quartile = "Q", high = "H"
    }

    init(size: Int, bits: [Bool]) {
        precondition(bits.count == size * size)
        self.size = size
        self.bits = bits
    }

    /// Whether the module at column `x`, row `y` (from the top left) is dark.
    subscript(x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < size, y < size else { return false }
        return bits[y * size + x]
    }

    /// The code for `text`, or nil where Core Image declines.
    static func make(_ text: String, correction: Correction = .quartile) -> QRMatrix? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = correction.rawValue
        guard let output = filter.outputImage else { return nil }
        let extent = output.extent.integral
        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let image = context.createCGImage(output, from: extent) else { return nil }
        return read(image)
    }

    /// One module per pixel, in a grey bitmap of our own layout — row 0 at the
    /// top, whatever the image's own format — with the quiet zone Core Image
    /// adds trimmed off.
    static func read(_ image: CGImage) -> QRMatrix? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[y * width + x] < 128 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY, maxX - minX == maxY - minY else { return nil }
        let size = maxX - minX + 1
        var bits = [Bool](repeating: false, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                bits[y * size + x] = pixels[(y + minY) * width + (x + minX)] < 128
            }
        }
        return QRMatrix(size: size, bits: bits)
    }

    // MARK: Regions

    /// Inside one of the three 7×7 finder patterns, which are drawn as eyes of
    /// their own rather than as dots.
    func isInFinder(x: Int, y: Int) -> Bool {
        let near = 7, far = size - 7
        return (x < near && y < near) || (x >= far && y < near) || (x < near && y >= far)
    }

    /// The square left clear for the wings: `side` modules, centred. Odd, so a
    /// module's centre sits on the code's.
    func logoSide(fraction: Double = 0.27) -> Int {
        var side = Int((Double(size) * fraction).rounded())
        if side % 2 == 0 { side += 1 }
        return side
    }

    func isUnderLogo(x: Int, y: Int, side: Int) -> Bool {
        let start = (size - side) / 2
        return x >= start && x < start + side && y >= start && y < start + side
    }

    /// A made-up code for while the real one is on its way: the eyes where a
    /// code's are, and noise in between. **Not a code** — a placeholder that
    /// decoded would send a phone somewhere.
    static func placeholder(size: Int = 41, seed: UInt64 = 0x57_696E_6763) -> QRMatrix {
        var state = seed
        var bits = [Bool](repeating: false, count: size * size)
        for index in bits.indices {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            bits[index] = (state >> 33) & 1 == 1
        }
        return QRMatrix(size: size, bits: bits)
    }
}
