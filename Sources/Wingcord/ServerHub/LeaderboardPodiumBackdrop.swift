import SwiftUI

/// The night behind the podium: a violet glow where the winner stands and a
/// scatter of small stars.
///
/// **Still, and drawn once.** A card that may sit on screen for an hour gets
/// no animation of its own (INVARIANTS §2, "anything that ticks"); the stars
/// are placed by a fixed seed, so they don't jump between redraws.
struct LeaderboardPodiumBackdrop: View {
    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let glow = Gradient(colors: [
                Color(hex: 0x7B5CFF).opacity(0.38),
                Color(hex: 0x4A2E9C).opacity(0.18),
                .clear,
            ])
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .radialGradient(
                    glow,
                    center: CGPoint(x: size.width / 2, y: size.height * 0.55),
                    startRadius: 0,
                    endRadius: max(size.width, size.height) * 0.55
                )
            )
            var seed = SeededGenerator(state: 0x5EED_57A2)
            for _ in 0..<44 {
                let x = CGFloat.random(in: 0...size.width, using: &seed)
                let y = CGFloat.random(in: 0...size.height, using: &seed)
                let radius = CGFloat.random(in: 0.6...1.8, using: &seed)
                let alpha = Double.random(in: 0.25...0.8, using: &seed)
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: radius * 2, height: radius * 2)),
                    with: .color(.white.opacity(alpha))
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
