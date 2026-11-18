import Foundation
import WingcordCore
import WingcordVoice

// MARK: - Calls, in the store
//
// The store holds *facts* about calls — who is in which channel, what switches
// are set on them, which sounds a server has. It holds nothing that moves at the
// frame rate: the audio level, the packet counters and the per-frame speaking
// energy live in the engine and arrive here only when the ANSWER changes.
//
// That split is the whole reason a call does not cost a redraw a frame. A
// presentation carrying somebody's live level would invalidate every tile fifty
// times a second; `speakingUserIDs` changes a few times a sentence.

/// What the memoized voice presentation is keyed on.
struct VoiceMemoKey: Hashable, Sendable {
    var channelID: ChannelID?
    /// Bumped when a voice state, a member or a role changes — never on a
    /// message. `railRevision` moves on every inbound message in the account,
    /// which would rebuild the whole call several times a second for an answer
    /// that cannot have changed.
    var voiceRevision: UInt64
    var memberRevision: UInt64
    /// What they are playing, for the game chip.
    var voicePresenceRevision: UInt64
    /// A profile fetched or an avatar's colour derived, for the tile ground
    /// and the name's face.
    var identityRevision: UInt64
    var blockedUserIDs: Set<UserID>
    var ignoredUserIDs: Set<UserID>
    /// A role or an overwrite moved, for the soundboard's Use Soundboard.
    var roleRevision: UInt64
    var speaking: Set<UserID>
    var liveVideo: Set<UserID>
    var spotlight: UserID?
    var isMuted: Bool
    var isDeafened: Bool
    var isCameraOn: Bool
    var isScreenSharing: Bool
    var quality: VoiceQuality
    var connectedSince: Date?
}

extension AppModel {

    // MARK: Naming

    /// What to call somebody inside a call — their nickname where the server
    /// gave them one, their display name otherwise.
    func voiceName(of userID: UserID, inGuild guildID: GuildID?) -> String {
        guard let user = users[userID] else { return "Unknown" }
        if let guildID, let member = members[guildID]?[userID] {
            return member.resolvedName(user: user)
        }
        return user.preferredName
    }

    /// Their role colour, turned down by the reader's own saturation setting —
    /// the same treatment every other person-derived colour in the app gets.
    func voiceNameColor(of userID: UserID, inGuild guildID: GuildID?) -> UInt32? {
        guard let guildID, let member = members[guildID]?[userID],
              let roles = roles[guildID] else { return nil }
        return RoleResolver.nameColorValue(of: member.roleIDs, in: roles)
            .map { UserColor.desaturated($0, by: AppSettings.shared.userColorSaturation) }
    }

    // MARK: Reading

    /// Everybody in one voice channel, in a stable order.
    ///
    /// **Ordered by join time, which is what the id encodes.** Sorting by name
    /// makes a channel reshuffle whenever somebody is renamed, and sorting by
    /// nothing makes it reshuffle on every dictionary rehash — which reads as
    /// the tiles twitching.
    func voiceStates(in channelID: ChannelID) -> [VoiceState] {
        voiceStates.values
            .filter { $0.channelID == channelID }
            .sorted { $0.userID.rawValue < $1.userID.rawValue }
    }

