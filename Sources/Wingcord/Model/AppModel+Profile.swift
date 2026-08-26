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
            status: presence?.status ?? .offline,
            customStatus: presence?.customStatus?.state,
            activity: presence?.primaryActivity,
            bio: decoration?.bio,
            isBot: user.isBot,
            badges: user.flags.badges,
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
            isSelf: user.id == currentUserID
        )
    }

    /// Opens someone's profile from any surface.
    func openProfile(_ userID: UserID, anchor: CGRect, depth: ProfileRequest.Depth = .mini) {
        profileRequest = ProfileRequest(
            userID: userID,
            guildID: selectedGuildID,
            anchor: anchor,
            depth: depth
        )
    }
}
