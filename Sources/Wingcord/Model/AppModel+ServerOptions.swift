import SwiftUI
import WingcordCore

// MARK: - What a server's menu offers, and what happens when it is used
//
// Two surfaces open on the same value: the chevron beside the server's name and
// a right-click on its tile in the rail. They are one menu with one set of rows
// — Discord's own two menus differ only in that the rail's can mark the server
// read — so there is one request type, one presenter and one view.

/// An open server menu.
struct ServerOptionsRequest: Identifiable, Hashable, Sendable {
    var guildID: GuildID
    /// The control's own frame, in the window root's space, so the popover
    /// points at what opened it — see `SecondaryClickCatcher`.
    var anchor: CGRect
    /// Which edge the surface hangs off. The rail is a column on the leading
    /// edge, so its menu goes right; the name pill is already inside the
    /// sidebar and its menu hangs below.
    var edge: Edge
    /// Which page the menu opens on — the root, or linked roles when a chip
    /// in a message asked for them.
    var page: ServerOptionsMenu.Surface = .root

    /// **Keyed on the server, not on the anchor.** Re-opening the same menu
    /// from the other surface should move it, not stack a second one; and a
    /// rect is a poor identity — a scroll would change it under an open
    /// popover and rebuild the whole thing.
    var id: GuildID { guildID }
}

extension AppModel {

    // MARK: Opening and closing

    func openServerOptions(
        _ guildID: GuildID,
        anchor: CGRect,
        edge: Edge = .trailing,
        page: ServerOptionsMenu.Surface = .root
    ) {
        serverOptionsMenu = ServerOptionsRequest(guildID: guildID, anchor: anchor, edge: edge, page: page)
    }

    /// Goes where an `<id:…>` chip points — Discord's module `392605`.
    ///
    /// **The guide, the channel browser and Channels & Roles only in a
    /// Community server**, where Discord goes too; anywhere else the chip is a
    /// name and a click on it does nothing. Linked roles open the server
    /// menu's own list, or the one role a chip names.
    func openStaticRoute(_ route: StaticRoute, itemID: UInt64?, anchor: CGRect) {
        guard let guildID = selectedGuildID, let guild = guilds[guildID] else { return }
        switch route {
        case .linkedRoles:
            openServerOptions(
                guildID,
                anchor: anchor,
                page: itemID.map { .linkedRole(RoleID(rawValue: $0)) } ?? .linkedRoles
            )
        case .home, .guide, .browse, .customize:
            guard guild.features.contains("COMMUNITY") else { return }
            let surface: GuildSurface = switch route {
            case .browse: .browseChannels
            case .customize: .channelsAndRoles
            default: .serverGuide
            }
            openSurface(surface)
        }
    }

    func dismissServerOptions() { serverOptionsMenu = nil }

    // MARK: The record behind it

    /// The reader's settings for one server.
    ///
    /// **Never nil.** READY carries an entry for every server the account has
    /// touched and none for the rest, and "no entry" is not an unknown — it is
    /// every default. A menu that had to wait for a fetch before it could draw
    /// nine switches would open blank on exactly the servers nobody has
    /// configured, which is most of them.
    func guildSettings(for guildID: GuildID) -> GuildUserSettings {
        guildUserSettings[guildID] ?? GuildUserSettings(guildID: guildID)
    }

    /// Applies a record that arrived from the wire.
    func applyGuildUserSettings(_ settings: GuildUserSettings) {
        guildUserSettings[settings.guildID] = settings
        reflectGuildMute(settings)
    }

    /// Writes one field, optimistically.
    ///
    /// **The switch moves now and is put back if the write fails.** Every one
    /// of these is a control the reader is looking at; a round trip before it
    /// moves reads as a control that does not work, and one left moved after a
    /// failure is a client that lies about whether it is muted.
    func applyGuildSetting(_ change: GuildUserSettingsChange, in guildID: GuildID) {
        let previous = guildSettings(for: guildID)
        let next = change.applied(to: previous)
        guildUserSettings[guildID] = next
        reflectGuildMute(next)
        sessionController.writeGuildSettings(change, in: guildID, restoring: previous)
    }

