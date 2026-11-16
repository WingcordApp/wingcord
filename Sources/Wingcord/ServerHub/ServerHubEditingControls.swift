import SwiftUI

/// Add Widget, Cancel and Save, while the hub is being edited.
///
/// **Save is the one tinted control** (HIG: "use a prominent style … for the
/// most likely action. Keep to one or two prominent buttons per view"), and it
/// waits for a change before it can be pressed.
struct ServerHubEditingControls: View {
    var presentation: ServerHubPresentation

    @Environment(AppModel.self) private var model

    private var isSaving: Bool { presentation.saveState == .saving }

    var body: some View {
        if case .failed(let message) = presentation.saveState {
            Text(message)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(Palette.destructive)
                .lineLimit(1)
                .padding(.horizontal, Spacing.margin)
                .frame(height: SearchField.height)
                .glassEffect(.regular, in: .capsule)
                .help(message)
                .transition(.materialize)
        }
        ServerHubBarButton(title: "Add Widget", systemImage: "plus", action: addWidget)
            .disabled(isSaving)
        ServerHubBarButton(title: "Cancel", action: cancel)
            .keyboardShortcut(.cancelAction)
            .disabled(isSaving)
        ServerHubBarButton(title: "Save", isProminent: true, isWorking: isSaving, action: save)
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!presentation.hasChanges || isSaving)
    }

    private func addWidget() {
        model.serverHub.sheet = .addWidget(column: 0, index: presentation.columns.first?.count ?? 0)
    }

    private func cancel() {
        model.cancelServerHubEdit()
    }

    private func save() {
        model.saveServerHubEdit()
    }
}
