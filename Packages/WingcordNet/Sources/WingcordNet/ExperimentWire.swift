import Foundation
import WingcordCore

// MARK: - READY's experiments, read
//
// Three arrays of bare positional arrays — Discord's experiment store reads
// them by index (`736056`'s `ei`, the apex store's `setExperimentAssignments`),
// and so does this. **Nothing here can fail READY**: every field is read with
// a fallback, an entry this cannot read is left out, and the arrays arrive as
// `JSONTree`, which decodes any shape.

enum ExperimentWire {

    /// READY's three, raw, as the Experiments page lists them.
    static func snapshot(experiments: JSONTree?, guild: JSONTree?, apex: JSONTree?) -> ExperimentSnapshot {
        ExperimentSnapshot(
            user: (experiments?.array ?? []).compactMap(user),
            guild: Dictionary(
                (guild?.array ?? []).compactMap(self.guild).map { ($0.hash, $0) },
                uniquingKeysWith: { first, _ in first }
            ),
            apex: self.apex(apex)
        )
    }

    /// `[hash, revision, bucket, override, population, hash_result, …]`.
    static func user(_ entry: JSONTree) -> UserExperimentAssignment? {
        guard let fields = entry.array, fields.count >= 5, let hash = fields[0].uint32 else { return nil }
        return UserExperimentAssignment(
            hash: hash,
            revision: fields[1].int ?? 0,
            bucket: fields[2].int ?? ExperimentBucket.control,
            isOverride: fields[3].int == 0,
            population: fields[4].int ?? 0
        )
    }

    /// `[hash, hash_key, revision, populations, overrides, overrides_formatted,
    /// holdout_name, holdout_bucket, aa_mode, trigger_debugging]`.
    static func guild(_ entry: JSONTree) -> GuildExperiment? {
        guard let fields = entry.array, fields.count >= 4, let hash = fields[0].uint32 else { return nil }
        func field(_ index: Int) -> JSONTree? { index < fields.count ? fields[index] : nil }
        var overrides: [UInt64: Int] = [:]
        for override in field(4)?.array ?? [] {
            guard let object = override.object, let bucket = object["b"]?.int else { continue }
            for id in object["k"]?.array ?? [] {
                if let value = id.string.flatMap(UInt64.init) ?? id.number.map({ UInt64($0) }) { overrides[value] = bucket }
            }
        }
        return GuildExperiment(
            hash: hash,
            hashKey: field(1)?.string,
            revision: field(2)?.int ?? 0,
            populations: (field(3)?.array ?? []).compactMap(population),
            overrides: overrides,
            overridesFormatted: (field(5)?.array ?? []).map { ($0.array ?? []).compactMap(population) },
            holdoutName: field(6)?.string,
            holdoutControlBucket: field(7)?.int
        )
    }

    /// `[[[bucket, [{s, e}]], …], [[filterHash, value], …]]` — Discord's `et`.
    static func population(_ entry: JSONTree) -> ExperimentPopulation? {
        guard let parts = entry.array, parts.count >= 1 else { return nil }
        let buckets: [ExperimentPopulation.Bucket] = (parts[0].array ?? []).compactMap { bucket in
            guard let pair = bucket.array, pair.count >= 2, let index = pair[0].int else { return nil }
            let ranges: [Range<Int>] = (pair[1].array ?? []).compactMap { range in
                guard let start = range.object?["s"]?.int, let end = range.object?["e"]?.int, end >= start else { return nil }
                return start..<end
            }
            return .init(bucket: index, ranges: ranges)
        }
        let filters = parts.count > 1 ? (parts[1].array ?? []).map(filter) : []
        return ExperimentPopulation(buckets: buckets, filters: filters)
    }

    /// One `[filterHash, [[keyHash, value], …]]` — Discord's `L` table.
    static func filter(_ entry: JSONTree) -> ExperimentFilter {
        guard let pair = entry.array, pair.count >= 2, let hash = pair[0].uint32,
              let kind = ExperimentFilter.kind(forHash: hash) else { return .unknown }
        let values = (pair[1].array ?? []).compactMap { item -> (UInt32, JSONTree)? in
            guard let parts = item.array, parts.count >= 2, let key = parts[0].uint32 else { return nil }
            return (key, parts[1])
        }
        func value(_ name: String) -> JSONTree? {
            let key = MurmurHash3.hash32(name)
            return values.first { $0.0 == key }?.1
        }
        // `R`: every range is `min_id` / `max_id`, whatever it measures.
        func uint64(_ tree: JSONTree?) -> UInt64? { tree?.string.flatMap(UInt64.init) ?? tree?.number.map { UInt64($0) } }
        func int(_ tree: JSONTree?) -> Int? { tree?.int ?? tree?.string.flatMap(Int.init) }
        let first = values.first?.1
        switch kind {
        case "guild_ids":
            return .guildIDs(Set((value("guild_ids")?.array ?? []).compactMap { uint64($0) }))
        case "guild_id_range":
            return .guildIDRange(min: uint64(value("min_id")), max: uint64(value("max_id")))
        case "guild_age_range_days":
            return .ageRangeDays(min: int(value("min_id")), max: int(value("max_id")))
        case "guild_member_count_range":
            return .memberCountRange(min: int(value("min_id")), max: int(value("max_id")))
        case "guild_has_feature":
            return .hasFeature(Set((first?.array ?? []).compactMap(\.string)))
        case "guild_hub_types":
            return .hubTypes(Set((first?.array ?? []).compactMap(\.int)))
        case "guild_has_vanity_url":
            return .hasVanityURL(first?.bool ?? false)
        case "guild_in_range_by_hash":
            let key = value("hash_key").flatMap { $0.string ?? $0.number.map { String(Int($0)) } } ?? ""
            return .inRangeByHash(hashKey: key, target: int(value("target")) ?? 0)
        default:
            return .unknown
        }
    }

    /// `{assignments: {<unit>: {<id>: {evaluation_id, assignments: [[hash,
    /// variant, flags, revision, tracked, config]]}}}}` — every unit's.
    static func apex(_ tree: JSONTree?) -> [ApexAssignment] {
        var out: [ApexAssignment] = []
        for unit in tree?.object?["assignments"]?.object?.values ?? [:].values {
            for entity in unit.object?.values ?? [:].values {
                for entry in entity.object?["assignments"]?.array ?? [] {
                    guard let fields = entry.array, fields.count >= 2, let hash = fields[0].uint32 else { continue }
                    let flags = fields.count > 2 ? fields[2].int ?? 0 : 0
                    out.append(ApexAssignment(
                        hash: hash,
                        variantID: fields[1].int ?? 0,
                        isOverride: flags & ApexAssignment.overrideFlag != 0,
                        revision: fields.count > 3 ? fields[3].int ?? 0 : 0
                    ))
                }
            }
        }
        return out
    }
}

extension JSONTree {
    var array: [JSONTree]? { if case .array(let value) = self { value } else { nil } }
    var object: [String: JSONTree]? { if case .object(let value) = self { value } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var number: Double? { if case .number(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var int: Int? { number.flatMap { $0.rounded() == $0 ? Int(exactly: $0) : nil } }
    /// A hash: an unsigned 32-bit number — Discord's `v3` never goes negative.
    var uint32: UInt32? { number.flatMap { $0 >= 0 && $0 <= Double(UInt32.max) ? UInt32($0) : nil } }
}
