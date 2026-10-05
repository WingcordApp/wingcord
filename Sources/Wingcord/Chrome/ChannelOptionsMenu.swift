import SwiftUI
import WingcordCore

/// A server channel's own menu — Discord's `channel-context` (`50c63888` for
/// a text channel, `1bd21c67` for a category), right-clicked in the sidebar.
///
/// **Discord's groups, in its order**: Mark As Read; Invite People and Copy
/// Link; the mute and the notification level; Edit Channel and Delete
/// Channel; Copy Channel ID. A category trades the invite for Collapse
/// Category. Each row is there only where the reader can do it.
///
/// **One list, two more levels, one surface** — the mute durations and the
/// notification levels swap in place, as the server menu's do.
struct ChannelOptionsMenu: View {
    var channelID: ChannelID
    var close: () -> Void

    enum Surface: Hashable {
        case root
        case mute
        case notifications
    }

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var surface = Surface.root

    static let width: CGFloat = 236

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let channel = model.channelIndex[channelID], let guildID = channel.guildID {
                switch surface {
                case .root: root(channel, guildID: guildID)
                case .mute: mutePicker(channel, guildID: guildID)
                case .notifications: levels(channel, guildID: guildID)
                }
            }
        }
        .padding(.vertical, Spacing.tight)
        .frame(width: Self.width)
        .animation(motion.standard, value: surface)
    }

    // MARK: Root

    @ViewBuilder
    private func root(_ channel: Channel, guildID: GuildID) -> some View {
        let isCategory = channel.kind == .category
        let permissions = model.permissionGate.permissions(in: channel.id)
        let override = model.guildSettings(for: guildID).channelOverrides[channel.id]
        let isMuted = override?.isMuted() ?? false

        FlyoutRow(title: "Mark As Read", symbolName: "checkmark.circle") {
            markRead(channel, guildID: guildID)
            close()
        }
        FlyoutDivider()
        if isCategory {
            FlyoutRow(
                title: "Collapse Category",
                accessory: .checkbox(model.collapsedCategoryIDs.contains(channel.id))
            ) {
                model.toggleCategory(channel.id)
            }
        } else {
            if permissions.contains(.createInvite) {
                // Discord's name for a channel's own invite (`e6e0cb97`'s `D`),
                // and an invite made for this channel rather than the server's
                // default one.
                FlyoutRow(
                    title: channel.kind == .voice ? "Invite to Voice" : "Invite to Channel",
                    symbolName: "person.badge.plus",
                    accessory: .disclosure
                ) {
                    let anchor = model.channelOptionsMenu?.anchor ?? .zero
                    close()
                    model.openServerOptions(guildID, anchor: anchor, page: .invite, inviteChannelID: channel.id)
                }
            }
            FlyoutRow(title: "Copy Link", symbolName: "link") {
                AppModel.copy("https://discord.com/channels/\(guildID.rawValue)/\(channel.id.rawValue)")
                close()
            }
        }
        if channel.kind == .voice {
            voiceStatusRow(channel, guildID: guildID, permissions: permissions)
        }
        FlyoutDivider()
        FlyoutRow(
            title: isMuted
                ? (isCategory ? "Unmute Category" : "Unmute Channel")
                : (isCategory ? "Mute Category" : "Mute Channel"),
            subtitle: isMuted ? override?.muteDuration()?.title : nil,
            symbolName: isMuted ? "bell" : "bell.slash",
            accessory: isMuted ? .none : .disclosure
        ) {
            if isMuted {
                model.applyGuildSetting(.channelMuted(channel.id, nil), in: guildID)
            } else {
                surface = .mute
            }
        }
        if channel.kind != .voice {
            FlyoutRow(
                title: "Notification Settings",
                subtitle: levelTitle(override?.messageNotifications ?? .inherit, channel: channel),
                symbolName: "bell.badge",
                accessory: .disclosure
            ) {
                surface = .notifications
            }
        }
        let canEdit = !permissions.isDisjoint(with: [.manageChannels, .manageRoles, .manageWebhooks])
        if canEdit || permissions.contains(.manageChannels) {
            FlyoutDivider()
            if canEdit {
                FlyoutRow(title: isCategory ? "Edit Category" : "Edit Channel", symbolName: "gearshape") {
                    close()
                    ServerSettingsWindow.open(guildID, channel: channel.id)
                }
            }
            // Discord's "Create Text Channel" — in the category, or beside
            // this channel; a voice channel's offers "Create Voice Channel".
            if permissions.contains(.manageChannels) {
                let isVoice = channel.kind == .voice
                FlyoutRow(
                    title: isVoice ? "Create Voice Channel" : "Create Text Channel",
                    symbolName: "plus.circle"
                ) {
                    close()
                    model.openChannelCreation(
                        inGuild: guildID,
                        parentID: isCategory ? channel.id : channel.parentID,
                        kind: isVoice ? .voice : .text
                    )
                }
            }
            if permissions.contains(.manageChannels) {
                FlyoutRow(
                    title: isCategory ? "Delete Category" : "Delete Channel",
                    symbolName: "trash",
                    isDestructive: true
                ) {
                    close()
                    model.requestChannelDeletion(channel.id)
                }
            }
        }
        if AppSettings.shared.developerMode {
            FlyoutDivider()
            FlyoutRow(title: isCategory ? "Copy Category ID" : "Copy Channel ID", symbolName: "number") {
                AppModel.copy(channel.id.description)
                close()
            }
        }
    }

    /// Discord's status item (`671483`), in its voice-actions group: Set for
    /// somebody in the channel who may set one, Clear for somebody holding
    /// Manage Channels from outside it, while there is one to clear.
    @ViewBuilder
    private func voiceStatusRow(_ channel: Channel, guildID: GuildID, permissions: Permissions) -> some View {
        let managesChannels = model.permissionGate.permissions(inGuild: guildID).contains(.manageChannels)
        let canSet = permissions.isSuperset(of: [.setVoiceChannelStatus, .connect, .viewChannel])
        let isHere = model.connectedVoiceChannelID == channel.id
        let hasStatus = !(model.voiceChannelInfo[channel.id]?.status ?? "").isEmpty
        if !isHere, managesChannels, hasStatus {
            FlyoutDivider()
            FlyoutRow(title: "Clear Channel Status", symbolName: "xmark.circle") {
                model.clearVoiceStatus(in: channel.id)
                close()
            }
        } else if isHere, canSet {
            FlyoutDivider()
            FlyoutRow(title: "Set Channel Status", symbolName: "pencil") {
                close()
                model.editVoiceStatus(in: channel.id)
            }
        }
    }

    // MARK: Levels

    @ViewBuilder
    private func mutePicker(_ channel: Channel, guildID: GuildID) -> some View {
        FlyoutBackRow(title: channel.kind == .category ? "Mute Category" : "Mute Channel") { surface = .root }
        FlyoutDivider()
        let current = model.guildSettings(for: guildID).channelOverrides[channel.id]?.muteDuration()
        ForEach(MuteDuration.allCases, id: \.self) { duration in
            FlyoutRow(
                title: duration.title,
                symbolName: "clock",
                accessory: .tick(duration == current),
                isSelected: duration == current
            ) {
                model.applyGuildSetting(.channelMuted(channel.id, duration), in: guildID)
                close()
            }
        }
    }

    /// Discord's notification levels for a channel (`288104`): the default it
    /// inherits — the category's where it has one — then the three levels.
    @ViewBuilder
    private func levels(_ channel: Channel, guildID: GuildID) -> some View {
        let level = model.guildSettings(for: guildID).channelOverrides[channel.id]?.messageNotifications ?? .inherit
        FlyoutBackRow(title: "Notification Settings") { surface = .root }
        FlyoutDivider()
        FlyoutRow(
            title: channel.parentID == nil ? "Use Server Default" : "Use Category Default",
            accessory: .tick(level == .inherit),
            isSelected: level == .inherit
        ) {
            model.applyGuildSetting(.channelLevel(channel.id, .inherit), in: guildID)
        }
        ForEach([MessageNotificationLevel.allMessages, .onlyMentions, .nothing], id: \.self) { candidate in
            FlyoutRow(
                title: levelTitle(candidate, channel: channel),
                accessory: .tick(level == candidate),
                isSelected: level == candidate
            ) {
                model.applyGuildSetting(.channelLevel(channel.id, candidate), in: guildID)
            }
        }
    }

    private func levelTitle(_ level: MessageNotificationLevel, channel: Channel) -> String {
        switch level {
        case .allMessages: "All Messages"
        case .onlyMentions: "Only @mentions"
        case .nothing: "Nothing"
        case .inherit: channel.parentID == nil ? "Use Server Default" : "Use Category Default"
        }
    }

    /// A category marks every channel under it read.
    private func markRead(_ channel: Channel, guildID: GuildID) {
        guard channel.kind == .category else {
            model.markRead(channel.id)
            return
        }
        for childID in model.channelIndex.channelIDs(inGuild: guildID)
        where model.channelIndex[childID]?.parentID == channel.id {
            model.markRead(childID)
        }
    }
}

