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
            attach: {},
            completions: completions,
            completionQuery: completionQuery ?? "",
            commitCompletion: commit,
            onPick: { model.apply($0.pick, in: channelID) },
            onPickGIF: { gif in
                // A GIF is sent as its URL, which every other client unfurls
                // back into an embed. Straight out rather than into the draft:
                // picking one is the whole message.
                model.sendMessage(gif.url.absoluteString, in: channelID)
            }
        )
    }

    /// The shortcode being typed, if any.
    private var completionQuery: String? {
        EmojiAutocomplete.query(in: model.messages(in: channelID)?.draft ?? "")
    }

    /// What to offer for it.
    ///
    /// Resolved in the body rather than kept in state: it is a prefix search
    /// over a memoized catalog, and state would need invalidating from three
    /// places that can each change the answer.
    private var completions: [ExpressionItem] {
        guard let completionQuery else { return [] }
        return EmojiAutocomplete.matches(
            for: completionQuery,
            custom: model.emojiCatalog.sections
        )
    }

    private func commit(_ item: ExpressionItem) {
        guard case .insert(let text) = item.pick else { return }
        model.mutateBox(channelID) { box in
            box.draft = EmojiAutocomplete.applying(text, to: box.draft)
        }
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
