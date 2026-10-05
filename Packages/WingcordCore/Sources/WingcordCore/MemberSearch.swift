import Foundation

/// The Members page's search — Discord's member-safety query (`144073`).
///
/// **Ten facets, one request.** Every filter the page offers is a field of
/// this value, and `DiscordREST.searchMembers` turns it into the body Discord's
/// own builder makes: the text becomes `usernames` and `user_id` terms, the
/// four safety flags go into `or_query`, everything else into `and_query`.
public struct MemberSearchQuery: Hashable, Sendable {
    /// Usernames and ids, comma-separated — Discord's own field takes both.
    public var text: String
    public var requiresUnusualDMActivity: Bool
    public var requiresTimeout: Bool
    public var requiresUnusualAccountActivity: Bool
    public var requiresQuarantine: Bool
    public var roleIDs: Set<RoleID>
    /// Member Since — when they joined the server.
    public var joined: DateRange
    /// Joined Discord — when the account was made, searched as a snowflake
    /// range over the user id.
    public var accountCreated: DateRange
    public var sourceInviteCode: String?
    public var joinSourceType: Int?
    public var sort: GuildMemberRow.Sort

    public init(
        text: String = "",
        requiresUnusualDMActivity: Bool = false,
        requiresTimeout: Bool = false,
        requiresUnusualAccountActivity: Bool = false,
        requiresQuarantine: Bool = false,
        roleIDs: Set<RoleID> = [],
        joined: DateRange = .all,
        accountCreated: DateRange = .all,
        sourceInviteCode: String? = nil,
        joinSourceType: Int? = nil,
        sort: GuildMemberRow.Sort = .joinedNewest
    ) {
        self.text = text
        self.requiresUnusualDMActivity = requiresUnusualDMActivity
        self.requiresTimeout = requiresTimeout
        self.requiresUnusualAccountActivity = requiresUnusualAccountActivity
        self.requiresQuarantine = requiresQuarantine
        self.roleIDs = roleIDs
        self.joined = joined
        self.accountCreated = accountCreated
        self.sourceInviteCode = sourceInviteCode
        self.joinSourceType = joinSourceType
        self.sort = sort
    }

    /// The page's heading: "Recent Members" for the default query, "Search
    /// Results" once anything narrows it (`hasDefaultSearchStateByGuildId`).
    public var isDefault: Bool {
        var defaults = MemberSearchQuery()
        defaults.sort = sort
        return self == defaults
    }

    /// Whether any of the four safety flags is on — the Signals column's
    /// filter is lit.
    public var filtersSignals: Bool {
        requiresUnusualDMActivity || requiresTimeout || requiresUnusualAccountActivity
            || requiresQuarantine
    }

    /// The text, split the way Discord splits it (`859126`): comma-separated
    /// terms, a snowflake is an id and anything else a username. Nothing for a
    /// single character, which Discord does not search on.
    public var terms: (usernames: [String], userIDs: [String]) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 1 else { return ([], []) }
        var usernames: [String] = []
        var ids: [String] = []
        for part in trimmed.split(separator: ",") {
            let term = part.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty else { continue }
            if term.count >= 17, term.allSatisfy(\.isNumber) { ids.append(term) } else { usernames.append(term) }
        }
        return (usernames, ids)
    }

    /// How long unusual DM activity counts as a signal — Discord's `tX`.
    public static let unusualDMWindow: TimeInterval = 2 * 86400
}

/// A date filter: one of Discord's presets, or a custom range.
public struct DateRange: Hashable, Sendable {
    public enum Preset: Int, CaseIterable, Identifiable, Sendable {
        case all = 0, pastHour, pastDay, pastWeek, pastTwoWeeks, pastFourWeeks, pastThreeMonths, custom

        public var id: Int { rawValue }

        public var title: String {
            switch self {
            case .all: "All"
            case .pastHour: "Past 1 hr"
            case .pastDay: "Past 24 hrs"
            case .pastWeek: "Past 7 days"
            case .pastTwoWeeks: "Past 2 weeks"
            case .pastFourWeeks: "Past 4 weeks"
            case .pastThreeMonths: "Past 3 months"
            case .custom: "Custom Range"
            }
        }

        /// The start of a preset's window, counted back from `now`.
        public func after(_ now: Date, calendar: Calendar = .current) -> Date? {
            switch self {
            case .all, .custom: nil
            case .pastHour: now.addingTimeInterval(-3600)
            case .pastDay: now.addingTimeInterval(-86400)
            case .pastWeek: now.addingTimeInterval(-7 * 86400)
            case .pastTwoWeeks: now.addingTimeInterval(-14 * 86400)
            case .pastFourWeeks: now.addingTimeInterval(-28 * 86400)
            case .pastThreeMonths: calendar.date(byAdding: .month, value: -3, to: now)
            }
        }
    }

    public var preset: Preset
    public var after: Date?
    public var before: Date?

    public init(preset: Preset = .all, after: Date? = nil, before: Date? = nil) {
        self.preset = preset
        self.after = after
        self.before = before
    }

    public static let all = DateRange()

    /// A preset, its window fixed at the moment it was chosen — as Discord's
    /// menu does (`moment().subtract(...)` when picked).
    public static func preset(_ preset: Preset, now: Date = .now) -> DateRange {
        DateRange(preset: preset, after: preset.after(now), before: nil)
    }

    /// Whether it narrows anything — an `after` is what Discord tests.
    public var isActive: Bool { after != nil }
}

/// Where the next page of the members table starts — the last row's join time
/// and id, which is what Discord's cursor holds (`vf`).
public struct MemberSearchCursor: Hashable, Sendable {
    public var joinedAt: Date
    public var userID: UserID

    public init(joinedAt: Date, userID: UserID) {
        self.joinedAt = joinedAt
        self.userID = userID
    }
}

/// A snowflake that names an instant — the lower bound of an id range.
public enum SnowflakeTime {
    public static let discordEpochMilliseconds: UInt64 = 1_420_070_400_000

    public static func snowflake(at date: Date) -> UInt64 {
        let milliseconds = UInt64(max(0, date.timeIntervalSince1970 * 1000))
        guard milliseconds > discordEpochMilliseconds else { return 0 }
        return (milliseconds - discordEpochMilliseconds) << 22
    }
}

/// One page of the members table, and how many match in all.
public struct MemberSearchPage: Hashable, Sendable {
    public var rows: [GuildMemberRow]
    public var total: Int

    public init(rows: [GuildMemberRow], total: Int) {
        self.rows = rows
        self.total = total
    }

    /// Where the page after this one starts, or nil where there is none.
    public var nextCursor: MemberSearchCursor? {
        guard let last = rows.last, let joinedAt = last.joinedAt else { return nil }
        return MemberSearchCursor(joinedAt: joinedAt, userID: last.id)
    }
}
