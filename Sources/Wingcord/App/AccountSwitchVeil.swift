import SwiftUI
import WingcordCore

/// What's on screen during a switch: who you're becoming, over the whole window.
///
/// **Never the sign-in screen.** Their picture materializes over the app, everything of
/// the last account is cleared behind it, and it dissolves onto the new one when that's
/// ready. It lets nothing through, because the window underneath is empty by then and
/// the next account's READY is about to land on the main thread.
///
/// **The ground and the content in two `if`s, because each comes and goes its own way**:
/// a transition inside something that's coming or going isn't honoured.
struct AccountSwitchVeilHost: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    func body(content: Content) -> some View {
        content
            .overlay {
                if let change = model.accountSwitch {
                    // A switch covers the window it's emptying. A sign-in has
                    // nothing behind it to hide but its own backdrop, which only
                    // dims, so the ember runs on under the veil.
                    Group {
                        if change.kind == .signingIn {
                            Color.black.opacity(0.42)
                        } else {
                            Color.clear.readingSurface()
                        }
                    }
                    .contentShape(.rect)
                    .accessibilityHidden(true)
                    // **Past the titlebar** (`INVARIANTS.md`): stopped at the
                    // safe area, "Logging in as…" dimmed everything but the
                    // strip under the traffic lights, where the ember burned on
                    // at full strength (Alex, 2026-11-18).
                    .ignoresSafeArea()
                    .transition(.opacity)
                }
            }
            .overlay {
                if let change = model.accountSwitch {
                    AccountSwitchVeil(target: change.target, kind: change.kind)
                        .transition(motion.reduceMotion ? AnyTransition.opacity : AnyTransition(.materialize))
                }
            }
            .animation(motion.reduceMotion ? motion.fade : .easeInOut(duration: AccountSwitch.veilIn), value: model.accountSwitch?.serial)
            .task(id: model.accountSwitch?.serial) {
                guard let serial = model.accountSwitch?.serial else { return }
                try? await Task.sleep(for: .seconds(AccountSwitch.veilAtLeast))
                while model.accountSwitch?.serial == serial, !Task.isCancelled {
                    if case .failed = model.connectionState { break }
                    if case .signedOut = model.connectionState { break }
                    if model.showsWorkspace {
                        // A beat for the first layout of the new window, under cover.
                        try? await Task.sleep(for: .milliseconds(150))
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard model.accountSwitch?.serial == serial else { return }
                model.accountSwitch = nil
            }
    }
}

private struct AccountSwitchVeil: View {
    var target: StoredAccount
    var kind: AccountSwitch.Kind

    private static let picture: CGFloat = 96

    private var title: String {
        switch kind {
        case .switching: "Switching to \(target.preferredName)"
        case .signingIn: "Logging in as \(target.preferredName)"
        }
    }

    var body: some View {
        VStack(spacing: Spacing.margin) {
            AvatarView(
                url: target.avatarURL(side: Self.picture),
                monogram: target.monogram,
                side: Self.picture
            )
            VStack(spacing: Spacing.hair) {
                Text(title)
                    .font(.system(.title2, weight: .semibold))
                    .foregroundStyle(InkColor.solid)
                Text("@\(target.username)")
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.secondary)
            }
            // AppKit's own, which keeps turning while READY has the main thread.
            ProgressView().controlSize(.small)
        }
        .accessibilityElement(children: .combine)
        // The whole window's changing under somebody who can't see it change.
        .onAppear {
            AccessibilityNotification.Announcement(title).post()
        }
    }
}
