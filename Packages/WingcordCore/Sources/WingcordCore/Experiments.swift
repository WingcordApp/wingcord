import Foundation

// MARK: - Discord's experiments
//
// What READY says the account and its servers are in (`experiments`,
// `guild_experiments`, `apex_experiments`), and Discord's own evaluation of a
// server's — `ExperimentStore.getGuildExperimentDescriptor` in web build 641803
// (module `736056`), line for line. Shown read-only in Settings › Advanced ›
// Experiments (docs/CLIPS-PRESENCE.md, D26), and asked by the one surface that
// follows one: a voice invite's channel-list card
// (`2026-05_voice_channel_list_invite_embed`).
//
// **Every name is known by its hash.** Assignments carry `murmurhash.v3(name)`,
// never the name; `KnownExperiments` is the bundle's list to read them with.

public enum ExperimentBucket {
    /// Discord's `NOT_ELIGIBLE` — the population says no.
    public static let notEligible = -1
    /// `CONTROL`.
    public static let control = 0

    /// "Control", "Treatment 1"…
    public static func title(_ bucket: Int) -> String {
        switch bucket {
        case notEligible: "Not eligible"
        case control: "Control"
        default: "Treatment \(bucket)"
        }
    }
}

/// One of the account's own experiments — an entry of READY's `experiments`:
/// `[hash, revision, bucket, override, population, hash_result, aa_mode, …]`.
public struct UserExperimentAssignment: Hashable, Sendable {
    public var hash: UInt32
    public var revision: Int
    public var bucket: Int
    /// **Zero on the wire means overridden** — Discord's `override: 0 === o`.
    public var isOverride: Bool
    public var population: Int

    public init(hash: UInt32, revision: Int, bucket: Int, isOverride: Bool, population: Int) {
        self.hash = hash
        self.revision = revision
        self.bucket = bucket
        self.isOverride = isOverride
        self.population = population
    }
}

/// A server experiment's rollout — an entry of READY's `guild_experiments`.
public struct GuildExperiment: Hashable, Sendable {
    public var hash: UInt32
    /// What a position is hashed from instead of the name, when set.
    public var hashKey: String?
    public var revision: Int
    public var populations: [ExperimentPopulation]
    /// Servers put straight into a bucket, by id.
    public var overrides: [UInt64: Int]
    /// Populations tried before the rollout's own, as overrides.
    public var overridesFormatted: [[ExperimentPopulation]]
    public var holdoutName: String?
    public var holdoutControlBucket: Int?

    public init(
        hash: UInt32, hashKey: String? = nil, revision: Int = 0, populations: [ExperimentPopulation] = [],
        overrides: [UInt64: Int] = [:], overridesFormatted: [[ExperimentPopulation]] = [],
        holdoutName: String? = nil, holdoutControlBucket: Int? = nil
    ) {
        self.hash = hash
        self.hashKey = hashKey
        self.revision = revision
        self.populations = populations
        self.overrides = overrides
        self.overridesFormatted = overridesFormatted
        self.holdoutName = holdoutName
        self.holdoutControlBucket = holdoutControlBucket
    }
}

/// One population: which servers it takes (`filters`, all of them) and which
/// bucket each slice of positions falls in.
public struct ExperimentPopulation: Hashable, Sendable {
    public var buckets: [Bucket]
    public var filters: [ExperimentFilter]

    public struct Bucket: Hashable, Sendable {
        public var bucket: Int
        /// Positions `start..<end`, out of 10 000.
        public var ranges: [Range<Int>]

        public init(bucket: Int, ranges: [Range<Int>]) {
            self.bucket = bucket
            self.ranges = ranges
        }
    }

    public init(buckets: [Bucket], filters: [ExperimentFilter] = []) {
        self.buckets = buckets
        self.filters = filters
    }
}

/// Discord's filter table (`736056`'s `L`), each keyed on the wire by the
/// murmur hash of its name.
public enum ExperimentFilter: Hashable, Sendable {
    case guildIDs(Set<UInt64>)
    case guildIDRange(min: UInt64?, max: UInt64?)
    case ageRangeDays(min: Int?, max: Int?)
    case memberCountRange(min: Int?, max: Int?)
    case hasFeature(Set<String>)
    case hubTypes(Set<Int>)
    case hasVanityURL(Bool)
    case inRangeByHash(hashKey: String, target: Int)
    /// One this build does not know. **It passes**, as in Discord, where an
    /// unknown filter parses to null and the population loop skips it.
    case unknown

    /// The wire's key for each, `murmurhash.v3(name)`.
    public static func kind(forHash hash: UInt32) -> String? {
        names[hash]
    }

    static let names: [UInt32: String] = Dictionary(uniqueKeysWithValues: [
        "guild_ids", "guild_id_range", "guild_age_range_days", "guild_member_count_range",
        "guild_has_feature", "guild_hub_types", "guild_has_vanity_url", "guild_in_range_by_hash",
    ].map { (MurmurHash3.hash32($0), $0) })
}

/// What a server's filters are asked about.
public struct ExperimentGuildFacts: Hashable, Sendable {
    public var id: UInt64
    public var features: Set<String>
    public var memberCount: Int?
    public var hubType: Int?
    public var hasVanityURL: Bool

