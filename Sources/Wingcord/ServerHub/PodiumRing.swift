import SwiftUI

/// The ring around a face on the podium, drawn natively from Discord's three
/// ring SVGs (`/assets/607118ac1eb0343b.svg` and its two siblings): two
/// one-point circles in vertical gradients, the inner with a soft shadow under
/// it, the outer with a warm light above it.
struct PodiumRing: View {
    var place: PodiumPlace

    private struct Spec {
        var center: CGPoint
        var inner: (top: UInt32, bottom: UInt32)
        var outer: (top: UInt32, bottom: UInt32)
        var gradientTop: CGFloat
        var gradientBottom: CGFloat
    }

    var body: some View {
        let spec = Self.spec(place)
        Canvas { context, _ in
            let start = CGPoint(x: spec.center.x, y: spec.gradientTop)
            let end = CGPoint(x: spec.center.x, y: spec.gradientBottom)

            // "Ring stroke": r 19.5 (30.5 for the winner), a drop shadow one
            // point down.
            var inner = context
            inner.addFilter(.shadow(color: .black.opacity(0.49), radius: 0.5, x: 0, y: 1))
            inner.stroke(
                circle(spec.center, radius: place == .first ? 30.5 : 19.5),
                with: .linearGradient(
                    Gradient(colors: [Color(hex: spec.inner.top), Color(hex: spec.inner.bottom)]),
                    startPoint: start, endPoint: end
                ),
                lineWidth: 1
            )

            // "Ring highlight": a point further out, lit from above.
            var outer = context
            outer.addFilter(.shadow(
                color: Color(red: 1, green: 0.953, blue: 0.545).opacity(0.3),
                radius: 1, x: 0, y: -1
            ))
            outer.stroke(
                circle(spec.center, radius: place == .first ? 31.5 : 20.5),
                with: .linearGradient(
                    Gradient(colors: [Color(hex: spec.outer.top), Color(hex: spec.outer.bottom)]),
                    startPoint: start, endPoint: end
                ),
                lineWidth: 1
            )
        }
        .frame(width: place.ringFrame.width, height: place.ringFrame.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func circle(_ center: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private static func spec(_ place: PodiumPlace) -> Spec {
        switch place {
        case .first:
            Spec(center: CGPoint(x: 34, y: 35), inner: (0xEA8B00, 0xE6BA63), outer: (0xFFE990, 0xDCA041),
                 gradientTop: 4, gradientBottom: 66)
        case .second:
            Spec(center: CGPoint(x: 23, y: 24), inner: (0x464F5F, 0xA3B5BB), outer: (0xD7E7F1, 0x586273),
                 gradientTop: 4, gradientBottom: 44)
        case .third:
            Spec(center: CGPoint(x: 22, y: 23), inner: (0xDB4D00, 0xFF8731), outer: (0xFFB97B, 0xDB4D00),
                 gradientTop: 3, gradientBottom: 43)
        }
    }
}
