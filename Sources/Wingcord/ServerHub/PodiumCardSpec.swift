import SwiftUI

/// A podium card, as Discord's SVG draws it (`eK`, `eV`, `eq` in its hub
/// module): the pennant's path, the surface, a radial tint at a quarter
/// opacity, a two-point border in a three-stop gradient kept inside the shape,
/// and — for the winner — a gold glow.
struct PodiumCardSpec {
    /// The card's own canvas, in its SVG units.
    var viewBox: CGSize
    /// Where the card sits relative to its column: the winner's is drawn 18
    /// points out on every side, for its glow.
    var frame: CGRect
    var path: Path
    var tint: Color
    /// The SVG's `gradientTransform` for the tint's unit circle.
    var tintTransform: CGAffineTransform
    var borderStart: CGPoint
    var borderEnd: CGPoint
    var borderColors: [Color]
    var borderEndOpacity: Double
    var hasGlow: Bool

    static func forPlace(_ place: PodiumPlace) -> PodiumCardSpec {
        switch place {
        case .first:
            PodiumCardSpec(
                viewBox: CGSize(width: 156, height: 223.524),
                frame: CGRect(x: -18, y: -18, width: 156, height: 223.524),
                path: winnerPath,
                tint: Color(hex: 0xFFB06F),
                tintTransform: CGAffineTransform(translationX: 78, y: 18)
                    .rotated(by: .pi / 2)
                    .scaledBy(x: 188, y: 120),
                borderStart: CGPoint(x: 25.435, y: 18),
                borderEnd: CGPoint(x: 64.37, y: 211.909),
                borderColors: [Color(hex: 0xE3C784), Color(hex: 0x846416), Color(hex: 0xD0B679)],
                borderEndOpacity: 0.916,
                hasGlow: true
            )
        case .second:
            PodiumCardSpec(
                viewBox: CGSize(width: 96, height: 155.395),
                frame: CGRect(x: 0, y: 0, width: 96, height: 155.395),
                path: runnerUpPath,
                tint: Color(hex: 0x8993FA),
                tintTransform: CGAffineTransform(a: -2.656, b: 156, c: -130.577, d: -2.879, tx: 48, ty: 0),
                borderStart: CGPoint(x: 5.948, y: 0),
                borderEnd: CGPoint(x: 38.463, y: 160.535),
                borderColors: [Color(hex: 0xD7E7F1), Color(hex: 0x5884A0), Color(hex: 0xD7E7F1)],
                borderEndOpacity: 1,
                hasGlow: false
            )
        case .third:
            PodiumCardSpec(
                viewBox: CGSize(width: 96, height: 155.395),
                frame: CGRect(x: 0, y: 0, width: 96, height: 155.395),
                path: runnerUpPath,
                tint: Color(hex: 0xFF6831),
                tintTransform: CGAffineTransform(a: 0, b: 156, c: -85.016, d: -17.4, tx: 48, ty: 0),
                borderStart: CGPoint(x: 6.204, y: -9.81),
                borderEnd: CGPoint(x: 32.417, y: 135.978),
                borderColors: [Color(hex: 0xFFB97B), Color(hex: 0xA96830), Color(hex: 0xFFB97B)],
                borderEndOpacity: 0.916,
                hasGlow: false
            )
        }
    }

    /// `M18 22C18 19.7909 … 18 173.402V22Z` — the winner's pennant, inset 18
    /// for its glow.
    private static let winnerPath: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 18, y: 22))
        path.addCurve(to: CGPoint(x: 22, y: 18), control1: CGPoint(x: 18, y: 19.7909), control2: CGPoint(x: 19.7909, y: 18))
        path.addLine(to: CGPoint(x: 134, y: 18))
        path.addCurve(to: CGPoint(x: 138, y: 22), control1: CGPoint(x: 136.209, y: 18), control2: CGPoint(x: 138, y: 19.7909))
        path.addLine(to: CGPoint(x: 138, y: 173.402))
        path.addCurve(to: CGPoint(x: 135.795, y: 176.977), control1: CGPoint(x: 138, y: 174.915), control2: CGPoint(x: 137.147, y: 176.298))
        path.addLine(to: CGPoint(x: 79.7951, y: 205.099))
        path.addCurve(to: CGPoint(x: 76.2049, y: 205.099), control1: CGPoint(x: 78.6656, y: 205.666), control2: CGPoint(x: 77.3344, y: 205.666))
        path.addLine(to: CGPoint(x: 20.2049, y: 176.977))
        path.addCurve(to: CGPoint(x: 18, y: 173.402), control1: CGPoint(x: 18.8532, y: 176.298), control2: CGPoint(x: 18, y: 174.915))
        path.closeSubpath()
        return path
    }()

    /// `M0 4C0 1.79086 … 0 126.289V4Z` — second and third.
    private static let runnerUpPath: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 4))
        path.addCurve(to: CGPoint(x: 4, y: 0), control1: CGPoint(x: 0, y: 1.79086), control2: CGPoint(x: 1.79086, y: 0))
        path.addLine(to: CGPoint(x: 92, y: 0))
        path.addCurve(to: CGPoint(x: 96, y: 4), control1: CGPoint(x: 94.2091, y: 0), control2: CGPoint(x: 96, y: 1.79086))
        path.addLine(to: CGPoint(x: 96, y: 126.289))
        path.addCurve(to: CGPoint(x: 93.9823, y: 129.764), control1: CGPoint(x: 96, y: 127.726), control2: CGPoint(x: 95.2299, y: 129.052))
        path.addLine(to: CGPoint(x: 49.9823, y: 154.869))
        path.addCurve(to: CGPoint(x: 46.0177, y: 154.869), control1: CGPoint(x: 48.7537, y: 155.57), control2: CGPoint(x: 47.2463, y: 155.57))
        path.addLine(to: CGPoint(x: 2.01767, y: 129.764))
        path.addCurve(to: CGPoint(x: 0, y: 126.289), control1: CGPoint(x: 0.770119, y: 129.052), control2: CGPoint(x: 0, y: 127.726))
        path.closeSubpath()
        return path
    }()
}
