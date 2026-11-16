import SwiftUI

/// The Server Hub page, fed from the store.
///
/// Reads the SELECTED guild, as every guild page's container does — the
/// presentation already decided which server this is.
struct ServerHubContainer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let presentation = model.serverHubPresentation {
            ServerHubPage(presentation: presentation)
                .task(id: presentation.guildID) { model.prepareServerHub(presentation.guildID) }
                .onDisappear { model.leaveServerHub(presentation.guildID) }
        }
    }
}
