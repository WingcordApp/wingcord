import Foundation
import WingcordCore

extension AppModel {

    /// Resolves everything a profile surface draws.
    ///
    /// One resolver for both the card and the full profile. Two resolvers is how
    /// a nickname shows in one surface and not the other, and how a role list
    /// ends up sorted differently in each.
    func profilePresentation(for request: ProfileRequest) -> ProfilePresentation? {
        guard let user = users[request.userID] else { return nil }
        let guildID = request.guildID ?? selectedGuildID
        let member = guildID.flatMap { members[$0]?[request.userID] }
        let guildRoles = guildID.flatMap { roles[$0] } ?? [:]
        let presence = presences[request.userID]
        let decoration = user.decoration

        return ProfilePresentation(
            userID: user.id,
            displayName: user.preferredName,
            handle: user.handle,
            nickname: member?.nickname,
            avatarURL: avatarURL(
                forUserID: user.id,
                inGuild: guildID,
                side: Metrics.avatarProfile
            ),
            monogram: user.monogram,
            decorationURL: decoration?.avatarDecorationHash
                .flatMap { CDN.avatarDecoration(hash: $0) },
            bannerURL: decoration?.bannerHash.flatMap {
                CDN.userBanner(userID: user.id, hash: $0, width: 512)
            },
            accentColorValue: decoration?.accentColor,
            themeColorValues: decoration?.themeColorValues ?? [],
            status: presence?.status ?? .offline,
            customStatus: presence?.customStatus?.state,
            customStatusEmoji: presence?.customStatus?.emoji,
            activity: presence?.primaryActivity,
            bio: decoration?.bio,
            isBot: user.isBot,
            badges: AccountBadges.resolve(flags: user.flags, decoration: decoration),
            guildTag: decoration?.primaryGuildTag.map { tag in
                GuildTag(
                    text: tag,
                    badgeURL: decoration.flatMap { decoration in
                        guard let guildID = decoration.primaryGuildID,
                              let hash = decoration.primaryGuildBadgeHash
                        else { return nil }
                        return CDN.guildTagBadge(guildID: guildID, hash: hash)
                    },
                    guildID: decoration?.primaryGuildID
                )
            },
            roles: (member?.roleIDs ?? [])
                .compactMap { guildRoles[$0] }
                // `@everyone` is on every member and says nothing, so it is not
                // shown — Discord hides it too, and a role list whose first
                // entry is always the same one trains the eye to skip the list.
                .filter { role in
                    guard let guildID else { return true }
                    return role.id.rawValue != guildID.rawValue
                }
                .sorted(by: Role.seniorityOrder)
                .map {
                    ProfileRole(id: $0.id, name: $0.name, colorValue: $0.displayColorValue)
                },
            memberSince: member?.joinedAt,
            // Derived from the snowflake rather than fetched: the id already
            // carries a millisecond timestamp, so there is nothing to request.
            accountCreated: user.id.timestamp,
            isSelf: user.id == currentUserID,
            pronouns: decoration?.pronouns,
            effect: decoration?.profileEffectSKU.flatMap { profileEffects[$0] },
            connections: decoration?.connectedAccounts ?? [],
            premiumTier: decoration?.premiumTier ?? .none,
            premiumSince: decoration?.premiumSince,
            legacyUsername: decoration?.legacyUsername,
            mutualServers: mutualServers(of: decoration),
            guild: guildID.flatMap(mutualServer(for:)),
            directMessageChannelID: user.id == currentUserID
                ? nil
                : directMessageChannel(with: user.id),
            isLoading: profilesLoading.contains(user.id)
        )
    }

    /// The shared servers, resolved against the rail the reader already has.
    ///
    /// A mutual server is by definition one the reader is in, so its name and
    /// icon are already resident and no second request exists for them. One
    /// that is somehow missing is dropped rather than drawn as an unknown row:
    /// the label the reader sees and the list it opens are then always the same
    /// length, which a placeholder row would quietly break.
    private func mutualServers(of decoration: UserDecoration?) -> [MutualServer] {
        guard let decoration, !decoration.mutualGuilds.isEmpty else { return [] }
        var result: [MutualServer] = []
        result.reserveCapacity(decoration.mutualGuilds.count)
        for mutual in decoration.mutualGuilds {
            guard var server = mutualServer(for: mutual.id) else { continue }
            server.nickname = mutual.nickname
            result.append(server)
        }
        // The rail's order, so the list reads the same way the servers do.
        result.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return result
    }

    /// One resident guild, named and pictured.
    private func mutualServer(for guildID: GuildID) -> MutualServer? {
        guard let guild = guilds[guildID] else { return nil }
        return MutualServer(
            id: guild.id,
            name: guild.name,
            iconURL: guild.iconHash.flatMap {
                CDN.guildIcon(guildID: guild.id, hash: $0, side: Metrics.avatarRow)
            },
            monogram: guild.monogram,
            nickname: nil
        )
    }

    /// The direct message already open with someone.
    ///
    /// A scan of the private channel list rather than an index of its own: the
    /// list is the account's DMs — a hundred or so on a busy account — and it is
    /// walked once, when a profile opens. An index would be a second structure
    /// to keep correct on every channel event for a lookup nobody makes in a
    /// loop.
    func directMessageChannel(with userID: UserID) -> ChannelID? {
        channelIndex.privateChannelIDs().first { channelID in
            guard let channel = channelIndex[channelID],
                  channel.kind == .directMessage
            else { return false }
            return channel.recipientIDs.contains(userID)
        }
    }

    /// Leaves the profile and opens the conversation.
    func openDirectMessage(_ channelID: ChannelID) {
        profileRequest = nil
        selectGuild(nil)
        selectChannel(channelID)
    }

    /// Opens someone's profile from any surface.
    ///
    /// The card is raised *first* and the fetch started after, so it appears on
    /// the click rather than on the round trip. The banner, bio and theme
    /// colours are the only things the request adds, and they arrive into a card
    /// that is already on screen.
    func openProfile(_ userID: UserID, anchor: CGRect, depth: ProfileRequest.Depth = .mini) {
        profileRequest = ProfileRequest(
            userID: userID,
            guildID: selectedGuildID,
            anchor: anchor,
            depth: depth
        )
        sessionController.loadProfile(of: userID, inGuild: selectedGuildID)
    }
}
