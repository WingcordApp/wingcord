import Foundation
import SwiftUI
import WingcordCore

// MARK: - Moderation, from the reader's side
//
// One context per (server, person), resolved from the store and handed to
// `ModerationPolicy` — so the person menu, Mod View and the Members page all
// ask one function the same question and cannot disagree about whether Ban is
// offered. The writes live in `SessionController+Moderation`.

/// A moderation dialog, raised from a menu, Mod View or the Members page.
///
/// **One value, one sheet** — presented by `MessageActionPresenter`, where the
/// window's sheets already live.
enum ModerationDialog: Identifiable, Hashable, Sendable {
    case kick(UserID, GuildID)
    case ban(UserID, GuildID)
    case bulkBan([UserID], GuildID)
    case timeout(UserID, GuildID)
    case removeTimeout(UserID, GuildID)
    case nickname(UserID, GuildID)
    case prune(GuildID)

    var id: String {
        switch self {
        case .kick(let user, let guild): "kick-\(guild.rawValue)-\(user.rawValue)"
        case .ban(let user, let guild): "ban-\(guild.rawValue)-\(user.rawValue)"
        case .bulkBan(let users, let guild): "bulk-\(guild.rawValue)-\(users.count)"
        case .timeout(let user, let guild): "timeout-\(guild.rawValue)-\(user.rawValue)"
        case .removeTimeout(let user, let guild): "untimeout-\(guild.rawValue)-\(user.rawValue)"
        case .nickname(let user, let guild): "nick-\(guild.rawValue)-\(user.rawValue)"
        case .prune(let guild): "prune-\(guild.rawValue)"
        }
    }

    var guildID: GuildID {
        switch self {
        case .kick(_, let guild), .ban(_, let guild), .bulkBan(_, let guild), .timeout(_, let guild),
             .removeTimeout(_, let guild), .nickname(_, let guild), .prune(let guild):
            guild
        }
    }
}

extension AppModel {

    /// Everything Discord's gates read about the reader and this person here.
    ///
    /// Nil where the reader is not in the server. A person who is not a member
    /// (somebody seen in an old message) still gets a context — Ban works on
    /// them and nothing else does.
    func moderationContext(for userID: UserID, in guildID: GuildID) -> ModerationContext? {
        guard let guild = guilds[guildID], let me = currentUserID else { return nil }
        let roles = self.roles[guildID] ?? [:]
        let target = members[guildID]?[userID]
        let mine = members[guildID]?[me]
        let user = users[userID]
        let targetPermissions = target.map {
            PermissionResolver.permissions(
                forMember: $0.roleIDs,
                userID: userID,
                guildID: guildID,
                guildOwnerID: guild.ownerID,
                roles: roles,
                channel: nil
            )
        } ?? []
        return ModerationContext(
            guildID: guildID,
            guildFeatures: guild.features,
            actorPermissions: permissionGate.permissions(inGuild: guildID),
            actorIsOwner: guild.ownerID == me,
            actorHighestRole: RoleOrder.highest(of: mine?.roleIDs ?? [], in: roles, guildID: guildID),
            targetIsSelf: userID == me,
            targetIsOwner: guild.ownerID == userID,
            targetHighestRole: target.flatMap {
                RoleOrder.highest(of: $0.roleIDs, in: roles, guildID: guildID)
            },
            targetIsAdministrator: targetPermissions.contains(.administrator),
            targetIsBot: user?.isBot ?? false,
            targetIsSystem: user?.isSystem ?? false,
            targetIsMember: target != nil,
            targetIsGuest: target?.flags.contains(.isGuest) ?? false,
            targetFlags: target?.flags ?? [],
            targetJoinedAt: target?.joinedAt,
            targetTimedOutUntil: target?.communicationDisabledUntil
        )
    }

    /// What may be done to this person here — the one answer every surface
    /// reads.
    func moderationActions(for userID: UserID, in guildID: GuildID) -> ModerationActions {
        moderationContext(for: userID, in: guildID).map(ModerationPolicy.actions) ?? ModerationActions()
    }

    /// The roles the Roles submenu offers this person, with which of them the
    /// reader may toggle.
    func assignableRoles(for userID: UserID, in guildID: GuildID) -> [(role: Role, isEnabled: Bool)] {
        guard let context = moderationContext(for: userID, in: guildID) else { return [] }
        let held = Set(members[guildID]?[userID]?.roleIDs ?? [])
        let all = Array((roles[guildID] ?? [:]).values)
        guard context.actorPermissions.contains(.administrator)
            || context.actorPermissions.contains(.manageRoles)
        else {
            // Without Manage Roles the submenu lists what they hold, inert.
            return all
                .filter { held.contains($0.id) && $0.id.rawValue != guildID.rawValue }
                .sorted { RoleOrder.outranks($0, $1, guildID: guildID) }
                .map { ($0, false) }
        }
        return ModerationPolicy.assignableRoles(all, holding: held, context: context)
    }