    /// The chips drawn under a voice channel's row in the sidebar.
    ///
    /// **Everything is resolved here**, once per rebuild: the name, the face,
    /// the switches, the custom status and the mark of whatever they are
    /// playing. The row is then a function of its chip and reaches nothing.
    ///
    /// The guild is passed rather than read from `selectedGuildID` so the answer
    /// is the same whichever list is asking — a nickname resolved against the
    /// *selected* server would be the wrong nickname the moment anything but the
    /// open sidebar called this.
    /// - Parameter onStageOnly: a stage's row lists the people on its stage,
    ///   not an audience that can run to thousands — filtered before a single
    ///   chip is built.
    func voiceChips(in channelID: ChannelID, guildID: GuildID?, onStageOnly: Bool = false) -> [VoiceMemberChip] {
        let states = voiceStates(in: channelID).filter {
            !onStageOnly || (!$0.isSuppressed && $0.requestToSpeakAt == nil)
        }
        guard !states.isEmpty else { return [] }
        var chips: [VoiceMemberChip] = []
        chips.reserveCapacity(states.count)
        for state in states {
            let user = users[state.userID]
            let presence = presences[state.userID]
            let status = presence?.customStatus
            let game = presence?.primaryActivity
            var chip = VoiceMemberChip(
                id: state.userID,
                name: voiceName(of: state.userID, inGuild: guildID),
                avatarURL: user.flatMap { avatarURL(for: $0, side: Metrics.avatarVoiceRow) },
                monogram: user?.monogram ?? "?",
                isSpeaking: speakingUserIDs.contains(state.userID),
                // **Our own microphone is the engine's, not the server's.** Our
                // state on the wire lags a mute by a round trip, and a row that
                // takes half a second to cross out its own microphone reads as
                // the button not having worked.
                isMuted: state.userID == currentUserID ? isSelfMuted : state.isSilenced,
                isDeafened: state.userID == currentUserID
                    ? isSelfDeafened
                    : (state.isSelfDeafened || state.isServerDeafened),
                isStreaming: state.userID == currentUserID ? isScreenSharing : state.isStreaming,
                isCameraOn: state.userID == currentUserID ? isCameraOn : state.isCameraOn,
                statusEmoji: status?.emoji,
                // A custom status is `state`, never `name` — the name of a
                // custom activity is the literal string "Custom Status".
                statusText: status?.state.flatMap { $0.isEmpty ? nil : $0 },
                gameIconURL: gameMarkURL(for: game),
                gameName: game?.name,
                streamKey: state.isStreaming
                    ? GoLiveKey.make(
                        guildID: guildID, channelID: channelID, userID: state.userID
                    )
                    : nil
            )
            if state.channelID == connectedVoiceChannelID, state.userID != currentUserID {
                chip.isLocallyMuted = audioContext.isMuted(state.userID)
                chip.platform = voicePlatforms[state.userID]
            }
            chips.append(chip)
        }
        return chips
    }

    /// The small square mark of whatever somebody is doing.
    ///
    /// **The game's own icon first, then the application's.** `/games` answers
    /// for titles Discord tracks and carries the art Discord itself draws; every
    /// other application — a bot, Wordle, a music client — has only the icon it
    /// registered, which is the picture Discord falls back to. An activity with
    /// neither draws nothing rather than a grey square: a row that ends in a
    /// placeholder for everybody says less than one that ends in nothing.
    private func gameMarkURL(for activity: Activity?) -> URL? {
        guard let activity, activity.kind != .custom,
              let applicationID = activity.applicationID
        else { return nil }
        if let game = games[applicationID],
           let url = gameArtURL(game, kind: .mark, side: Metrics.voiceGameMark) {
            return url
        }
        return applicationIconURL(applicationID, side: Metrics.voiceGameMark)
    }

    /// The avatar a call tile's colour is read from, in points: Discord's
    /// `getAvatarURL(guildId, 80)` — the profile's own rendition, so a person
    /// whose profile was opened already has the answer.
    static let tileGroundSide = CGFloat(ProfileThemePalette.profilePixelSize) / 2

    /// A call tile's colour — see `VoiceTileGround`. Every colour is
    /// desaturated as the reader asked before it is mixed, as Discord's are.
    private func tileGround(of userID: UserID, user: User?, inGuild guildID: GuildID?) -> VoiceTileGround? {
        let saturation = userColorSaturation
        if let user, let chosen = cosmetics(of: user)?.themeColorValues, chosen.count >= 2 {
            let base = ProfileThemeColors.modalBackground(primary: chosen[0], secondary: chosen[1])
            return VoiceTileGround(
                primary: UserColor.desaturated(chosen[0], by: saturation),
                secondary: UserColor.desaturated(chosen[1], by: saturation),
                base: UserColor.desaturated(base, by: saturation)
            )
        }
        guard let url = tileGroundArtwork(of: userID, inGuild: guildID),
              let colour = derivedPalettes[url]?.first
        else { return nil }
        return VoiceTileGround(flat: UserColor.desaturated(colour, by: saturation))
    }

