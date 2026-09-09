import AppKit
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
/// **The nameplate slot was reserved a version before anything filled it, and
/// that is what made filling it cheap.** A nameplate is full-row artwork drawn
/// *behind* the row, and retrofitting one into a row design that never reserved
/// a background layer means changing the row's height, its insets and its text
/// colours all at once — which is a redesign, not a feature. Because the plate
/// rect, the paint order and the scrim were already there, turning them on cost
/// two fields here, a URL builder, and no layout change at all.
struct MemberEntry: Hashable, Sendable, Identifiable {
    var userID: UserID
    var name: String
    /// The highest coloured role's colour, or nil for the default.
    var colorValue: UInt32?
    var avatarURL: URL?
    var monogram: String
    var decorationURL: URL?
    /// The face this person's display name is set in, or nil for the app's own.
    ///
    /// **The face only, not the whole style.** A roster holds five hundred of
    /// these and the effect's colours are needed for exactly one row at a time —
    /// the hovered one — which the store can answer directly. Carrying the
    /// palette here would put a heap array on every row to serve none of them.
    ///
    /// Discord's own dialog says colours and effects do not appear in servers,
    /// and this is what that means in practice: the face carries over, the
    /// colour stays the role's.
    var displayNameFont: DisplayNameFont?
    var status: PresenceStatus
    var isOnMobile: Bool
    /// The activity or custom-status line beneath the name. Nil collapses the
    /// row to one line.
    var subtitle: String?
    var isBot: Bool
    /// The clan / guild tag chip beside the name.
    var tag: String?
    /// The tag's guild badge, drawn inside the chip. A tag without it is only
    /// half the mark people recognise.
    var tagBadgeURL: URL?
    /// Full-row artwork drawn behind everything else.
    var nameplateURL: URL?
    /// The same artwork moving, played on the row under the pointer and on no
    /// other. See `MemberListCanvas` for the clock that drives it.
    var nameplateAnimatedURL: URL?
    /// The colour that artwork names itself with.
    ///
    /// Carried as the palette rather than as a resolved colour so the painter
    /// can key its gradient cache on it — a raw colour value would have to be
    /// turned into a `CGGradient` inside the draw, once per plated row per
    /// repaint. `.none` is a real answer and means a plate with no wash.
    var nameplatePalette: NameplatePalette = .none
    /// Whether this person owns the conversation.
    ///
    /// A group DM's creator, drawn with a crown after their name. **Only ever
    /// true in a group**: a guild has an owner too, and Discord marks them the
    /// same way — but a guild roster is grouped by hoisted role and the owner is
    /// already at the top of it, so a second mark there says nothing the reader
    /// did not already know.
    var isOwner: Bool = false

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
    /// The owner's crown, beside a name.
    static let crownSide: CGFloat = 12
    static let sectionHeaderHeight: CGFloat = 28
    static let sectionSpacing: CGFloat = 6

    /// Every row, whether or not it carries a second line.
    ///
    /// **One height, deliberately.** A roster where the rows with an activity
    /// are eight points taller than the rows without one has a ragged rhythm
    /// down its whole length — and because a nameplate is drawn to the plate's
    /// height, two heights also means the same 672x126 strip is fitted two
    /// different ways in one list. The name centres itself when there is no
    /// second line; see `MemberRowPainter.drawMember`.
    static let rowHeight: CGFloat = 46

    static func height(for entry: MemberEntry) -> CGFloat { rowHeight }

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

    // The tag chip beside a name — a clan tag, or the APP mark. Its width is
    // reserved before the name is drawn and its parts are drawn afterwards, so
    // every number below is read twice and must be read from one place.

    static let tagChipHeight: CGFloat = 15
    /// Each side, inside the chip.
    static let tagChipPadding: CGFloat = 5
    /// Between the name and the chip.
    static let tagChipGap: CGFloat = 5
    /// The guild badge drawn inside a clan tag.
    static let tagBadgeSide: CGFloat = 11
    /// Between that badge and the letters.
    static let tagBadgeGap: CGFloat = 3
    /// Built once. `NSFont.systemFont` goes through the font manager, and this
    /// is asked for twice per tagged row per repaint.
    ///
    /// `nonisolated(unsafe)` for the same reason `MessageTextStyle` is
    /// `@unchecked Sendable`: an `NSFont` is immutable once created and
    /// documented as safe to read from any thread, and this one is never
    /// written after launch.
    nonisolated(unsafe) static let tagChipFont = NSFont.systemFont(ofSize: 9, weight: .bold)

    /// How wide a chip holding `textWidth` of letters comes out.
    ///
    /// The reservation and the draw both call this. Two hand-written sums that
    /// have to agree is how a chip ends up with its padding pooled on one side.
    static func tagChipWidth(textWidth: CGFloat, hasBadge: Bool) -> CGFloat {
        tagChipPadding * 2 + textWidth
            + (hasBadge ? tagBadgeSide + tagBadgeGap : 0)
    }

    /// Where a nameplate's artwork lands inside its plate.
    ///
    /// **Fit to the plate's HEIGHT, anchored to its trailing edge**, and
    /// overflowing the leading edge when that makes it wider than the plate.
    ///
    /// Established by measuring Discord's own roster rather than by choosing:
    /// on a reference row whose plate is 540x87 device pixels, the roses begin
    /// at x=345. Fitting the strip to the plate's *width* puts them at 311;
    /// fitting to its height and hanging it off the trailing edge puts them at
    /// 347. Two pixels, against a thirty-four pixel error.
    ///
    /// The rule matters because the plate's proportions are not the strip's.
    /// A 672x126 strip is 5.33 wide; a two-line plate is about 5.0 and a
    /// one-line plate about 6.1 — so the same naive aspect-*fill* fits to the
    /// height on one row and to the width on the other, and the second of those
    /// stretches the strip vertically. Roses come out as ellipses on exactly
    /// half the roster, which is the kind of defect that is invisible on an
    /// abstract gradient and unmissable on anything with a shape in it.
    ///
    /// Its own function because the painter and its test have to agree about a
    /// rectangle neither can see.
    static func nameplateArtRect(in plate: CGRect, imagePixelSize: CGSize) -> CGRect {
        let aspect = imagePixelSize.width / max(imagePixelSize.height, 1)
        let width = (plate.height * aspect).rounded()
        return CGRect(
            x: plate.maxX - width,
            y: plate.minY,
            width: width,
            height: plate.height
        )
    }

    /// The width nameplate art is fetched and drawn at, in points.
    ///
    /// **The strip's width at the plate's height**, which is the only number
    /// that is right: a plate is fitted to its HEIGHT and hung off its trailing
    /// edge — see `nameplateArtRect` for the measurement that settled it — so
    /// the strip comes out five and a third times the plate's height and never
    /// the row's width.
    ///
    /// This used to be a flat 400, a row's width, and it over-fetched by 70%:
    /// the still was decoded at the source's full 672 pixels for a picture
    /// drawn at 470. It matters more now than it did, because the moving form
    /// is thirty-nine of those.
    static let nameplateArtWidth: CGFloat = ((rowHeight - 2) * Nameplate.artworkAspect)
        .rounded()
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
