import SwiftUI
import WingcordCore

/// Discord's "You are now a member of" (`739c2913`'s `H`): what an approved
/// application says the first time the reader opens the server after it.
///
/// **One way out, and every way out acknowledges.** Discord's "Let's Go!" and
/// its close are the same function, so there is no Cancel — dismissing it is
/// having seen it.
struct ApplicationApprovedSheet: View {
    var notice: ApprovedApplicationNotice

    @Environment(AppModel.self) private var model
    @Environment(\.isTopModal) private var isTop

    var body: some View {
        let guild = model.guilds[notice.guildID]
        ModalAlert(
            hero: .serverIcon(
                guild?.iconHash.flatMap { CDN.guildIcon(guildID: notice.guildID, hash: $0, side: ModalHero.side) },
                monogram: guild?.monogram ?? "",
                badge: "checkmark.seal.fill"
            ),
            // Discord's two paragraphs: the phrase, then the server.
            title: "You are now a member of \(notice.serverName)!",
            message: Text("Hooray! It's time to talk and meet your new community."),
            actions: [
                ModalAlertAction(title: "Let's Go!", symbolName: "arrow.right", role: .act, closes: false, perform: acknowledge),
            ]
        )
        // Escape is a close, and a close is the acknowledgement.
        .background {
            Button("", action: acknowledge)
                .keyboardShortcut(isTop ? .cancelAction : nil)
                .hidden()
        }
    }

    private func acknowledge() {
        model.acknowledgeApprovedApplication(notice.guildID)
    }
}
