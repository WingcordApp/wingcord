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
        // **A right-click over selected words leads with them**, as Discord's
        // menu does: Copy, then the two that ask about the words — macOS's
        // Look Up and Search with Google, in a text view's order — above
        // everything about the message itself.
        if model.messageMenu?.selectedText != nil {
            menuGroups.insert(contentsOf: [[.copySelection], [.lookUp, .searchWithGoogle]], at: 0)
        }

        return content
            // Who reacted: a layer over the window rather than a presentation,
            // so the profile and the person menu it opens stack above it — see
            // `ReactionsListLayer`.
            .overlay { ReactionsListLayer() }
            // A server's events, opened from the sidebar, the inbox, the live
            // card or a link — over the reactors list, under the profiles.
            .overlay { EventsLayer() }
            // A form an application raised, over everything a message raises.
            .overlay { InteractionModalLayer() }
            // Who holds a role, beside the mention that was clicked — under
            // the profiles, so a card opened from a row comes up above it.
            .overlay { RoleMembersLayer() }
            // The member list's Activity section: a card's popout, the
            // heading's menu and its About.
            .modifier(ActivitySectionPresenter())
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
                item: $model.traitsFlyout,
                attachmentAnchor: .rect(.rect(model.traitsFlyout?.anchor ?? .zero)),
                arrowEdge: .bottom
            ) { request in
                GuildTraitsFlyout(traits: request.traits)
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
                    onPickSuperReaction: model.hasNitro ? { react($0, .burst) } : nil,
                    reactingIn: request.channelID
                )
                .environment(model)
                .presentationBackground(.clear)
            }
            .modal(item: $model.forwardRequest) { request in
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
            .modal(item: $model.shareProfileRequest) { request in
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
            .modal(item: $model.reportRequest) { request in
                ReportSheet(request: request)
                    .environment(model)
            }
            .modal(item: $model.pollEditor) { request in
                PollEditorSheet(request: request)
                    .environment(model)
            }
            // Kick, Ban, Timeout and the rest — raised from the person menu,
            // Mod View and the Members page alike.
            .modal(item: $model.moderationDialog) { dialog in
                ModerationDialogView(dialog: dialog)
                    .environment(model)
            }
            // Create Event and Edit Event, from the server's events.
            .modal(item: $model.eventEditor) { request in
                EventEditorHost(request: request, model: model)
            }
            // A voice channel's status, from its menu or from the In voice
            // card on a profile.
            .modal(item: $model.voiceStatusEditor) { request in
                VoiceStatusSheet(request: request)
                    .environment(model)
            }
            // Create Channel and Create Category, from the server menu, a
            // category, or a channel's own menu.
            .modal(item: $model.channelCreation) { request in
                CreateChannelSheet(request: request)
                    .environment(model)
            }
            // **On a view of its own**, so that its suppression toggle is the
            // only one: the modifier reaches every dialog under it.
            .background { FakeNitroEmbedDialog() }
            // Discord's Preview Camera, from the camera's ▾, the reader's own
            // menu in a call, or the camera switch while "Always preview
            // video" is on.
            .modal(isPresented: $model.isCameraPreviewOpen) {
                CameraPreviewSheet()
                    .environment(model)
            }
            // Apply to Join — from a server's card, or an invite into a server
            // that reviews who joins.
            .modal(
                item: $model.joinApplicationRequest,
                // A submitted application's coachmark waits for this.
                onDismiss: { model.raiseQueuedApplicationCoachmark() }
            ) { request in
                JoinApplicationSheet(request: request)
                    .environment(model)
            }
            // The other end of the same application: approved, and seen for
            // the first time. Its only ways out — the button and Escape — both
            // acknowledge.
            .modal(item: $model.approvedApplication, style: .alert) { notice in
                ApplicationApprovedSheet(notice: notice)
                    .environment(model)
            }
            // A new member's greeting, where the server still has a Welcome
            // Screen — after the invite that brought them.
            .modal(item: $model.welcomeScreenNotice) { notice in
                WelcomeScreenSheet(
                    presentation: model.welcomeScreenPresentation(for: notice.guildID, screen: notice.screen),
                    openChannel: { model.openWelcomeScreenChannel($0) }
                )
            }
            // Raised by a running activity asking for a grant, not by anything
            // in this file — it lives here because this is where the window's
            // sheets are presented from, and a second presenter would be a
            // second place for two sheets to fight over the window.
            .modal(item: $model.activityConsent) { request in
                ActivityConsentSheet(request: request)
                    .environment(model)
            }
            // Ignore and Block, asked first — one card that turns between them.
            .modal(item: $model.relationshipConfirmation, style: .alert) { request in
                RelationshipConfirmationCard(request: request)
                    .environment(model)
            }
            // The one irreversible act in the set, as a card: what goes, in
            // the reader's words, and Delete in the act's colour with no
            // Return — it is read before it is pressed (D11b).
            .modal(item: $model.deleteRequest, style: .alert) { request in
                ModalAlert(
                    hero: .symbol("trash.fill"),
                    title: request.isOwn ? "Delete your message?" : "Delete this message?",
                    message: Text(
                        request.isOwn
                            ? "“\(request.excerpt)” will be removed for everyone. This cannot be undone."
                            : "\(request.authorName)'s message “\(request.excerpt)” will be removed for everyone. This cannot be undone."
                    ),
                    actions: [
                        .cancel(),
                        .act("Delete", symbol: "trash", irreversible: true) { model.confirmDelete() },
                    ]
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

/// Vencord's "Hold on!" (FakeNitro's `CannotEmbedNoticeModal`), in its words,
/// before a send or an edit whose links the channel will not embed. The
/// system's "Do not show this message again" is the plugin's checkbox — its
/// `disableEmbedPermissionCheck`.
private struct FakeNitroEmbedDialog: View {
    @Environment(AppModel.self) private var model
    @State private var settings = AppSettings.shared

    var body: some View {
        Color.clear
            .modal(
                isPresented: Binding(
                    get: { model.fakeNitroEmbedPrompt != nil },
                    set: { if !$0 { model.fakeNitroEmbedPrompt = nil } }
                ),
                style: .alert
            ) {
                if let prompt = model.fakeNitroEmbedPrompt {
                    ModalAlert(
                        hero: .symbol("exclamationmark.triangle.fill", tint: .orange),
                        title: "Hold on!",
                        message: Text("You are trying to send/edit a message that contains a FakeNitro emoji or sticker, however you do not have permissions to embed links in the current channel. Are you sure you want to send this message? Your FakeNitro items will appear as a link only."),
                        actions: [
                            .cancel(),
                            .act("Send Anyway", symbol: "paperplane.fill") { prompt.proceed() },
                        ],
                        // The plugin's own checkbox — its `disableEmbedPermissionCheck`.
                        suppression: $settings.fakeNitroSkipsEmbedCheck
                    )
                }
            }
            // The plugin's other "Hold on!", for an animated sticker.
            .modal(
                isPresented: Binding(
                    get: { model.fakeNitroStickerRefused },
                    set: { model.fakeNitroStickerRefused = $0 }
                ),
                style: .alert
            ) {
                ModalAlert(
                    hero: .symbol("exclamationmark.triangle.fill", tint: .orange),
                    title: "Hold on!",
                    message: Text("You cannot send this message because it contains an animated FakeNitro sticker, and you do not have permissions to attach files in the current channel. Please remove the sticker to proceed."),
                    actions: [.okay("OK")]
                )
            }
    }
}
