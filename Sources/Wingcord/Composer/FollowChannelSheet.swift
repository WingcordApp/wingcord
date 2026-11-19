import SwiftUI
import WingcordCore

/// Which announcement channel is being followed.
struct FollowChannelRequest: Identifiable, Hashable {
    var id: ChannelID
}

/// **Follow** on an announcement channel's bar: Discord's "Follow #channel" —
/// pick one of your servers, then one of its channels, and every announcement
/// is reposted there (`POST /channels/{id}/followers`). Only servers and
/// channels where you can manage webhooks are offered, because nowhere else
/// can take the follow (his ask, 2026-11-19).
struct FollowChannelSheet: View {
    var source: ChannelID

    @Environment(AppModel.self) private var model
    @ModalDismiss private var dismiss
    @State private var guildID: GuildID?
    @State private var targetID: ChannelID?
    @State private var isWorking = false

    var body: some View {
        FormSheet(
            title: "Follow #\(model.channelIndex[source]?.name ?? "channel")",
            subtitle: Text("Get this channel’s updates in a channel of your own server."),
            confirmTitle: "Follow",
            isWorking: isWorking,
            canConfirm: targetID != nil && !isWorking,
            width: 420,
            confirmSymbol: "megaphone",
            confirm: follow
        ) {
            if servers.isEmpty {
                Text("You need Manage Webhooks in a channel of one of your servers to follow this one.")
                    .font(.system(.callout))
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Server", selection: $guildID) {
                    Text("Choose a server").tag(GuildID?.none)
                    ForEach(servers) { guild in
                        Text(guild.name).tag(GuildID?.some(guild.id))
                    }
                }
                Picker("Channel", selection: $targetID) {
                    Text("Choose a channel").tag(ChannelID?.none)
                    ForEach(channels, id: \.id) { channel in
                        Text("#\(channel.name)").tag(ChannelID?.some(channel.id))
                    }
                }
                .disabled(guildID == nil)
            }
        }
        .onChange(of: guildID) { targetID = channels.count == 1 ? channels.first?.id : nil }
    }

    /// The reader's servers with somewhere a follow can land, by name.
    private var servers: [Guild] {
        model.guilds.values
            .filter { !followTargets(in: $0.id).isEmpty }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var channels: [Channel] {
        guildID.map(followTargets(in:)) ?? []
    }

    /// Text and announcement channels where the reader can manage webhooks,
    /// in the list's order — never the channel being followed.
    private func followTargets(in guildID: GuildID) -> [Channel] {
        model.sidebarOrderedChannelIDs(inGuild: guildID).compactMap { id in
            guard id != source, let channel = model.channelIndex[id],
                  channel.kind == .text || channel.kind == .announcement,
                  model.permissionGate.permissions(in: id).contains(.manageWebhooks)
            else { return nil }
            return channel
        }
    }

    private func follow() {
        guard let targetID, !isWorking else { return }
        isWorking = true
        Task {
            let followed = await model.sessionController.followAnnouncementChannel(source, into: targetID)
            isWorking = false
            if followed {
                model.reportSuccess("Following #\(model.channelIndex[source]?.name ?? "channel") in #\(model.channelIndex[targetID]?.name ?? "channel").")
                dismiss()
            }
        }
    }
}

extension SessionController {
    /// Follows `source` into `target`; a refusal is said in the reader's words.
    func followAnnouncementChannel(_ source: ChannelID, into target: ChannelID) async -> Bool {
        do {
            try await rest.followAnnouncementChannel(source, into: target)
            return true
        } catch {
            model.reportActionFailure("Couldn’t follow the channel: \(Self.describe(error))")
            return false
        }
    }
}

/// Presents `FollowChannelSheet` — on the message box, where its Follow is.
struct FollowChannelPresenter: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.modal(item: Binding(
            get: { model.followRequest },
            set: { model.followRequest = $0 }
        )) { request in
            FollowChannelSheet(source: request.id)
        }
    }
}
