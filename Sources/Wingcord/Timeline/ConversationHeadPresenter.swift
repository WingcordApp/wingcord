import SwiftUI
import WingcordCore

/// What a conversation head's controls raise at the window root: Discord's
/// Deauthorize Application for an app's DM (`s$`), and a group's Edit Group
/// and Add Friends to DM (`sr`).
struct ConversationHeadPresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var groupName = ""

    func body(content: Content) -> some View {
        content
            .alert(
                "Deauthorize Application",
                isPresented: Binding(
                    get: { model.headDeauthorization != nil },
                    set: { if !$0 { model.headDeauthorization = nil } }
                ),
                presenting: model.headDeauthorization
            ) { app in
                Button("Cancel", role: .cancel) {}
                Button("Deauthorize", role: .destructive) { model.sessionController.deauthorizeApp(app) }
            } message: { app in
                Text("This action will remove the link between your Discord account and \(app.name)")
            }
            .alert(
                "Edit Group",
                isPresented: Binding(
                    get: { model.groupRename != nil },
                    set: { if !$0 { model.groupRename = nil } }
                )
            ) {
                // Discord's placeholder: the name the group has without one.
                TextField(memberNames(model.groupRename), text: $groupName)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    guard let channelID = model.groupRename else { return }
                    model.sessionController.renameGroup(channelID, to: groupName)
                }
                .disabled(groupName == currentName(model.groupRename))
            }
            .onChange(of: model.groupRename) { _, channelID in groupName = currentName(channelID) }
            .sheet(isPresented: Binding(
                get: { model.groupInvite != nil },
                set: { if !$0 { model.groupInvite = nil } }
            )) {
                if let channelID = model.groupInvite {
                    GroupInviteSheet(channelID: channelID)
                }
            }
    }

    private func currentName(_ channelID: ChannelID?) -> String {
        channelID.flatMap { model.channelIndex[$0]?.name } ?? ""
    }

    private func memberNames(_ channelID: ChannelID?) -> String {
        guard let channel = channelID.flatMap({ model.channelIndex[$0] }) else { return "" }
        return channel.recipientIDs
            .filter { $0 != model.currentUserID }
            .compactMap { model.users[$0]?.preferredName }
            .joined(separator: ", ")
    }
}

extension View {
    /// Apply once, at the window root.
    func presentsConversationHeads() -> some View {
        modifier(ConversationHeadPresenter())
    }
}

/// Discord's Add Friends to DM, for a group that already exists: friends not
/// in it yet, up to the group's room, added with Add.
private struct GroupInviteSheet: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var picked: [UserID] = []

    /// Discord's cap on a group without Nitro's bigger groups.
    private static let memberLimit = 10

    var body: some View {
        let members = Set((model.channelIndex[channelID]?.recipientIDs ?? []) + [model.currentUserID].compactMap { $0 })
        let room = max(0, Self.memberLimit - members.count - picked.count)
        let friends = model.relationships
            .filter { $0.value == .friend && !members.contains($0.key) }
            .compactMap { model.users[$0.key] }
            .filter { query.isEmpty || $0.preferredName.localizedCaseInsensitiveContains(query)
                || $0.username.localizedCaseInsensitiveContains(query) }
            .sorted { $0.preferredName.localizedCaseInsensitiveCompare($1.preferredName) == .orderedAscending }

        VStack(alignment: .leading, spacing: Spacing.snug) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text("Add Friends to DM")
                    .font(.system(.title3, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                Text(room == 1 ? "You can add 1 more person." : "You can add \(room) more people.")
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.secondary)
            }
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
            if friends.isEmpty {
                Text("No results found.")
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(friends) { friend in
                            row(friend, isDisabled: room == 0 && !picked.contains(friend.id))
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    model.sessionController.addGroupRecipients(picked, to: channelID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty)
            }
        }
        .padding(Spacing.group)
        .frame(width: 400, height: 460)
    }

    private func row(_ friend: User, isDisabled: Bool) -> some View {
        let isOn = picked.contains(friend.id)
        return Button {
            if isOn { picked.removeAll { $0 == friend.id } } else { picked.append(friend.id) }
        } label: {
            HStack(spacing: Spacing.snug) {
                AvatarView(
                    url: model.avatarURL(forUserID: friend.id, inGuild: nil, side: 32),
                    monogram: friend.monogram,
                    side: 32
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(friend.preferredName)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                    Text(friend.username)
                        .font(.system(.caption))
                        .foregroundStyle(Ink.tertiary)
                }
                Spacer(minLength: Spacing.base)
                Image(symbol: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(isOn ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Ink.tertiary))
            }
            .padding(.vertical, Spacing.tight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
