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
            displayNameStyle: decoration?.displayNameStyle,
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
            avatarDecorationSKU: decoration?.avatarDecorationSKU,
            nameplate: decoration?.nameplate,
            bannerURL: decoration?.bannerHash.flatMap {
                CDN.userBanner(userID: user.id, hash: $0, width: 512)
            },
            accentColorValue: decoration?.accentColor,
            themeColorValues: themeColorValues(of: user, decoration),
            status: presence?.status ?? .offline,
            customStatus: presence?.customStatus?.state,
            customStatusEmoji: presence?.customStatus?.emoji,
            activity: presence?.primaryActivity,
            activityButtonURLs: presence?.primaryActivity?.sessionID
                .flatMap { activityButtonURLs[$0] } ?? [],
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
                .map { role in
                    ProfileRole(
                        id: role.id, name: role.name,
                        colorValue: userColor(role.displayColorValue) ?? 0,
                        // **Desaturated through the same projection as every
                        // other user colour**, so the accessibility slider
                        // reaches a gradient role as well as a flat one —
                        // §"User colour is turned down at the PROJECTION".
                        colors: role.colors.map { stops in
                            RoleColors(
                                primary: userColor(stops.primary) ?? stops.primary,
                                secondary: stops.secondary.flatMap { userColor($0) },
                                tertiary: stops.tertiary.flatMap { userColor($0) }
                            )
                        },
                        iconURL: role.iconHash.flatMap { hash in
                            CDN.roleIcon(roleID: role.id, hash: hash, side: 16)
                        },
                        unicodeEmoji: role.unicodeEmoji
                    )
                },
            memberSince: member?.joinedAt,
            // Derived from the snowflake rather than fetched: the id already
            // carries a millisecond timestamp, so there is nothing to request.
            accountCreated: user.id.timestamp,
            isSelf: user.id == currentUserID,
            pronouns: decoration?.pronouns,
            effect: decoration?.profileEffectSKU.flatMap { profileEffects[$0] },
            frame: decoration?.profileFrameSKU.flatMap { profileFrames[$0] },
            connections: decoration?.connectedAccounts ?? [],
            premiumTier: decoration?.premiumTier ?? .none,
            premiumSince: decoration?.premiumSince,
            legacyUsername: decoration?.legacyUsername,
            mutualServers: mutualServers(of: decoration),
            mutualFriends: decoration?.mutualFriends ?? [],
            isProfilePrivate: decoration?.isProfilePrivate ?? false,
            note: notes[user.id] ?? "",
            relationship: relationship(with: user.id),
            isRelationshipBusy: relationshipsInFlight.contains(user.id),
            guild: guildID.flatMap(mutualServer(for:)),
            directMessageChannelID: user.id == currentUserID
                ? nil
                : directMessageChannel(with: user.id),
            isLoading: profilesLoading.contains(user.id)
        )
    }

    /// What the Activity tab draws, joined.
    ///
    /// **The covers are resolved here, not in the row.** A row that looked its
    /// own game up would redo the lookup on every hover anywhere in the list,
    /// and there are twenty of them; joined once, the list is a value the pane
    /// can compare in O(1).
    func activityPresentation(for userID: UserID) -> ProfileActivityPresentation {
        let entries = recentActivity[userID] ?? []
        var covers: [String: URL] = [:]
        covers.reserveCapacity(entries.count)
        for entry in entries {
            guard let id = entry.subject.applicationID, let game = games[id] else { continue }
            // The square mark, not the portrait cover: this is a 40-point tile
            // in a list, and a 40-point sliver of box art is unrecognisable
            // where the icon still reads.
            covers[entry.id] = gameArtURL(game, kind: .mark, side: Metrics.activityRecentIcon)
        }
        return ProfileActivityPresentation(
            recent: entries,
            covers: covers,
            isLoading: recentActivityLoading.contains(userID)
        )
    }

    /// How much saturation colour that came from a person keeps.
    ///
    /// Read through the model rather than from `AppSettings` at each call site,
    /// so every projection that carries a user colour reads the same value and
    /// registers the same observation dependency.
    var userColorSaturation: Double { AppSettings.shared.userColorSaturation }

    /// `value` with the reader's saturation applied.
    ///
    /// **Applied where a colour enters a PROJECTION, never inside a draw.** The
    /// member list and the transcript are painted canvases: a transform in
    /// their draw loops would run per row per frame for an answer that changes
    /// when a slider moves. Baked in here, the painters never learn this
    /// setting exists — and the memo keys carry it so a cache hit cannot serve
    /// the previous saturation.
    func userColor(_ value: UInt32?) -> UInt32? {
        guard let value else { return nil }
        return UserColor.desaturated(value, by: userColorSaturation)
    }

    /// A profile's two colours, chosen or derived.
    ///
    /// **Discord themes a profile even when the account set no colours**, by
    /// quantising their own artwork — so a client that reads `theme_colors` and
    /// stops draws most Nitro profiles flat grey. What comes back here is the
    /// same shape either way, which is the point: the surfaces cannot tell a
    /// derived theme from a chosen one, and neither treatment can drift.
    ///
    /// Empty until the artwork resolves, and empty forever for an account with
    /// none — both of which the card already draws as its neutral ground.
    func themeColorValues(of user: User, _ decoration: UserDecoration?) -> [UInt32] {
        let saturation = userColorSaturation
        if let chosen = decoration?.themeColorValues, !chosen.isEmpty {
            return chosen.map { UserColor.desaturated($0, by: saturation) }
        }
        guard let url = themeArtworkURL(of: user, decoration) else { return [] }
        return (derivedPalettes[url] ?? []).map { UserColor.desaturated($0, by: saturation) }
    }

    /// The artwork those colours come out of, or nil where none are derived.
    ///
    /// **Banner first, avatar second.** Confirmed on two live profiles with no
    /// banner, whose derived colour is directly measurable and matches their
    /// avatar to within four units of 255. The banner branch is inferred from a
    /// third whose avatar quantises to near-black while his card is emphatically
    /// orange — his banner's colour, not his avatar's.
    ///
    /// **Gated on the tier, and not simply on having paid.** Nitro Basic is a
    /// paid tier that does not get profile theming, so a gate written as
    /// `!= .none` spends a fetch and a decode to colour a profile Discord
    /// leaves grey — see `PremiumTier.derivesProfileTheme`.
    ///
    /// The size is `ProfileThemePalette.profilePixelSize`, and it is not a rendering
    /// choice: quantise the same picture at a different size and a different
    /// swatch wins. `rung(forSide:scale:)` rounds 64 at 2x to exactly that.
    func themeArtworkURL(of user: User, _ decoration: UserDecoration?) -> URL? {
        guard let decoration, decoration.premiumTier.derivesProfileTheme,
              decoration.themeColorValues?.isEmpty ?? true
        else { return nil }
        let side = CGFloat(ProfileThemePalette.profilePixelSize) / 2
        if let hash = decoration.bannerHash {
            return CDN.userBanner(userID: user.id, hash: hash, width: side)
        }
        guard let hash = user.avatarHash else { return nil }
        return CDN.avatar(userID: user.id, hash: hash, side: side)
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

    /// Opens the card that is already showing out into the full profile.
    ///
    /// **Written synchronously, and it starts the one fetch the card did not
    /// need.** Recent activity is the full profile's alone — the card has no
    /// section for it and the tab strip that would gate on it does not exist
    /// there — so asking for it when a card opens would be one request per
    /// avatar anybody clicks.
    func expandProfile() {
        guard let request = profileRequest, request.depth != .full else { return }
        profileRequest?.depth = .full
        sessionController.loadRecentActivity(of: request.userID)
    }

    /// Writes to somebody from their profile.
    ///
    /// Resolves the conversation first — making one where there is not one yet —
    /// so the control works for a person the reader has never spoken to, which
    /// is most of the people whose profile anybody opens.
    func messagePerson(_ userID: UserID) {
        guard userID != currentUserID else { return }
        if let existing = directMessageChannel(with: userID) {
            openDirectMessage(existing)
            return
        }
        sessionController.openConversation(with: userID)
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
        // The buttons on a rich presence, for both depths: the card draws the
        // current activity too, and their links are a route of their own.
        if let activity = presences[userID]?.primaryActivity {
            sessionController.loadActivityButtons(of: userID, activity: activity)
            // **And the app's own icon, where the presence publishes no
            // artwork.** Rich presence art is optional — Roblox sends a name
            // and nothing else — and the card drew a grey plate with a
            // controller in it where Discord draws the application icon.
            //
            // **Gated on the artwork RESOLVING, not on a key being present**,
            // and the difference is a whole class of game. An asset key is a
            // tagged union written as a string and this client answers nil for
            // a tag it does not know — so a presence carrying such a key had a
            // `largeImageKey` (the old gate passed it over), no URL to draw,
            // and no icon fetched to fall back to. The full profile hid it:
            // its Activity tab loads the recent-activity inventory, which fills
            // the same directory on its way past, so the same card drew the
            // real icon one click deeper. Minecraft was the account that showed
            // it.
            if activity.largeArtworkURL(side: Metrics.avatarProfile) == nil,
               let id = activity.applicationID
            {
                resolveApplications([id])
            }
        }
        if depth == .full { sessionController.loadRecentActivity(of: userID) }
        // **Started here as well as after the profile route answers**, so a
        // derived theme resolves alongside that request rather than behind it.
        // Both entry points are guarded on the palette already being known, so
        // the second caller is a dictionary lookup — and this is the one that
        // fires for a person whose profile is already resident.
        if let user = users[userID] { sessionController.deriveTheme(of: user) }
    }
}

extension AppModel {
    /// Whether the full profile is the surface that owns the window.
    ///
    /// **The window's toolbar cannot be dimmed, so while this is true it is
    /// taken away instead.** The profile's scrim is a layer in the content view
    /// and the toolbar's items are drawn above it: measured, the scrim darkened
    /// the strip's ground and left the channel pill, the three chrome buttons
    /// and the system's own search field burning at full strength over a dimmed
    /// window. Nothing dims an `NSToolbar` item, and `.searchable`'s field is
    /// the system's rather than ours, so there is no version of this where the
    /// bar stays and looks covered.
    ///
    /// The mini card is deliberately not included: it dims nothing — a card
    /// beside a row does not interrupt the window — so there is nothing for the
    /// bar to be inconsistent with. See `ProfilePresenter.dismissLayer`.
    var isFullProfileShown: Bool { profileRequest?.depth == .full }
}