    /// Raises a moderation dialog, closing whatever menu asked for it.
    func presentModeration(_ dialog: ModerationDialog) {
        userMenu = nil
        moderationDialog = dialog
    }

    // MARK: Acting
    //
    // Each act asks the policy again at the moment it is confirmed: a dialog
    // can sit open while a role changes underneath it, and a click on a stale
    // dialog must not send what the server would only refuse.

    func kick(_ userID: UserID, from guildID: GuildID, reason: String) {
        guard moderationActions(for: userID, in: guildID).canKick else { return }
        sessionController.kick(userID, from: guildID, reason: Self.reason(reason))
    }

    func ban(_ userID: UserID, from guildID: GuildID, deleting: BanMessageDeletion, reason: String) {
        guard moderationActions(for: userID, in: guildID).canBan else { return }
        sessionController.ban(userID, from: guildID, deleting: deleting, reason: Self.reason(reason))
    }

    func bulkBan(_ userIDs: [UserID], from guildID: GuildID, deleting: BanMessageDeletion, reason: String) {
        guard ModerationPolicy.canBulkBan(permissionGate.permissions(inGuild: guildID)) else { return }
        let banned = userIDs.filter { moderationActions(for: $0, in: guildID).canBan }
        guard !banned.isEmpty, let reason = Self.reason(reason) else { return }
        sessionController.bulkBan(banned, from: guildID, deleting: deleting, reason: reason)
    }

    func timeOut(
        _ userID: UserID,
        in guildID: GuildID,
        for duration: TimeoutDuration,
        reason: String
    ) async -> Bool {
        guard moderationActions(for: userID, in: guildID).canTimeout else { return false }
        return await sessionController.timeOut(userID, in: guildID, for: duration, reason: Self.reason(reason))
    }

    /// The menu's ⌘-click on Timeout: sixty seconds, no dialog — Discord's own
    /// shortcut (`J` in `351001`).
    func quickTimeout(_ userID: UserID, in guildID: GuildID) {
        userMenu = nil
        Task { _ = await timeOut(userID, in: guildID, for: .sixtySeconds, reason: "") }
    }

    func removeTimeout(_ userID: UserID, in guildID: GuildID) async -> Bool {
        guard moderationActions(for: userID, in: guildID).canTimeout else { return false }
        return await sessionController.removeTimeout(userID, in: guildID)
    }

    /// Nil when it landed; otherwise what to show under the field.
    func setNickname(_ nickname: String, of userID: UserID, in guildID: GuildID) async -> String? {
        await sessionController.setNickname(nickname, of: userID, in: guildID)
    }

    func setRole(_ roleID: RoleID, held: Bool, of userID: UserID, in guildID: GuildID) {
        guard assignableRoles(for: userID, in: guildID).contains(where: { $0.role.id == roleID && $0.isEnabled })
        else { return }
        sessionController.setRole(roleID, held: held, of: userID, in: guildID)
    }

    func setVerified(_ isVerified: Bool, of userID: UserID, in guildID: GuildID) {
        guard moderationActions(for: userID, in: guildID).canVerify else { return }
        userMenu = nil
        sessionController.setVerified(isVerified, of: userID, in: guildID)
    }

    func moderateVoice(_ act: VoiceModeration, of userID: UserID, in guildID: GuildID) {
        userMenu = nil
        sessionController.moderateVoice(act, of: userID, in: guildID)
    }

    func prune(in guildID: GuildID, days: Int, includeRoles: [RoleID]) {
        guard let guild = guilds[guildID],
              ModerationPolicy.canPrune(
                permissionGate.permissions(inGuild: guildID),
                isOwner: guild.ownerID == currentUserID,
                features: guild.features
              )
        else { return }
        sessionController.prune(in: guildID, days: days, includeRoles: includeRoles)
    }

    /// How many a prune would remove, or nil where Discord would not say.
    func pruneEstimate(in guildID: GuildID, days: Int, includeRoles: [RoleID]) async -> Int? {
        try? await sessionController.pruneEstimate(in: guildID, days: days, includeRoles: includeRoles)
    }

