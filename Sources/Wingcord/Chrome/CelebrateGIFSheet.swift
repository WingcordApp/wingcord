import SwiftUI
import WingcordCore

/// Discord's "Celebrate the moment with a GIF" (module 367516): a message,
/// a GIF picked from a search that starts on "Celebrate", Cancel and Send.
struct CelebrateGIFSheet: View {
    var request: CelebrateGIFRequest

    @Environment(AppModel.self) private var model
    @ModalDismiss private var dismiss
    @State private var message = ""
    @State private var query = "Celebrate"
    @State private var chosen: GIF?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            HStack(alignment: .firstTextBaseline) {
                Text("Celebrate the moment with a GIF")
                    .font(.system(.title3, weight: .bold))
                    .foregroundStyle(Ink.primary)
                Spacer(minLength: Spacing.base)
                ModalCloseButton { dismiss() }
            }
            TextField(
                "Send a fun message: \u{2018}Woohoo! Let\u{2019}s celebrate our Friendship Anniversary!\u{2019}",
                text: $message
            )
            .modalField()
            GIFBoard(query: $query, showsFavorites: false, onPick: { chosen = $0 })
                .environment(model)
                .frame(height: 300)
                .clipShape(.rect(cornerRadius: Radius.chip, style: .continuous))
            HStack(spacing: Spacing.base) {
                if let chosen {
                    // What Send will send: the board picks, it doesn't send.
                    RemoteImage(url: chosen.previewURL, side: 44, bucket: .attachment) { Palette.surfaceRaised }
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 44)
                        .clipShape(.rect(cornerRadius: 8, style: .continuous))
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                Button("Send") {
                    guard let chosen else { return }
                    model.sessionController.sendAnniversaryGIF(chosen, message: message, to: request.userID)
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(Palette.accent)
                .disabled(chosen == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.margin)
        .frame(width: 500)
    }
}

/// Send a GIF on a Friend Anniversaries row.
struct CelebrateGIFRequest: Identifiable, Hashable, Sendable {
    var userID: UserID
    var id: UInt64 { userID.rawValue }
}
