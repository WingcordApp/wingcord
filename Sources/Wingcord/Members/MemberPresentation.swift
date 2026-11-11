import AppKit
import CoreGraphics
import Foundation
import WingcordCore

/// The member list beside the conversation on screen, as the column draws it.
///
/// **A server's list is Discord's, not a regrouping of whoever this client
/// holds** — see `MemberList`. Its groups come from the server and set the
/// column's whole height, and only the members the server has sent are built: the
/// few hundred rows around the viewport, however long the list is. Every other
/// row is a placeholder until its page arrives.
///
/// **Rows here are the column's, not the server's.** The two used to be one
/// number. A section that is collapsed, and a person moved up into Active Now,
/// are rows the server still counts and the column doesn't draw, so a section
/// carries where it came from (`RosterServerSpan`) and `serverRow(forView:)` turns
/// what's on screen back into what the subscription asks for.
nonisolated struct Roster: Equatable, Sendable {
    /// Which list this is. A different one starts at the top, as Discord's
    /// does: its list view is keyed on the list's id.
    var identity: String
    var sections: [RosterSection]
    /// The members the column can draw, by its own row.
    var members: [Int: MemberEntry]
    /// Every row the column draws, sent or not.
    var rowCount: Int

    static let empty = Roster(identity: "", sections: [], members: [:], rowCount: 0)

    /// The row of the server's list that a row of this column shows, or nil for
    /// one the client made up: Active Now's, a game's, a letter's.
    func serverRow(forView row: Int) -> Int? {
        guard !sections.isEmpty, row >= 0 else { return nil }
        var low = 0
        var high = sections.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if sections[mid].index <= row { low = mid } else { high = mid - 1 }
        }
        let section = sections[low]
        guard let span = section.span, row <= section.index + section.count else { return nil }
        var server = span.heading + (row - section.index)
        guard row > section.index else { return server }
        for hidden in span.hidden where hidden <= server { server += 1 }
        return server
    }
}

/// One group's heading, and where its rows are.
nonisolated struct RosterSection: Hashable, Sendable {
    /// What this is, to remember it collapsed.
    var key: MemberSectionKey
    /// The name. Nil for a letter, whose glyph is all it says, and for the group
    /// a list holds before the server has named any, which draws as a placeholder.
    var title: String?
    /// What follows the name: "1,204", "7+". Nil for Offline, as Discord has it
    /// (`t6`, `763349`), and for a letter.
    var countText: String?
    /// The hoisted role's colour, which the name is drawn in.
    var colorValue: UInt32?
    /// What sits in front of the name.
    var glyph: RosterGlyph = .none
    /// The heading's row. Its members are the `count` rows after it.
    var index: Int
    /// The rows drawn after it: none while collapsed.
    var count: Int
    var isCollapsed = false
    /// Whether a click folds it. A placeholder heading and a role's popout don't.
    var canCollapse = true
    /// Where it sits in the server's list. Nil for a section the client made up.
    var span: RosterServerSpan?
    var kind: RosterSectionKind = .standard

    /// The heading as one line, for VoiceOver.
    var label: String? {
        guard let title else { return nil }
        return countText.map { "\(title) · \($0)" } ?? title
    }

    var isPlaceholder: Bool { key == .unknown }
}

/// What a section's heading is.
nonisolated enum RosterSectionKind: Hashable, Sendable {
    /// A hairline, a glyph, a name, a count and a chevron.
    case standard
    /// A room some of a section's people are in (`nr`, `763349`).
    case voiceGroup(RosterVoiceGroup)
    /// The rest of a section, after its rooms. It has no heading to draw: the one
    /// above it speaks for it.
    case continuation
}

/// A room, as a section of the member list draws it.
nonisolated struct RosterVoiceGroup: Hashable, Sendable {
    var channelID: ChannelID
    var isStage: Bool
    /// Others in the room who aren't drawn: "3 others in voice".
    var extraCount: Int
    var isReaderIn: Bool
    var canJoin: Bool
}

