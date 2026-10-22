import Foundation
import WingcordCore

// MARK: - Discord's experiments, asked

extension AppModel {

    /// A server's bucket in one of Discord's server experiments, by Discord's
    /// own evaluation — nil where the server is not in it.
    func guildExperimentBucket(_ name: String, in guildID: GuildID) -> Int? {
        guard let guild = guilds[guildID] else { return nil }
        let facts = ExperimentGuildFacts(
            id: guildID.rawValue,
            features: guild.features,
            memberCount: guild.memberCount,
            // A vanity address is a feature here; the code itself is not kept.
            hasVanityURL: guild.features.contains("VANITY_URL")
        )
        return Experiments.guildBucket(name, guild: facts, in: experiments.guild)
    }

    /// Whether a voice invite into this server is drawn as the channel row —
    /// the reader's choice, or Discord's experiment where they left it to it.
    func usesVoiceChannelRow(in guildID: GuildID?) -> Bool {
        switch AppSettings.shared.voiceInviteCardStyle {
        case .channelRow: true
        case .card: false
        case .asDiscordDecides:
            guildID.flatMap { guildExperimentBucket(Self.voiceChannelRowExperiment, in: $0) }.map { $0 >= 1 } ?? false
        }
    }

    static let voiceChannelRowExperiment = "2026-05_voice_channel_list_invite_embed"
}
