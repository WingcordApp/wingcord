import SwiftUI
import WingcordCore

/// Discord's "Add to Profile" on a game profile (`581745`): a menu of the
/// reader's four game lists, each adding this game or taking it off, with
/// "Max games reached" on a list at its cap.
struct GameAddToProfileButton: View {
    var gameID: ApplicationID

    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            if let choices = model.gameListChoices(for: gameID) {
                ForEach(choices) { choice in
                    Button {
                        Task { await model.sessionController.toggleGame(gameID, in: choice.kind) }
                    } label: {
                        if choice.isFull {
                            Label("\(choice.label) · Max games reached", systemImage: choice.symbol)
                        } else {
                            Label(choice.label, systemImage: choice.symbol)
                        }
                    }
                    .disabled(choice.isFull)
                }
            } else {
                Text("Loading your profile…")
            }
        } label: {
            Label("Add to Profile", systemImage: "plus")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(InkColor.primary)
                .padding(.horizontal, Spacing.snug)
                .frame(height: Metrics.control + 6)
                .contentShape(.capsule)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .interactiveChromeOverMedia(in: .capsule)
        .help("Add to Profile")
        // The reader's own board, which the menu edits, if it hasn't been read.
        .task {
            guard model.gameListChoices(for: gameID) == nil, let me = model.currentUserID,
                  !LaunchOptions.current.usesDemoFixtures
            else { return }
            await model.sessionController.fetchProfile(of: me, inGuild: nil)
        }
    }
}
