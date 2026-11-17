import SwiftUI

/// One pennant behind a place on the podium, drawn natively from Discord's own
/// numbers (`PodiumCardSpec`) — no file of theirs is shipped or fetched.
///
/// The SVG's `preserveAspectRatio="none"` is honoured: the drawing is scaled
/// to whatever box it is given, as the stylesheet sizes it.
struct PodiumCard: View {
    var place: PodiumPlace

    var body: some View {
        let spec = PodiumCardSpec.forPlace(place)
        Canvas { context, size in
            context.scaleBy(x: size.width / spec.viewBox.width, y: size.height / spec.viewBox.height)
            if spec.hasGlow { drawGlow(spec, in: &context) }

            // The surface, then the place's colour from the top at a quarter.
            context.fill(spec.path, with: .color(PodiumCard.surface))
            var tint = context
            tint.clip(to: spec.path)
            tint.opacity = 0.25
            tint.concatenate(spec.tintTransform)
            tint.fill(
                Path(CGRect(x: -4, y: -4, width: 8, height: 8)),
                with: .radialGradient(
                    Gradient(colors: [spec.tint, spec.tint.opacity(0)]),
                    center: .zero,
                    startRadius: 0,
                    endRadius: 1
                )
            )

            // A two-point stroke masked by the shape: the inner point shows.
            var border = context
            border.clip(to: spec.path)
            border.stroke(
                spec.path,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: spec.borderColors[0], location: 0),
                        .init(color: spec.borderColors[1], location: 0.514),
                        .init(color: spec.borderColors[2].opacity(spec.borderEndOpacity), location: 1),
                    ]),
                    startPoint: spec.borderStart,
                    endPoint: spec.borderEnd
                ),
                lineWidth: 2
            )

            if spec.hasGlow { drawInnerGlow(spec, in: &context) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Discord's `--background-surface-high`: a theme's raised surface, which
    /// in this app is the theme's own (`Palette.surfaceRaised`).
    static let surface = Palette.surfaceRaised

    /// The winner's outer glow and its warm rim, outside the shape only — the
    /// filter's `outerGlow` (blur 9) and `highlightGlow` (blur 2.5).
    private func drawGlow(_ spec: PodiumCardSpec, in context: inout GraphicsContext) {
        context.drawLayer { layer in
            layer.clipToLayer(options: .inverse) { mask in
                mask.fill(spec.path, with: .color(.black))
            }
            var outer = layer
            outer.addFilter(.blur(radius: 9))
            outer.fill(spec.path, with: .color(Color(red: 0.961, green: 0.601, blue: 0.098).opacity(0.41)))
            var rim = layer
            rim.addFilter(.blur(radius: 2.5))
            rim.fill(spec.path, with: .color(Color(red: 1, green: 0.881, blue: 0.713).opacity(0.35)))
        }
    }

    /// The filter's `innerGlow`: the shape less its own blur (7.5), so the
    /// colour gathers along the inside of the edge.
    private func drawInnerGlow(_ spec: PodiumCardSpec, in context: inout GraphicsContext) {
        context.drawLayer { layer in
            layer.clip(to: spec.path)
            layer.fill(spec.path, with: .color(Color(red: 0.961, green: 0.299, blue: 0.098).opacity(0.21)))
            var eraser = layer
            eraser.blendMode = .destinationOut
            eraser.addFilter(.blur(radius: 7.5))
            eraser.fill(spec.path, with: .color(.black))
        }
    }
}