    private func tileGroundArtwork(of userID: UserID, inGuild guildID: GuildID?) -> URL? {
        avatarURL(forUserID: userID, inGuild: guildID, side: Self.tileGroundSide)
    }

    /// Whether the reader is in this channel's call.
    func isConnected(to channelID: ChannelID) -> Bool {
        connectedVoiceChannelID == channelID
    }

    /// One person's tile, from their voice state.
    ///
    /// **One builder, used by the call and by the lobby somebody watches before
    /// they join it.** The two surfaces show the same faces with the same rings
    /// and the same badges; building them twice would let them drift, and the
    /// whole point of the lobby is that joining is a continuation of what is
    /// already on screen rather than a different thing appearing.
    private func participant(
        from state: VoiceState, inGuild guildID: GuildID?, users: [UserID: User]
    ) -> VoiceParticipant {
        let user = users[state.userID]
        let isSelf = state.userID == currentUserID
        return VoiceParticipant(
            id: state.userID,
            displayName: voiceName(of: state.userID, inGuild: guildID),
            // The server's own face where they set one, as Discord's tile
            // draws it — and the face the ground's colour is read from.
            avatarURL: avatarURL(forUserID: state.userID, inGuild: guildID, side: Metrics.avatarProfile),
            monogram: user?.monogram ?? "?",
            nameFont: user.flatMap { cosmetics(of: $0)?.displayNameStyle?.font },
            ground: tileGround(of: state.userID, user: user, inGuild: guildID),
            groundArtwork: tileGroundArtwork(of: state.userID, inGuild: guildID),
            // Our own tile lights from the engine's gate, not from a packet we
            // sent to ourselves — there is no loopback, so a self tile driven
            // by `speakingUserIDs` never lights at all.
            isSpeaking: isSelf ? isSelfSpeaking : speakingUserIDs.contains(state.userID),
            isSelfMuted: isSelf ? isSelfMuted : state.isSelfMuted,
            isServerMuted: state.isServerMuted,
            isServerDeafened: state.isServerDeafened,
            isDeafened: isSelf ? isSelfDeafened : state.isSelfDeafened,
            isLocallyMuted: !isSelf && audioContext.isMuted(state.userID),
            isBlocked: blockedUserIDs.contains(state.userID),
            isIgnored: ignoredUserIDs.contains(state.userID),
            platform: voicePlatforms[state.userID],
            // Discord's game chip: the activity a game is played under.
            game: presences[state.userID]?.activities?.list
                .first { $0.kind == .playing }
                .map { VoiceGame(name: $0.name, iconURL: applicationIconURL($0.applicationID, side: 32)) },
            isCameraOn: isSelf ? isCameraOn : state.isCameraOn,
            isStreaming: isSelf ? isScreenSharing : state.isStreaming,
            isSelf: isSelf,
            // Our own picture is the capture preview, which is live the moment
            // the camera is on — it never goes through the network.
            hasLiveVideo: isSelf
                ? (isCameraOn || isScreenSharing)
                : liveVideoUserIDs.contains(state.userID),
            isWatched: watchedStreamUserID == state.userID
        )
    }

    // MARK: A call happening without you

    /// Who is sitting in this conversation's call, when the reader is not.
    ///
    /// **Empty means there is nothing to join**, which is not the same as there
    /// being no `directCalls` entry: that survives the last person leaving, and
    /// a panel offering to join an empty room is worse than no panel.
    ///
    /// Video is deliberately **not** carried. Nothing is subscribed to their
    /// streams until the reader joins — a lobby that decoded everybody's camera
    /// would spend a call's worth of CPU on a panel nobody has stepped into.
    func callLobby(for channelID: ChannelID) -> [VoiceParticipant] {
        guard connectedVoiceChannelID != channelID else { return [] }
        let guildID = channelIndex[channelID]?.guildID
        let users = self.users
        // **The reader too**, when they are in it from another device (Alex,
        // 2026-11-18): not connected here means any state of theirs in this
        // call is another session's, and Discord's lobby shows them in it.
        return voiceStates.values
            .filter { $0.channelID == channelID }
            .sorted { $0.userID.rawValue < $1.userID.rawValue }
            .map { state in
                var tile = participant(from: state, inGuild: guildID, users: users)
                tile.hasLiveVideo = false
                return tile
            }
    }