    public init(id: UInt64, features: Set<String> = [], memberCount: Int? = nil, hubType: Int? = nil, hasVanityURL: Bool = false) {
        self.id = id
        self.features = features
        self.memberCount = memberCount
        self.hubType = hubType
        self.hasVanityURL = hasVanityURL
    }

    /// The server's age in whole days, read off its id as Discord reads it.
    func ageInDays(now: Date) -> Int {
        let millis = Double((id >> 22) + 1_420_070_400_000)
        return Int((now.timeIntervalSince1970 * 1000 - millis) / 86_400_000)
    }
}

public enum Experiments {

    /// A server's bucket in an experiment, or nil where it is not in it —
    /// Discord's `getGuildExperimentDescriptor`:
    ///
    /// 1. an override by id wins (unless it is "not eligible");
    /// 2. the position is `v3("<hashKey or name>:<id>") % 10000`;
    /// 3. the override populations, then the rollout's own: the first whose
    ///    filters all pass gives the bucket its position falls in, Control
    ///    where none covers it, nothing where it is "not eligible";
    /// 4. a holdout whose control bucket the server is in takes it back out.
    public static func guildBucket(
        _ name: String,
        guild: ExperimentGuildFacts,
        in experiments: [UInt32: GuildExperiment],
        now: Date = .now
    ) -> Int? {
        guard let experiment = experiments[MurmurHash3.hash32(name)] else { return nil }
        if let forced = experiment.overrides[guild.id] {
            return forced == ExperimentBucket.notEligible ? nil : forced
        }
        let position = Self.position(experiment.hashKey ?? name, guildID: guild.id)
        for populations in experiment.overridesFormatted {
            if let bucket = evaluate(populations, guild: guild, position: position, now: now) { return bucket }
        }
        guard let bucket = evaluate(experiment.populations, guild: guild, position: position, now: now) else { return nil }
        if let holdout = experiment.holdoutName, let control = experiment.holdoutControlBucket, holdout != name,
           guildBucket(holdout, guild: guild, in: experiments, now: now) == control {
            return nil
        }
        return bucket
    }

    /// `murmurhash.v3("<key>:<id>") % 1e4`.
    public static func position(_ key: String, guildID: UInt64) -> Int {
        Int(MurmurHash3.hash32("\(key):\(guildID)") % 10_000)
    }

    /// Discord's `er`.
    static func evaluate(_ populations: [ExperimentPopulation], guild: ExperimentGuildFacts, position: Int, now: Date) -> Int? {
        for population in populations {
            guard population.filters.allSatisfy({ passes($0, guild: guild, now: now) }) else { continue }
            let bucket = population.buckets.first { $0.ranges.contains { $0.contains(position) } }?.bucket
                ?? ExperimentBucket.control
            return bucket == ExperimentBucket.notEligible ? nil : bucket
        }
        return nil
    }

    static func passes(_ filter: ExperimentFilter, guild: ExperimentGuildFacts, now: Date) -> Bool {
        switch filter {
        case .guildIDs(let ids): ids.contains(guild.id)
        case .guildIDRange(let min, let max): within(guild.id, min, max)
        case .ageRangeDays(let min, let max): within(guild.ageInDays(now: now), min, max)
        case .memberCountRange(let min, let max): guild.memberCount.map { within($0, min, max) } ?? false
        case .hasFeature(let features): !features.isDisjoint(with: guild.features)
        case .hubTypes(let types): guild.hubType.map(types.contains) ?? false
        case .hasVanityURL(let wanted): guild.hasVanityURL == wanted
        case .inRangeByHash(let key, let target):
            // **Doubled when positive**, as the source writes it:
            // `(i > 0 ? i + i : i >>> 0) % 1e4 < target`.
            { let hash = UInt64(MurmurHash3.hash32("\(key):\(guild.id)")); return Int((hash > 0 ? hash * 2 : hash) % 10_000) < target }()
        case .unknown: true
        }
    }

    private static func within<T: Comparable>(_ value: T, _ min: T?, _ max: T?) -> Bool {
        !(min.map { value < $0 } ?? false) && !(max.map { value > $0 } ?? false)
    }
}

/// Discord's apex experiments — the newer system: per unit (the user, the
/// installation, a guild) a list of `[hashedName, variantId, flags, revision,
/// trackedVariantId, config]`.
public struct ApexAssignment: Hashable, Sendable {
    public var hash: UInt32
    public var variantID: Int
    public var isOverride: Bool
    public var revision: Int

    /// `flags & IsOverride`.
    public static let overrideFlag = 1

    public init(hash: UInt32, variantID: Int, isOverride: Bool, revision: Int) {
        self.hash = hash
        self.variantID = variantID
        self.isOverride = isOverride
        self.revision = revision
    }
}

/// Everything READY said, as the Experiments page lists it.
public struct ExperimentSnapshot: Hashable, Sendable {
    public var user: [UserExperimentAssignment]
    public var guild: [UInt32: GuildExperiment]
    public var apex: [ApexAssignment]

    public init(user: [UserExperimentAssignment] = [], guild: [UInt32: GuildExperiment] = [:], apex: [ApexAssignment] = []) {
        self.user = user
        self.guild = guild
        self.apex = apex
    }

    public var isEmpty: Bool { user.isEmpty && guild.isEmpty && apex.isEmpty }
}
