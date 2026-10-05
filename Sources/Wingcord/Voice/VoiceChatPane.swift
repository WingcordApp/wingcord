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
// somebody writes a line. And it is drawn as every other column is — see
// `ColumnTranscript` — so a call's chat and a thread beside a conversation are
// recognisably the same kind of thing.
struct VoiceChatPane: View {
    var chrome: ChannelPreviewChrome
    var close: () -> Void

    var body: some View {
        ColumnTranscript(channelID: chrome.channelID) {
            GlassEffectContainer(spacing: Spacing.base) {
                HStack(spacing: Spacing.base) {
                    ColumnHeaderIdentity(name: chrome.name, help: chrome.topic ?? chrome.name) {
                        Image(symbol: chrome.symbolName)
                    }
                    Spacer(minLength: 0)
                    ColumnHeaderControl(systemImage: "xmark", label: "Close Chat", action: close)
                }
            }
            .padding(.horizontal, Spacing.snug)
            .padding(.bottom, Spacing.base)
        } foot: {
            VStack(spacing: 0) {
                ComposerStatusRow(channelID: chrome.channelID)
                ComposerContainer(channelID: chrome.channelID)
            }
        }
        .frame(width: Proportions.threadColumnIdeal)
        // The column's own edge — `ThreadPanel`'s reason: the call beside it is
        // the same opaque ground.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Ink.quaternary)
                .frame(width: 1)
                .ignoresSafeArea()
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
        VoiceChatPane(chrome: model.channelPreviewChrome(for: channelID)) {
            model.isVoiceChatShown = false
        }
    }
}
