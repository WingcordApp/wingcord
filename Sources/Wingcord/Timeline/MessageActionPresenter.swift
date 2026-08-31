import SwiftUI
import WingcordCore

/// The one place everything a message raises is presented.
///
/// Attached at the window root and nowhere else. The transcript is a drawn
/// canvas: a click writes a value with the rect it happened at and stops there,
/// and this anchors beside that rect — `INVARIANTS.md` §1.
///
/// **Five surfaces, one modifier.** Written inline they would be five
/// presentation modifiers evaluated as part of some row's body, including their
/// titles, on every evaluation of that row — §2.
struct MessageActionPresenter: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        // **Read here, in the modifier's own body, not inside the presentation
        // closures.** A read that only happens inside a closure SwiftUI calls
        // to build a presented view is not a dependency this view is guaranteed
        // to be invalidated by — and the delete confirmation's words, the
        // menu's rows and the report's tree all arrive or change while the
        // surface is already up.
        let menuGroups = model.messageMenu.map {
            model.actions(for: $0.messageID, in: $0.channelID).menuGroups
        } ?? []
        let deletion = model.deleteRequest

        return content
            .popover(
                item: $model.messageMenu,
                attachmentAnchor: .rect(.rect(model.messageMenu?.anchor ?? .zero)),
                arrowEdge: .bottom
            ) { request in
                MessageMenu(groups: menuGroups) { kind in
                    MessageActionRouter.perform(
                        kind,
                        messageID: request.messageID,
                        channelID: request.channelID,
                        model: model,
                        anchor: request.anchor
                    )
                }
                // The menu carries its own material, so the popover must carry
                // none — two in series read as frost rather than as glass.
                .presentationBackground(.clear)
            }
            .popover(
                item: $model.reactionPicker,
                attachmentAnchor: .rect(.rect(model.reactionPicker?.anchor ?? .zero)),
                arrowEdge: .bottom
            ) { request in
                ExpressionPicker(
                    mode: .emoji,
                    onPick: { item in
                        guard case .insert(let token) = item.pick,
                              let emoji = EmojiRef(messageToken: token)
                        else { return }
                        model.toggleReaction(
                            emoji, on: request.messageID, in: request.channelID
                        )
                        model.reactionPicker = nil
                    },
                    // The GIF board is unreachable in emoji mode; the closure is
                    // required by the picker's signature and this is the honest
                    // answer for a reaction, which cannot be a GIF.
                    onPickGIF: { _ in }
                )
                .environment(model)
                .presentationBackground(.clear)
            }
            .sheet(item: $model.forwardRequest) { request in
                ForwardSheet(
                    preview: model.forwardPreview(for: request),
                    targets: model.forwardTargets(excluding: request.channelID),
                    send: { targets, comment in model.forward(to: targets, comment: comment) },
                    dismiss: { model.forwardRequest = nil }
                )
            }
            .sheet(item: $model.reportRequest) { request in
                ReportSheet(request: request)
                    .environment(model)
            }
            .alert(
                deletion?.isOwn == true ? "Delete your message?" : "Delete this message?",
                isPresented: Binding(
                    get: { model.deleteRequest != nil },
                    // **Only ever clears when the store is still showing this
                    // one.** A setter that clears unconditionally can dismiss a
                    // second request on its way in.
                    set: { if !$0 { model.deleteRequest = nil } }
                ),
                presenting: deletion
            ) { _ in
                Button("Delete", role: .destructive) { model.confirmDelete() }
                Button("Cancel", role: .cancel) { model.deleteRequest = nil }
            } message: { request in
                // **A system alert, deliberately, where everything else here is
                // glass.** This is the one irreversible act in the set; it wants
                // the platform's own destructive vocabulary, its Escape and
                // Return handling and its VoiceOver announcement, none of which
                // a hand-built panel would inherit.
                Text(
                    request.isOwn
                        ? "“\(request.excerpt)” will be removed for everyone. This cannot be undone."
                        : "\(request.authorName)'s message “\(request.excerpt)” will be removed for everyone. This cannot be undone."
                )
            }
    }
}

extension View {
    /// Apply once, at the window root, above `.environment(model)`.
    func presentsMessageActions() -> some View {
        modifier(MessageActionPresenter())
    }
}
