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
            isEditing: model.messages(in: channelID)?.editing != nil,
            // **One field, two destinations.** An edit borrows the bar and must
            // not eat the draft underneath it, so the binding routes by which
            // state is live rather than by copying one into the other — a copy
            // is what loses whichever the reader abandoned.
            text: Binding(
                get: {
                    let box = model.messages(in: channelID)
                    return box?.editing?.text ?? box?.draft ?? ""
                },
                set: { newValue in
                    if model.messages(in: channelID)?.editing != nil {
                        // An edit is not typing in the channel: nobody is
                        // waiting on three dots for a message that already
                        // arrived.
                        model.mutateBox(channelID) { $0.editing?.text = newValue }
                        return
                    }
                    // Reported before the write, while the previous draft is
                    // still readable. **Only on growth**: deleting a mistake is
                    // not typing, and telling the channel it is keeps the
                    // indicator alive through a minute of somebody backspacing.
                    let previous = model.messages(in: channelID)?.draft ?? ""
                    if newValue.count > previous.count {
                        model.sessionController.reportTyping(in: channelID)
                    }
                    model.mutateBox(channelID) { $0.draft = newValue }
                }
            ),
            send: send,
            cancelReply: { model.cancelReply(in: channelID) },
            cancelEdit: { model.cancelEdit(in: channelID) },
            replyToLatest: { model.replyToLatestMessage() },
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
            },
            activityChannelID: channelID
        )
    }

    /// The shortcode being typed, if any.
    private var completionQuery: String? {
        let box = model.messages(in: channelID)
        return EmojiAutocomplete.query(in: box?.editing?.text ?? box?.draft ?? "")
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
            // Into whichever field the bar is showing, for the same reason the
            // binding routes: completing a shortcode while editing must land in
            // the edit and not in the draft behind it.
            if let existing = box.editing?.text {
                box.editing?.text = EmojiAutocomplete.applying(text, to: existing)
            } else {
                box.draft = EmojiAutocomplete.applying(text, to: box.draft)
            }
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
        // Return commits whichever the bar is holding. One entry point, so the
        // send control, the key press and the menu item cannot disagree about
        // what pressing Send means while an edit is open.
        if model.messages(in: channelID)?.editing != nil {
            model.commitEdit(in: channelID)
            return
        }
        let draft = model.messages(in: channelID)?.draft ?? ""
        model.sendMessage(draft, in: channelID)
    }
}
