import SwiftUI

// MARK: - The podium's entrance
//
// Discord's, from its stylesheet (`.full-motion .podium_i8iX4X` and the
// columns), with its timings and curves, all after the stack's half-second
// hold: the winner falls in from 1.6× from 250 ms; second and third slide in
// from 116 points either side from 680 and 780 ms; each column's face and words
// rise six points after it lands; the medals pop with an overshoot last. Nothing moves under Reduce Motion —
// Discord runs it only under `.full-motion`.

/// A column arriving.
struct PodiumEntrance: ViewModifier {
    var place: PodiumPlace
    var hasLanded: Bool

    func body(content: Content) -> some View {
        switch place {
        case .first:
            content
                .scaleEffect(hasLanded ? 1 : 1.6, anchor: UnitPoint(x: 0.5, y: 0.15))
                .animation(.timingCurve(0.55, 0, 1, 0.45, duration: 0.56).delay(PodiumPlace.hold + 0.25), value: hasLanded)
                .opacity(hasLanded ? 1 : 0)
                .animation(.timingCurve(0.32, 0, 0.67, 0, duration: 0.39).delay(PodiumPlace.hold + 0.25), value: hasLanded)
        case .second, .third:
            content
                .scaleEffect(hasLanded ? 1 : 0.9)
                .offset(x: hasLanded ? 0 : (place == .second ? 116 : -116))
                .opacity(hasLanded ? 1 : 0)
                .animation(
                    .timingCurve(0.25, 1.08, 0.5, 1, duration: 0.56).delay(PodiumPlace.hold + (place == .second ? 0.68 : 0.78)),
                    value: hasLanded
                )
        }
    }
}
