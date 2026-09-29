import Foundation

/// The blurred stand-in Discord shows while a picture loads — its `placeholder`,
/// a ThumbHash, on attachments, embed pictures and gallery media alike.
///
/// **Discord's decode, not the reference library's.** Its worker (chunk
/// `792086589bac0680`, module `659601`) runs ThumbHash with `detail: 1` and
/// `pop: 1.1`: only the lowest luminance frequencies are kept, the luminance
/// detail is halved, and colour is lifted by 1.1 where the library lifts it by
/// 1.25. The result is softer than the library's, and it is what a reader of
/// Discord sees for the moment before the picture arrives.
public enum MediaPlaceholder {

    /// The only version this decodes. Anything else is left undrawn rather than
    /// guessed at.
    public static let version = 1

    /// A placeholder as it arrived, kept only where it is a version this
    /// decodes — an absent version is the only one Discord has shipped.
    public static func accepted(_ placeholder: String?, version: Int?) -> String? {
        guard let placeholder, !placeholder.isEmpty, (version ?? Self.version) == Self.version else { return nil }
        return placeholder
    }

    /// A decoded placeholder: at most 32 pixels on its long side, RGBA.
    public struct Pixels: Hashable, Sendable {
        public var width: Int
        public var height: Int
        public var rgba: [UInt8]
    }

    /// Decodes a base64 placeholder, or nil for one too short to be a hash.
    public static func decode(base64: String, detail: Int = 1, pop: Double = 1.1) -> Pixels? {
        guard let data = Data(base64Encoded: base64), data.count >= 5 else { return nil }
        return decode([UInt8](data), detail: detail, pop: pop)
    }

    static func decode(_ hash: [UInt8], detail: Int, pop: Double) -> Pixels? {
        func byte(_ index: Int) -> Int { index < hash.count ? Int(hash[index]) : 0 }
        let header24 = byte(0) | byte(1) << 8 | byte(2) << 16
        let header16 = byte(3) | byte(4) << 8
        let lDC = Double(header24 & 63) / 63
        let pDC = Double(header24 >> 6 & 63) / 31.5 - 1
        let qDC = Double(header24 >> 12 & 63) / 31.5 - 1
        let hasAlpha = header24 >> 23 != 0
        let isLandscape = header16 >> 15 != 0
        let lx = max(3, isLandscape ? (hasAlpha ? 5 : 7) : header16 & 7)
        let ly = max(3, isLandscape ? header16 & 7 : (hasAlpha ? 5 : 7))
        let aDC = hasAlpha ? Double(byte(5) & 15) / 15 : 1
        let aScale = Double(byte(5) >> 4) / 15

        var acIndex = 0
        let acStart = hasAlpha ? 6 : 5
        func channel(_ nx: Int, _ ny: Int, _ scale: Double) -> [Double] {
            var values: [Double] = []
            for cy in 0..<ny {
                var cx = cy == 0 ? 1 : 0
                while cx * ny < nx * (ny - cy) {
                    let nibble = byte(acStart + (acIndex >> 1)) >> ((acIndex & 1) << 2) & 15
                    values.append((Double(nibble) / 7.5 - 1) * scale)
                    acIndex += 1
                    cx += 1
                }
            }
            return values
        }
        let lAC = channel(lx, ly, Double(header24 >> 18 & 31) / 31 / 2)
        let pAC = channel(3, 3, Double(header16 >> 3 & 63) / 63 * pop)
        let qAC = channel(3, 3, Double(header16 >> 9 & 63) / 63 * pop)
        let aAC = hasAlpha ? channel(5, 5, aScale) : []

        let ratio = Double(isLandscape ? (hasAlpha ? 5 : 7) : header16 & 7)
            / Double(isLandscape ? header16 & 7 : (hasAlpha ? 5 : 7))
        guard ratio.isFinite, ratio > 0 else { return nil }
        let width = Int((ratio > 1 ? 32 : 32 * ratio).rounded())
        let height = Int((ratio > 1 ? 32 / ratio : 32).rounded())
        guard width > 0, height > 0 else { return nil }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let columns = max(lx, hasAlpha ? 5 : 3)
        let rows = max(ly, hasAlpha ? 5 : 3)
        var fx = [Double](repeating: 0, count: columns)
        var fy = [Double](repeating: 0, count: rows)
        var i = 0
        for y in 0..<height {
            for cy in 0..<rows { fy[cy] = cos(.pi / Double(height) * (Double(y) + 0.5) * Double(cy)) }
            for x in 0..<width {
                for cx in 0..<columns { fx[cx] = cos(.pi / Double(width) * (Double(x) + 0.5) * Double(cx)) }
                var l = lDC, p = pDC, q = qDC, a = aDC

                var j = 0
                for cy in 0..<ly {
                    let fy2 = 2 * fy[cy]
                    var cx = cy == 0 ? 1 : 0
                    while cx * ly < lx * (ly - cy) {
                        if cx <= detail, cy <= detail { l += lAC[j] * fx[cx] * fy2 }
                        cx += 1
                        j += 1
                    }
                }
                j = 0
                for cy in 0..<3 {
                    let fy2 = 2 * fy[cy]
                    var cx = cy == 0 ? 1 : 0
                    while cx < 3 - cy {
                        let f = fx[cx] * fy2
                        p += pAC[j] * f
                        q += qAC[j] * f
                        cx += 1
                        j += 1
                    }
                }
                if hasAlpha {
                    j = 0
                    for cy in 0..<5 {
                        let fy2 = 2 * fy[cy]
                        var cx = cy == 0 ? 1 : 0
                        while cx < 5 - cy {
                            a += aAC[j] * fx[cx] * fy2
                            cx += 1
                            j += 1
                        }
                    }
                }

                let b = l - 2.0 / 3.0 * p
                let r = (3 * l - b + q) / 2
                let g = r - q
                rgba[i] = UInt8(max(0, 255 * min(1, r)))
                rgba[i + 1] = UInt8(max(0, 255 * min(1, g)))
                rgba[i + 2] = UInt8(max(0, 255 * min(1, b)))
                rgba[i + 3] = UInt8(max(0, 255 * min(1, a)))
                i += 4
            }
        }
        return Pixels(width: width, height: height, rgba: rgba)
    }
}
