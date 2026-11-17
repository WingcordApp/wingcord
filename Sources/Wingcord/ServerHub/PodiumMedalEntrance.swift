import SwiftUI

/// A medal popping in, last.
struct PodiumMedalEntrance: ViewModifier {
    var place: PodiumPlace
    var hasLanded: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(hasLanded ? 1 : 0.4)
            .opacity(hasLanded ? 1 : 0)
            .animation(.timingCurve(0.34, 1.56, 0.64, 1, duration: 0.42).delay(PodiumPlace.hold + delay), value: hasLanded)
    }

    private var delay: Double {
        switch place {
        case .first: 0.86
        case .second: 1.02
        case .third: 1.12
        }
    }
}
