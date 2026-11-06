import SwiftUI
import WingcordCore

// MARK: - The menu bar's submenus
//
// Alex's reference (DESIGN-NOTES §10, images 33–43). Each view takes the store
// as a value, because a menu bar command has no view environment. Every item
// here has an act behind it; the ones that do not yet are listed in §10.1 and
// are not shown.
//
// **They read `model.menuContext` and state that moves as rarely, nothing
// else** — see `MenuContext` for the flicker that rule ended.

extension FocusedValues {
    /// True while the workspace is the window in front.
    ///
    /// **The menu bar acts on the key window**, and most of it is about the
    /// workspace — the open channel, its newest message, going somewhere. With
    /// Settings or a server's settings in front those items are off rather than
    /// acting on a window behind it: ⌘F there used to search the channel in the
    /// window underneath. A scene value, not a view's: it holds whichever view
    /// in the workspace has focus, including none.
    @Entry var workspaceIsKey: Bool?
}

/// User › Online, Idle, Do Not Disturb, Invisible — one checked choice.
/// User › Switch Accounts: the now bar's flyout, as a command.
struct AccountsMenu: View {
    var model: AppModel

    var body: some View {
        Menu("Switch Accounts") {
            ForEach(model.storedAccounts) { account in
                let isCurrent = account.id == model.currentUserID?.description
                Toggle(
                    account.isSessionExpired
                        ? "\(account.preferredName) (session expired)"
                        : account.preferredName,
                    isOn: Binding(
                        get: { isCurrent },
                        set: { _ in model.requestAccountSwitch(to: account) }
                    )
                )
                .disabled(isCurrent)
            }
            Divider()
            if AccountList(model.storedAccounts).canAdd {
                Button("Add an Account…") { model.presentAddAccount() }
            }
            Button("Manage Accounts…") { SettingsWindow.open(.account) }
        }
        .disabled(model.currentUserID == nil)
    }
}

struct UserStatusPicker: View {
    var model: AppModel

