import AppKit
import CoreGraphics
import Foundation
import WingcordCore

/// The member list beside the conversation on screen, as the column draws it.
///
/// **A server's list is Discord's, not a regrouping of whoever this client
/// holds** — see `MemberList`. Its headings come from the list's groups and
/// set the column's whole height, and only the members the server has sent are
/// built: the few hundred rows around the viewport, however long the list is.
/// Every other row is a placeholder until its page arrives.
struct Roster: Equatable, Sendable {
    /// Which list this is. A different one starts at the top, as Discord's
    /// does: its list view is keyed on the list's id.
    var identity: String
    var sections: [RosterSection]
    /// The members the server has sent, by row.
    var members: [Int: MemberEntry]
    /// Every row, sent or not.
    var rowCount: Int

    static let empty = Roster(identity: "", sections: [], members: [:], rowCount: 0)
}

/// One group's heading, and where its rows are.
struct RosterSection: Hashable, Sendable {
    /// The words and the count, built once — "Moderators — 1,204". Nil for the
    /// group a list holds before the server has named any, which draws as a
    /// placeholder.
    var label: String?
    /// The hoisted role's colour, which the heading is drawn in.
    var colorValue: UInt32?
    /// The hoisted role's own mark, drawn before its name. Nil for Online,
    /// Offline, and every role that has not set one.
    var iconURL: URL?
    /// The heading's row. Its members are the `count` rows after it.
    var index: Int
    var count: Int
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
    /// **The enhanced role style's stops**, from the same role `colorValue`
    /// came from, already wrapped back to the first colour — nil for the
    /// ordinary roles, which is nearly all of them.
    ///
    /// Packed values rather than `Color`, because this is read by a painter off
    /// the main actor and a `Color` cannot be asked for its channels there.
    var gradient: [UInt32]?
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
    /// The line beneath the name — what they are doing and their custom
    /// status, as Discord draws it. Nil collapses the row to one line.
    var activityLine: ActivityStatusLine?
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
    /// Whether they are typing in the channel on screen right now.
    ///
    /// **A fact about the CHANNEL, carried on the roster's row.** Typing is
    /// scoped to a conversation — `box.typing` — and the member list is drawn
    /// beside one, so the person who is typing in the channel the reader is
    /// looking at is the person whose row says so. Somebody typing in a
    /// different channel of the same server is not this.
    var isTyping: Bool = false

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

    // The line under a name — see `MemberRowPainter.drawActivityLine`. The
    // painter and the prefetch both read these, and the emoji's side is half of
    // the image key the painter peeks with.

    /// The glyph in front of the activity.
    static let activityGlyphSide: CGFloat = 12
    /// A custom status's emoji.
    static let statusEmojiSide: CGFloat = 14
    /// Between the pieces of the line.
    static let activityGap: CGFloat = 4

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

    /// The hoisted role's mark in a section heading. Matched to the label's
    /// cap height rather than to its line box, so a heading with a mark and one
    /// without sit on the same baseline.
    static let sectionIconSide: CGFloat = 14

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

/// What sits at one row of the member list.
nonisolated enum MemberRow: Sendable {
    case header(RosterSection)
    case member(MemberEntry)
    /// A member the server has not sent yet.
    case placeholder

    var userID: UserID? {
        if case .member(let entry) = self { return entry.userID }
        return nil
    }
}

/// Where every row of a roster sits.
///
/// **Arithmetic, not a table.** A row is a heading or a member and both have a
/// fixed height, so a row's position is a count over the sections before it —
/// nothing here walks the rows, and a list of a million people costs one entry
/// per group. The table this replaces held an offset per row and was rebuilt
/// whenever anybody's presence moved.
nonisolated struct RosterLayout: Sendable {
    private(set) var sections: [RosterSection] = []
    /// The top of each section's heading.
    private var tops: [CGFloat] = []
    private(set) var rowCount = 0
    private(set) var contentHeight: CGFloat = 0

    static let headerHeight = MemberRowGeometry.sectionHeaderHeight + MemberRowGeometry.sectionSpacing
    static let memberHeight = MemberRowGeometry.rowHeight

    init() {}

    init(_ roster: Roster) {
        sections = roster.sections
        tops.reserveCapacity(sections.count)
        var top: CGFloat = 0
        for section in sections {
            tops.append(top)
            top += Self.headerHeight + CGFloat(section.count) * Self.memberHeight
        }
        contentHeight = top
        rowCount = sections.last.map { $0.index + $0.count + 1 } ?? 0
    }

    /// The row at `y`, clamped to the list: above the top is the first row and
    /// below the end is the last.
    func index(at y: CGFloat) -> Int? {
        guard rowCount > 0 else { return nil }
        guard y > 0 else { return 0 }
        guard y < contentHeight else { return rowCount - 1 }
        var low = 0
        var high = tops.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if tops[mid] <= y { low = mid } else { high = mid - 1 }
        }
        let section = sections[low]
        let intoMembers = y - tops[low] - Self.headerHeight
        guard intoMembers >= 0, section.count > 0 else { return section.index }
        return section.index + 1 + min(Int(intoMembers / Self.memberHeight), section.count - 1)
    }

    /// The section a row belongs to: its heading's, or the one it is a member of.
    func sectionIndex(containing index: Int) -> Int {
        var low = 0
        var high = sections.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if sections[mid].index <= index { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The row's band, full width.
    func frame(at index: Int, width: CGFloat) -> CGRect {
        let position = sectionIndex(containing: index)
        let heading = sections[position].index
        guard index > heading else {
            return CGRect(x: 0, y: tops[position], width: width, height: Self.headerHeight)
        }
        return CGRect(
            x: 0,
            y: tops[position] + Self.headerHeight + CGFloat(index - heading - 1) * Self.memberHeight,
            width: width,
            height: Self.memberHeight
        )
    }

    /// What sits at a row, from the roster this layout was made from.
    func row(at index: Int, in roster: Roster) -> MemberRow {
        let section = sections[sectionIndex(containing: index)]
        if index == section.index { return .header(section) }
        return roster.members[index].map { .member($0) } ?? .placeholder
    }
}
