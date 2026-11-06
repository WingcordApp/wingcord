import SwiftUI
import WingcordCore

/// "21 new messages since 7:31 PM · Mark As Read", centred under the toolbar.
///
/// **In a band of its own under the toolbar's row**, floating over the rows:
/// clear glass, untinted, over the transcript — every in-window control here is.
///
/// Two halves, as Discord's bar has: the sentence goes to the first unread
/// message, and Mark As Read acknowledges the channel — which is also what
/// makes the pill go, because it is drawn only while the channel is unread.
struct NewMessagesPill: View {
    /// A step lighter than the composer's controls, and the band it floats in.
    static let pillHeight: CGFloat = 32
    static let bandHeight: CGFloat = pillHeight + Spacing.tight * 2

    var banner: NewMessagesBanner
    var jump: () -> Void
    var markRead: () -> Void

    @Environment(\.motion) private var motion

    var body: some View {
        HStack(spacing: 0) {
            Button(action: jump) {
                Text(banner.sentence())
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentTransition(.numericText())
                    .padding(.leading, Spacing.snug)
                    .padding(.trailing, Spacing.base)
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Goes to the first unread message"))

            Divider().frame(height: NewMessagesPill.pillHeight * 0.5)

            Button(action: markRead) {
                Label("Mark As Read", systemImage: "checkmark.message")
                    .labelStyle(.titleAndIcon)
                    .fontWeight(.semibold)
                    .padding(.leading, Spacing.base)
                    .padding(.trailing, Spacing.snug)
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(InkColor.solid)
        .frame(height: NewMessagesPill.pillHeight)
        .glassEffect(.regular.interactive(), in: .capsule)
        .animation(motion.fadeQuick, value: banner.count)
    }
}
