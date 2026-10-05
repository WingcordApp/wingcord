import CoreGraphics
import Foundation
import WingcordCore

// MARK: - What a reader can do about a person
//
// Blocking, ignoring, inviting and reporting. Each is gated here as well as
// where it is drawn, and each is written optimistically then reverted on a
// refusal — the two sets are what every surface reads to decide how the person
// is drawn, and a state that arrives a round trip after the click reads as the
// click having missed.

extension AppModel {

    /// Raises the person menu beside the row that asked for it.
    ///
    /// Silent for anybody the store does not know, and for the reader outside
    /// a server — a menu that opens onto "nothing to do here" is a menu that
    /// should not have opened. Inside one the reader's own menu has their
    /// profile, Edit Per-server Profile and their roles.
    func openUserMenu(for userID: UserID, anchor: CGRect, inGuild guildID: GuildID? = nil) {
        let guildID = guildID ?? selectedGuildID
        guard users[userID] != nil,
              userActions(for: userID) != nil || guildID != nil
        else { return }
        dismissMessageSurfaces()
        userMenu = UserMenuRequest(userID: userID, guildID: guildID, anchor: anchor)
    }

    func isBlocked(_ userID: UserID) -> Bool { blockedUserIDs.contains(userID) }
    func isIgnored(_ userID: UserID) -> Bool { ignoredUserIDs.contains(userID) }
    func relationship(with userID: UserID) -> Relationship {
        relationships[userID] ?? .none
    }

    /// Whether a profile's ⋯ has anything behind it: Discord's own account
    /// offers only its ID, and that only in Developer Mode.
    func offersProfileMenu(for userID: UserID) -> Bool {
        users[userID]?.isSystem != true || AppSettings.shared.developerMode
    }

    /// Everything the person menu offers for one person.
    ///
    /// Nil for the reader themselves: blocking, ignoring and reporting yourself
    /// are three controls with nothing behind them, and a menu of three inert
    /// rows is worse than no menu.
    func userActions(for userID: UserID) -> UserActions? {
        guard userID != currentUserID, users[userID] != nil else { return nil }
        return UserActions(
            relationship: relationship(with: userID),
            isBlocked: isBlocked(userID),
            isIgnored: isIgnored(userID),
            isBusy: relationshipsInFlight.contains(userID),
            canInvite: !invitableGuilds(for: userID).isEmpty,
            developerMode: AppSettings.shared.developerMode,
            offersFriendship: !(users[userID]?.isBot ?? false) && !(users[userID]?.isSystem ?? false)
        )
    }

    /// Sends a friend request, accepts one, withdraws one, or unfriends.
    ///
    /// **One entry point for four acts**, because they are one route and one
    /// slot: what the row does is decided by what the relationship currently
    /// is, and a caller that had to choose would be a second copy of that
    /// decision. `Relationship.friendActionAdds` is where it lives.
    func toggleFriend(with userID: UserID) {
        guard userID != currentUserID else { return }
        let current = relationship(with: userID)
        guard current != .blocked else { return }
        guard relationshipsInFlight.insert(userID).inserted else { return }

        let adds = current.friendActionAdds
        // Optimistic: accepting shows the friendship at once, sending shows the
        // request as outgoing, and both are put back by the controller if the
        // route refuses.
        relationships[userID] = adds
            ? (current == .incomingRequest ? .friend : .outgoingRequest)
            : nil
        identityRevision &+= 1
        sessionController.writeFriend(adds, userID: userID, revertingTo: current)
    }

    /// Puts a relationship back after the route refused it.
    func revertFriend(userID: UserID, to previous: Relationship) {
        relationships[userID] = previous == .none ? nil : previous
        identityRevision &+= 1
    }

    // MARK: Notes

    func note(for userID: UserID) -> String { notes[userID] ?? "" }

