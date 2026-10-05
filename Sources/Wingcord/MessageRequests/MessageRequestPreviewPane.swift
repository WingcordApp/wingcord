import SwiftUI
import WingcordCore

/// A message request read beside its page — Discord's sidebar
/// (`ViewMessageRequestSidebar`): the conversation with its media held back,
/// and the request's bar where the composer would be.
///
/// **The transcript is the ordinary one.** It knows the channel is a request
/// and lays its messages out as Discord's restricted preview does — see
/// `Message.restrictedPreview` — so this pane adds only the chrome around it.
/// A spam request also carries Discord's question above it, with Mark as Not
/// Spam, which accepts it.
struct MessageRequestPreviewPane: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model

    var body: some View {
        let isSpam = model.channelIndex[channelID]?.messageRequest == .spam
        ColumnTranscript(channelID: channelID) {
            VStack(spacing: Spacing.base) {
                ChannelPreviewHeader(
                    chrome: model.channelPreviewChrome(for: channelID),
                    open: nil,
                    close: { model.previewMessageRequest(channelID) }
                )
                if isSpam { SpamQuestion(channelID: channelID) }
            }
            .padding(.horizontal, Spacing.snug)
            .padding(.bottom, Spacing.base)
        } foot: {
            // The request's bar where the composer would be — measured and
            // paid as an inset like the composer, by `ColumnTranscript`.
            MessageRequestBar(channelID: channelID)
        }
        .frame(width: Proportions.previewColumnIdeal)
        // The column's own edge — `ChannelPreviewPane`'s reason.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Ink.quaternary)
                .frame(width: 1)
                .ignoresSafeArea()
        }
    }
}

/// Discord's question over a spam request (`XVOKgj`), and its one answer.
private struct SpamQuestion: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text("Was this message spam? Let us know and help improve Discord\u{2019}s spam filtering.")
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            MessageRequestButton(
                title: "Mark as Not Spam",
                isProminent: false,
                isBusy: model.messageRequestsInFlight.contains(channelID)
            ) {
                model.acceptMessageRequest(channelID)
            }
        }
        .padding(Spacing.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.clear, in: .rect(cornerRadius: Radius.glass))
    }
}
