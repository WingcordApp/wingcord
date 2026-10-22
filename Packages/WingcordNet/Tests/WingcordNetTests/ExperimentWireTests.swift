import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// READY's experiment arrays, read by position as Discord's store reads them.
struct ExperimentWireTests {
    private func h(_ name: String) -> UInt32 { MurmurHash3.hash32(name) }

    private func tree(_ json: String) throws -> JSONTree {
        try JSONDecoder().decode(JSONTree.self, from: Data(json.utf8))
    }

    @Test("A user assignment: zero in the override slot means overridden")
    func user() throws {
        let snapshot = ExperimentWire.snapshot(
            experiments: try tree("[[\(h("2021-10_runtime_accessibility_system")),3,1,0,2,4321,0,0],[12345,1,0,-1,0,0,0,0]]"),
            guild: nil, apex: nil
        )
        #expect(snapshot.user.count == 2)
        #expect(snapshot.user[0].bucket == 1)
        #expect(snapshot.user[0].isOverride)
        #expect(!snapshot.user[1].isOverride)
        #expect(KnownExperiments.byHash[snapshot.user[0].hash]?.label == "Runtime Accessibility System")
    }

    @Test("A server rollout: populations, filters by hashed name, overrides by id")
    func guild() throws {
        let name = "2026-05_voice_channel_list_invite_embed"
        let json = """
        [[\(h(name)),null,2,
          [[[[1,[{"s":0,"e":5000}]],[2,[{"s":5000,"e":10000}]]],
            [[\(h("guild_has_feature")),[[\(h("guild_features")),["COMMUNITY"]]]],
             [\(h("guild_member_count_range")),[[\(h("min_id")),100],[\(h("max_id")),null]]],
             [999,[[1,2]]]]]],
          [{"b":3,"k":["1520000000000000001"]}],
          [],null,null,0,0]]
        """
        let snapshot = ExperimentWire.snapshot(experiments: nil, guild: try tree(json), apex: nil)
        let experiment = try #require(snapshot.guild[h(name)])
        #expect(experiment.revision == 2)
        #expect(experiment.overrides[1_520_000_000_000_000_001] == 3)
        let population = try #require(experiment.populations.first)
        #expect(population.buckets.map(\.bucket) == [1, 2])
        #expect(population.buckets[0].ranges == [0..<5000])
        #expect(population.filters == [.hasFeature(["COMMUNITY"]), .memberCountRange(min: 100, max: nil), .unknown])

        let member = ExperimentGuildFacts(id: 42, features: ["COMMUNITY"], memberCount: 300)
        let bucket = Experiments.guildBucket(name, guild: member, in: snapshot.guild)
        #expect(bucket == (Experiments.position(name, guildID: 42) < 5000 ? 1 : 2))
        let overridden = ExperimentGuildFacts(id: 1_520_000_000_000_000_001)
        #expect(Experiments.guildBucket(name, guild: overridden, in: snapshot.guild) == 3)
    }

    @Test("Apex assignments from every unit, the override bit read")
    func apex() throws {
        let json = """
        {"assignments":{"1":{"987654321987654321":{"evaluation_id":"e","assignments":[[\(h("2025-04-native-markdown")),2,1,4,2,null],[77,1,0,1,1,null]]}}}}
        """
        let snapshot = ExperimentWire.snapshot(experiments: nil, guild: nil, apex: try tree(json))
        #expect(snapshot.apex.count == 2)
        let first = try #require(snapshot.apex.first { $0.hash == h("2025-04-native-markdown") })
        #expect(first.variantID == 2)
        #expect(first.isOverride)
        #expect(KnownExperiments.byHash[first.hash]?.isApex == true)
    }

    @Test("Shapes this cannot read are left out, never fatal")
    func lenient() throws {
        let snapshot = ExperimentWire.snapshot(
            experiments: try tree(#"[["x"],[1],null,{"a":1}]"#),
            guild: try tree(#"[[1,null,0,"nope"],"x"]"#),
            apex: try tree(#""weird""#)
        )
        #expect(snapshot.user.isEmpty)
        #expect(snapshot.guild[1]?.populations.isEmpty == true)
        #expect(snapshot.apex.isEmpty)
    }
}