    /// Keeps the hot-path tables agreeing with the record.
    ///
    /// `mutedGuildIDs` is read by the rail on every badge and
    /// `notificationPreferences` by the notifier on every arriving message.
    /// They are derived from this record, so they are written from the one
    /// place it is — otherwise a server muted from the menu keeps ringing until
    /// the next reconnect, which is the bug this exists to prevent rather than
    /// to document.
    private func reflectGuildMute(_ settings: GuildUserSettings) {
        let guildID = settings.guildID
        // The **running** mute, not the flag: Discord leaves `muted` true and
        // lets the end time pass — see `ThreadMuteConfig.isActive`.
        if settings.isMuted() {
            mutedGuildIDs.insert(guildID)
            notificationPreferences.mutedGuildIDs.insert(guildID)
        } else {
            mutedGuildIDs.remove(guildID)
            notificationPreferences.mutedGuildIDs.remove(guildID)
        }
        notificationPreferences.guildLevels[guildID] = settings.messageNotifications
        if settings.suppressEveryone {
            notificationPreferences.suppressEveryoneGuildIDs.insert(guildID)
        } else {
            notificationPreferences.suppressEveryoneGuildIDs.remove(guildID)
        }
        if settings.suppressRoles {
            notificationPreferences.suppressRoleMentionGuildIDs.insert(guildID)
        } else {
            notificationPreferences.suppressRoleMentionGuildIDs.remove(guildID)
        }
        for (channelID, override) in settings.channelOverrides {
            notificationPreferences.channelLevels[channelID] = override.messageNotifications
            if override.isMuted() {
                notificationPreferences.mutedChannelIDs.insert(channelID)
            } else {
                notificationPreferences.mutedChannelIDs.remove(channelID)
            }
        }
    }

    // MARK: What the menu needs to know about the server

    /// Everything the root list reads, as one value.
    ///
    /// **Assembled once per open rather than read row by row.** The menu's body
    /// runs on every hover and every surface change; six lookups into three
    /// stores per row is that cost multiplied by the number of rows, for
    /// answers that cannot change while the popover is up.
    func serverOptions(for guildID: GuildID) -> ServerOptions? {
        guard let guild = guilds[guildID] else { return nil }
        let settings = guildSettings(for: guildID)
        let permissions = permissionGate.permissions(inGuild: guildID)
        return ServerOptions(
            guildID: guildID,
            name: guild.name,
            isPreviewing: isPreviewing(guildID),
            isUnread: guildBadge(for: guildID).unread,
            settings: settings,
            privacy: activityPrivacy.privacy(in: guildID),
            // **A permission, because a row without it is a round trip to a
            // 403** — `INVARIANTS.md` §5.5.
            canInvite: permissions.contains(.createInvite),
            // Resolved as the menu opens rather than when a row is clicked:
            // the permission walk is the expensive half, and doing it on the
            // press would put it on the main actor between the click and the
            // request. Nil is a server whose only invitable channels the reader
            // cannot see, which is a server with no usable target — so the row
            // goes rather than failing.
            inviteChannelID: inviteChannel(inGuild: guildID),
            // **Not one permission.** Discord opens the window for anybody
            // holding any of the moderation set, and shows them only the pages
            // that set reaches — so the row's gate is "is there a page", not
            // "do they manage the server". A reader with none of them used to
            // get a window of seven pages that all answered 403.
            canManageGuild: !ServerSettingsSection.reachable(with: permissions).isEmpty,
            // **Drawn only once the answer is in and non-empty.** Most servers
            // have no linked roles, and a row that opened onto "nothing here" is
            // the inert control §5.5 forbids. The fetch is started when the menu
            // opens and cached for the session, so the row settles on the first
            // open and is instant on every one after.
            hasLinkedRoles: !(linkedRoles[guildID] ?? []).isEmpty,
            // Discord greys Leave Server for the owner rather than hiding it:
            // the answer to "why can I not leave" is the row itself.
            isOwner: guild.ownerID == currentUserID,
            developerMode: AppSettings.shared.developerMode
        )
    }
}

// MARK: - The lists the menu's own surfaces draw

/// One channel in the notification sheet, either already carrying an override
/// or a candidate for one.
struct ChannelOverrideRow: Identifiable, Hashable, Sendable {
    var id: ChannelID
    var name: String
    var symbolName: String
    /// The level it is on, for the row that already has one. Empty for a
    /// candidate, which has nothing to report yet.
    var summary: String
}

/// One friend who is not in this server yet.
struct InvitableFriend: Identifiable, Hashable, Sendable {
    var id: UserID
    var name: String
}

extension AppModel {

