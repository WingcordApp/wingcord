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
        var menuGroups = model.messageMenu.map {
            model.actions(for: $0.messageID, in: $0.channelID).menuGroups
        } ?? []
        // **Apps is offered only when an app actually has something.** No
        // permission gates it — see `MessageActionKind.apps` — so the question
        // is whether the command index holds a MESSAGE command that applies
        // here, and it is answered where the index lives rather than in the
        // permission table.
        if let request = model.messageMenu,
           !model.contextCommandGroups(.message, in: request.channelID).isEmpty
        {
            menuGroups.append([.apps])
        }
        let deletion = model.deleteRequest

        return content
            // Who reacted: a layer over the window rather than a presentation,
            // so the profile and the person menu it opens stack above it — see
            // `ReactionsListLayer`.
            .overlay { ReactionsListLayer() }
            // A form an application raised, over everything a message raises.
            .overlay { InteractionModalLayer() }
            // A select menu's options, off the menu — Discord's dropdown.
            .popover(
                item: Binding(
                    get: { model.selectMenu },
                    // **Closing goes through the store**, because closing is
                    // when a menu that takes several sends what was chosen.
                    set: { if $0 == nil { model.closeSelectMenu() } else { model.selectMenu = $0 } }
                ),
                attachmentAnchor: .rect(.rect(model.selectMenu?.anchor ?? .zero)),
                arrowEdge: .bottom
            ) { request in
                SelectMenuFlyout(request: request)
                    .environment(model)
                    .presentationBackground(.clear)
            }
            .popover(
                item: $model.messageMenu,
                attachmentAnchor: .rect(.rect(model.messageMenu?.anchor ?? .zero)),
                arrowEdge: .bottom
            ) { request in
                MessageMenu(
                    groups: menuGroups,
                    // The subject the Apps list runs against. Passed rather
                    // than rebuilt inside: the menu holds no model reference
                    // beyond the environment and has no business deciding
                    // what a right-click was on.
                    appTarget: .message(request.messageID, in: request.channelID),
                    perform: { kind in
                        MessageActionRouter.perform(
                            kind,
                            messageID: request.messageID,
                            channelID: request.channelID,
                            model: model,
                            anchor: request.anchor
                        )
                    },
                    // Passed rather than routed through `MessageActionRouter`,
                    // because it carries a value the router's signature has no
                    // room for: the router turns a *kind* into a call, and a
                    // reminder needs the duration that was chosen.
                    setReminder: { preset in
                        model.setReminder(
                            preset,
                            on: request.messageID,
                            in: request.channelID
                        )
                    }
                )
                // The menu carries its own material, so the popover must carry
                // none — two in series read as frost rather than as glass.
                .presentationBackground(.clear)
            }
            .popover(
                item: $model.reactionPicker,
                attachmentAnchor: .rect(.rect(model.reactionPicker?.anchor ?? .zero)),
                arrowEdge: .bottom
            ) { request in
                let react = { (item: ExpressionItem, kind: ReactionKind) in
                    guard case .insert(let token) = item.pick,
                          let emoji = EmojiRef(messageToken: token)
                    else { return }
                    model.toggleReaction(
                        emoji, kind: kind, location: .reactionPicker,
                        on: request.messageID, in: request.channelID
                    )
                    model.reactionPicker = nil
                }
                ExpressionPicker(
                    mode: .emoji,
                    onPick: { react($0, .normal) },
                    // The GIF board is unreachable in emoji mode; the closure is
                    // required by the picker's signature and this is the honest
                    // answer for a reaction, which cannot be a GIF.
                    onPickGIF: { _ in },
                    // The switch exists only for an account that can send one.
                    onPickSuperReaction: model.hasNitro ? { react($0, .burst) } : nil
                )
                .environment(model)
                .presentationBackground(.clear)
            }
            .sheet(item: $model.forwardRequest) { request in
                ForwardSheet(
                    targets: model.forwardTargets(excluding: request.channelID),
                    send: { targets, comment in model.forward(to: targets, comment: comment) },
                    dismiss: { model.forwardRequest = nil }
                ) {
                    QuotedMessageRow(message: model.forwardPreview(for: request))
                }
            }
            // Discord's forward modal with a person in it (`880867`): its own
            // title, the profile link beside Send, and nothing quoted.
            .sheet(item: $model.shareProfileRequest) { request in
                ForwardSheet(
                    title: "Share Profile",
                    subtitle: nil,
                    targets: model.forwardTargets(excluding: nil),
                    copyLink: { AppModel.copy(request.link) },
                    send: { targets, comment in model.shareProfile(to: targets, comment: comment) },
                    dismiss: { model.shareProfileRequest = nil }
                ) {
                    ProfileSharePreview(userID: request.userID)
                }
            }
            .sheet(item: $model.reportRequest) { request in
                ReportSheet(request: request)
                    .environment(model)
            }
            // Raised by a running activity asking for a grant, not by anything
            // in this file — it lives here because this is where the window's
            // sheets are presented from, and a second presenter would be a
            // second place for two sheets to fight over the window.
            .sheet(item: $model.activityConsent) { request in
                ActivityConsentSheet(request: request)
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