    // MARK: The call, as one value

    /// Nil when there is no call. Memoized: the tile grid, the HUD and the
    /// overlay all read it, and each of them would otherwise rebuild every
    /// participant on every evaluation.
    var voicePresentation: VoicePresentation? {
        // Every observable input is read before the early return. A memo that
        // returns its cache without touching them registers no dependency, and
        // its reader is then never invalidated — §2.
        let states = voiceStates
        let userTable = users
        let channelID = connectedVoiceChannelID
        let key = VoiceMemoKey(
            channelID: channelID,
            voiceRevision: voiceRevision,
            memberRevision: memberRevision,
            voicePresenceRevision: voicePresenceRevision,
            identityRevision: identityRevision,
            blockedUserIDs: blockedUserIDs,
            ignoredUserIDs: ignoredUserIDs,
            roleRevision: roleRevision,
            speaking: speakingUserIDs,
            liveVideo: liveVideoUserIDs,
            spotlight: spotlightUserID,
            isMuted: isSelfMuted,
            isDeafened: isSelfDeafened,
            isCameraOn: isCameraOn,
            isScreenSharing: isScreenSharing,
            quality: voiceQuality,
            connectedSince: voiceConnectedSince
        )
        if let voicePresentationCache, voicePresentationCache.key == key {
            return voicePresentationCache.value
        }

        guard let channelID, let channel = channelIndex[channelID] else {
            voicePresentationCache = (key, nil)
            return nil
        }
        let guild = channel.guildID.flatMap { guilds[$0] }
        var participants: [VoiceParticipant] = []
        participants.reserveCapacity(8)

        for state in states.values.sorted(by: { $0.userID.rawValue < $1.userID.rawValue })
        where state.channelID == channelID {
            participants.append(participant(from: state, inGuild: channel.guildID, users: userTable))
        }

        let value = VoicePresentation(
            placement: channel.guildID == nil ? .direct(channelID) : .channel(channelID),
            channelName: displayName(of: channel),
            guildName: guild?.name,
            participants: participants,
            spotlightUserID: resolvedSpotlight(among: participants),
            isMuted: isSelfMuted,
            isDeafened: isSelfDeafened,
            isCameraOn: isCameraOn,
            isScreenSharing: isScreenSharing,
            quality: voiceQuality,
            ringingUserIDs: directCalls[channelID]?.ringingUserIDs ?? [],
            soundboard: soundboardAccess(in: channel),
            canLaunchActivities: channel.guildID == nil
                || permissionGate.permissions(in: channel.id).contains(.useEmbeddedActivities),
            connectedSince: voiceConnectedSince
        )
        voicePresentationCache = (key, value)
        return value
    }

    /// Whether the call's soundboard can be opened — see `SoundboardAccess`.
    private func soundboardAccess(in channel: Channel) -> SoundboardAccess {
        if channel.guildID != nil, !permissionGate.permissions(in: channel.id).contains(.useSoundboard) {
            return .unavailable
        }
        let me = currentUserID.flatMap { voiceStates[$0] }
        return me?.isServerMuted == true ? .serverMuted : .available
    }

    /// Who fills the stage.
    ///
    /// **A share wins over a pin, and a pin wins over nothing.** Somebody
    /// sharing a screen is the reason everybody is looking; a reader who then
    /// pins a face has said otherwise and that has to hold, which is why the pin
    /// is cleared rather than overridden when the share ends.
    private func resolvedSpotlight(among participants: [VoiceParticipant]) -> UserID? {
        if let spotlightUserID, participants.contains(where: { $0.id == spotlightUserID }) {
            return spotlightUserID
        }
        return participants.first { $0.isStreaming && $0.hasLiveVideo }?.id
    }

    // MARK: The soundboard

