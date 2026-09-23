import SwiftUI
import WingcordCore

// MARK: - A voice channel's text chat
//
// **A voice channel has a transcript, and it is the same channel.** Discord gives
// a voice channel the same id for both halves, so this is the ordinary timeline
// and the ordinary composer pointed at the channel the call is in — not a second
// kind of conversation and not a second store.
//
// It lives in the supplementary column rather than under the tiles, for the
// reason the roster does: the thing the column is for is *beside* what you are
// doing, and a chat under a video grid takes height from the grid every time
// somebody writes a line.
struct VoiceChatPane: View {
    var channelID: ChannelID
    var close: () -> Void

    @Environment(AppModel.self) private var model
    @State private var composerHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            transcript
        }
        .frame(width: Proportions.memberColumnIdeal + 40)
    }

    private var header: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(.footnote, weight: .medium))
                .foregroundStyle(Ink.secondary)
            Text(model.channelIndex[channelID]?.name ?? "Chat")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
            Spacer(minLength: Spacing.base)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Hide the chat")
            .accessibilityLabel(Text("Hide the chat"))
        }
        .padding(.horizontal, Spacing.snug)
        .frame(height: 38)
    }

    private var transcript: some View {
        TimelineContainer(channelID: channelID, topInset: 0, bottomInset: composerHeight)
            .safeAreaBar(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    ComposerStatusRow(channelID: channelID)
                    ComposerContainer(channelID: channelID)
                }
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onChange(of: proxy.size.height, initial: true) { _, height in
                                guard abs(composerHeight - height) > 0.5 else { return }
                                // A measured value: written with animations off,
                                // or the transcript lurches whenever the composer
                                // grows a line. §3.
                                var transaction = Transaction()
                                transaction.disablesAnimations = true
                                withTransaction(transaction) { composerHeight = height }
                            }
                    }
                }
            }
    }
}

/// Reads the store and hands the pane its channel.
///
/// One container per surface — §2 — so a message arriving in the chat cannot
/// invalidate the tiles beside it.
struct VoiceChatContainer: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model

    var body: some View {
        VoiceChatPane(channelID: channelID) {
            model.isVoiceChatShown = false
        }
    }
}