    var body: some View {
        Picker("Status", selection: Binding(
            get: { model.selfStatus },
            set: { model.updateSelfStatus($0) }
        )) {
            ForEach([PresenceStatus.online, .idle, .doNotDisturb, .invisible], id: \.self) { status in
                Text(status.label).tag(status)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        .disabled(!model.menuContext.isReady)
    }
}

/// Channel › Profile — the person a direct message is with.
struct ChannelProfileMenu: View {
    var model: AppModel

    var body: some View {
        let userID = model.menuContext.recipientID
        Menu("Profile") {
            if let userID {
                Button("View Profile") {
                    model.openProfile(userID, anchor: .zero, depth: .full)
                }
                // Where the person menu's Add Note goes: the note is on the
                // full profile. A fixed title — whether one exists is a read
                // the menu bar does not make (`MenuContext`).
                Button("Add Note…") {
                    model.openProfile(userID, anchor: .zero, depth: .full)
                }
                Divider()
                switch model.relationship(with: userID) {
                case .friend:
                    Button("Remove Friend") { model.toggleFriend(with: userID) }
                case .none, .incomingRequest:
                    Button("Add Friend") { model.toggleFriend(with: userID) }
                default:
                    EmptyView()
                }
                Button(model.isIgnored(userID) ? "Unignore" : "Ignore") {
                    model.askToIgnore(userID)
                }
                Button(model.isBlocked(userID) ? "Unblock" : "Block") {
                    model.askToBlock(userID)
                }
            }
        }
        .disabled(userID == nil)
    }
}

/// Channel › Recents — Alex's reference's "recents drop down under the search
/// tab": the channels visited this session, the conversations with drafts, and
/// Clear Recents. Each item goes where the switcher's row would.
struct ChannelRecentsMenu: View {
    var model: AppModel

    var body: some View {
        let context = model.menuContext
        Menu("Recents") {
            Menu("Recent Channels") {
                ForEach(context.recentChannels) { row in item(row) }
            }
            .disabled(context.recentChannels.isEmpty)
            Menu("Drafts") {
                ForEach(context.draftChannels) { row in item(row) }
            }
            .disabled(context.draftChannels.isEmpty)
            Divider()
            Button("Clear Recents") { model.clearRecents() }
                .disabled(context.recentChannels.isEmpty)
        }
    }

    /// A row as the switcher draws it: the channel or person, and under it the
    /// server — the answer to "which #general".
    private func item(_ row: QuickSwitchRow) -> some View {
        Button { model.openQuickSwitchRow(row) } label: {
            Text(row.title)
            if let trailing = row.trailing { Text(trailing) }
        }
    }
}

/// Channel › Invite to.
///
/// In a server channel, Invite to Server… and Invite to Channel… — the server
/// menu's invite page, for the server or for this channel (a thread's parent:
/// an invite cannot point into a thread). In a direct message, the servers its
/// person can be invited to, as the person menu's Invite to Server lists them.
struct ChannelInviteMenu: View {
    var model: AppModel

    var body: some View {
        let context = model.menuContext
        Menu("Invite to") {
            if context.canInvite {
                Button("Invite to Server…") { model.openServerMenuFromMenuBar(page: .invite) }
                Button("Invite to Channel…") {
                    let channelID = context.kind?.isThread == true ? context.parentID : context.channelID
                    model.openServerMenuFromMenuBar(page: .invite, inviteChannelID: channelID)
                }
            } else if let userID = context.recipientID {
                ForEach(context.inviteGuilds) { guild in
                    Button(guild.name) { model.invite(userID, to: guild) }
                }
            }
        }
        .disabled(!context.canInvite && context.inviteGuilds.isEmpty)
    }
}

/// Channel › what a forum's toolbar row holds, because every control in it is also
/// a command (INVARIANTS: "The chrome is ours"). The same questions the row's Sort &
/// View asks, with the menu bar's checkmarks.
struct ChannelForumMenu: View {
    var model: AppModel

    var body: some View {
        if let forum = model.menuContext.forum, let channelID = model.menuContext.channelID {
            Menu(forum.isMedia ? "Sort" : "Sort & View") {
                Picker("Sort by", selection: choice(forum, channelID, \.sortOrder)) {
                    ForEach(ForumSortOrder.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                // A media channel is always a gallery.
                if !forum.isMedia {
                    Picker("View as", selection: choice(forum, channelID, \.layout)) {
                        ForEach(ForumLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
                if forum.hasTags {
                    Picker("Tag Matching", selection: choice(forum, channelID, \.tagMatching)) {
                        ForEach(TagMatching.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
                Divider()
                Button("Reset to default") {
                    model.setForumQuery(forum.query.resettingToDefaults(forum.defaults), in: channelID)
                }
            }
            if forum.hasGuidelines {
                Button(model.areForumGuidelinesShown ? "Hide Guidelines" : "Show Guidelines") {
                    model.areForumGuidelinesShown.toggle()
                }
            }
        }
    }

    private func choice<Value: Hashable>(
        _ forum: MenuContext.ForumMenu,
        _ channelID: ChannelID,
        _ path: WritableKeyPath<ForumQuery, Value>
    ) -> Binding<Value> {
        Binding(
            get: { forum.query[keyPath: path] },
            set: { value in
                var next = forum.query
                next[keyPath: path] = value
                model.setForumQuery(next, in: channelID)
            }
        )
    }
}

/// Channel › Developer — the ids and links Discord's developer mode copies.
struct ChannelDeveloperMenu: View {
    var model: AppModel

    var body: some View {
        let context = model.menuContext
        Menu("Developer") {
            if let userID = context.recipientID {
                Button("Copy User ID") { AppModel.copy(String(userID.rawValue)) }
                Button("Copy User Link") { AppModel.copy("https://discord.com/users/\(userID.rawValue)") }
            }
            if let channelID = context.channelID {
                Button("Copy Channel ID") { AppModel.copy(String(channelID.rawValue)) }
            }
            ShortcutMenuItem(shortcut: .copyChannelLink, model: model)
        }
        .disabled(context.channelID == nil)
    }
}

/// Channel › Channel Settings — for a reader who may manage the channel.
struct ChannelSettingsMenu: View {
    var model: AppModel

    var body: some View {
        let context = model.menuContext
        Menu("Channel Settings") {
            if let channelID = context.channelID, let guildID = context.guildID {
                Button("Edit Channel…") { ServerSettingsWindow.open(guildID, channel: channelID) }
                if context.kind?.isThread == false {
                    Button("Duplicate Channel…") { model.openChannelDuplication(of: channelID) }
                }
                Button("Create Text Channel…") {
                    model.openChannelCreation(inGuild: guildID, parentID: context.parentID)
                }
                Divider()
                Button("Delete Channel…", role: .destructive) {
                    model.requestChannelDeletion(channelID)
                }
            }
        }
        .disabled(!context.canManageChannels)
    }
}

/// Channel › Notifications — muting, and how loud a server channel is.
struct ChannelNotificationsMenu: View {
    var model: AppModel

    var body: some View {
        let context = model.menuContext
        // A server channel's own level; a conversation, a thread and a voice
        // channel have none — `ChannelOptionsMenu.levels(for:)`.
        let kind = context.kind ?? .text
        let level: MessageNotificationLevel? = context.guildID.flatMap { guildID in
            guard let channelID = context.channelID, !kind.isThread,
                  !ChannelOptionsMenu.levels(for: kind).isEmpty else { return nil }
            return model.guildSettings(for: guildID).channelOverrides[channelID]?.messageNotifications ?? .inherit
        }
        Menu("Notifications") {
            Menu("Mute For") {
                ForEach(MuteDuration.allCases, id: \.self) { duration in
                    Button(duration.title) { model.muteOpenChannel(for: duration) }
                }
            }
            if let level {
                Divider()
                Picker("Notification Preferences", selection: Binding(
                    get: { level },
                    set: { model.setOpenChannelNotificationLevel($0) }
                )) {
                    ForEach([.inherit] + ChannelOptionsMenu.levels(for: kind), id: \.self) { candidate in
                        Text(ChannelOptionsMenu.levelTitle(candidate, kind: kind, inCategory: context.parentID != nil))
                            .tag(candidate)
                    }
                }
            }
            Divider()
            if context.guildID != nil {
                Button("Manage Server Notifications") { model.openServerMenuFromMenuBar(page: .notifications) }
            }
            Button("Manage All Notifications") { SettingsWindow.open(.notifications) }
        }
        .disabled(context.channelID == nil)
    }
}

/// One menu item bound to whatever the reader has moved its shortcut to.
///
/// **A cleared binding keeps its item and loses its equivalent**, which is what
/// makes clearing one a way of freeing a combination rather than of hiding a
/// command — the item is still in the menu, still says what it does, and is
/// still clickable. On the item rather than on the menu: a whole menu that
/// greys out while the app is connecting reads as a feature that is missing,
/// where greyed items read as a feature that is not ready yet.
struct ShortcutMenuItem: View {
    var shortcut: AppShortcut
    var model: AppModel
    /// The menu's own wording, where it differs from the table's.
    var title: String?

    var body: some View {
        let binding = AppSettings.shared.shortcut(for: shortcut)?.keyboardShortcut
        Button(title ?? shortcut.menuTitle) { shortcut.perform(in: model) }
            .keyboardShortcut(binding)
            .disabled(!shortcut.isAvailable(in: model))
    }
}
