import SwiftUI
import WingcordCore

/// What stands in a message request's composer slot: Discord's bar (`n$`),
/// "Accept the request to send a message, view attachments, and use links.",
/// with Decline and Accept DM.
///
/// **Where the composer would be, and the same glass body**, so a request reads
/// as a conversation that is not open yet rather than as a different surface.
/// Both answers wait while one is out — Discord disables the pair together.
struct MessageRequestBar: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model

    var body: some View {
        let isBusy = model.messageRequestsInFlight.contains(channelID)
        VStack(alignment: .leading, spacing: Spacing.snug) {
            Text("Accept the request to send a message, view attachments, and use links.")
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.base) {
                Spacer(minLength: 0)
                MessageRequestButton(title: "Decline", isProminent: false, isBusy: isBusy) {
                    model.declineMessageRequest(channelID)
                }
                MessageRequestButton(title: "Accept DM", isProminent: true, isBusy: isBusy) {
                    model.acceptMessageRequest(channelID)
                }
            }
        }
        .padding(Spacing.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.clear, in: .rect(cornerRadius: Radius.glass))
        .padding(.horizontal, Spacing.margin)
        .padding(.bottom, Spacing.snug)
    }
}

/// One of a request's two answers: Discord's small secondary and primary.
struct MessageRequestButton: View {
    var title: String
    var isProminent: Bool
    var isBusy: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(isProminent ? AnyShapeStyle(.white) : AnyShapeStyle(Ink.primary))
                .padding(.horizontal, Spacing.snug)
                .frame(height: Metrics.control)
                .background(
                    isProminent ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Palette.hoverFill),
                    in: .capsule
                )
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .opacity(isBusy ? 0.5 : 1)
    }
}
