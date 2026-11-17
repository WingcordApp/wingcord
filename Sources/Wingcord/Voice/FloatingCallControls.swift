import SwiftUI

/// Floats the call's capsule over the foot of what it is applied to, and shows
/// it while the pointer is over that — FaceTime's controls.
///
/// **The pointer reveals it** (HIG, Pointing devices: "Let the pointer reveal
/// and hide controls that automatically minimize or fade out"), so a call
/// someone is only watching is all faces. It never hides on a timer here
/// (HIG, Accessibility: minimize time-boxed UI): it stays while the pointer is
/// over the call, while anything it raised is open, for a few seconds after the
/// call appears so the reader learns where it lives, and always under
/// VoiceOver.
struct FloatingCallControls<Controls: View>: ViewModifier {
    /// Shown whatever the pointer does: an activity being played, where the
    /// capsule sits under the game rather than over it.
    var isPinned: Bool
    /// Above the foot of the content.
    var lift: CGFloat
    var controls: Controls

    @Environment(\.motion) private var motion
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverOn
    @State private var isPointerInside = false
    @State private var isEngaged = false
    @State private var isIntroducing = true

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                controls
                    .onPreferenceChange(CallControlsEngagedKey.self) { engaged in
                        isEngaged = engaged
                    }
                    .padding(.bottom, lift)
                    // It rises from the foot it lives at and sinks back into it
                    // (apple-design §7), and only fades under Reduce Motion.
                    .opacity(isShown ? 1 : 0)
                    .offset(y: isShown || motion.reduceMotion ? 0 : 6)
                    .allowsHitTesting(isShown)
                    .accessibilityHidden(!isShown)
                    .animation(motion.standard, value: isShown)
            }
            .onHover { hovering in
                guard isPointerInside != hovering else { return }
                isPointerInside = hovering
            }
            .task {
                try? await Task.sleep(for: .seconds(3))
                isIntroducing = false
            }
    }

    private var isShown: Bool {
        isPinned || isPointerInside || isEngaged || isIntroducing || isVoiceOverOn
    }
}

extension View {
    /// The call's capsule, floating over this view's foot. See
    /// `FloatingCallControls`.
    func floatingCallControls<Controls: View>(
        isPinned: Bool = false,
        lift: CGFloat = CallCapsuleMetrics.lift,
        @ViewBuilder controls: () -> Controls
    ) -> some View {
        modifier(FloatingCallControls(isPinned: isPinned, lift: lift, controls: controls()))
    }
}
