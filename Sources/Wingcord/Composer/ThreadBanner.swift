import SwiftUI
import WingcordCore

/// What Discord's banner over a thread's composer says (`128783`'s `U`): a
/// locked thread, or a closed and locked one — and the moderator's way out.
struct ThreadBannerState: Equatable {
    enum Kind: Equatable {
        /// "…has been locked. Only moderators can send messages." — Unlock.
        case locked
        /// "…has been closed and locked. Only moderators can reopen it." — Open.
        case closedAndLocked
    }

    var kind: Kind
    /// A forum post, which Discord's sentences call a post.
    var isPost: Bool
    /// Whether the reader may do something about it: Manage Threads, which is
    /// what both Unlock and reopening a locked thread take.
    var offersAction: Bool

    var message: String {
        let noun = isPost ? "post" : "thread"
        return switch kind {
        case .locked: "This \(noun) has been locked. Only moderators can send messages."
        case .closedAndLocked: "This \(noun) has been closed and locked. Only moderators can reopen it."
        }
    }

    var actionTitle: String {
        switch kind {
        case .locked: "Unlock"
        case .closedAndLocked: "Open"
        }
    }
}

extension AppModel {
    /// The banner over a thread's composer, or nil where Discord shows none —
    /// anything that is not locked.
    func threadBanner(for channelID: ChannelID) -> ThreadBannerState? {
        guard let thread = channelIndex[channelID], thread.kind.isThread,
              let metadata = thread.threadMetadata, metadata.isLocked
        else { return nil }
        let parent = thread.parentID.flatMap { channelIndex[$0] }
        return ThreadBannerState(
            kind: metadata.isArchived ? .closedAndLocked : .locked,
            isPost: ThreadGate.isForumPost(thread, parent: parent),
            offersAction: permissionGate.permissions(in: channelID).contains(.manageThreads)
        )
    }

    /// The banner's button: Unlock, or Open — which opens the thread and leaves
    /// it locked, as Discord's does.
    func performThreadBannerAction(_ kind: ThreadBannerState.Kind, threadID: ChannelID) {
        switch kind {
        case .locked: setThreadLocked(false, threadID: threadID)
        case .closedAndLocked: setThreadArchived(false, threadID: threadID)
        }
    }
}

/// Discord's banner over a locked thread's composer: the sentence, and Unlock
/// or Open for a moderator.
///
/// **Over the composer, not instead of it.** A moderator still writes in a
/// locked thread; everybody else's composer says it cannot, on its own.
struct ThreadBanner: View {
    var state: ThreadBannerState
    var act: () -> Void

    var body: some View {
        HStack(spacing: Spacing.snug) {
            Text(state.message)
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if state.offersAction {
                MessageRequestButton(title: state.actionTitle, isProminent: false, isBusy: false, action: act)
            }
        }
        .padding(Spacing.snug)
        .glassEffect(.clear, in: .rect(cornerRadius: Radius.glass))
        .padding(.horizontal, Spacing.margin)
        .padding(.bottom, Spacing.snug)
    }
}

/// Reads the store for one thread's banner.
struct ThreadBannerContainer: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model

    var body: some View {
        if let state = model.threadBanner(for: channelID) {
            ThreadBanner(state: state) {
                model.performThreadBannerAction(state.kind, threadID: channelID)
            }
        }
    }
}
