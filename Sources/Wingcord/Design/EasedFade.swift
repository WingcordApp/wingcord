import SwiftUI

/// Discord's fade for a picture that dissolves into its card
/// (`imageFadeToLeftMask`, module `506619`).
///
/// **Sixteen stops on an ease, not a straight ramp.** A linear fade shows a
/// band where it starts — the eye finds the corner in the ramp — and Discord's
/// curve is the easing gradient that has none. The stops are theirs, to the
/// thousandth.
enum EasedFade {
    /// Transparent at the start, opaque at the end. A mask, so only the alpha
    /// is read.
    static let gradient = Gradient(stops: [
        .init(color: .clear, location: 0),
        .init(color: .black.opacity(0.013), location: 0.047),
        .init(color: .black.opacity(0.049), location: 0.092),
        .init(color: .black.opacity(0.104), location: 0.136),
        .init(color: .black.opacity(0.175), location: 0.18),
        .init(color: .black.opacity(0.259), location: 0.226),
        .init(color: .black.opacity(0.352), location: 0.274),
        .init(color: .black.opacity(0.45), location: 0.326),
        .init(color: .black.opacity(0.55), location: 0.383),
        .init(color: .black.opacity(0.648), location: 0.445),
        .init(color: .black.opacity(0.741), location: 0.514),
        .init(color: .black.opacity(0.825), location: 0.591),
        .init(color: .black.opacity(0.896), location: 0.677),
        .init(color: .black.opacity(0.951), location: 0.773),
        .init(color: .black.opacity(0.987), location: 0.88),
        .init(color: .black, location: 1),
    ])
}

extension View {
    /// Dissolves the view in from its leading edge across its whole width, as
    /// Discord's widget pictures do.
    func fadingInFromLeading() -> some View {
        mask {
            LinearGradient(gradient: EasedFade.gradient, startPoint: .leading, endPoint: .trailing)
        }
    }
}
