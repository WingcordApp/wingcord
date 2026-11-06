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
                if model.accountSwitch != nil {
                    Color.clear
                        .readingSurface()
                        .contentShape(.rect)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
            .overlay {
                if let change = model.accountSwitch {
                    AccountSwitchVeil(target: change.target)
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

    private static let picture: CGFloat = 96

    var body: some View {
        VStack(spacing: Spacing.margin) {
            AvatarView(
                url: target.avatarURL(side: Self.picture),
                monogram: target.monogram,
                side: Self.picture
            )
            VStack(spacing: Spacing.hair) {
                Text("Switching to \(target.preferredName)")
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
            AccessibilityNotification.Announcement("Switching to \(target.preferredName)").post()
        }
    }
}
