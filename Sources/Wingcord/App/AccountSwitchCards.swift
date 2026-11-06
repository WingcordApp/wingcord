import SwiftUI
import WingcordCore

/// A switch's question, and the sign-in for another account. Asked from the window's
/// root, like the rest: the card that pressed them has gone by the time they show.
struct AccountSwitchCards: ViewModifier {
    var model: AppModel

    func body(content: Content) -> some View {
        content
            .modal(
                isPresented: Binding(
                    get: { model.accountSwitchPrompt != nil },
                    set: { if !$0 { model.accountSwitchPrompt = nil } }
                ),
                style: .alert
            ) {
                if let prompt = model.accountSwitchPrompt {
                    ModalAlert(
                        hero: .avatar(prompt.target.avatarURL(side: ModalHero.side), monogram: prompt.target.monogram),
                        title: "Switch to \(prompt.target.preferredName)?",
                        message: Text(prompt.message),
                        actions: [
                            .cancel(),
                            .act("Switch", symbol: "arrow.left.arrow.right") {
                                model.sessionController.switchAccount(to: prompt.target)
                            },
                        ]
                    )
                }
            }
            // A slip here costs a password and a code, and the row's right under the switcher.
            .modal(
                isPresented: Binding(
                    get: { model.logOutPrompt != nil },
                    set: { if !$0 { model.logOutPrompt = nil } }
                ),
                style: .alert
            ) {
                if let account = model.logOutPrompt {
                    ModalAlert(
                        hero: .avatar(account.avatarURL(side: ModalHero.side), monogram: account.monogram),
                        title: "Log out of \(account.preferredName)?",
                        message: Text("Its sign-in is removed from this Mac. To use it here again, you'll have to log in again."),
                        actions: [
                            .cancel(),
                            .act("Log Out", symbol: "rectangle.portrait.and.arrow.right", irreversible: true) {
                                model.confirmLogOut(of: account)
                            },
                        ]
                    )
                }
            }
            .modal(
                isPresented: Binding(
                    get: { model.isAddingAccount },
                    set: { model.isAddingAccount = $0 }
                ),
                style: .panel
            ) {
                DiscordLoginView { token in
                    model.isAddingAccount = false
                    model.sessionController.addAccount(token: token)
                }
                .frame(width: 560, height: 720)
                .overlay(alignment: .topTrailing) {
                    ModalCloseButton { model.isAddingAccount = false }
                        .padding(Spacing.margin)
                }
            }
    }
}
