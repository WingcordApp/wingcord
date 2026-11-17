import SwiftUI

/// A column's face and words, once it has landed.
struct PodiumContentEntrance: ViewModifier {
    var place: PodiumPlace
    var hasLanded: Bool

    func body(content: Content) -> some View {
        content
            .offset(y: hasLanded ? 0 : 6)
            .opacity(hasLanded ? 1 : 0)
            .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.32).delay(PodiumPlace.hold + delay), value: hasLanded)
    }

    private var delay: Double {
        switch place {
        case .first: 0.72
        case .second: 0.93
        case .third: 1.03
        }
    }
}