    /// The sound each person just pressed, by name, for the chip on their
    /// tile — every call surface draws the same ones.
    var soundboardEffectNames: [UserID: String] {
        var names: [UserID: String] = [:]
        for (userID, soundID) in soundboardEffects {
            names[userID] = soundboardSound(id: soundID)?.name ?? "sound"
        }
        return names
    }

    /// Every sound the reader could press here, as Discord's picker lays it
    /// out — its `useSoundGrid`:
    ///
    /// Favorites, then Frequently Used (the three most played that are not
    /// favourites), then the call's own server — never locked, with Add Sound
    /// where a slot is free and the reader may add — then Discord Sounds, then
    /// every other server with sounds, locked without Nitro. **With Nitro,
    /// Discord Sounds goes last** (`p||eP(i,s)` before the other servers,
    /// `p&&eP(i,s)` after them).
    var soundboardPresentation: SoundboardPresentation {
        let playsEverywhere = entitlements.has(.soundboardEverywhere)
        let callID = connectedVoiceChannelID
        let home = callID.flatMap { channelIndex[$0] }?.guildID
        let channelPermissions = home != nil ? callID.map { permissionGate.permissions(in: $0) } ?? [] : []
        let guildPermissions = home.map { permissionGate.permissions(inGuild: $0) } ?? []
        let me = currentUserID.flatMap { voiceStates[$0] }
        let key = SoundboardMemoKey(
            revision: soundboardRevision,
            guildID: home,
            playsEverywhere: playsEverywhere,
            channelPermissions: channelPermissions,
            guildPermissions: guildPermissions,
            isSilenced: isSelfDeafened || (me?.isServerMuted ?? false) || (me?.isSuppressed ?? false),
            guildOrder: orderedGuildIDs,
            favorites: soundboardFavorites,
            frequent: soundboardFrequentSoundIDs
        )
        if let soundboardCache, soundboardCache.key == key { return soundboardCache.value }

        let perGuild = guildSoundboardSounds
        let mayUseExternal = channelPermissions.contains(.useExternalSounds)
        func entry(_ sound: SoundboardSound) -> SoundboardPresentation.Entry {
            SoundboardPresentation.Entry(
                id: sound.id,
                name: sound.name,
                emoji: sound.emojiName,
                emojiURL: sound.emojiID.flatMap {
                    CDN.emoji(id: EmojiID(rawValue: $0), animated: false, side: 22)
                },
                isLocked: !SoundboardGate.canPlay(
                    sound, playsEverywhere: playsEverywhere, inGuild: home,
                    mayUseExternalSounds: mayUseExternal
                ),
                isFavorite: UInt64(sound.id).map(key.favorites.contains) ?? false,
                refusal: SoundboardGate.refusal(sound, playsEverywhere: playsEverywhere, inGuild: home)
            )
        }
        func serverSection(_ guild: Guild, sounds: [SoundboardSound], isLocked: Bool) -> SoundboardPresentation.Section {
            SoundboardPresentation.Section(
                id: String(guild.id.rawValue),
                kind: .server,
                title: guild.name,
                iconURL: guild.iconHash.flatMap {
                    CDN.guildIcon(guildID: guild.id, hash: $0, side: Metrics.avatarRow)
                },
                monogram: Self.soundboardMonogram(guild.name),
                isLocked: isLocked,
                sounds: sounds.map(entry)
            )
        }

        var byID: [String: SoundboardSound] = [:]
        for sound in defaultSoundboardSounds { byID[sound.id] = sound }
        for sounds in perGuild.values { for sound in sounds { byID[sound.id] = sound } }

        var sections: [SoundboardPresentation.Section] = []
        let favorites = key.favorites.inOrder.compactMap { byID[String($0)] }
        if !favorites.isEmpty {
            sections.append(SoundboardPresentation.Section(
                id: "favorites", kind: .favorites, title: "Favorites", iconURL: nil, monogram: "",
                isLocked: false, sounds: favorites.map(entry)
            ))
        }
        let frequent = key.frequent
            .filter { id in !(UInt64(id).map(key.favorites.contains) ?? false) }
            .prefix(3)
            .compactMap { byID[$0] }
        if !frequent.isEmpty {
            sections.append(SoundboardPresentation.Section(
                id: "frequently-used", kind: .frequentlyUsed, title: "Frequently Used", iconURL: nil,
                monogram: "", isLocked: false, sounds: frequent.map(entry)
            ))
        }
        // The call's own server, once its sounds have been read — an Add Sound
        // tile alone before then would say the server has none.
        if let home, let guild = guilds[home], let sounds = perGuild[home] {
            var section = serverSection(guild, sounds: sounds, isLocked: false)
            let canAdd = guildPermissions.contains(.createExpressions)
                || guildPermissions.contains(.manageExpressions)
            if (canAdd && sounds.count < ExpressionSlots.soundboard(premiumTier: guild.premiumTier))
                || sounds.isEmpty {
                section.addSound = SoundboardPresentation.AddSound(
                    guildID: home, guildName: guild.name, canAdd: canAdd
                )
            }
            sections.append(section)
        }
        let defaults = defaultSoundboardSounds.isEmpty ? nil : SoundboardPresentation.Section(
            id: "default", kind: .defaults, title: "Discord Sounds", iconURL: nil, monogram: "",
            isLocked: false, sounds: defaultSoundboardSounds.map(entry)
        )
        if !playsEverywhere, let defaults { sections.append(defaults) }
        for guildID in key.guildOrder where guildID != home {
            guard let sounds = perGuild[guildID], !sounds.isEmpty, let guild = guilds[guildID] else { continue }
            sections.append(serverSection(guild, sounds: sounds, isLocked: !playsEverywhere))
        }
        if playsEverywhere, let defaults { sections.append(defaults) }

        let value = SoundboardPresentation(
            sections: sections,
            playsEverywhere: playsEverywhere,
            isSilenced: key.isSilenced,
            // Discord offers Server Settings to someone who may both create
            // and manage the server's expressions.
            managedGuildID: guildPermissions.contains(.createExpressions)
                && guildPermissions.contains(.manageExpressions) ? home : nil
        )
        soundboardCache = (key, value)
        return value
    }

