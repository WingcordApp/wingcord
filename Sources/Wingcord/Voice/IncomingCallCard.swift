import SwiftUI

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

    var body: some View {
        HStack(spacing: Spacing.snug) {
            AvatarView(url: avatarURL, monogram: monogram, side: 44)
                .overlay {
                    // The ring's pulse, ambient and self-initiated — the one
                    // class §3 exempts from the two-hundred-millisecond bar.
                    // **Off a timeline, not a `repeatForever` animation**, which
                    // SwiftUI waits on before it removes a view — so an
                    // answered call's card could never leave. See `VoiceTile`.
                    SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30, paused: motion.reduceMotion)) { timeline in
                        let ring = Self.ring(at: timeline.date, still: motion.reduceMotion)
                        Circle()
                            .strokeBorder(Palette.presenceOnline.opacity(0.55 - 0.45 * ring), lineWidth: 2)
                            .padding(-2.5 - 4.5 * ring)
                    }
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
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.card))
        .padding(.top, Spacing.base)
        .transition(.move(edge: .top).combined(with: .materialize(from: .top)))
        .animation(motion.panel, value: callerName)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Incoming call from \(callerName)"))
    }

    /// 0…1 and back over two seconds, eased at both ends.
    private static func ring(at date: Date, still: Bool) -> CGFloat {
        guard !still else { return 0 }
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2
        return 0.5 - 0.5 * cos(phase * 2 * .pi)
    }
}