/// The Join or Disconnect on a room's heading, while the pointer's in the room or
/// the reader is.
struct MemberVoiceButton: Equatable, Sendable, Identifiable {
    var channelID: ChannelID
    /// The heading's eyebrow, in the scroll view's own space.
    var frame: CGRect
    var isReaderIn: Bool
    var canJoin: Bool
    var id: UInt64 { channelID.rawValue }
}

/// What's in front of a section's name.
nonisolated enum RosterGlyph: Hashable, Sendable {
    case none
    /// Discord's four green lobes (`tU`, `763349`).
    case activeNow
    /// Its person with a green dot (`845311`).
    case online
    /// The offline ring.
    case offline
    /// A role's uploaded icon.
    case image(URL)
    /// A role's unicode emoji.
    case emoji(String)
    /// A game's picture, as a squircle, or nil where nothing has one yet.
    case game(URL?)
    /// A first letter, in place of a name.
    case letter(String)
}

/// Where a section of the column sits in the server's list.
nonisolated struct RosterServerSpan: Hashable, Sendable {
    /// Its heading's row in the server's list.
    var heading: Int
    /// Its rows the column shows somewhere else, in ascending order.
    var hidden: [Int] = []
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
nonisolated struct MemberEntry: Hashable, Sendable, Identifiable {
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
    /// Online in a headset — Discord's `isVROnline`.
    var isOnVR = false
    /// The device an online mark is drawn as.
    var client: PresenceClient { PresenceClient(isOnMobile: isOnMobile, isOnVR: isOnVR) }
    /// The line beneath the name — Discord's friends sidebar's (`MemberRowLine`).
    /// Nil collapses the row to one line.
    var line: MemberRowLine?
    var isBot: Bool
    /// A verified app's badge carries a check — `AppBadge`.
    var isVerifiedBot = false
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
    /// The picture at the row's trailing end: the game, or what's playing.
    var art: MemberRowArt?
    /// The game they're playing, which is what makes them Active Now and what a
    /// game's section gathers. Never set for an app: a bot's "Playing /help" is
    /// a slogan.
    var liveGame: MemberLiveGame?
    /// The line they get under that game's own heading, which already names it.
    var gameSectionLine: MemberRowLine?
    /// And under a room's: the game's words, or how long they've been there.
    var voiceGroupLine: MemberRowLine?
    /// And under a room's inside a game's section.
    var gameVoiceGroupLine: MemberRowLine?
    /// The room they're talking in, where the reader can see it.
    var voiceChannelID: ChannelID?
    /// That room, where the reader could join it and isn't already there —
    /// Discord's `B` (`tR`, `763349`). What puts Join Voice on the row.
    var joinableVoiceChannelID: ChannelID?
    /// Whether this row is the reader's: no Message on it.
    var isReader = false

    var id: UInt64 { userID.rawValue }

    /// Discord's test (`M`, `546359`): online, and playing or in a room. **Not an
    /// app**, and not somebody listening to something.
    var isActiveNow: Bool {
        guard !isBot, status != .offline, status != .unknown else { return false }
        return liveGame != nil || voiceChannelID != nil
    }

    /// How many buttons the row grows under the pointer — see
    /// `MemberRowGeometry.actionsWidth(count:)`.
    var actionCount: Int {
        1 + (isReader ? 0 : 1) + (joinableVoiceChannelID == nil ? 0 : 1)
    }
}

/// The row the pointer is on, for the glass buttons that sit on it.
struct MemberRowHover: Equatable, Sendable {
    var userID: UserID
    /// In the scroll view's own space: where it is on screen, whatever the scroll.
    var rowFrame: CGRect
    var isReader: Bool
    /// The room Join Voice would join, if it has that button.
    var joinableVoiceChannelID: ChannelID?
}

/// The picture at the end of a row.
nonisolated enum MemberRowArt: Hashable, Sendable {
    case image(URL)
    /// Something with an application and no picture yet — Discord's `tx.V` with
    /// no source. The row keeps its shape while the application is looked up.
    case placeholder(ActivityStatusLine.Glyph)
}

/// What somebody is playing.
nonisolated struct MemberLiveGame: Hashable, Sendable {
    /// Discord's `game:{application_id ?? name}`.
    var key: String
    var name: String
    var applicationID: ApplicationID?
    var artURL: URL?
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
    /// Discord's sidebar's 32 (`T._3.SIZE_32`), measured on Alex's screenshot 43.
    static let avatarSide: CGFloat = 32
    static let avatarGap: CGFloat = 8
    /// The owner's crown, beside a name.
    static let crownSide: CGFloat = 12
    /// How much of an offline row's content stays: decision 9 in `docs/MEMBER-LIST.md`.
    static let offlineInk: CGFloat = 0.45

    /// Every row, whether or not it carries a second line: a 48-point plate and a
    /// point either side — `32 + (8 + 1) * 2`, Discord's `rowHeight` (`nd`,
    /// `763349`), and 100 pixels apart on Alex's screenshot 41.
    ///
    /// **One height, deliberately.** A roster where the rows with an activity
    /// are eight points taller than the rows without one has a ragged rhythm
    /// down its whole length — and because a nameplate is drawn to the plate's
    /// height, two heights also means the same 672x126 strip is fitted two
    /// different ways in one list. The name centres itself when there is no
    /// second line; see `MemberRowPainter.drawMember`.
    static let rowHeight: CGFloat = 50

    // The picture at the row's end, and what takes its place under the pointer.

    /// The squircle: 32 points, Discord's `tx.V` at `size: 32`.
    static let artSide: CGFloat = 32
    /// `--radius-xs`, its `.contentImage`.
    static let artCorner: CGFloat = 4
    /// Between the words and it: the row's gap.
    static let artGap: CGFloat = 8
    /// A round glass button under the pointer: 32, Discord's `sm`.
    static let actionSide: CGFloat = 32
    /// Between them, Discord's `gap: var(--space-8)`.
    static let actionGap: CGFloat = 8
    /// Between the words and the first of them: `margin-inline-start: 4px`.
    static let actionsLeadingGap: CGFloat = 4

    /// What the buttons take from the row, the gap in front of them included.
    static func actionsWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * actionSide + CGFloat(count - 1) * actionGap + actionsLeadingGap
    }

    /// The picture's place: at the plate's end, centred on it.
    static func artRect(in rowFrame: CGRect) -> CGRect {
        let plate = plateRect(in: rowFrame)
        return CGRect(
            x: plate.maxX - contentInset - artSide,
            y: plate.midY - artSide / 2,
            width: artSide,
            height: artSide
        )
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

    /// The glyph in front of the activity: Discord's controller is 24x20 pixels on
    /// Alex's screenshot 43, and an SF `gamecontroller.fill` fitted to this comes
    /// out at 26x18.
    static let activityGlyphSide: CGFloat = 13
    /// A custom status's emoji: `--custom-activity-status-emoji-size: 12px`.
    static let statusEmojiSide: CGFloat = 12
    /// Between the pieces of the line: `gap: 4`.
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

/// A section heading's measurements — Discord's (`tX`, `tW`, `416852`, `945584`),
/// checked against Alex's screenshot 41: a hairline at y 191, the words' centre at
/// 219, the first row's at 259.
nonisolated enum MemberSectionGeometry {
    /// `24 + 12 + 4`, Discord's `sectionHeaderHeight`.
    static let height: CGFloat = 40
    /// With the `16` it puts above every heading but the first.
    static let separatedHeight: CGFloat = 56
    /// The band the glyph, the words and the chevron share.
    static let eyebrowHeight: CGFloat = 24
    /// Under it, before the first row.
    static let bottomPadding: CGFloat = 4
    /// From the top of a separated heading to its hairline.
    static let hairlineOffset: CGFloat = 12
    /// The column's edge to everything in a heading: the list's 8 and the
    /// eyebrow's 8.
    static let inset: CGFloat = 16
    /// The box the glyph is centred in: `.leading`'s 18.
    static let glyphBox: CGFloat = 18
    /// Between the box, the words and the chevron: the stack's 8.
    static let gap: CGFloat = 8
    /// The chevron's box: Discord's `xs`.
    static let chevronSide: CGFloat = 16

    static func eyebrow(in frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX,
            y: frame.maxY - bottomPadding - eyebrowHeight,
            width: frame.width,
            height: eyebrowHeight
        )
    }

    /// The glyph's box inside a heading's frame.
    static func glyphRect(in frame: CGRect) -> CGRect {
        let eyebrow = eyebrow(in: frame)
        return CGRect(
            x: frame.minX + inset,
            y: eyebrow.midY - glyphBox / 2,
            width: glyphBox,
            height: glyphBox
        )
    }
}

/// A room's section — Discord's `nr` (`763349`, `798350`): `2 * 16 + 24 + 4`, its
/// rows, and 24 more where it says who else is there.
nonisolated enum MemberVoiceGroupGeometry {
    static let padding: CGFloat = 16
    static let eyebrowHeight: CGFloat = 24
    static let gapToRows: CGFloat = 4
    static let extraHeight: CGFloat = 24
    /// How far the edge and the wash stop short of the group's top and foot.
    static let backgroundInset: CGFloat = 8

    static var headingHeight: CGFloat { padding + eyebrowHeight + gapToRows }

    static func footerHeight(extraCount: Int) -> CGFloat {
        padding + (extraCount > 0 ? extraHeight : 0)
    }

    static func eyebrow(in heading: CGRect) -> CGRect {
        CGRect(x: heading.minX, y: heading.minY + padding, width: heading.width, height: eyebrowHeight)
    }
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
///
/// **Every heading but the first is taller**, by the hairline and the air over it
/// — and the first too, when something sits above the roster.
nonisolated struct RosterLayout: Sendable {
    private(set) var sections: [RosterSection] = []
    /// The top of each section's heading.
    private var tops: [CGFloat] = []
    private(set) var rowCount = 0
    private(set) var contentHeight: CGFloat = 0
    private var separatesFirst = false

    /// A heading with nothing above it.
    static let headerHeight = MemberSectionGeometry.height
    static let memberHeight = MemberRowGeometry.rowHeight

    init() {}

    init(_ roster: Roster, separatesFirst: Bool = false) {
        sections = roster.sections
        self.separatesFirst = separatesFirst
        tops.reserveCapacity(sections.count)
        var top: CGFloat = 0
        for position in sections.indices {
            tops.append(top)
            top += headingHeight(position)
                + CGFloat(sections[position].count) * Self.memberHeight
                + footerHeight(position)
        }
        contentHeight = top
        rowCount = sections.last.map { $0.index + $0.count + 1 } ?? 0
    }

    private func headingHeight(_ position: Int) -> CGFloat {
        switch sections[position].kind {
        case .standard:
            isSeparated(position) ? MemberSectionGeometry.separatedHeight : MemberSectionGeometry.height
        case .voiceGroup:
            MemberVoiceGroupGeometry.headingHeight
        case .continuation:
            0
        }
    }

    private func footerHeight(_ position: Int) -> CGFloat {
        guard case .voiceGroup(let group) = sections[position].kind else { return 0 }
        return MemberVoiceGroupGeometry.footerHeight(extraCount: group.extraCount)
    }

    /// Whether a section's heading draws the hairline over it.
    func isSeparated(_ position: Int) -> Bool {
        guard sections[position].kind == .standard else { return false }
        return position > 0 || separatesFirst
    }

    /// The whole of a section's band: heading, rows and foot.
    func sectionFrame(_ position: Int, width: CGFloat) -> CGRect {
        CGRect(
            x: 0,
            y: tops[position],
            width: width,
            height: headingHeight(position)
                + CGFloat(sections[position].count) * Self.memberHeight
                + footerHeight(position)
        )
    }

    /// How tall everything under a heading is, down to the next heading of its own
    /// kind: its rows, and the rooms and the rest that belong to it. What a fold moves.
    func bodyHeight(ofSectionAt position: Int) -> CGFloat {
        var height = CGFloat(sections[position].count) * Self.memberHeight
        var next = position + 1
        while next < sections.count, sections[next].kind != .standard {
            height += sectionFrame(next, width: 0).height
            next += 1
        }
        return height
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
        let intoMembers = y - tops[low] - headingHeight(low)
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
        let height = headingHeight(position)
        guard index > heading else {
            return CGRect(x: 0, y: tops[position], width: width, height: height)
        }
        return CGRect(
            x: 0,
            y: tops[position] + height + CGFloat(index - heading - 1) * Self.memberHeight,
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
