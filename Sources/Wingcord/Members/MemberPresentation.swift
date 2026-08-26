import CoreGraphics
import Foundation
import WingcordCore

/// One grouping in the member list: a hoisted role, or Online / Offline.
struct MemberSection: Hashable, Sendable, Identifiable {
    /// Nil for the two synthetic groups.
    var roleID: RoleID?
    var title: String
    var count: Int
    /// The hoisted role's colour, which the heading is drawn in.
    var colorValue: UInt32?
    var members: [MemberEntry]

    var id: UInt64 { roleID?.rawValue ?? (title == "Online" ? 1 : 2) }
}

/// One person in the member list.
///
/// **`nameplateURL` is here from the first version even though nameplates are
/// not fetched yet, and that is deliberate.** A nameplate is full-row artwork
/// drawn *behind* the row, and retrofitting one into a row design that never
/// reserved a background layer means changing the row's height, its insets and
/// its text colours all at once — which is a redesign, not a feature. Reserving
/// the slot now costs one optional URL and makes adding them later a painter
/// change and nothing else.
struct MemberEntry: Hashable, Sendable, Identifiable {
    var userID: UserID
    var name: String
    /// The highest coloured role's colour, or nil for the default.
    var colorValue: UInt32?
    var avatarURL: URL?
    var monogram: String
    var decorationURL: URL?
    var status: PresenceStatus
    var isOnMobile: Bool
    /// The activity or custom-status line beneath the name. Nil collapses the
    /// row to one line.
    var subtitle: String?
    var isBot: Bool
    /// The clan / guild tag chip beside the name.
    var tag: String?
    /// Full-row artwork drawn behind everything else.
    var nameplateURL: URL?

    var id: UInt64 { userID.rawValue }
}

/// Where each piece of a member row lands.
///
/// **The plate rect is computed for every row whether or not there is artwork**,
/// which is what makes a nameplate a paint-time addition rather than a layout
/// change: rows are the same height and the same shape with or without one, so a
/// list of mixed rows has no ragged edge and adding plates reflows nothing.
nonisolated enum MemberRowGeometry {
    static let horizontalMargin: CGFloat = 8
    static let contentInset: CGFloat = 8
    static let avatarSide = Metrics.avatarRow
    static let avatarGap: CGFloat = 8
    static let sectionHeaderHeight: CGFloat = 28
    static let sectionSpacing: CGFloat = 6

    /// One line: avatar, name.
    static let singleLineHeight: CGFloat = 38
    /// Two lines: avatar, name, activity.
    static let doubleLineHeight: CGFloat = 46

    static func height(for entry: MemberEntry) -> CGFloat {
        entry.subtitle == nil ? singleLineHeight : doubleLineHeight
    }

    /// The rounded rect the row's own surface occupies — the hover fill, the
    /// selection pill, and the nameplate artwork all use exactly this.
    static func plateRect(in rowFrame: CGRect) -> CGRect {
        rowFrame.insetBy(dx: horizontalMargin, dy: 1)
    }

    static func avatarRect(in rowFrame: CGRect) -> CGRect {
        let plate = plateRect(in: rowFrame)
        return CGRect(
            x: plate.minX + contentInset,
            y: plate.midY - avatarSide / 2,
            width: avatarSide,
            height: avatarSide
        )
    }

    static func textOriginX(in rowFrame: CGRect) -> CGFloat {
        avatarRect(in: rowFrame).maxX + avatarGap
    }

    /// The width nameplate art is fetched at.
    ///
    /// A plate spans the whole row, so this is a row's width rather than an
    /// avatar's. Asking for an avatar-sized rendition of a 672px strip and then
    /// aspect-filling it across the column is how a plate ends up visibly soft.
    static let nameplateWidth: CGFloat = 400
}

/// One flattened row of the member list.
///
/// Flat, like the timeline, and for the same reason: the row at a scroll offset
/// is found by binary search over one array, and a nested sections-containing-
/// members shape would need that search to descend.
nonisolated enum MemberRow: Sendable {
    case header(title: String, count: Int, colorValue: UInt32?)
    case member(MemberEntry)

    var height: CGFloat {
        switch self {
        case .header: MemberRowGeometry.sectionHeaderHeight + MemberRowGeometry.sectionSpacing
        case .member(let entry): MemberRowGeometry.height(for: entry)
        }
    }

    var userID: UserID? {
        if case .member(let entry) = self { return entry.userID }
        return nil
    }
}

nonisolated extension Array where Element == MemberSection {
    /// Flattens sections into rows.
    func flattened() -> [MemberRow] {
        var rows: [MemberRow] = []
        rows.reserveCapacity(reduce(0) { $0 + $1.members.count + 1 })
        for section in self {
            guard !section.members.isEmpty else { continue }
            rows.append(.header(
                title: section.title,
                count: section.count,
                colorValue: section.colorValue
            ))
            for member in section.members { rows.append(.member(member)) }
        }
        return rows
    }
}