/// Presents the channel menu from the window root, at the row's rect.
struct ChannelOptionsPresenter: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        return content
            .popover(
                item: $model.channelOptionsMenu,
                attachmentAnchor: .rect(.rect(model.channelOptionsMenu?.anchor ?? .zero)),
                arrowEdge: .trailing
            ) { request in
                ChannelOptionsMenu(channelID: request.channelID, close: { model.channelOptionsMenu = nil })
                    .environment(model)
                    .presentationBackground(.clear)
            }
            // Discord's delete modal (`572874`): a refusal first where the
            // server needs the channel, otherwise the confirmation.
            .alert(
                model.channelDeletion?.title ?? "",
                isPresented: Binding(
                    get: { model.channelDeletion != nil },
                    set: { if !$0 { model.channelDeletion = nil } }
                ),
                presenting: model.channelDeletion
            ) { request in
                if request.refusal == nil {
                    Button(request.confirmTitle, role: .destructive) { model.confirmChannelDeletion() }
                    Button("Cancel", role: .cancel) { model.channelDeletion = nil }
                } else {
                    Button("Okay", role: .cancel) { model.channelDeletion = nil }
                }
            } message: { request in
                Text(request.message)
            }
    }
}

extension View {
    /// Apply once, at the window root.
    func presentsChannelOptions() -> some View {
        modifier(ChannelOptionsPresenter())
    }
}
