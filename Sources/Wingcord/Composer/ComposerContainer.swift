import SwiftUI
import WingcordCore

/// Reads the store, hands the composer plain values.
///
/// The draft lives in the channel's `MessageBox` rather than in `@State` here,
/// so switching channels and coming back returns what was typed — and so an
/// eviction of the transcript never takes unsent input with it.
struct ComposerContainer: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        // Reading `roleRevision` registers the dependency the permission answer
        // below actually depends on — the gate itself is `@ObservationIgnored`,
        // so without this the composer would keep its old enabled state until
        // something unrelated invalidated the view.
        let _ = model.roleRevision
        Composer(
            channelName: model.channelIndex[channelID].map(model.displayName(of:)) ?? "",
            canSend: model.permissionGate.canSend(in: channelID),
            replyingToAuthor: replyingToAuthor,
            text: Binding(
                get: { model.messages(in: channelID)?.draft ?? "" },
                set: { newValue in model.mutateBox(channelID) { $0.draft = newValue } }
            ),
            send: send,
            cancelReply: { model.mutateBox(channelID) { $0.replyingTo = nil } },
            attach: {}
        )
    }

    private var replyingToAuthor: String? {
        guard let replyID = model.messages(in: channelID)?.replyingTo,
              let message = model.messages(in: channelID)?.messages.first(where: { $0.id == replyID }),
              let user = model.users[message.authorID]
        else { return nil }
        return user.preferredName
    }

    private func send() {
        let draft = model.messages(in: channelID)?.draft ?? ""
        model.sendMessage(draft, in: channelID)
    }
}
