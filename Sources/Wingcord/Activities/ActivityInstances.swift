import Foundation
import Observation
import WingcordCore

/// Every activity running where this account can see, and who is in each.
///
/// **Discord's `EmbeddedActivitiesStore`, as a store of its own** (module
/// 933958): rebuilt for every server from READY_SUPPLEMENTAL and GUILD_CREATE,
/// patched by `EMBEDDED_ACTIVITY_UPDATE_V2`, one instance per application per
/// place, gone when nobody is left in it. The call's activity tile, the hub's
/// whiteboard, Join on an invitation and the launcher's "In this call now" all
/// read it; the frame opens from it (`SessionController.reconcileActivity`).
///
/// Beside the model rather than inside it, as `ServerHubStore` is: activity
/// updates arrive a few times a minute on a busy account, and a change here
/// should only touch what draws activities.
@MainActor
@Observable
final class ActivityInstances {
    /// Instances by place, then by app.
    private(set) var byLocation: [ActivityLocation: [ApplicationID: ActivityInstance]] = [:] {
        didSet { revision &+= 1 }
    }
    /// Moves on every change: what the sidebar's memo keys on, so a voice row
    /// redraws the activity under it (decision 8) and nothing else rebuilds.
    private(set) var revision: UInt64 = 0

    /// One instance changed: started, someone joined or left, or it ended.
    func apply(_ instance: ActivityInstance) {
        var place = byLocation[instance.location] ?? [:]
        if instance.isEmpty {
            place[instance.applicationID] = nil
        } else {
            place[instance.applicationID] = instance
        }
        byLocation[instance.location] = place.isEmpty ? nil : place
    }

    /// A server's whole list, as READY_SUPPLEMENTAL or GUILD_CREATE gives it.
    /// What it doesn't list has ended.
    func replace(guild guildID: GuildID, with instances: [ActivityInstance]) {
        var next = byLocation.filter { $0.key.guildID != guildID }
        for instance in instances where !instance.isEmpty {
            next[instance.location, default: [:]][instance.applicationID] = instance
        }
        byLocation = next
    }

    /// A new connection: every server's list is replaced, and the private
    /// channels' instances (which no bootstrap lists) are kept until their own
    /// updates say otherwise.
    func replaceGuilds(_ instances: [GuildID: [ActivityInstance]]) {
        var next = byLocation.filter { $0.key.guildID == nil }
        for (_, list) in instances {
            for instance in list where !instance.isEmpty {
                next[instance.location, default: [:]][instance.applicationID] = instance
            }
        }
        byLocation = next
    }

    /// A channel was deleted, or a server left.
    func remove(channel channelID: ChannelID) {
        byLocation = byLocation.filter { $0.key.channelID != channelID }
    }

    func remove(guild guildID: GuildID) {
        byLocation = byLocation.filter { $0.key.guildID != guildID }
    }

    // MARK: Reading

    /// What runs in a channel, oldest launch first.
    func instances(in channelID: ChannelID) -> [ActivityInstance] {
        byLocation
            .filter { $0.key.channelID == channelID }
            .flatMap(\.value.values)
            .sorted { $0.launchOrder < $1.launchOrder }
    }

    func instance(of applicationID: ApplicationID, in channelID: ChannelID) -> ActivityInstance? {
        byLocation.first { $0.key.channelID == channelID }?.value[applicationID]
    }

    /// The instance a person is in, if any (Discord's
    /// `getEmbeddedActivityForUserId`). Their newest, if two.
    func instance(for userID: UserID) -> ActivityInstance? {
        byLocation.values
            .flatMap(\.values)
            .filter { $0.includes(userID) }
            .max { $0.launchOrder < $1.launchOrder }
    }

    /// The instance this session is in, if any: what the frame should show.
    func instance(for userID: UserID, session sessionID: String) -> ActivityInstance? {
        byLocation.values
            .flatMap(\.values)
            .first { $0.includes(userID, session: sessionID) }
    }

    /// Every running instance in one server's channels.
    func instances(inGuild guildID: GuildID) -> [ActivityInstance] {
        byLocation
            .filter { $0.key.guildID == guildID }
            .flatMap(\.value.values)
    }
}

private extension ActivityInstance {
    /// Launch ids are snowflakes: numbers, compared as numbers (an older one
    /// can be a digit shorter).
    var launchOrder: UInt64 { UInt64(launchID) ?? 0 }
}