    private static func soundboardMonogram(_ name: String) -> String {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first)
        return initials.isEmpty ? "#" : String(initials).uppercased()
    }

    /// The sound behind an id, wherever it came from.
    func soundboardSound(id: String) -> SoundboardSound? {
        if let match = defaultSoundboardSounds.first(where: { $0.id == id }) { return match }
        for sounds in guildSoundboardSounds.values {
            if let match = sounds.first(where: { $0.id == id }) { return match }
        }
        return nil
    }
}

struct SoundboardMemoKey: Hashable, Sendable {
    var revision: UInt64
    var guildID: GuildID?
    var playsEverywhere: Bool
    var channelPermissions: Permissions
    var guildPermissions: Permissions
    var isSilenced: Bool
    var guildOrder: [GuildID]
    var favorites: SoundboardFavorites
    var frequent: [String]
}

// MARK: - Going live

/// What the Go Live sheet's surface shows.
enum GoLivePreview: Equatable {
    /// Nothing picked yet.
    case empty
    /// Picked, and the capture is coming up.
    case starting
    /// The picture that Go Live will send.
    case previewing
    /// The capture refused, in the system's own words.
    case failed(String)
}

/// What is picked for a share, as the surfaces name it.
struct ScreenShareSourceSummary: Equatable {
    /// Discord's name for it — the windows' titles, the applications', or
    /// "Entire Screen".
    var name: String
    var hasWindows: Bool
    var hasApplications: Bool

    init(_ source: ShareSource) {
        name = source.name
        hasWindows = source.hasWindows
        hasApplications = source.hasApplications
    }

    /// What Discord's menu calls picking again: "Add Window" over windows,
    /// "Add Application" over applications, and "Change Windows" over a
    /// screen.
    var changeTitle: String {
        if hasWindows { "Add Window" } else if hasApplications { "Add Application" } else { "Change Windows" }
    }
}

// MARK: - A picture of somebody's screen share

extension AppModel {