    /// A reason as Discord sends one: trimmed, and absent rather than empty.
    private static func reason(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(ModerationReason.maximumLength))
    }

    // MARK: Mod View

    /// Opens Mod View on somebody — from the person menu, the Members page or
    /// a profile. Discord's `openModView` (`901472`): the server is selected if
    /// it is not already, and the panel opens on Info.
    func openModView(for userID: UserID, in guildID: GuildID) {
        guard moderationActions(for: userID, in: guildID).canOpenModView else { return }
        userMenu = nil
        profileRequest = nil
        if selectedGuildID != guildID { selectGuild(guildID) }
        // It takes the column the search was in; the search comes back over
        // it when Message History asks.
        if isSearchShown { closeSearch() }
        if let modView, modView.guildID == guildID, modView.userID == userID {
            modView.panel = .info
            return
        }
        let session = sessionController
        let store = ModViewStore(
            guildID: guildID,
            userID: userID,
            loaders: ModViewStore.Loaders(
                counts: { guildID, userID in
                    try await session.rest.activityCounts(of: userID, in: guildID)
                },
                auditLog: { guildID, userID in
                    try await session.modViewAuditLog(of: userID, in: guildID)
                },
                joinSource: { guildID, userID in
                    try await session.rest.memberSupplemental(in: guildID, userIDs: [userID])[userID]
                },
                refreshMember: { guildID, userID in
                    session.refreshMember(userID, in: guildID)
                }
            )
        )
        modView = store
        store.load()
        sessionController.refreshMember(userID, in: guildID)
    }

    func closeModView() {
        modView = nil
    }

    /// Mod View's Messages, Links and Media rows: Discord's own search, from
    /// them, in the search column — which shows over Mod View until it closes.
    func searchModViewHistory(_ kind: MessageSearchHas?) {
        guard let modView, let user = users[modView.userID] else { return }
        var text = "from: \(user.username)"
        if let kind { text += " has: \(kind.rawValue)" }
        messageSearch = MessageSearchState(scope: .guild(modView.guildID))
        messageSearch?.draft.content = text
        runSearch()
    }

    // MARK: The Members page

    /// Makes the Members page's store for this server, or keeps the one it has.
    func prepareMemberSafety(for guildID: GuildID) {
        if memberSafety?.guildID == guildID { return }
        let session = sessionController
        memberSafety = MemberSafetyStore(
            guildID: guildID,
            applications: MemberSafetyStore.Applications(
                list: { guildID, status in try await session.rest.joinRequests(in: guildID, status: status) },
                resolve: { guildID, requestID, approve, reason in
                    try await session.rest.resolveJoinRequest(requestID, in: guildID, approve: approve, reason: reason)
                },
                interview: { [weak self] request in
                    try await self?.enterJoinRequestInterview(request)
                }
            )
        ) { guildID, query, cursor in
            try await session.searchMembers(in: guildID, query: query, after: cursor)
        }
    }

    /// Goes to the conversation with an applicant — Discord's
    /// `handleOpenInterview`: the one already open where this client has it,
    /// else the route's, filed as Discord files its `CHANNEL_CREATE`.
    func enterJoinRequestInterview(_ request: GuildJoinRequest) async throws {
        if let existing = request.interviewChannelID, channelIndex[existing] != nil {
            openDirectMessage(existing)
            return
        }
        let channel = try await sessionController.rest.openJoinRequestInterview(request.id)
        if channelIndex[channel.id] == nil {
            channelIndex.upsert(channel)
            permissionGate.invalidate()
            sidebarRevision &+= 1
        }
        openDirectMessage(channel.id)
    }

    /// Whether the Members page has Discord's application tabs (`496767`):
    /// a server that reviews applications, and Kick Members to review them.
    func reviewsApplications(in guildID: GuildID) -> Bool {
        guard let features = guilds[guildID]?.features else { return false }
        return features.contains("MEMBER_VERIFICATION_MANUAL_APPROVAL")
            && features.contains("MEMBER_VERIFICATION_GATE_ENABLED")
            && permissionGate.permissions(inGuild: guildID).contains(.kickMembers)
    }

    /// Server Settings → Members: Discord leaves settings for the Members page
    /// (`566fbdb0`), so this raises the main window on it.
    func openMembersPage(in guildID: GuildID) {
        if selectedGuildID != guildID { selectGuild(guildID) }
        openSurface(.members)
        MainWindow.raise()
    }

    /// A role's dot: its colour as this reader sees colours, or Discord's
    /// grey for a role with none (`TpD`).
    func roleDotColor(_ role: Role) -> Color {
        Color(hex: roleColor(role.displayColorValue) ?? 0x99AAB5)
    }

    /// What a dialog calls the person: their name in this server.
    func moderationName(of userID: UserID, in guildID: GuildID) -> String {
        members[guildID]?[userID]?.nickname
            ?? users[userID]?.preferredName
            ?? String(userID.rawValue)
    }

    /// The account's own handle — Discord titles Kick and Timeout with it.
    func moderationHandle(of userID: UserID) -> String {
        users[userID]?.username ?? String(userID.rawValue)
    }
}

