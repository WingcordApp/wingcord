import AppKit

/// The trackpad's three feelings, named for what they mean here.
///
/// **Only for a gesture already under the reader's finger.** macOS plays these
/// on a Force Touch trackpad and nowhere else, so nothing may depend on one —
/// each marks something the screen is already showing: a notch reached, an edge
/// hit, a choice made.
enum Haptics {
    /// A notch on a dial — the colour rail settling on a named hue.
    static func tick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Something stopped the gesture — the puck reaching the pad's edge.
    static func bump() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    /// A choice landed — a swatch, the dice, the eyedropper.
    static func pop() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
}