    /// The channels that already carry a setting of their own, named and
    /// summarised.
    ///
    /// **Sorted by the sidebar's own order**, not by the dictionary's: an
    /// override table is a `[ChannelID: …]` and drawing it in hash order would
    /// reshuffle itself every time one was added.
    func channelOverrideRows(in guildID: GuildID) -> [ChannelOverrideRow] {
        let settings = guildSettings(for: guildID)
        var rows: [ChannelOverrideRow] = []
        for channelID in channelIndex.channelIDs(inGuild: guildID) {
            guard let override = settings.channelOverrides[channelID],
                  let channel = channelIndex[channelID]
            else { continue }
            // **An override carrying only a flag is not a setting the reader
            // made.** Every channel in an opt-in server has one — `flags` with
            // `OPT_IN_ENABLED` and nothing else — and listing those would put
            // four hundred rows under a heading that should hold two.
            guard override.isMuted || override.messageNotifications != .inherit else { continue }
            rows.append(
                ChannelOverrideRow(
                    id: channelID,
                    name: channel.name,
                    symbolName: channel.kind.symbolName,
                    summary: Self.summary(of: override)
                )
            )
        }
        return rows
    }

    /// The channels that could be given one.
    ///
    /// Conversations only, and only ones the reader can see: a level on a
    /// channel they cannot read is a setting with nothing to apply to.
    func overridableChannelRows(in guildID: GuildID) -> [ChannelOverrideRow] {
        var rows: [ChannelOverrideRow] = []
        for channelID in channelIndex.channelIDs(inGuild: guildID) {
            guard let channel = channelIndex[channelID] else { continue }
            guard channel.kind.isConversation || channel.kind == .category else { continue }
            guard permissionGate.canView(channelID) else { continue }
            rows.append(
                ChannelOverrideRow(
                    id: channelID,
                    name: channel.name,
                    symbolName: channel.kind.symbolName,
                    summary: ""
                )
            )
        }
        return rows
    }

    private static func summary(of override: ChannelUserSettings) -> String {
        if override.isMuted() { return "Muted" }
        return switch override.messageNotifications {
        case .allMessages: "All"
        case .onlyMentions: "Mentions"
        case .nothing: "Nothing"
        case .inherit: "Default"
        }
    }

    // MARK: Inviting

    /// Friends who are not in this server, as far as the client can tell.
    ///
    /// **The member table is the only evidence available and it is partial** —
    /// a large server's roster arrives a page at a time — so a friend who *is*
    /// here but has not been fetched will still be listed. That errs toward
    /// showing, which §5.5 asks for: the cost is a redundant invite, and the
    /// cost of the other direction is a friend who cannot be invited at all.
    func invitableFriends(for guildID: GuildID) -> [InvitableFriend] {
        let roster = members[guildID] ?? [:]
        var result: [InvitableFriend] = []
        for (userID, relationship) in relationships
        where relationship == .friend && roster[userID] == nil {
            guard let user = users[userID] else { continue }
            result.append(InvitableFriend(id: userID, name: user.preferredName))
        }
        return result.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Mints a link and sends it to one friend, in the conversation with them —
    /// which is what "invite to server" means and the only way a client can
    /// deliver one.
    func inviteFriend(_ userID: UserID, toChannel channelID: ChannelID) {
        guard userID != currentUserID else { return }
        guard permissionGate.permissions(in: channelID).contains(.createInvite) else { return }
        sessionController.sendInvite(to: userID, channelID: channelID)
    }

    /// Makes the shareable link, once.
    ///
    /// **Guarded on the cache, because every mint is a real invite.** The task
    /// that calls this runs whenever the invite surface appears, and a `POST`
    /// per appearance would litter the server's invite list with codes nobody
    /// used.
    func mintInviteLink(for guildID: GuildID, channelID: ChannelID) {
        guard serverInviteLinks[guildID] == nil else { return }
        sessionController.mintInviteLink(for: guildID, channelID: channelID)
    }

    // MARK: Linked roles

    /// The roles this server grants for an account elsewhere.
    ///
    /// Empty both when there are none and when the answer has not landed — the
    /// menu's row consults `hasLinkedRoles`, which knows the difference.
    func linkedRoles(in guildID: GuildID) -> [LinkedRole] {
        linkedRoles[guildID] ?? []
    }

    /// One role, named and coloured out of the store.
    ///
    /// **The role itself is not in the configuration payload** — it carries an
    /// id and its rules and nothing else — so the name comes from the roles the
    /// guild already sent. A role the store has never seen keeps its id as a
    /// name rather than disappearing: it is a role the reader could still earn.
    func linkedRoleName(_ roleID: RoleID, in guildID: GuildID) -> String {
        roles[guildID]?[roleID]?.name ?? "Role"
    }

    /// Writes an eligibility answer onto the role it was measured for.
    ///
    /// **Merged by rule identity, not replaced.** The eligibility route answers
    /// the groups without the role id and, on a server whose configuration has
    /// changed underneath, could answer a different shape from the one the page
    /// is drawing. Matching on the rule's own identity means a stale extra group
    /// is dropped rather than drawn with somebody else's result on it.
    func applyLinkedRoleEligibility(
        _ groups: [[RoleConnectionRule]],
        for roleID: RoleID,
        inGuild guildID: GuildID
    ) {
        guard var roles = linkedRoles[guildID],
              let index = roles.firstIndex(where: { $0.id == roleID })
        else { return }
        var results: [String: Bool] = [:]
        for rule in groups.flatMap(\.self) {
            guard let isMet = rule.isMet else { continue }
            results[rule.id] = isMet
        }
        roles[index].groups = roles[index].groups.map { group in
            group.map { rule in
                var measured = rule
                measured.isMet = results[rule.id]
                return measured
            }
        }
        linkedRoles[guildID] = roles
    }

    /// What the hover controls on somebody's status bubble do.
    ///
    /// **Nil on the reader's own and where there is nothing to answer** — you do
    /// not react to yourself, and a status with no words and no emoji has
    /// nothing to quote.
    func statusAnswering(for profile: ProfilePresentation) -> CustomStatusAnswering? {
        guard !profile.isSelf else { return nil }
        let status = CustomStatus(
            text: profile.customStatus,
            emoji: profile.customStatusEmoji
        )
        guard !status.isEmpty else { return nil }
        let userID = profile.userID
        // **The handle, not the display name** — the capture writes
        // `robinresting's status`, which is the account's username.
        let handle = users[userID]?.handle ?? profile.handle
        return CustomStatusAnswering(name: handle) { [weak self] answer in
            self?.sessionController.answerStatus(
                of: userID, handle: handle, status: status, answer: answer
            )
        }
    }

    /// Opens discovery on its Apps half — which is all Discord's own App
    /// Directory row does.
    func openAppDirectory() {
        if discovery == nil {
            discovery = DiscoveryState(tab: .apps)
        } else {
            discovery?.tab = .apps
        }
        sessionController.loadDiscovery()
    }
}

/// A server the reader has asked to leave, waiting on the alert.
///
/// Carries the name as well as the id: the alert names the server, and by the
/// time it is answered the store may no longer hold a guild the reader just
/// left from another client.
struct LeaveGuildRequest: Identifiable, Hashable, Sendable {
    var guildID: GuildID
    var name: String
    var id: GuildID { guildID }
}

extension AppModel {