    /// Asks Discord for the newest frame of a stream.
    ///
    /// **Only ever from a hover, and that is the whole design.** Discord does
    /// not push previews; a client that wanted a live thumbnail on every LIVE
    /// row in a busy server would be polling a REST route once per row per few
    /// seconds, which is a rate-limit slot spent on pictures nobody is looking
    /// at. One request while the pointer rests, repeated for as long as it does,
    /// costs a request per hover.
    ///
    /// Fire-and-forget and silent: a stream that has just ended answers 404, and
    /// the flyout already draws a plate when there is no picture.
    func requestStreamPreview(key: String) {
        sessionController.loadStreamPreview(key: key)
    }
}

// MARK: - Who is in voice in a server, for the rail

extension AppModel {

    /// The faces the rail's hover chip draws for one server.
    ///
    /// **Discord's own rule** (`useGuildTooltipActivity`, module `24594`),
    /// ported after two rounds of counts that came out higher than its:
    ///
    ///  - **Voice** is everybody in a voice channel the reader can see, less
    ///    the AFK room, less whoever the streams row already draws.
    ///  - **Streams** are screen shares, wherever they are. A camera is
    ///    somebody in voice with video on, and it stays in voice.
    ///  - **Stage** is the speakers on a live stage the reader can see, with a
    ///    count of everybody listening beside them. A stage is not a voice
    ///    channel and is in neither row above.
    ///  - **Blocked and ignored people are drawn nowhere**, though the listener
    ///    count still includes them, as Discord's does.
    ///
    /// Discord also lifts people inside an embedded Activity into a row of
    /// their own. This client does not track who is in one, so they stay in
    /// voice — the one place the two counts can still differ.
    ///
    /// **Asked for one server at a time, while the pointer is on it**: one pass
    /// over the account's voice table, where visibility is a cached lookup per
    /// channel in `PermissionGate`.
    func railHoverPresence(for guildID: GuildID) -> RailHoverPresence {
        var voice: [UserID] = []
        var streams: [UserID] = []
        var speakers: [UserID] = []
        var listeners = 0
        for state in voiceStates.values where state.guildID == guildID {
            guard let channelID = state.channelID else { continue }
            let isHidden = isHiddenFromVoice(state.userID)
            if state.isStreaming, !isHidden { streams.append(state.userID) }
            if isCountedVoiceRoom(channelID, inGuild: guildID) {
                // Somebody sharing their screen is drawn once, in that row.
                if !state.isStreaming, !isHidden { voice.append(state.userID) }
            } else if isVisibleLiveStage(channelID) {
                if state.isSuppressed {
                    listeners += 1
                } else if !isHidden {
                    speakers.append(state.userID)
                }
            }
        }
        return RailHoverPresence(
            stage: railHoverRow(speakers, slots: RailHoverPresence.stageFaceSlots, in: guildID),
            stageListeners: listeners,
            voice: railHoverRow(voice, slots: RailHoverPresence.faceSlots, in: guildID),
            streams: railHoverRow(streams, slots: RailHoverPresence.faceSlots, in: guildID)
        )
    }

    /// One row, cut the way Discord's facepile cuts it.
    ///
    /// **Ordered by id before the cut**, so which faces make the row is stable.
    /// Discord orders by affinity scores this client does not have; ordering by
    /// nothing reshuffles on every dictionary rehash, which reads as the faces
    /// twitching while the chip is open.
    private func railHoverRow(
        _ people: [UserID],
        slots: Int,
        in guildID: GuildID
    ) -> RailHoverPresence.Row {
        let pile = RailHoverPresence.pile(count: people.count, slots: slots)
        guard pile.faces > 0 else { return RailHoverPresence.Row() }
        let drawn = people.sorted { $0.rawValue < $1.rawValue }.prefix(pile.faces)
        return RailHoverPresence.Row(
            faces: drawn.map { userID in
                RailHoverPresence.Face(
                    id: userID,
                    // **Guild-aware**, so somebody wearing a different face in
                    // this server is drawn with it — the answer the roster and
                    // the sidebar give, rather than a third one.
                    avatarURL: avatarURL(
                        forUserID: userID,
                        inGuild: guildID,
                        side: Metrics.avatarInline
                    ),
                    monogram: users[userID]?.monogram ?? "?"
                )
            },
            overflow: pile.overflow
        )
    }

