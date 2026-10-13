import Foundation
import WingcordCore
import WingcordNet

// MARK: - Moderation writes
//
// Each act is Discord's own request (`DiscordREST+Moderation`), and each one
// lands the way Discord's client lands it:
//
//   - **Kick, Ban and Prune close their dialog and go.** Discord's own dialogs
//     do not wait for the answer; a refusal comes back as a notice.
//   - **Timeout, Remove Timeout and Change Nickname wait**, because Discord's
//     do — a spinner on the button, and the dialog stays up on a refusal.
//   - **A member write answers with the member**, which is applied at once;
//     `GUILD_MEMBER_UPDATE` confirms it after.

extension SessionController {

    /// Kicks somebody. Discord takes them out of its member store the moment
    /// the DELETE answers (`GUILD_MEMBER_REMOVE_LOCAL`), before the gateway
    /// says so.
    func kick(_ userID: UserID, from guildID: GuildID, reason: String?) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.kickMember(userID, in: guildID, reason: reason)
                removeMember(userID, from: guildID)
            } catch {
                Self.trace("kick \(userID) failed: \(Self.describe(error))")
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    /// Bans somebody, member or not. A ban ends a membership, so they leave the
    /// store on the answer, as a kick does.
    func ban(_ userID: UserID, from guildID: GuildID, deleting: BanMessageDeletion, reason: String?) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.banMember(
                    userID, in: guildID, deleteMessageSeconds: deleting.rawValue, reason: reason
                )
                removeMember(userID, from: guildID)
            } catch {
                Self.trace("ban \(userID) failed: \(Self.describe(error))")
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    /// Bans the Members page's selection.
    ///
    /// **The answer is not the outcome.** Version two of the route answers
    /// once the bans are queued, and `GUILD_BULK_BAN_UPDATE` reports who was
    /// banned — which can arrive before the POST's own answer, so the guild is
    /// marked in flight before anything is sent.
    func bulkBan(_ userIDs: [UserID], from guildID: GuildID, deleting: BanMessageDeletion, reason: String) {
        model.bulkBansInFlight.insert(guildID)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.bulkBan(
                    userIDs, in: guildID, deleteMessageSeconds: deleting.rawValue, reason: reason
                )
            } catch {
                Self.trace("bulk ban of \(userIDs.count) failed: \(Self.describe(error))")
                model.bulkBansInFlight.remove(guildID)
                model.reportActionFailure("Mass ban failed")
                model.memberSafety?.clearSelection(in: guildID)
            }
        }
    }

    /// What `GUILD_BULK_BAN_UPDATE` says — Discord's `BulkBanManager`.
    ///
    /// Reported only for a ban this window started: the event reaches every
    /// session of the moderator, and a notice for a ban made on a phone would
    /// arrive out of nowhere.
    func applyBulkBanOutcome(in guildID: GuildID, banned: [UserID], failed: [UserID]) {
        for userID in banned { removeMember(userID, from: guildID) }
        guard model.bulkBansInFlight.remove(guildID) != nil else { return }
        if !failed.isEmpty, banned.isEmpty {
            model.reportActionFailure("Mass ban failed")
        } else {
            // Discord's string misspells it ("succesful"); the words are its own.
            model.reportSuccess("Mass ban successful")
        }
        model.memberSafety?.clearSelection(in: guildID)
    }

    /// Times somebody out. True when Discord took it.
    ///
    /// Discord confirms this one out loud — "{name} Timed Out" — because a
    /// timeout changes nothing the moderator is looking at.
    func timeOut(
        _ userID: UserID,
        in guildID: GuildID,
        for duration: TimeoutDuration,
        reason: String?
    ) async -> Bool {
        do {
            let member = try await rest.timeOutMember(
                userID, in: guildID, until: duration.until(), reason: reason
            )
            apply(member, in: guildID)
            model.reportSuccess("\(model.moderationName(of: userID, in: guildID)) Timed Out")
            return true
        } catch {
            Self.trace("timeout \(userID) failed: \(Self.describe(error))")
            model.reportActionFailure(Self.describe(error))
            return false
        }
    }

    /// Lifts a timeout early. True when Discord took it.
    func removeTimeout(_ userID: UserID, in guildID: GuildID) async -> Bool {
        do {
            let member = try await rest.timeOutMember(userID, in: guildID, until: nil)
            apply(member, in: guildID)
            model.reportSuccess("Timeout Removed")
            return true
        } catch {
            Self.trace("remove timeout \(userID) failed: \(Self.describe(error))")
            model.reportActionFailure(Self.describe(error))
            return false
        }
    }

    /// Sets or clears somebody's nickname here. Nil when it landed; otherwise
    /// the reason, which the dialog puts under its field as Discord's does.
    func setNickname(_ nickname: String, of userID: UserID, in guildID: GuildID) async -> String? {
        do {
            let member = try await rest.setNickname(nickname, of: userID, in: guildID)
            apply(member, in: guildID)
            return nil
        } catch {
            Self.trace("nickname \(userID) failed: \(Self.describe(error))")
            return Self.describe(error)
        }
    }

    /// Puts a role on somebody or takes it off — the Roles submenu's checkbox,
    /// a profile's + and ×.
    ///
    /// **Drawn at once and undone on a refusal**, as Discord's own submenu is.
    /// The route takes the whole list, so it is computed from the store at
    /// the moment of the click — which already holds any toggle still in
    /// flight, and two quick clicks send two lists that each include the other.
    func setRole(_ roleID: RoleID, held: Bool, of userID: UserID, in guildID: GuildID) {
        guard var member = model.members[guildID]?[userID] else { return }
        if held {
            guard !member.roleIDs.contains(roleID) else { return }
            member.roleIDs.append(roleID)
        } else {
            guard member.roleIDs.contains(roleID) else { return }
            member.roleIDs.removeAll { $0 == roleID }
        }
        apply(member, in: guildID)
        let roles = member.roleIDs
        Task { [weak self] in
            guard let self else { return }
            do {
                let answer = try await rest.setRoles(roles, of: userID, in: guildID)
                apply(answer, in: guildID)
            } catch {
                Self.trace("roles \(userID) failed: \(Self.describe(error))")
                // Only the one role goes back: anything toggled since stays.
                if var now = model.members[guildID]?[userID] {
                    if held {
                        now.roleIDs.removeAll { $0 == roleID }
                    } else if !now.roleIDs.contains(roleID) {
                        now.roleIDs.append(roleID)
                    }
                    apply(now, in: guildID)
                }
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    /// Verify / Unverify Member: the bypass bit, every other flag carried.
    func setVerified(_ isVerified: Bool, of userID: UserID, in guildID: GuildID) {
        guard let member = model.members[guildID]?[userID] else { return }
        var flags = member.flags
        if isVerified { flags.insert(.bypassesVerification) } else { flags.remove(.bypassesVerification) }
        Task { [weak self] in
            guard let self else { return }
            do {
                let answer = try await rest.setMemberFlags(flags, of: userID, in: guildID)
                apply(answer, in: guildID)
            } catch {
                Self.trace("verify \(userID) failed: \(Self.describe(error))")
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    /// Server Mute, Server Deafen, Disconnect and Move To — the voice rows.
    /// The voice state that follows comes back on the gateway.
    func moderateVoice(_ act: VoiceModeration, of userID: UserID, in guildID: GuildID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                switch act {
                case .mute(let isMuted):
                    try await rest.setServerMute(isMuted, of: userID, in: guildID)
                case .deafen(let isDeafened):
                    try await rest.setServerDeafen(isDeafened, of: userID, in: guildID)
                case .move(let channelID):
                    try await rest.moveMember(userID, in: guildID, to: channelID)
                case .disconnect:
                    try await rest.moveMember(userID, in: guildID, to: nil)
                }
            } catch {
                Self.trace("voice moderation of \(userID) failed: \(Self.describe(error))")
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    /// How many a prune would remove.
    func pruneEstimate(in guildID: GuildID, days: Int, includeRoles: [RoleID]) async throws -> Int {
        try await rest.pruneEstimate(in: guildID, days: days, includeRoles: includeRoles)
    }

    /// Prunes. Discord's button closes its dialog and goes.
    func prune(in guildID: GuildID, days: Int, includeRoles: [RoleID]) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.prune(in: guildID, days: days, includeRoles: includeRoles)
            } catch {
                Self.trace("prune failed: \(Self.describe(error))")
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    // MARK: Channels

    /// Delete Channel from the sidebar. `CHANNEL_DELETE` takes it off the
    /// list; a refusal says why.
    func deleteChannel(_ channelID: ChannelID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.deleteChannel(channelID)
            } catch {
                Self.trace("delete channel \(channelID) failed: \(Self.describe(error))")
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    /// Create Channel and Create Category — one `POST`, overwrites included
    /// (`ChannelCreation.overwrites`). Returns what to say when it is refused,
    /// in the server's words or the modal's own.
    ///
    /// **A new text-like channel is opened**, as Discord's modal transitions
    /// to it — once `CHANNEL_CREATE` has put it on the list.
    func createChannel(
        name: String,
        kind: ChannelKind,
        parentID: ChannelID?,
        isPrivate: Bool,
        duplicating source: Channel? = nil,
        in guildID: GuildID
    ) async -> String? {
        let me = model.currentUserID
        let seesEverything = model.permissionGate.permissions(inGuild: guildID).contains(.administrator)
            || model.guilds[guildID]?.ownerID == me
        // Duplicate Channel copies the permissions instead of making them.
        let overwrites = source?.overwrites ?? ChannelCreation.overwrites(
            kind: kind,
            isPrivate: isPrivate,
            guildID: guildID,
            creator: me,
            creatorSeesEverything: seesEverything
        )
        do {
            let channel = try await rest.createChannel(
                in: guildID,
                name: name,
                kind: kind,
                parentID: kind == .category ? nil : parentID,
                overwrites: overwrites,
                bitrate: source?.bitrate,
                userLimit: source?.userLimit
            )
            if let channel, [.text, .announcement, .forum, .media].contains(channel.kind),
               model.channelIndex[channel.id] != nil
            {
                model.selectChannel(channel.id)
            }
            return nil
        } catch {
            Self.trace("create channel failed: \(Self.describe(error))")
            if case .api(_, _, let message?) = error as? DiscordREST.Failure, !message.isEmpty {
                return message
            }
            return "An error occurred, please try again."
        }
    }

    // MARK: Mod View

    /// What was done to somebody, with everybody it names put on the store so
    /// the rows can say who did it.
    func modViewAuditLog(of userID: UserID, in guildID: GuildID) async throws -> AuditLogPage {
        try await rest.auditLog(in: guildID, limit: 50, targetID: userID.rawValue)
    }

    /// The member and their profile, asked again whatever this session asked
    /// before — Mod View opening, and its Refresh.
    func refreshMember(_ userID: UserID, in guildID: GuildID) {
        if let socket {
            Task { await socket.requestGuildMembers(guildID: guildID, userIDs: [userID]) }
        }
        loadProfile(of: userID, inGuild: guildID)
    }

    // MARK: The Members page

    /// One page of the Members table, with its people written into the stores
    /// the gates and the person menu read — where nothing fresher is there.
    func searchMembers(
        in guildID: GuildID,
        query: MemberSearchQuery,
        after cursor: MemberSearchCursor?
    ) async throws -> MemberSearchPage? {
        let page = try await rest.searchMembers(in: guildID, query: query, after: cursor)
        if let page { ingest(page.rows, in: guildID) }
        return page
    }

    private func ingest(_ rows: [GuildMemberRow], in guildID: GuildID) {
        var members: [UserID: Member] = [:]
        var users: [UserID: User] = [:]
        for row in rows {
            if model.members[guildID]?[row.id] == nil {
                members[row.id] = Member(
                    userID: row.id,
                    nickname: row.nickname,
                    avatarHash: row.guildAvatarHash,
                    roleIDs: row.roleIDs,
                    joinedAt: row.joinedAt,
                    communicationDisabledUntil: row.timedOutUntil,
                    isPending: row.isPending,
                    flags: row.flags,
                    unusualDMActivityUntil: row.unusualDMActivityUntil
                )
            }
            if model.users[row.id] == nil {
                users[row.id] = User(
                    id: row.id,
                    username: row.username,
                    displayName: row.displayName,
                    avatarHash: row.avatarHash,
                    discriminator: row.discriminator ?? "0",
                    isBot: row.isBot
                )
            }
        }
        if !users.isEmpty {
            model.users.merge(users) { existing, _ in existing }
            model.identityRevision &+= 1
        }
        ingestMembers(members, users: [:], presences: [:], inGuild: guildID)
    }

    // MARK: The store

    /// Somebody is no longer in a server — kicked, banned or gone.
    func removeMember(_ userID: UserID, from guildID: GuildID) {
        model.memberSafety?.remove(userID, from: guildID)
        guard model.members[guildID]?.removeValue(forKey: userID) != nil else { return }
        model.permissionGate.invalidate()
        model.memberRevision &+= 1
        model.roleRevision &+= 1
    }

    private func apply(_ member: Member?, in guildID: GuildID) {
        guard let member else { return }
        ingestMembers([member.userID: member], users: [:], presences: [:], inGuild: guildID)
        model.memberSafety?.update(member, in: guildID)
    }
}

/// The voice rows of the person menu.
enum VoiceModeration: Hashable, Sendable {
    case mute(Bool)
    case deafen(Bool)
    case move(ChannelID)
    case disconnect
}
