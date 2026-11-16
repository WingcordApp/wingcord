import SwiftUI
import WingcordCore

/// Who may draw on the whiteboard — Discord's "Restrict access by role": the
/// roles allowed Use Activities in the hub's channel, everyone when none is
/// picked. Saved straight to the channel, as Discord's is.
struct WhiteboardAccessSheet: View {
    var guildID: GuildID

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<RoleID> = []

    private var roles: [Role] {
        (model.roles[guildID].map { Array($0.values) } ?? [])
            .filter { $0.id.rawValue != guildID.rawValue && !$0.isManaged }
            .sorted { $0.position > $1.position }
    }

    private var canManage: Bool {
        guard let channelID = model.serverHub.spaces[guildID]?.channelID else { return false }
        return model.permissionGate.permissions(in: channelID).contains(.manageRoles)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.margin) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text("Restrict access by role")
                    .font(.system(.title2, weight: .bold))
                Text("Only these roles can use the whiteboard. Leave this empty to let everyone use it.")
                    .font(.system(.callout))
                    .foregroundStyle(Ink.secondary)
            }
            List(roles) { role in
                Toggle(isOn: $chosen[contains: role.id]) {
                    HStack(spacing: Spacing.base) {
                        Circle()
                            .fill(role.colorValue == 0 ? Ink.tertiary : Color(hex: role.colorValue))
                            .frame(width: 10, height: 10)
                        Text(role.name)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .frame(minHeight: 240)
            .disabled(!canManage)
            if !canManage {
                Label("You don\u{2019}t have permission to change who can use the whiteboard.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(.callout))
                    .foregroundStyle(Ink.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canManage)
            }
        }
        .padding(Spacing.group)
        .frame(width: 440, height: 480)
        .task { chosen = model.whiteboardRoleIDs(guildID) }
    }

    private func save() {
        model.setWhiteboardRoles(chosen)
        dismiss()
    }

    private func close() {
        dismiss()
    }
}
