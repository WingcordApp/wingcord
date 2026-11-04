import SwiftUI
import WingcordCore

/// Discord's Delete Server (`310482`): "Delete '{name}'", "Are you sure you want
/// to delete **{name}**? This action cannot be undone.", the server's name typed
/// back, and Delete Server.
///
/// **The name is compared without case, as Discord compares it** — a wrong
/// one says "You didn't enter the server name correctly" and sends nothing.
struct DeleteServerSheet: View {
    let store: ServerSettingsStore
    var guildName: String
    /// Run once the server is gone — the window has nothing left to show.
    var deleted: () -> Void

    @ModalDismiss private var dismiss
    @State private var typed = ""
    @State private var failure: String?
    @State private var isWorking = false

    var body: some View {
        FormSheet(
            title: "Delete \u{2018}\(guildName)\u{2019}",
            subtitle: Text("Are you sure you want to delete \(Text(verbatim: guildName).bold())? This action cannot be undone."),
            confirmTitle: "Delete Server",
            isDestructive: true,
            isWorking: isWorking,
            canConfirm: !typed.isEmpty,
            confirm: delete
        ) {
            SheetField(title: "Enter server name") {
                TextField("", text: $typed)
                    .modalField()
                    .autocorrectionDisabled()
            }
            if let failure {
                Text(failure)
                    .font(.system(.caption))
                    .foregroundStyle(Palette.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func delete() {
        guard typed.lowercased() == guildName.lowercased() else {
            failure = "You didn't enter the server name correctly"
            return
        }
        isWorking = true
        failure = nil
        Task {
            let refusal = await store.deleteServer()
            isWorking = false
            if let refusal {
                failure = refusal
            } else {
                dismiss()
                deleted()
            }
        }
    }
}