// MARK: - The person menu's server half

/// What Discord's guild-member menu (`GuildChannelUserContextMenu`) offers
/// beyond the relationship rows, resolved once per body.
struct GuildPersonMenu: Hashable {
    enum NicknameRow: Hashable {
        /// Somebody else's, through the Change Nickname dialog.
        case change
        /// The reader's own — Discord's Edit Per-server Profile.
        case editOwnProfile
    }

    var isSelf: Bool
    /// The account's handle — Discord titles Timeout, Kick and Ban with it.
    var handle: String
    var nickname: NicknameRow?
    /// How many roles the Roles level lists; nil hides the row.
    var roleCount: Int?
    /// Voice channels they can be moved to; empty hides Move to.
    var moveTargets: [ChannelID]
    var moderation: ModerationActions
    var voice: VoiceModerationRows?

    /// Whether the moderation group has anything in it.
    var hasModeration: Bool {
        moderation.canOpenModView || moderation.canVerify || moderation.canTimeout
            || moderation.canKick || moderation.canBan || voice?.isEmpty == false
    }
}

/// Server Mute, Server Deafen and Disconnect, for somebody in voice here.
struct VoiceModerationRows: Hashable {
    var isMuted: Bool
    var isDeafened: Bool
    var canMute: Bool
    var canDeafen: Bool
    var canDisconnect: Bool

    var isEmpty: Bool { !(canMute || canDeafen || canDisconnect) }
}

extension AppModel {

    func guildPersonMenu(for userID: UserID, in guildID: GuildID) -> GuildPersonMenu? {
        guard guilds[guildID] != nil else { return nil }
        let isSelf = userID == currentUserID
        let moderation = moderationActions(for: userID, in: guildID)
        let isGuest = members[guildID]?[userID]?.flags.contains(.isGuest) ?? false
        let nickname: GuildPersonMenu.NicknameRow? = if isSelf {
            .editOwnProfile
        } else if moderation.canChangeNickname {
            .change
        } else {
            nil
        }
        let roles = members[guildID]?[userID] == nil ? [] : assignableRoles(for: userID, in: guildID)
        return GuildPersonMenu(
            isSelf: isSelf,
            handle: moderationHandle(of: userID),
            nickname: isGuest ? nil : nickname,
            roleCount: roles.isEmpty ? nil : roles.count,
            moveTargets: isGuest ? [] : moveTargets(for: userID, in: guildID),
            moderation: moderation,
            voice: isGuest ? nil : voiceModerationRows(for: userID, in: guildID)
        )
    }

    /// Discord's voice rows (`291247`): while they sit in a voice channel here
    /// that the reader can see. Mute and Deafen are not offered for somebody
    /// listening on a stage, who has nothing to mute.
    func voiceModerationRows(for userID: UserID, in guildID: GuildID) -> VoiceModerationRows? {
        guard let state = voiceStates[userID], state.guildID == guildID, let channelID = state.channelID
        else { return nil }
        let permissions = permissionGate.permissions(in: channelID)
        guard permissions.contains(.viewChannel) else { return nil }
        let speaks = channelIndex[channelID]?.kind != .stage || !state.isSuppressed
        let rows = VoiceModerationRows(
            isMuted: state.isServerMuted,
            isDeafened: state.isServerDeafened,
            canMute: speaks && permissions.contains(.muteMembers),
            canDeafen: speaks && permissions.contains(.deafenMembers),
            canDisconnect: userID != currentUserID && permissions.contains(.moveMembers)
        )
        return rows.isEmpty ? nil : rows
    }

