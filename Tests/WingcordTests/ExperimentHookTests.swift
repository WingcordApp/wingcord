import Foundation
import Testing
@testable import Wingcord
import WingcordCore

/// The one surface that follows a Discord experiment — a voice invite's
/// channel-row card — and the reader's say over it.
@MainActor
@Suite("Experiment hooks")
struct ExperimentHookTests {

    private let guildID = GuildID(rawValue: 1_520_000_000_000_000_001)

    /// A model whose one server is in the voice-row experiment's `bucket` for
    /// every position.
    private func model(bucket: Int?) -> AppModel {
        let model = AppModel()
        model.guilds[guildID] = Guild(id: guildID, name: "Lumen Club", ownerID: UserID(rawValue: 1))
        if let bucket {
            let experiment = GuildExperiment(
                hash: MurmurHash3.hash32(AppModel.voiceChannelRowExperiment),
                populations: [ExperimentPopulation(buckets: [.init(bucket: bucket, ranges: [0..<10_000])])]
            )
            model.experiments = ExperimentSnapshot(guild: [experiment.hash: experiment])
        }
        return model
    }

    @Test("Left to Discord, the server's bucket decides")
    func discordDecides() async {
        await withAppSettings(\.voiceInviteCardStyle) { settings in
            settings.voiceInviteCardStyle = .asDiscordDecides
            #expect(model(bucket: 1).usesVoiceChannelRow(in: guildID))
            #expect(!model(bucket: 0).usesVoiceChannelRow(in: guildID), "control")
            #expect(!model(bucket: nil).usesVoiceChannelRow(in: guildID), "not in it")
            #expect(!model(bucket: 1).usesVoiceChannelRow(in: nil), "no server")
            #expect(model(bucket: 1).guildExperimentBucket(AppModel.voiceChannelRowExperiment, in: guildID) == 1)
        }
    }

    @Test("The reader's choice wins over the bucket")
    func readerDecides() async {
        await withAppSettings(\.voiceInviteCardStyle) { settings in
            settings.voiceInviteCardStyle = .channelRow
            #expect(model(bucket: nil).usesVoiceChannelRow(in: guildID))
            settings.voiceInviteCardStyle = .card
            #expect(!model(bucket: 1).usesVoiceChannelRow(in: guildID))
        }
    }
}
