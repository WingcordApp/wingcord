import AppKit
import Foundation
import WingcordCore

// MARK: - The measurement lines of docs/BETA3.md §1

/// Which servers and moments have already been written up this session, so
/// stepping back and forth through the rail repeats nothing.
@MainActor
enum LoadProbeMemory {
    static var writtenUp: Set<String> = []
}

extension AppModel {

    /// Why a server opened with nothing in its channel list (BETA3 §1.7).
    ///
    /// **Written only when the list is empty**, and once per server and
    /// moment, so the log answers which of three it is: no channels held for
    /// the server, every one refused by the permission check, or the reader's
    /// own member record and roles missing. Counts and flags only; the ids are
    /// hashed by the log like every other.
    func logServerVisibilityIfEmpty(_ guildID: GuildID, moment: StaticString) {
        guard let guild = guilds[guildID] else { return }
        let ids = channelIndex.channelIDs(inGuild: guildID)
        let filtered = hidesUnfollowedChannels(inGuild: guildID)
        var categories = 0, viewable = 0, inList = 0, everyoneDenied = 0
        for id in ids {
            guard let channel = channelIndex[id] else { continue }
            if channel.kind == .category {
                categories += 1
                continue
            }
            if channel.overwrites.contains(where: {
                $0.subject == .role && $0.id == guildID.rawValue && $0.deny.contains(.viewChannel)
            }) {
                everyoneDenied += 1
            }
            guard permissionGate.canView(id) else { continue }
            viewable += 1
            if isChannelInList(channel, filtered: filtered) { inList += 1 }
        }
        guard inList == 0 else { return }
        let memory = "\(guildID.rawValue) \(moment)"
        guard LoadProbeMemory.writtenUp.insert(memory).inserted else { return }

        let me = currentUserID.flatMap { members[guildID]?[$0] }
        let serverRoles = roles[guildID] ?? [:]
        let everyone = serverRoles[RoleID(rawValue: guildID.rawValue)]
        let followed = ids.filter { followedChannelIDs.contains($0) }.count
        let optIn = (guildUserSettings[guildID]?.flags ?? 0) & GuildUserSettingsFlags.optInChannelsOn != 0
        Log.info(
            .app,
            "server \(guildID) shows no channel (\(public: moment)): held \(ids.count - categories) + \(categories) categories, viewable \(viewable), in the list \(inList), followed \(followed), opt-in \(optIn), filtered \(filtered); member record \(me != nil), its roles \(me?.roleIDs.count ?? 0), pending \(me?.isPending ?? false), member flags \(me?.flags.rawValue ?? 0); server roles \(serverRoles.count), @everyone held \(everyone != nil), @everyone may view \(everyone?.permissions.contains(.viewChannel) ?? false), denied @everyone on \(everyoneDenied); server-wide view \(permissionGate.permissions(inGuild: guildID).contains(.viewChannel)); onboarding \(guild.features.contains("GUILD_ONBOARDING")), rules gate \(guild.features.contains("MEMBER_VERIFICATION_GATE_ENABLED")), previewing \(guildPreview?.guildID == guildID)"
        )
    }

    /// Discord refused a channel's history that Wingcord thought readable —
    /// both sides of the disagreement, in one line (BETA3 §1.7).
    func logRefusedHistory(_ channelID: ChannelID, code: Int?) {
        let permissions = permissionGate.permissions(in: channelID)
        let guildID = channelIndex.guildID(of: channelID)
        let me = guildID.flatMap { guild in currentUserID.flatMap { members[guild]?[$0] } }
        Log.info(
            .app,
            "Discord refused \(channelID)'s history (code \(code ?? 0)) where Wingcord sees view \(permissions.contains(.viewChannel)), history \(permissions.contains(.readMessageHistory)); member record \(me != nil), its roles \(me?.roleIDs.count ?? 0), pending \(me?.isPending ?? false)"
        )
    }

    /// Whether a member list's first rows are all drawable: sent by Discord,
    /// and naming people whose records are held. What "the rows came in"
    /// means to somebody looking at the column (BETA3 §1.9).
    func isMemberListHeadFilled(_ key: MemberListKey, rows wanted: Int = 30) -> Bool {
        guard let list = memberLists[key], list.rowCount > 0 else { return false }
        let guildMembers = members[key.guildID]
        for index in 0..<min(wanted, list.rowCount) {
            guard let row = list.rows[index] else { return false }
            if case .member(let userID) = row, guildMembers?[userID] == nil || users[userID] == nil {
                return false
            }
        }
        return true
    }
}

extension AnimationClock {

    /// Which switch is keeping pictures still, in words for the log
    /// (BETA3 §1.2) — the first of the gates `playsAnimatedEmoji` checks.
    static var whyStill: StaticString {
        let settings = AppSettings.shared
        if !settings.playsAnimatedContent { return "animated content is off in Settings" }
        if settings.isLowPowerModeOn { return "Low Power Mode is on" }
        if settings.isRunningHot { return "the Mac is running hot" }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return "Reduce Motion is on" }
        if GameMode.shared.isThrottling { return "Game Mode is holding animations" }
        return "no switch (all gates open)"
    }
}
