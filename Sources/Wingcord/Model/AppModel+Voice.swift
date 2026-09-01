import Foundation
import WingcordCore

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
    var speaking: Set<UserID>
    var liveVideo: Set<UserID>
    var spotlight: UserID?
    var isMuted: Bool
    var isDeafened: Bool
    var isCameraOn: Bool
    var isScreenSharing: Bool
    var quality: VoiceQuality
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
    func voiceChips(in channelID: ChannelID) -> [VoiceMemberChip] {
        voiceStates(in: channelID).map { state in
            let user = users[state.userID]
            return VoiceMemberChip(
                id: state.userID,
                name: voiceName(of: state.userID, inGuild: selectedGuildID),
                avatarURL: user.flatMap { avatarURL(for: $0, side: Metrics.avatarInline) },
                isSpeaking: speakingUserIDs.contains(state.userID),
                isMuted: state.isSilenced
            )
        }
    }

    /// Whether the reader is in this channel's call.
    func isConnected(to channelID: ChannelID) -> Bool {
        connectedVoiceChannelID == channelID
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
            speaking: speakingUserIDs,
            liveVideo: liveVideoUserIDs,
            spotlight: spotlightUserID,
            isMuted: isSelfMuted,
            isDeafened: isSelfDeafened,
            isCameraOn: isCameraOn,
            isScreenSharing: isScreenSharing,
            quality: voiceQuality
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
            let user = userTable[state.userID]
            let isSelf = state.userID == currentUserID
            participants.append(VoiceParticipant(
                id: state.userID,
                displayName: voiceName(of: state.userID, inGuild: channel.guildID),
                avatarURL: user.flatMap { avatarURL(for: $0, side: Metrics.avatarProfile) },
                monogram: user?.monogram ?? "?",
                nameColor: voiceNameColor(of: state.userID, inGuild: channel.guildID),
                // Our own tile lights from the engine's gate, not from a packet
                // we sent to ourselves — there is no loopback, so a self tile
                // driven by `speakingUserIDs` never lights at all.
                isSpeaking: isSelf ? isSelfSpeaking : speakingUserIDs.contains(state.userID),
                isSelfMuted: isSelf ? isSelfMuted : state.isSelfMuted,
                isServerMuted: state.isServerMuted,
                isDeafened: isSelf ? isSelfDeafened : state.isSelfDeafened,
                isCameraOn: isSelf ? isCameraOn : state.isCameraOn,
                isStreaming: isSelf ? isScreenSharing : state.isStreaming,
                isSelf: isSelf,
                // Our own picture is the capture preview, which is live the
                // moment the camera is on — it never goes through the network.
                hasLiveVideo: isSelf
                    ? (isCameraOn || isScreenSharing)
                    : liveVideoUserIDs.contains(state.userID)
            ))
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
            ringingUserIDs: directCalls[channelID]?.ringingUserIDs ?? []
        )
        voicePresentationCache = (key, value)
        return value
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

    /// Every sound the reader could press here, grouped by where it came from.
    ///
    /// **Discord's own six are always first and never locked.** They are the
    /// only sounds an account with no subscription can use anywhere, so putting
    /// them anywhere but the top makes the free half of the feature the half
    /// nobody finds.
    var soundboardPresentation: SoundboardPresentation {
        let defaults = defaultSoundboardSounds
        let perGuild = guildSoundboardSounds
        let guildTable = guilds
        let key = SoundboardMemoKey(
            revision: soundboardRevision,
            guildID: selectedGuildID,
            hasNitro: hasNitro
        )
        if let soundboardCache, soundboardCache.key == key { return soundboardCache.value }

        var sections: [SoundboardPresentation.Section] = []
        if !defaults.isEmpty {
            sections.append(SoundboardPresentation.Section(
                id: "default",
                title: "Discord Sounds",
                iconURL: nil,
                monogram: "♪",
                isLocked: false,
                sounds: defaults.map { entry(for: $0, locked: false) }
            ))
        }

        let home = connectedVoiceChannelID.flatMap { channelIndex[$0] }?.guildID
            ?? selectedGuildID
        for guildID in orderedGuildIDs {
            guard let sounds = perGuild[guildID], !sounds.isEmpty,
                  let guild = guildTable[guildID] else { continue }
            let isLocked = !SoundboardGate.canPlay(
                sounds[0], hasNitro: hasNitro, inGuild: home
            ) && guildID != home
            sections.append(SoundboardPresentation.Section(
                id: String(guildID.rawValue),
                title: guild.name,
                iconURL: guild.iconHash.flatMap {
                    CDN.guildIcon(guildID: guildID, hash: $0, side: Metrics.avatarRow)
                },
                monogram: Self.soundboardMonogram(guild.name),
                isLocked: isLocked,
                sounds: sounds.map {
                    entry(
                        for: $0,
                        locked: !SoundboardGate.canPlay(
                            $0, hasNitro: hasNitro, inGuild: home
                        )
                    )
                }
            ))
        }

        let value = SoundboardPresentation(sections: sections, hasNitro: hasNitro)
        soundboardCache = (key, value)
        return value
    }

    private func entry(for sound: SoundboardSound, locked: Bool) -> SoundboardPresentation.Entry {
        SoundboardPresentation.Entry(
            id: sound.id,
            name: sound.name,
            emoji: sound.emojiName,
            emojiURL: sound.emojiID.flatMap {
                CDN.emoji(id: EmojiID(rawValue: $0), animated: false, side: 22)
            },
            isLocked: locked
        )
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
    var hasNitro: Bool
}
