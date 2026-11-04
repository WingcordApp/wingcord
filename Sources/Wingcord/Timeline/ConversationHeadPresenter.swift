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
            // Deliberately chosen, so the act's colour; it cannot be undone,
            // so no Return (D11b).
            .modal(item: Binding(
                get: { model.headDeauthorization },
                set: { if $0 == nil { model.headDeauthorization = nil } }
            ), style: .alert) { app in
                ModalAlert(
                    hero: .symbol("link.badge.plus"),
                    title: "Deauthorize Application",
                    message: Text("This action will remove the link between your Discord account and \(app.name)"),
                    actions: [
                        .cancel(),
                        .act("Deauthorize", symbol: "xmark.shield", irreversible: true) {
                            model.sessionController.deauthorizeApp(app)
                        },
                    ]
                )
            }
            .modal(
                isPresented: Binding(
                    get: { model.groupRename != nil },
                    set: { if !$0 { model.groupRename = nil } }
                ),
                style: .alert
            ) {
                ModalAlert(
                    hero: .symbol("person.3.fill"),
                    title: "Edit Group",
                    actions: [
                        .cancel(),
                        .act("Save", symbol: "checkmark", enabled: groupName != currentName(model.groupRename)) {
                            guard let channelID = model.groupRename else { return }
                            model.sessionController.renameGroup(channelID, to: groupName)
                        },
                    ]
                ) {
                    // Discord's placeholder: the name the group has without one.
                    ModalTextField(placeholder: memberNames(model.groupRename), text: $groupName, symbolName: "pencil")
                }
            }
            .onChange(of: model.groupRename) { _, channelID in groupName = currentName(channelID) }
            .modal(isPresented: Binding(
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
    @ModalDismiss private var dismiss
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

        VStack(alignment: .leading, spacing: 0) {
            ModalHeader(
                title: "Add Friends to DM",
                subtitle: Text(room == 1 ? "You can add 1 more person." : "You can add \(room) more people."),
                close: { dismiss() }
            )
            VStack(alignment: .leading, spacing: Spacing.snug) {
                SearchField(prompt: "Search friends", text: $query)
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
                    .softScrollEdgesVertical()
                }
            }
            .padding(.horizontal, Spacing.group)
            HStack {
                Spacer()
                ModalButton(title: "Add", symbolName: "person.badge.plus", role: .act) {
                    model.sessionController.addGroupRecipients(picked, to: channelID)
                    dismiss()
                }
                .disabled(picked.isEmpty)
            }
            .padding(Spacing.margin)
        }
        .frame(width: 420, height: 500)
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
