import SwiftUI
import WingcordCore

/// What a pending application's tile offers, from a right-click in the rail —
/// Discord's `97187` ("Server Actions"): Reapply on a denial, Withdraw
/// Application or Discard Application, and the server's id.
///
/// No material of its own: the popover's glass is the body — §4.9.
struct JoinRequestMenu: View {
    var guildID: GuildID
    var close: () -> Void

    @Environment(AppModel.self) private var model

    static let width: CGFloat = 220

    var body: some View {
        let status = model.ownJoinRequests[guildID]?.status
        VStack(alignment: .leading, spacing: 0) {
            if status == .rejected {
                FlyoutRow(title: "Reapply", symbolName: "arrow.clockwise") {
                    model.reapply(toGuild: guildID, opensForm: false)
                    close()
                }
            }
            // An application never sent is discarded; one that was, withdrawn.
            FlyoutRow(
                title: status == .started ? "Discard Application" : "Withdraw Application",
                symbolName: "xmark.circle",
                isDestructive: true
            ) {
                close()
                model.askToWithdrawApplication(guildID)
            }
            if AppSettings.shared.developerMode {
                FlyoutDivider()
                FlyoutRow(title: "Copy Server ID", symbolName: "number") {
                    AppModel.copy(guildID.description)
                    close()
                }
            }
        }
        .padding(.vertical, Spacing.tight)
        .frame(width: Self.width)
    }
}
