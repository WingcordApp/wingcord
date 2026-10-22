import Foundation
import Testing
@testable import WingcordCore

/// Discord's server experiment evaluation, rule by rule.
struct ExperimentsTests {
    private let name = "2026-05_voice_channel_list_invite_embed"
    private let guild = ExperimentGuildFacts(id: 1_520_000_000_000_000_001, features: ["COMMUNITY"], memberCount: 121)

    private func experiment(_ populations: [ExperimentPopulation], overrides: [UInt64: Int] = [:]) -> [UInt32: GuildExperiment] {
        [MurmurHash3.hash32(name): GuildExperiment(hash: MurmurHash3.hash32(name), populations: populations, overrides: overrides)]
    }

    private var position: Int { Experiments.position(name, guildID: guild.id) }

    @Test("A server's position is the hash of name and id, out of ten thousand")
    func positionRule() {
        #expect(position == Int(MurmurHash3.hash32("\(name):\(guild.id)") % 10_000))
        #expect((0..<10_000).contains(position))
    }

    @Test("The bucket whose range holds the position; Control where none does")
    func buckets() {
        let all = experiment([ExperimentPopulation(buckets: [.init(bucket: 1, ranges: [0..<10_000])])])
        #expect(Experiments.guildBucket(name, guild: guild, in: all) == 1)
        let elsewhere = experiment([ExperimentPopulation(buckets: [.init(bucket: 1, ranges: [(position + 1)..<(position + 2)])])])
        #expect(Experiments.guildBucket(name, guild: guild, in: elsewhere) == ExperimentBucket.control)
        #expect(Experiments.guildBucket("not-a-loaded-experiment", guild: guild, in: all) == nil)
    }

    @Test("Filters gate a population; the first that admits the server decides")
    func filters() {
        let rollout = experiment([
            ExperimentPopulation(buckets: [.init(bucket: 2, ranges: [0..<10_000])], filters: [.hasFeature(["PARTNERED"])]),
            ExperimentPopulation(buckets: [.init(bucket: 1, ranges: [0..<10_000])], filters: [.memberCountRange(min: 100, max: 500)]),
        ])
        #expect(Experiments.guildBucket(name, guild: guild, in: rollout) == 1)
        var partnered = guild
        partnered.features.insert("PARTNERED")
        #expect(Experiments.guildBucket(name, guild: partnered, in: rollout) == 2)
        var tiny = guild
        tiny.memberCount = 3
        #expect(Experiments.guildBucket(name, guild: tiny, in: rollout) == nil, "no population admits it")
    }

    @Test("An override by id wins; not eligible takes the server out")
    func overrides() {
        let pops = [ExperimentPopulation(buckets: [.init(bucket: 1, ranges: [0..<10_000])])]
        #expect(Experiments.guildBucket(name, guild: guild, in: experiment(pops, overrides: [guild.id: 3])) == 3)
        #expect(Experiments.guildBucket(name, guild: guild, in: experiment(pops, overrides: [guild.id: -1])) == nil)
        let out = experiment([ExperimentPopulation(buckets: [.init(bucket: -1, ranges: [0..<10_000])])])
        #expect(Experiments.guildBucket(name, guild: guild, in: out) == nil)
    }

    @Test("An unknown filter passes, as Discord skips a filter it cannot read")
    func unknownPasses() {
        let rollout = experiment([ExperimentPopulation(buckets: [.init(bucket: 1, ranges: [0..<10_000])], filters: [.unknown])])
        #expect(Experiments.guildBucket(name, guild: guild, in: rollout) == 1)
    }

    @Test("The hash-range filter doubles a positive hash, as the source does")
    func hashRange() {
        let hash = UInt64(MurmurHash3.hash32("key:\(guild.id)"))
        let doubled = Int((hash > 0 ? hash * 2 : hash) % 10_000)
        #expect(Experiments.passes(.inRangeByHash(hashKey: "key", target: doubled + 1), guild: guild, now: .now))
        #expect(!Experiments.passes(.inRangeByHash(hashKey: "key", target: doubled), guild: guild, now: .now))
    }

    @Test("A holdout's control bucket takes a server back out")
    func holdout() {
        let holdoutName = "2026-01_holdout"
        var experiments = experiment([ExperimentPopulation(buckets: [.init(bucket: 1, ranges: [0..<10_000])])])
        experiments[MurmurHash3.hash32(name)]?.holdoutName = holdoutName
        experiments[MurmurHash3.hash32(name)]?.holdoutControlBucket = 0
        experiments[MurmurHash3.hash32(holdoutName)] = GuildExperiment(
            hash: MurmurHash3.hash32(holdoutName),
            populations: [ExperimentPopulation(buckets: [.init(bucket: 0, ranges: [0..<10_000])])]
        )
        #expect(Experiments.guildBucket(name, guild: guild, in: experiments) == nil)
    }

    @Test("The bundle's names read assignments back into words")
    func names() {
        let known = KnownExperiments.byHash[MurmurHash3.hash32(name)]
        #expect(known?.label == "Voice Channel List Invite Embed")
        #expect(known?.kind == .guild)
        #expect(ExperimentBucket.title(2) == "Treatment 2")
    }
}
