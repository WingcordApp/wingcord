import SwiftUI

/// A card's Edit and Remove, while the hub is being edited.
///
/// **Glass in the content layer, and the one place the HIG allows it**: "a
/// transient interactive control in that layer … can take on Liquid Glass
/// while activated" — these exist only while the hub is being edited. One glass
/// body for the pair, the buttons regions of it (§4: never glass on glass).
struct ServerHubCardEditControls: View {
    var widget: ServerHubPresentation.Widget

    @Environment(AppModel.self) private var model

    var body: some View {
        HeaderControlGroup {
            if widget.settings != nil, !widget.isLocked {
                HeaderGroupButton(systemImage: "pencil", label: "Edit \(widget.title.isEmpty ? "Widget" : widget.title)", action: edit)
            }
            HeaderGroupButton(systemImage: "trash", label: "Remove \(widget.title.isEmpty ? "Widget" : widget.title)", action: remove)
        }
        .environment(\.headerControlSide, 30)
    }

    private func edit() {
        model.serverHub.sheet = widget.settings
    }

    private func remove() {
        model.removeServerHubWidget(widget.id)
    }
}
