import SwiftUI

/// The sign-in screen's living ground (docs/LOGIN-ONBOARDING.md D3–D4): the ember
/// behind the login and, on the welcome, the wings and "Wingcord" over it.
///
/// **Two grounds behind one view.** Wingcord's own builds draw MetalForge's ember
/// wallpaper and its particles gathering into the lockup (`Welcome/MetalForge/`,
/// `EmberRenderer`). That code is used under the owner's MetalForge subscription,
/// whose terms let it ship in the app and forbid publishing it, so it lives in a
/// folder the public copy of the source leaves out (scripts/public-mirror), and
/// `Package.swift` defines `WINGCORD_METALFORGE` only while the folder is there.
/// Without it, or under `--plain-backdrop`, `PlainEmberBackdrop` draws a ground
/// of Wingcord's own.
struct SignInBackdrop: View {
    enum Stage: Equatable {
        case welcome
        case login
    }

    var stage: Stage

    @Environment(\.motion) private var motion

    /// When the welcome's lockup has formed, for Get Started to follow it.
    static var lockupFormedAt: Double {
        #if WINGCORD_METALFORGE
        if !LaunchOptions.current.forcesPlainBackdrop { return EmberRenderer.lockupFormedAt }
        #endif
        return PlainEmberBackdrop.lockupFormedAt
    }

    var body: some View {
        ground
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var ground: some View {
        #if WINGCORD_METALFORGE
        if LaunchOptions.current.forcesPlainBackdrop {
            PlainEmberBackdrop(stage: stage, reduceMotion: motion.reduceMotion)
        } else {
            ZStack {
                // Under the Metal view: what shows if it can't start.
                PlainEmberBackdrop.still
                BackdropMetalView(stage: stage, reduceMotion: motion.reduceMotion)
            }
        }
        #else
        PlainEmberBackdrop(stage: stage, reduceMotion: motion.reduceMotion)
        #endif
    }
}