    /// Writes the reader's private note about somebody.
    ///
    /// **Applied locally and then sent**, and an empty note is a deletion rather
    /// than an empty string — which is the route's own convention. Nothing is
    /// sent for a note that did not change: the field commits on blur, and a
    /// card opened and closed would otherwise write one request per look.
    func setNote(_ note: String, for userID: UserID) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (notes[userID] ?? "") else { return }
        if trimmed.isEmpty { notes[userID] = nil } else { notes[userID] = trimmed }
        identityRevision &+= 1
        sessionController.writeNote(trimmed, for: userID)
    }

    /// The other person in a one-to-one conversation, when the reader blocked
    /// them — nil anywhere else, a group included, where Discord keeps the
    /// composer.
    func blockedRecipient(in channelID: ChannelID) -> UserID? {
        guard let channel = channelIndex[channelID], channel.kind == .directMessage,
              let partner = channel.recipientIDs.first(where: { $0 != currentUserID }),
              blockedUserIDs.contains(partner)
        else { return nil }
        return partner
    }

    /// Whether this is the direct message with Discord's system account —
    /// Discord's `isSystemDM`, which nobody can write in.
    func isSystemDirectMessage(_ channelID: ChannelID) -> Bool {
        guard let channel = channelIndex[channelID], channel.kind == .directMessage,
              let partner = channel.recipientIDs.first(where: { $0 != currentUserID })
        else { return false }
        return users[partner]?.isSystem == true
    }

    /// Turns the warning in front of an ignored person's profile off — its
    /// "Don't show this again" — here at once and on the account.
    func skipIgnoredProfileWarning() {
        let previous = syncedPreferences
        syncedPreferences.skipsIgnoredProfileWarning = true
        sessionController.writeSyncedPreference(.skipsIgnoredProfileWarning(true), restoring: previous)
    }

    /// The warning a profile opens behind, if it opens behind one — Discord's
    /// `useShowBlockedOrIgnoredProfile`: every blocked person's, and every
    /// ignored person's unless the reader turned that off.
    func profileWarning(for userID: UserID) -> ProfileWarning? {
        if blockedUserIDs.contains(userID) { return .blocked }
        if ignoredUserIDs.contains(userID), !syncedPreferences.skipsIgnoredProfileWarning { return .ignored }
        return nil
    }

    func setBlocked(_ isBlocked: Bool, userID: UserID) {
        guard userID != currentUserID else { return }
        guard relationshipsInFlight.insert(userID).inserted else { return }
        // Optimistic, and reverted by the controller on a refusal.
        if isBlocked {
            blockedUserIDs.insert(userID)
        } else {
            blockedUserIDs.remove(userID)
        }
        identityRevision &+= 1
        sessionController.writeBlock(isBlocked, userID: userID)
    }

    func setIgnored(_ isIgnored: Bool, userID: UserID) {
        guard userID != currentUserID else { return }
        guard relationshipsInFlight.insert(userID).inserted else { return }
        if isIgnored {
            ignoredUserIDs.insert(userID)
        } else {
            ignoredUserIDs.remove(userID)
        }
        identityRevision &+= 1
        sessionController.writeIgnore(isIgnored, userID: userID)
    }

    /// Rolls a relationship write back after the route refused it.
    func revertRelationship(userID: UserID, blocked: Bool?, ignored: Bool?) {
        if let blocked {
            if blocked { blockedUserIDs.insert(userID) } else { blockedUserIDs.remove(userID) }
        }
        if let ignored {
            if ignored { ignoredUserIDs.insert(userID) } else { ignoredUserIDs.remove(userID) }
        }
        identityRevision &+= 1
    }

    // MARK: Inviting

    /// The servers the reader can invite this person to.
    ///
    /// Three conditions, and each removes a row that would otherwise fail:
    ///
    ///  1. The reader holds `CREATE_INSTANT_INVITE` somewhere in the server.
    ///  2. There is a channel to mint the invite *in* — the permission is
    ///     per-channel, and a server where the reader can only invite to a
    ///     channel they cannot see is a server with no usable target.
    ///  3. The person is not already there, as far as the profile says. A
    ///     mutual-server list that has not been fetched leaves them all in,
    ///     which errs toward showing — `INVARIANTS.md` §5.5.
    func invitableGuilds(for userID: UserID) -> [InvitableGuild] {
        let alreadyIn = Set((users[userID]?.decoration?.mutualGuilds ?? []).map(\.id))
        var result: [InvitableGuild] = []
        for (guildID, guild) in guilds where !alreadyIn.contains(guildID) {
            guard let channelID = inviteChannel(inGuild: guildID) else { continue }
            result.append(
                InvitableGuild(
                    id: guildID,
                    name: guild.name,
                    iconURL: guild.iconHash.flatMap {
                        CDN.guildIcon(guildID: guildID, hash: $0, side: Metrics.avatarRow)
                    },
                    monogram: guild.monogram,
                    channelID: channelID
                )
            )
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The channel an invite to this server would be minted in.
    ///
    /// The first text channel in the sidebar's own order that the reader can
    /// both see and invite to, which is what Discord's own picker lands on.
    func inviteChannel(inGuild guildID: GuildID) -> ChannelID? {
        for channelID in channelIndex.channelIDs(inGuild: guildID) {
            guard let channel = channelIndex[channelID],
                  channel.kind == .text || channel.kind == .announcement
            else { continue }
            let permitted = permissionGate.permissions(in: channelID)
            guard permitted.contains(.viewChannel), permitted.contains(.createInvite) else {
                continue
            }
            return channelID
        }
        return nil
    }

    /// Mints an invite and sends it to the person, in the conversation with
    /// them — which is what "invite to server" means and the only way a client
    /// can deliver one.
    func invite(_ userID: UserID, to guild: InvitableGuild) {
        guard userID != currentUserID else { return }
        guard permissionGate.permissions(in: guild.channelID).contains(.createInvite) else {
            return
        }
        sessionController.sendInvite(to: userID, channelID: guild.channelID)
    }
}

/// What the person menu offers, resolved once.
struct UserActions: Hashable, Sendable {
    /// What the account is to them, which decides the friend row's words.
    var relationship: Relationship
    var isBlocked: Bool
    var isIgnored: Bool
    /// A relationship write is in flight, so both toggles are held.
    var isBusy: Bool
    var canInvite: Bool
    var developerMode: Bool
    /// Whether the friend row is offered at all — never on an app or on
    /// Discord's own account, as Discord's (`803664`: `bot ? null`).
    var offersFriendship = true
}

/// One server the reader could invite somebody to, and the channel it would be
/// minted in.
struct InvitableGuild: Identifiable, Hashable, Sendable {
    var id: GuildID
    var name: String
    var iconURL: URL?
    var monogram: String
    /// Resolved when the list is built rather than when a row is clicked: the
    /// permission walk is the expensive half and doing it per click would put
    /// it on the main actor between the press and the request.
    var channelID: ChannelID
}
