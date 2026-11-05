import SwiftUI
import WingcordCore

/// Everything joining a server needs, mounted once at the window root.
///
/// Three things, and they belong together because each is useless without the
/// others: the solver that can answer a human check, the host that can put one
/// on screen, and the sheet that raises the write which provokes it.
///
/// **The solver is created here and installed into the REST actor here.** It
/// outlives every sheet — a challenge can be raised by a write from anywhere,
/// and the profile editor is the next surface that will want one — so it belongs
/// to the window rather than to the flow that first needed it.
struct JoinServerPresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    /// Owned by this modifier, which lives as long as the window.
    @State private var solver = CaptchaSolver()

    func body(content: Content) -> some View {
        @Bindable var model = model
        // **Read here, in the modifier's own body**, not inside the sheet's
        // closure. The resolve lands from a task while the sheet is already up,
        // and a read that happens only inside a closure SwiftUI calls to build
        // the presented view is not a dependency this view is invalidated by —
        // the card would never appear.
        let sheet = model.joinServerSheet
        let _ = model.inviteSheet

        return content
            .modal(isPresented: sheetBinding) {
                if let sheet {
                    JoinServerSheet(
                        state: sheet,
                        setInput: { input in
                            model.joinServerSheet?.input = input
                            model.joinServerSheet?.joinFailure = nil
                            model.sessionController.resolveInvite(input)
                        },
                        join: {
                            guard let preview = sheet.preview else { return }
                            model.sessionController.joinServer(preview)
                        },
                        dismiss: { model.joinServerSheet = nil }
                    )
                }
            }
            // An invite link, clicked. A panel: a click beside it is No Thanks.
            .modal(item: inviteBinding, style: .panel) { invite in
                InviteAcceptSheet(
                    state: invite,
                    presentation: model.inviteSheetPresentation(invite),
                    setNickname: { model.inviteSheet?.nickname = $0 },
                    setAllowsDirectMessages: { model.inviteSheet?.allowsDirectMessages = $0 },
                    setShowsActivity: { model.inviteSheet?.showsActivity = $0 },
                    accept: { model.sessionController.acceptInviteSheet() },
                    openNitro: {
                        if let url = URL(string: "https://discord.com/nitro") { model.openExternal(url) }
                    },
                    dismiss: { model.closeInviteSheet() }
                )
            }
            // The root's own host. It presents every challenge raised while no
            // sheet is up; the Join sheet registers its own on top, because a
            // view a sheet covers cannot present anything.
            .captchaHost()
            .environment(solver)
            .task {
                // One installation for the life of the window. The bridge holds
                // no state — it hops to the solver and back — so handing the
                // actor a value rather than the `@MainActor` object keeps the
                // isolation boundary at one line.
                await model.sessionController.rest.setCaptchaSolver(
                    CaptchaBridge { solver }
                )
            }
    }

    /// **Nothing closes it while the accept is out.** A panel closes on a click
    /// beside it, and this one's answer would land on nothing.
    private var inviteBinding: Binding<InviteSheetState?> {
        Binding(
            get: { model.inviteSheet },
            set: { if $0 == nil, model.inviteSheet?.isAccepting != true { model.closeInviteSheet() } }
        )
    }

    /// **The setter may only clear the store when the store is still showing
    /// this sheet**, which is the rule every other presenter in this app keeps.
    private var sheetBinding: Binding<Bool> {
        Binding(
            get: { model.joinServerSheet != nil },
            set: { if !$0 { model.joinServerSheet = nil } }
        )
    }
}

extension View {
    /// Applied once, at the window root, above `.environment(model)`.
    func presentsJoinServer() -> some View {
        modifier(JoinServerPresenter())
    }
}
