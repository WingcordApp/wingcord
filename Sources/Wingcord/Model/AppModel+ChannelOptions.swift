import CoreGraphics
import Foundation
import WingcordCore

// MARK: - A server channel's own menu

/// Where to hang a channel's menu.
struct ChannelOptionsRequest: Identifiable, Hashable, Sendable {
    var channelID: ChannelID
    var anchor: CGRect
    var id: UInt64 { channelID.rawValue }
}

/// Delete Channel from the sidebar: Discord's refusal where the server needs
/// the channel (`572874`), otherwise its confirmation.
struct ChannelDeletionRequest: Identifiable, Hashable, Sendable {
    var channelID: ChannelID
    var name: String
    var isCategory: Bool
    var refusal: ChannelDeleteGate.Refusal?

    var id: UInt64 { channelID.rawValue }

    var title: String {
        if refusal != nil { return "Cannot Delete Channel" }
        return confirmTitle
    }

    var confirmTitle: String { isCategory ? "Delete Category" : "Delete Channel" }

    var message: String {
        refusal?.message ?? "Are you sure you want to delete \(name)? This cannot be undone."
    }
}

extension AppModel {

    /// A right-click on a sidebar row: a conversation's menu in a direct
    /// message, a thread's under its channel, a channel's in a server.
    func openChannelMenu(for channelID: ChannelID, anchor: CGRect) {
        guard channelIndex.guildID(of: channelID) != nil else {
            openDirectMessageMenu(for: channelID, anchor: anchor)
            return
        }
        if channelIndex[channelID]?.kind.isThread == true {
            openThreadMenu(for: channelID, anchor: anchor)
            return
        }
        dismissMessageSurfaces()
        threadOptionsMenu = nil
        channelOptionsMenu = ChannelOptionsRequest(channelID: channelID, anchor: anchor)
    }

    /// Asks before deleting — or says why it cannot, with what this window
    /// knows: the server's guide, its onboarding, and its community channels.
    func requestChannelDeletion(_ channelID: ChannelID) {
        guard let channel = channelIndex[channelID], let guildID = channel.guildID else { return }
        let onboarding = guildOnboardings[guildID]
        let chattable = (onboarding?.defaultChannelIDs ?? []).filter { id in
            guard let candidate = channelIndex[id] else { return false }
            return !ChannelAccess.isPrivate(candidate, guildID: guildID)
        }.count
        let guild = guilds[guildID]
        let refusal = ChannelDeleteGate.refusal(
            for: channelID,
            guide: serverGuides[guildID],
            onboarding: onboarding,
            chattableDefaults: chattable,
            community: guild.flatMap {
                $0.features.contains("COMMUNITY") ? ($0.rulesChannelID, $0.publicUpdatesChannelID) : nil
            }
        )
        channelDeletion = ChannelDeletionRequest(
            channelID: channelID,
            name: displayName(of: channel),
            isCategory: channel.kind == .category,
            refusal: refusal
        )
    }

    func confirmChannelDeletion() {
        guard let request = channelDeletion, request.refusal == nil else { return }
        channelDeletion = nil
        guard permissionGate.permissions(in: request.channelID).contains(.manageChannels) else { return }
        sessionController.deleteChannel(request.channelID)
    }
}

// MARK: - Creating

/// Create Channel or Create Category — Discord's modal, raised from the server
/// menu, a category's "+", or a channel's own menu.
struct ChannelCreationRequest: Identifiable, Hashable {
    var guildID: GuildID
    /// The category it goes in — "in {category}" under the title.
    var parentID: ChannelID?
    /// `.category` for Create Category; otherwise the type the list opens on.
    var kind: ChannelKind
    /// Discord's Duplicate Channel: the channel whose name, permissions, user
    /// limit and bitrate the new one copies, as it was when the item was
    /// chosen. Its type is fixed and there is no privacy switch — the
    /// permissions are the copied ones.
    var duplicating: Channel?

    var id: String {
        "\(guildID.rawValue)-\(parentID?.rawValue ?? 0)-\(kind.rawValue)-\(duplicating?.id.rawValue ?? 0)"
    }
}

extension AppModel {
    func openChannelCreation(inGuild guildID: GuildID, parentID: ChannelID? = nil, kind: ChannelKind = .text) {
        channelOptionsMenu = nil
        channelCreation = ChannelCreationRequest(guildID: guildID, parentID: parentID, kind: kind)
    }

    /// Discord's Duplicate Channel, for a reader with Manage Channels: Create
    /// Channel with the name, type and category of `channelID`.
    func openChannelDuplication(of channelID: ChannelID) {
        guard let channel = channelIndex[channelID], let guildID = channel.guildID else { return }
        channelOptionsMenu = nil
        channelCreation = ChannelCreationRequest(
            guildID: guildID, parentID: channel.parentID, kind: channel.kind, duplicating: channel
        )
    }

    /// A category's "+": a text channel inside it.
    func openChannelCreation(inCategory categoryID: ChannelID) {
        guard let guildID = channelIndex.guildID(of: categoryID) else { return }
        openChannelCreation(inGuild: guildID, parentID: categoryID)
    }
}