    // MARK: The three acts that are not settings

    /// Raises the confirmation. Leaving happens in `confirmLeaveGuild`.
    func requestLeaveGuild(_ guildID: GuildID) {
        guard let guild = guilds[guildID] else { return }
        leaveGuildRequest = LeaveGuildRequest(guildID: guildID, name: guild.name)
    }

    func confirmLeaveGuild() {
        guard let request = leaveGuildRequest else { return }
        leaveGuildRequest = nil
        sessionController.leaveGuild(request.guildID)
    }

    /// Marks every channel in a server read.
    ///
    /// **Per channel, because that is the only route there is.** Discord's own
    /// bulk-ack exists but is a different envelope with a different rate limit;
    /// the menu's job here is the same act the reader would do by clicking
    /// through the list, and the channels that are already read are skipped so
    /// a quiet server costs nothing.
    func markGuildRead(_ guildID: GuildID) {
        for channelID in channelIndex.channelIDs(inGuild: guildID) {
            guard let channel = channelIndex[channelID], channel.kind.isConversation else {
                continue
            }
            guard permissionGate.canView(channelID), unreadState(of: channel).unread else {
                continue
            }
            markRead(channelID)
        }
    }

    /// Opens the reader's own profile for this server, with the editor already
    /// on its per-server page.
    ///
    /// The full sheet rather than the mini card: the editor is a rail beside the
    /// profile and there is nowhere to put it on a card.
    func editPerServerProfile(in guildID: GuildID) {
        guard let userID = currentUserID else { return }
        profileRequest = ProfileRequest(
            userID: userID,
            guildID: guildID,
            anchor: .zero,
            depth: .full,
            editsScope: .guild(guildID)
        )
    }
}

/// What the server menu draws, resolved once when it opens.
struct ServerOptions: Hashable, Sendable {
    var guildID: GuildID
    var name: String
    /// A server being looked at rather than joined. Its menu is two rows and
    /// neither is a setting — there is nothing to configure about a server you
    /// are not in, and offering it is two round trips to a 403.
    var isPreviewing: Bool
    var isUnread: Bool
    var settings: GuildUserSettings
    var privacy: GuildPrivacy
    var canInvite: Bool
    var inviteChannelID: ChannelID?
    var canManageGuild: Bool
    var hasLinkedRoles: Bool
    var isOwner: Bool
    var developerMode: Bool
}
