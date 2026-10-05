import SwiftUI
import WingcordCore

/// The event editor, raised over the main window — Discord's Create Event lives
/// with the server's events, not in its settings.
///
/// The form is `EventSheet`, on a store of its own for this server; a refused
/// write is told through the window's notice, since there is no settings
/// toolbar here to carry it.
struct EventEditorHost: View {
    var request: EventEditorRequest

    @State private var store: ServerSettingsStore

    init(request: EventEditorRequest, model: AppModel) {
        self.request = request
        let store = ServerSettingsStore.make(for: request.guildID, model: model)
        store.reportFailure = { [weak model] message in model?.reportActionFailure(message) }
        _store = State(initialValue: store)
    }

    var body: some View {
        EventSheet(store: store, existing: request.event)
    }
}