    /// Move to (`252726`): the other voice channels here. The reader moves
    /// themselves anywhere they may connect; somebody else needs Move Members
    /// where they are and where they go. A full channel is not offered.
    func moveTargets(for userID: UserID, in guildID: GuildID) -> [ChannelID] {
        guard let state = voiceStates[userID], state.guildID == guildID, let current = state.channelID
        else { return [] }
        let isSelf = userID == currentUserID
        guard isSelf || permissionGate.permissions(in: current).contains(.moveMembers) else { return [] }
        return channelIndex.channelIDs(inGuild: guildID)
            .compactMap { channelIndex[$0] }
            .filter { ($0.kind == .voice || $0.kind == .stage) && $0.id != current }
            .filter { channel in
                let here = permissionGate.permissions(in: channel.id)
                let allowed = isSelf ? here.contains(.connect) : here.contains(.moveMembers)
                return allowed && !isFull(channel)
            }
            .sorted { $0.position < $1.position }
            .map(\.id)
    }

    /// Whether a voice channel has reached its user limit — Move To's rule,
    /// and the stream card's "Channel is full".
    func isFull(_ channel: Channel) -> Bool {
        guard let limit = channel.userLimit, limit > 0 else { return false }
        return voiceStates.values.count { $0.channelID == channel.id } >= limit
    }

    /// Where Move to sends somebody — or, for the reader, joins.
    func move(_ userID: UserID, to channelID: ChannelID, in guildID: GuildID) {
        userMenu = nil
        if userID == currentUserID {
            joinVoice(channelID)
        } else {
            sessionController.moderateVoice(.move(channelID), of: userID, in: guildID)
        }
    }
}

// MARK: - Roles on a profile

/// What the reader may do to somebody's roles where their roles are drawn —
/// the profile card, the full profile, Mod View. Discord's `B` in `f935efd0`:
/// a × on each role the reader could take off, and a + that opens the roles
/// they could give.
struct RoleEditing {
    var removable: Set<RoleID>
    /// What the + offers, in the server's role order.
    var addable: [ProfileRole]
    var remove: (RoleID) -> Void
    var add: (RoleID) -> Void
}

extension AppModel {

    /// Nil where the reader cannot touch this person's roles at all, which is
    /// everybody without Manage Roles.
    ///
    /// **Discord's reach rule**: a role below the reader's own highest, or any
    /// role for the owner; never a managed role, which belongs to an app or
    /// a subscription; never `@everyone`.
    func roleEditing(for userID: UserID, in guildID: GuildID) -> RoleEditing? {
        guard let member = members[guildID]?[userID],
              let guild = guilds[guildID],
              let me = currentUserID,
              permissionGate.permissions(inGuild: guildID).contains(.manageRoles)
        else { return nil }
        let roles = self.roles[guildID] ?? [:]
        let isOwner = guild.ownerID == me
        let mine = RoleOrder.highest(of: members[guildID]?[me]?.roleIDs ?? [], in: roles, guildID: guildID)
        func reaches(_ role: Role) -> Bool {
            guard role.id.rawValue != guildID.rawValue, !role.isManaged else { return false }
            if isOwner { return true }
            return mine.map { RoleOrder.outranks($0, role, guildID: guildID) } ?? false
        }
        let held = Set(member.roleIDs)
        return RoleEditing(
            removable: Set(member.roleIDs.compactMap { roles[$0] }.filter(reaches).map(\.id)),
            addable: roles.values
                .filter { reaches($0) && !held.contains($0.id) }
                .sorted { RoleOrder.outranks($0, $1, guildID: guildID) }
                .map(profileRole),
            remove: { [weak self] roleID in
                self?.sessionController.setRole(roleID, held: false, of: userID, in: guildID)
            },
            add: { [weak self] roleID in
                self?.sessionController.setRole(roleID, held: true, of: userID, in: guildID)
            }
        )
    }
}

// MARK: - Somebody's permissions

extension AppModel {

    /// What somebody's roles give them in a server — Mod View's permissions.
    /// Everything, for the owner or an administrator.
    func memberPermissions(of userID: UserID, in guildID: GuildID) -> Permissions {
        guard let guild = guilds[guildID], let member = members[guildID]?[userID] else { return [] }
        return PermissionResolver.permissions(
            forMember: member.roleIDs,
            userID: userID,
            guildID: guildID,
            guildOwnerID: guild.ownerID,
            roles: roles[guildID] ?? [:],
            channel: nil
        )
    }

    /// The roles that grant somebody a permission, and whether ownership does.
    func permissionSources(
        of permission: Permissions,
        for userID: UserID,
        in guildID: GuildID
    ) -> (roles: [Role], grantsOwnership: Bool) {
        ModPermissions.sources(
            of: permission,
            memberRoles: members[guildID]?[userID]?.roleIDs ?? [],
            roles: roles[guildID] ?? [:],
            guildID: guildID,
            isOwner: guilds[guildID]?.ownerID == userID
        )
    }
}
