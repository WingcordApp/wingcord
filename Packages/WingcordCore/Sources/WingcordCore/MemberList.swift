import Foundation

/// One of a server's member lists, as Discord's server lays it out.
///
/// **The server owns the list and this mirrors it.** Discord groups, sorts and
/// counts a server's members itself, and sends the result as rows at absolute
/// positions — a heading for each group, then that group's members — for the
/// ranges a client subscribes to. A client that groups whichever members it
/// happens to hold gets the counts wrong and stops where its one page ends:
/// "Level 20 — 11" for a group of 101, and a column that ends at the
/// hundredth row.
///
/// Every update carries the groups, and the groups fix the whole list's shape:
/// each is one heading plus `count` rows. So the column is its full height
/// before anything past the first page has arrived, and a row nobody has sent
/// yet is a hole that draws as a placeholder. Only rows the server has sent are
/// held, so a list of a million people costs the few hundred around the
/// viewport.
///
/// Discord's own store is `ChannelMemberStore` (module 963307), and every rule
/// here is its rule.
public struct MemberList: Hashable, Sendable {

    /// What a group gathers.
    public enum GroupID: Hashable, Sendable {
        case role(RoleID)
        case online
        case offline
        /// The one group a list holds before the server has described it.
        case unknown

        public init(wire: String) {
            switch wire {
            case "online": self = .online
            case "offline": self = .offline
            default: self = RoleID(wire).map { .role($0) } ?? .unknown
            }
        }
    }

    /// One group: a heading, and the `count` members after it.
    public struct Group: Hashable, Sendable {
        public var id: GroupID
        public var count: Int

        public init(id: GroupID, count: Int) {
            self.id = id
            self.count = max(0, count)
        }
    }

    /// What sits at one position.
    ///
    /// **A heading is a row too.** The server counts it in every index it sends,
    /// so it is held like any other row even though the column draws headings
    /// from `groups`, which is where Discord's list draws them from as well.
    public enum Row: Hashable, Sendable {
        case group(GroupID)
        case member(UserID)
    }

    /// One change the server made to the list.
    public enum Operation: Hashable, Sendable {
        /// The rows from `start` on, in order. Nil is a row this client could
        /// not read, and is left as a hole rather than dropped — dropping it
        /// would move every row after it up by one.
        case sync(start: Int, rows: [Row?])
        /// The server has stopped keeping these rows current.
        case invalidate(ClosedRange<Int>)
        case insert(Int, Row?)
        case update(Int, Row?)
        case delete(Int)
    }

    /// Rows a subscription asks for at a time.
    public static let pageSize = 100

    public private(set) var groups: [Group]
    /// Where each group's heading sits; its members are the rows after it.
    public private(set) var headingIndexes: [Int]
    /// The rows the server has sent and not taken back, by position.
    public private(set) var rows: [Int: Row]
    /// Every position in the list, sent or not.
    public private(set) var rowCount: Int

    /// A list the server has said nothing about: one heading for a group it has
    /// not named, which is how Discord's store starts one.
    public init() {
        groups = [Group(id: .unknown, count: 0)]
        headingIndexes = [0]
        rows = [:]
        rowCount = 1
    }

    /// Applies one `GUILD_MEMBER_LIST_UPDATE`: its operations in order, then its
    /// groups, which set where every heading sits and how long the list is.
    ///
    /// Two of Discord's rules are deliberately not copied. Its `DELETE` of a
    /// row it never received does nothing, and its `INVALIDATE` stops at the
    /// first such row; both leave the rows after them at stale positions. Here
    /// a delete always closes the gap and an invalidation drops its whole range.
    public mutating func apply(_ operations: [Operation], groups: [Group]) {
        for operation in operations {
            switch operation {
            case .sync(let start, let synced):
                for (offset, row) in synced.enumerated() { place(row, at: start + offset) }
            case .invalidate(let range):
                rows = rows.filter { !range.contains($0.key) }
            case .insert(let index, let row):
                shift(from: index, by: 1)
                place(row, at: index)
            case .update(let index, let row):
                place(row, at: index)
            case .delete(let index):
                rows[index] = nil
                shift(from: index + 1, by: -1)
            }
        }

        self.groups = groups
        var next = 0
        headingIndexes = groups.map { group in
            defer { next += group.count + 1 }
            return next
        }
        rowCount = next
        if rows.keys.contains(where: { $0 >= rowCount }) {
            rows = rows.filter { $0.key < rowCount }
        }
    }

    private mutating func place(_ row: Row?, at index: Int) {
        guard index >= 0 else { return }
        rows[index] = row
    }

    /// Moves every held row at or after `index` by `delta`, as a splice would.
    private mutating func shift(from index: Int, by delta: Int) {
        guard rows.keys.contains(where: { $0 >= index }) else { return }
        var moved: [Int: Row] = [:]
        moved.reserveCapacity(rows.count)
        for (position, row) in rows {
            moved[position >= index ? position + delta : position] = row
        }
        rows = moved
    }
}

extension MemberList {

    /// Which list a channel shows — Discord's rule, module 963307's `v`.
    ///
    /// **"everyone" when the server's @everyone role may view channels and no
    /// overwrite here takes that away**, which is the one list most channels
    /// share. Otherwise the list is named by which overwrites grant or deny
    /// viewing, so channels with the same audience share one list whatever
    /// else their overwrites say. The server may name a channel's list itself,
    /// and then that name wins.
    ///
    /// For a channel with a list of its own. A thread shows its parent's.
    public static func id(for channel: Channel, everyonePermissions: Permissions) -> String {
        if let memberListID = channel.memberListID { return memberListID }
        if everyonePermissions.contains(.viewChannel),
           !channel.overwrites.contains(where: { $0.deny.contains(.viewChannel) })
        {
            return "everyone"
        }
        let audience = channel.overwrites.compactMap { overwrite -> String? in
            if overwrite.allow.contains(.viewChannel) { return "allow:\(overwrite.id)" }
            if overwrite.deny.contains(.viewChannel) { return "deny:\(overwrite.id)" }
            return nil
        }
        return String(MurmurHash3.hash32(audience.sorted().joined(separator: ",")))
    }

    /// The pages to subscribe to while rows `visible` are on screen, with
    /// `margin` rows either side — Discord's rule, module 361610.
    ///
    /// **Always the first page**, which is where the list's top groups are,
    /// then every page the widened range touches.
    public static func pages(visible: ClosedRange<Int>, margin: Int) -> [ClosedRange<Int>] {
        var pages: [ClosedRange<Int>] = []
        var first = max(0, visible.lowerBound - margin)
        let last = visible.upperBound + margin
        if first > 0 {
            pages.append(0...pageSize - 1)
            first = max(pageSize, first)
        }
        first = first / pageSize * pageSize
        while first <= last {
            pages.append(first...first + pageSize - 1)
            first += pageSize
        }
        return pages
    }
}
