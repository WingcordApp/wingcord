import SwiftUI
import WingcordCore

// MARK: - Somebody is calling
//
// A card at the top of the window, over everything. Not an alert and not a
// sheet: both are modal, and a call arriving while you are typing must not take
// the keyboard away — you should be able to finish the sentence and then decide.
//
// **Two buttons, and only one of them is tinted.** Accept is the affirmative
// action and Decline is the destructive one; a card where both are coloured has
// no default, and a call that rings at three in the morning is exactly when the
// default matters.
struct IncomingCallCard: View {
    var callerName: String
    var avatarURL: URL?
    var monogram: String
    var accept: () -> Void
    var decline: () -> Void

    @Environment(\.motion) private var motion
    /// Drives the ring's pulse while it is ringing. Ambient, self-initiated
    /// motion — the one class §3 exempts from the two-hundred-millisecond bar.
    @State private var isRinging = false

    var body: some View {
        HStack(spacing: Spacing.snug) {
            AvatarView(url: avatarURL, monogram: monogram, side: 44)
                .overlay {
                    Circle()
                        .strokeBorder(Palette.presenceOnline.opacity(isRinging ? 0.1 : 0.55), lineWidth: 2)
                        .padding(isRinging ? -7 : -2.5)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(callerName)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                Text("Incoming call")
                    .font(Typeface.rowSubtitle)
                    .foregroundStyle(Ink.secondary)
            }

            Spacer(minLength: Spacing.margin)

            Button(action: decline) {
                Image(systemName: "phone.down.fill")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(InkColor.primary)
                    .frame(width: 34, height: 34)
                    .background { Circle().fill(Palette.destructive) }
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Decline")
            .accessibilityLabel(Text("Decline the call"))

            Button(action: accept) {
                Image(systemName: "phone.fill")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(InkColor.primary)
                    .frame(width: 34, height: 34)
                    .background { Circle().fill(Palette.affirmative) }
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .help("Answer")
            .accessibilityLabel(Text("Answer the call"))
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, Spacing.base)
        .frame(width: 360)
        .glassEffect(.clear.tint(Palette.flyoutTint), in: .rect(cornerRadius: Radius.card))
        .padding(.top, Spacing.base)
        .transition(.move(edge: .top).combined(with: .materialize(from: .top)))
        .task {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                isRinging = true
            }
        }
        .onDisappear { isRinging = false }
        .animation(motion.panel, value: callerName)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Incoming call from \(callerName)"))
    }
}
