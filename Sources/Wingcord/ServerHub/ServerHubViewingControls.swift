import SwiftUI

/// Edit and Settings, sharing one glass capsule as macOS groups toolbar items.
struct ServerHubViewingControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HeaderControlGroup {
            HeaderGroupButton(systemImage: "pencil", label: "Edit Server Hub", action: edit)
            HeaderGroupButton(systemImage: "gearshape", label: "Server Hub Settings", action: openSettings)
        }
    }

    private func edit() {
        model.beginServerHubEdit()
    }

    private func openSettings() {
        model.openServerHubSettings()
    }
}
