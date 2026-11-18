import SwiftUI

/// A running activity's controls under its game, in the call capsule's glass:
/// the app, what to do with its window, then Leave in red (Alex, 2026-11-18,
/// picked over a strip along the top edge and buttons on the corners).
///
/// **Under the game, never over it.** An activity draws to its own edges —
/// Wordle's keyboard is its last row — so a control on the frame would sit on
/// somebody's keys. The call stage pins its capsule under a game for the same
/// reason (`floatingCallControls(isPinned:)`), and this is that capsule's
/// vocabulary: regions of one body of glass, the window's controls set apart,
/// the destructive one in the call's red.
struct ActivityStageCapsule: View {
    var activity: RunningActivity
    @Binding var isFullHeight: Bool

    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: Spacing.base) {
                RemoteImage(url: activity.iconURL, side: 20) { Color.clear }
                    .frame(width: 20, height: 20)
                    .clipShape(.rect(cornerRadius: 6, style: .continuous))
                Text(activity.name)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(InkColor.primary)
                    .lineLimit(1)
            }
            .padding(.leading, Spacing.snug)
            .padding(.trailing, Spacing.base)
            .frame(height: CallCapsuleMetrics.slot)
            .accessibilityElement(children: .combine)

            divider
            // Discord's Invite to Activity: a server channel only (decision 8).
            if model.canInviteToRunningActivity {
                CallCapsuleAccessory(title: "Invite to Activity", systemImage: "person.crop.circle.badge.plus") {
                    model.inviteToRunningActivity()
                }
            }
            CallCapsuleAccessory(title: "Pop Out", systemImage: "macwindow.on.rectangle") {
                model.popOutActivity()
            }
            // The call band's Fill the Conversation, in this band's words.
            CallCapsuleAccessory(
                title: isFullHeight ? "Shrink the Activity" : "Fill the Conversation",
                systemImage: isFullHeight ? "rectangle.compress.vertical" : "rectangle.expand.vertical"
            ) {
                isFullHeight.toggle()
            }
            divider

            Button {
                Task { await model.sessionController.leaveActivity() }
            } label: {
                Label("Leave", systemImage: "rectangle.portrait.and.arrow.right")
                    .labelStyle(.titleAndIcon)
                    .font(.system(.subheadline, weight: .semibold))
                    .padding(.horizontal, Spacing.snug)
                    .frame(height: CallCapsuleMetrics.slot)
                    .contentShape(.capsule)
            }
            .buttonStyle(CallRegionStyle(part: .whole, isActive: false, isLeave: true))
            .foregroundStyle(CallButtonLook.ink(.leave, isActive: false))
            .help("Leave Activity")
            .accessibilityLabel(Text("Leave \(activity.name)"))
        }
        .padding(CallCapsuleMetrics.padding)
        .fixedSize()
        // Layout first, glass last — the call capsule's order.
        .floatingChrome(in: .capsule)
    }

    /// The call capsule's rule between kinds of control.
    private var divider: some View {
        Capsule()
            .fill(InkColor.primary.opacity(0.2))
            .frame(width: 1, height: CallCapsuleMetrics.disc / 2)
            .padding(.horizontal, CallCapsuleMetrics.padding)
            .accessibilityHidden(true)
    }
}
