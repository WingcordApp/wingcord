import SwiftUI
import WingcordCore

// MARK: - A thread, beside whatever it hangs off
//
// **The ordinary timeline and the ordinary composer, pointed at the thread.** A
// thread is a channel — see `ThreadMetadata` — so there is no second transcript
// type and no second store, exactly as a voice channel's chat is not one.
//
// It lives in the supplementary column for the reason the roster does: the thing
// the column is for is *beside* what you are doing. A thread sits beside the
// conversation it came out of; a forum post sits beside its board, which is also
// what keeps a way back on screen — see `AppModel.openThread`.
//
// **The chrome is every right-hand column's.** `ColumnTranscript` and
// `ColumnHeader` settle what one looks like in this app: a floating glass
// cluster over a transcript that runs beneath it, and a hairline down the
// leading edge because the column beside it is the same opaque ground. A second
// answer to the same question would be right-hand columns that do not look
// related.

struct ThreadPanel: View {
    var presentation: ThreadPanelPresentation
    var close: () -> Void
    /// The thread as the page — Discord's header click.
    var openFullView: () -> Void

    var body: some View {
        ColumnTranscript(channelID: presentation.channelID) {
            ThreadPanelHeader(
                presentation: presentation,
                close: close,
                openFullView: openFullView
            )
            .padding(.horizontal, Spacing.snug)
            .padding(.bottom, Spacing.base)
        } foot: {
            VStack(spacing: 0) {
                // Discord's banner over a locked thread, then the composer —
                // which says on its own when the reader cannot write here.
                ThreadBannerContainer(channelID: presentation.channelID)
                ComposerStatusRow(channelID: presentation.channelID)
                ComposerContainer(channelID: presentation.channelID)
            }
        }
        .frame(width: width)
        // The column's own edge. The transcript beside it is the same opaque
        // ground, so without a line the two run together and the thread reads
        // as the conversation having grown a second column of text.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Ink.quaternary)
                .frame(width: 1)
                .ignoresSafeArea()
        }
    }

    /// **Wider for a post, because the roles are reversed.** Beside a transcript
    /// the thread is the aside and the conversation is the page; beside a
    /// *board* the post is the page and the list is the index you came in
    /// through.
    private var width: CGFloat {
        presentation.isPost ? Proportions.postColumnIdeal : Proportions.threadColumnIdeal
    }
}

/// The name, the thread's menu, and Close — the column's header, see
/// `ColumnHeader`.
private struct ThreadPanelHeader: View {
    var presentation: ThreadPanelPresentation
    var close: () -> Void
    var openFullView: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: Spacing.base) {
            HStack(spacing: Spacing.base) {
                // The name is the way to the whole page, as Discord's header
                // is.
                Button(action: openFullView) {
                    identity
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                // Discord's "More" — the thread's own menu, in the split
                // view's order (`ThreadMenu.groups(at:developerMode:)`).
                ThreadMoreButton(threadID: presentation.channelID, place: .panel) {
                    ColumnHeaderControl.glyph("ellipsis")
                }
                .buttonStyle(.plain)
                .interactiveChromeOverMedia(in: .circle)
                .accessibilityLabel(Text("More"))
                ColumnHeaderControl(systemImage: "xmark", label: "Close", action: close)
            }
        }
    }

    private var identity: some View {
        ColumnHeaderIdentity(name: presentation.name, help: presentation.subtitle ?? presentation.name) {
            Image(symbol: presentation.symbolName)
        } accessory: {
            // The muted bell rides inside the identity capsule rather
            // than taking a control of its own: it is a fact about the
            // thread, not something to press.
            if presentation.isMuted {
                Image(systemName: "bell.slash.fill")
                    .font(.system(.caption2))
                    .foregroundStyle(Ink.tertiary)
                    .accessibilityLabel(Text(presentation.muteSummary ?? "Muted"))
            }
        }
    }
}

// MARK: - Container

/// Reads the store and hands the panel its snapshot.
///
/// One container per surface — §2 — so a message arriving in the conversation
/// beside it cannot invalidate the thread.
struct ThreadPanelContainer: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model

    var body: some View {
        ThreadPanel(
            presentation: model.threadPanelPresentation(for: channelID),
            close: { model.closeThread() },
            openFullView: { model.openThread(channelID, as: .fullView) }
        )
    }
}