    /// What each server's voice channels are doing, in one pass.
    ///
    /// **Computed once per rail rebuild and read as a table**, never per tile: a
    /// test per guild over the whole voice table is ninety-seven passes over
    /// five hundred states, on a memo that rebuilds whenever any message
    /// arrives anywhere in the account.
    ///
    /// **Discord's `GuildMediaStateStore`, rule for rule** (module `34162`):
    /// a room counts on the terms the hover chip counts it on, a screen share
    /// counts wherever it is, a live stage counts if the reader can see it,
    /// and blocked or ignored people count for nothing. Two rules are about
    /// the reader rather than the room:
    ///
    ///  - **A muted server carries no mark at all.** Muting is the reader
    ///    saying they do not want to hear from it.
    ///  - **The server the reader is in a call in describes their own room**,
    ///    whatever the rest of it is doing — and it is the mark drawn green.
    var voiceMarksByGuild: [GuildID: RailVoiceMark] {
        var found: [GuildID: RailVoiceMark] = [:]
        // The more specific fact wins whichever order the table is walked in —
        // a rule written as "last writer wins" would draw a speaker on a
        // server with a stream in it about half the time.
        func raise(_ guildID: GuildID, to mark: RailVoiceMark) {
            if let current = found[guildID], current >= mark { return }
            found[guildID] = mark
        }
        for state in voiceStates.values {
            guard let guildID = state.guildID, let channelID = state.channelID,
                  !mutedGuildIDs.contains(guildID),
                  !isHiddenFromVoice(state.userID)
            else { continue }
            if state.isStreaming { raise(guildID, to: .screenShare) }
            guard isCountedVoiceRoom(channelID, inGuild: guildID) else { continue }
            raise(guildID, to: state.isCameraOn ? .video : .voice)
        }
        for channelID in stageInstances.keys where isVisibleLiveStage(channelID) {
            guard let guildID = channelIndex[channelID]?.guildID,
                  !mutedGuildIDs.contains(guildID)
            else { continue }
            raise(guildID, to: .stage)
        }
        // **An event happening now outranks every room** — Discord's
        // `activeEvent`, checked first in `oi`.
        for guildID in scheduledEvents.keys where !mutedGuildIDs.contains(guildID) {
            if activeEvent(inGuild: guildID) != nil { raise(guildID, to: .event) }
        }
        if let ownChannelID = connectedVoiceChannelID,
           let own = channelIndex[ownChannelID], let guildID = own.guildID
        {
            // The reader's own room describes the server they are in a call
            // in — unless the event happening now is in that very room.
            found[guildID] = activeEvent(inGuild: guildID)?.location.channelID == ownChannelID
                ? .event
                : ownRoomMark(own)
        }
        return found
    }

    /// The mark for the server the reader is in a call in.
    private func ownRoomMark(_ channel: Channel) -> RailVoiceMark {
        if channel.kind == .stage { return .stage }
        if let userID = currentUserID, voiceStates[userID]?.isStreaming == true {
            return .screenShare
        }
        let hasVideo = voiceStates.values.contains {
            $0.channelID == channel.id && $0.isCameraOn
        }
        return hasVideo ? .video : .voice
    }

    /// A room the rail counts people in: a voice channel the reader can see,
    /// and not the one idle members are parked in. A stage is counted apart.
    private func isCountedVoiceRoom(_ channelID: ChannelID, inGuild guildID: GuildID) -> Bool {
        channelID != guilds[guildID]?.afkChannelID
            && channelIndex[channelID]?.kind == .voice
            && permissionGate.canView(channelID)
    }

    /// A stage that is on, in a channel the reader can see.
    private func isVisibleLiveStage(_ channelID: ChannelID) -> Bool {
        stageInstances[channelID] != nil
            && channelIndex[channelID]?.kind == .stage
            && permissionGate.canView(channelID)
    }

    /// Somebody the rail leaves out of every face and every mark.
    private func isHiddenFromVoice(_ userID: UserID) -> Bool {
        blockedUserIDs.contains(userID) || ignoredUserIDs.contains(userID)
    }
}
