import SwiftUI
import WingcordCore

// MARK: - Palette
//
// The chrome's three grounds and its one accent, plus the fills that are defined
// *relative* to them. Everything else in this app that carries colour carries it
// because a person chose it — an avatar, a banner, a role, a piece of media.
//
// THIS USED TO SAY there was deliberately no theme system, and that a second
// palette would be a new decision rather than a slot waiting to be filled. It is
// now that decision, and it is scoped exactly as narrowly as that note asked
// for: a theme moves `canvas`, `surface`, `surfaceRaised` and `accent`, and
// touches nothing else in this file. The reasoning, the ramp and the ten themes
// are in `Theme.swift`; how a value written on the main actor reaches a painter
// running off it is in `ThemeRuntime.swift`.
//
// **The relative fills stay relative.** A hover is white at 7%, a selection
// white at 15%, a flyout tint white at 8% — the surface *plus light*, which is
// the only definition that survives the system glass-intensity setting, Reduce
// Transparency, and a wallpaper showing through the sidebar column. Baking a
// theme colour into any of them breaks all three, and would also make them wrong
// over a backdrop picture, which is a ground this app does not choose.
//
// THE ONE MACOS DIFFERENCE, and it decides where these may be used:
// `NavigationSplitView`'s sidebar column is painted by AppKit with behind-window
// vibrancy. That vibrancy IS the bleed — the wallpaper and the menu-bar accent
// coming through the leading columns. Painting `canvas` over the sidebar throws
// it away. So `canvas` belongs to the DETAIL column and to floating panels; the
// rail and the channel list get `sidebarGround()`, which paints nothing until a
// theme or a picture gives it something to paint.

nonisolated enum Palette {
    /// The reading surface. #0A0A0C untouched, and near-black rather than pure
    /// black on purpose: Liquid Glass needs something behind it to lens and
    /// refract, and #000 makes every glass surface read as a flat grey panel.
    /// Every derived theme keeps that property — the ramp's darkest rung is
    /// Oklab L 0.10, which is not black either.
    ///
    /// Applied to the detail column only. See the note above.
    static var canvas: Color { Color(hex: ThemeAccess.colors.canvas) }

    /// Structural, non-floating surfaces: panel grounds, grouped row
    /// backgrounds, the opaque layer that scrolls *underneath* glass.
    static var surface: Color { Color(hex: ThemeAccess.colors.surface) }

    /// A slightly lifted structural surface, for a grouped row inside `surface`.
    static var surfaceRaised: Color { Color(hex: ThemeAccess.colors.surfaceRaised) }

    /// The selected channel's pill, and the travelling selection indicator, at
    /// rest.
    ///
    /// **White at 15%, not an opaque grey.** The pill is the surface *plus
    /// light*, so it is defined relative to whatever is behind it rather than as
    /// a colour of its own — which is the only definition that survives the
    /// system glass-intensity setting, Reduce Transparency, and the wallpaper
    /// showing through the sidebar column. An absolute hex here cannot stay
    /// correct, because on this platform the ground behind it is the user's
    /// desktop.
    static let selectionFill = Color.white.opacity(0.15)

    /// A row under the pointer, before it is selected. Half the selection's
    /// weight: a hover must be legible as *not yet chosen*.
    static let hoverFill = Color.white.opacity(0.07)

    /// The single accent. Used only for: primary buttons, the send arrow, focus
    /// rings. Nothing else in the chrome.
    ///
    /// **The house theme has none of its own and tracks the system's**, which is
    /// what makes Wingcord's blue agree with every other app on the Mac and what
    /// carries Increase Contrast for free. A theme that states a hue is opting
    /// out of that deliberately — it is the one saturated thing in a themed
    /// window, and it would be strange for a green room to send with a blue
    /// arrow.
    static var accent: Color {
        guard let value = ThemeAccess.colors.accent else { return Color.accentColor }
        return Color(hex: value)
    }

    /// Destructive actions only — Delete, Block, Leave, Disconnect.
    static let destructive = Color.red

    /// Affirmative call actions only (Accept).
    static let affirmative = Color.green

    /// What a clear-glass flyout is tinted with.
    ///
    /// **Clear glass over near-black has nothing to refract and disappears** —
    /// §4 — so a floating card that may land over an empty stretch of transcript
    /// needs a value of its own to be seen at rest. Kept low: past about a tenth
    /// the surface stops lensing what passes beneath and starts reading as a
    /// painted panel, which is the thing it is being rescued from.
    static let flyoutTint = Color.white.opacity(0.08)

    /// The ground under a custom status bubble, and under its tail.
    ///
    /// **A fixed scrim rather than a material.** It sits over a banner the
    /// reader did not choose and which may be animated, and §4 sends anything
    /// over moving artwork to a scrim for exactly that reason: a sampled
    /// material cannot promise the sentence on top of it stays legible frame to
    /// frame. Near-opaque, so white text clears it over a white banner.
    ///
    /// Themed, because it is a *surface* rather than a relative fill — it is
    /// `surface` with a hole punched in it, and a grey bubble on a green card
    /// would read as a piece of another app.
    static var statusBubble: Color { surface.opacity(0.92) }

    /// Muted conversations render badges in this instead of `unreadBadge`, so a
    /// muted unread never competes with a live one.
    static let mutedBadge = Color(hex: 0x6E6E76)

    /// Every unread badge in the app. Discord's own red rather than
    /// `destructive` — nothing is being destroyed, and sharing the token would
    /// make the two impossible to retune apart.
    static let unreadBadge = Color(hex: 0xF23F43)

    // MARK: Presence
    //
    // Discord's presence vocabulary. Content colours, not chrome: they describe
    // a person's state, so they are allowed to be coloured.

    static let presenceOnline = Color(hex: 0x23A55A)
    static let presenceIdle = Color(hex: 0xF0B232)
    static let presenceDoNotDisturb = Color(hex: 0xF23F43)
    static let presenceOffline = Color(hex: 0x80848E)
}

// MARK: - Foreground hierarchy
//
// Text legibility on glass comes from *vibrancy and weight*, never from making
// the material more opaque. These map to SwiftUI's hierarchical styles, which
// the system renders vibrantly against whatever is behind the glass and which
// honour Increase Contrast automatically. Do not replace them with fixed greys:
// a hardcoded #FFFFFF-at-60% adapts to nothing and fails contrast checks.

nonisolated enum Ink {
    /// Names, message bodies, primary labels.
    static let primary = HierarchicalShapeStyle.primary
    /// Timestamps, message previews, secondary metadata.
    static let secondary = HierarchicalShapeStyle.secondary
    /// Placeholder text, disabled glyphs, the least important line in a row.
    static let tertiary = HierarchicalShapeStyle.tertiary
    /// Separators and the faintest structural marks.
    static let quaternary = HierarchicalShapeStyle.quaternary
}

/// Concrete `Color` twins of `Ink`, for text that must hold a **fixed** value
/// regardless of what is behind it.
///
/// These are for text over **artwork** — a banner, a cover, a video frame —
/// where vibrancy composites against a picture nobody chose and the result is
/// unreadable rather than merely quiet. Everywhere else `Ink` is correct,
/// materials included; reaching for a fixed colour to "fix" quiet text on a
/// material fixes nothing while making the label stop tracking vibrancy,
/// Increase Contrast and the system glass-intensity setting.
///
/// Not `Color.primary` / `Color.secondary` — those *are* the hierarchy under
/// another name and behave identically, so reaching for them changes nothing
/// while looking like it should.
nonisolated enum InkColor {
    static let primary = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let tertiary = Color(nsColor: .tertiaryLabelColor)
}

// MARK: - Spacing

nonisolated enum Spacing {
    /// Hairline gap inside a control — a glyph to its own label.
    static let hair: CGFloat = 2
    /// Tight pairing — a name and its inline badge.
    static let tight: CGFloat = 4
    /// The base unit. Header cluster gaps, composer padding.
    static let base: CGFloat = 8
    /// Between related rows and inside grouped containers.
    static let snug: CGFloat = 12
    /// Standard leading/trailing column margin.
    static let margin: CGFloat = 16
    /// Between distinct groups in a panel.
    static let group: CGFloat = 24
    /// Between major sections.
    static let section: CGFloat = 32
}

// MARK: - Corner radii

/// The silhouette the app's two floating bars take.
///
/// **One value for both, and it is the reader's.** The now bar and the composer
/// are the same object in two places — a floating glass plate at the foot of a
/// column — so a preference that changed one and not the other would be a window
/// with two opinions about its own shape. Which one is right is genuinely taste,
/// which is exactly what a setting is for.
enum ChromeShape: String, CaseIterable, Sendable, Codable {
    /// Fully rounded ends. The shape a floating bar takes when it is read as an
    /// object rather than as a region.
    case pill
    /// A rounded rectangle at the house radius, so the bar reads as a panel of
    /// the same family as every card in the app.
    case boxy

    var label: String {
        switch self {
        case .pill: "Pill"
        case .boxy: "Boxy"
        }
    }

    var symbolName: String {
        switch self {
        case .pill: "capsule"
        case .boxy: "rectangle.roundedtop"
        }
    }

    /// The corner for a bar of this height.
    ///
    /// A capsule is not a constant — it is half the height — so the two answers
    /// cannot both be written down, and a hard-coded radius for the pill is
    /// wrong the moment the bar grows a line.
    ///
    /// **Boxy is `Radius.chip`, not `Radius.glass`, and that is the difference
    /// between a setting and a no-op.** The house glass radius is eighteen; a
    /// composer at rest is thirty-eight points tall, so its capsule radius is
    /// nineteen — the two answers were one point apart and the picker changed
    /// nothing anybody could see. Ten reads as a rounded rectangle at both bar
    /// heights, which is what the choice is actually between.
    func cornerRadius(forHeight height: CGFloat) -> CGFloat {
        switch self {
        case .pill: max(0, height / 2)
        case .boxy: Radius.chip
        }
    }
}

nonisolated enum Radius {
    /// Small inline chips — folder chips, tag chips, role chips.
    static let chip: CGFloat = 10
    /// Rows that carry a selection pill, and the category header capsule.
    static let row: CGFloat = 8
    /// Message bubbles.
    static let bubble: CGFloat = 16
    /// The house radius for floating glass rects — popovers, cards, panels.
    static let glass: CGFloat = 18
    /// Larger lifted surfaces: the profile card, the banner block.
    static let card: CGFloat = 24
}

// MARK: - Metrics
//
// Intrinsic *control* sizes only — the height of a bar, the diameter of an
// avatar. These are legitimately fixed because they describe the control, not
// the window it sits in.
//
// Anything describing window geometry — column widths, panel widths — belongs in
// `Proportions`, or is handed to the split view as a min/ideal/max triple and
// left to the system.
//
// THE MACOS SCALE. iOS Wingcord's row metrics are built around a 44pt tap
// target and a finger's imprecision. A pointer has neither constraint, and a
// desktop window has to show a server's whole channel tree without scrolling.
// Every row height here is therefore smaller than its iOS counterpart, and that
// is a deliberate re-tune rather than drift: the app is denser because the
// input device is precise.

nonisolated enum Metrics {
    // Anything containing text is a MINIMUM height, never a fixed one, and is
    // applied with `.frame(minHeight:)`. These are the heights at the default
    // text size; a user who has raised it gets taller rows, not clipped ones.

    /// A channel row, a member row, a DM row. 28 is the system's own list-row
    /// height in Finder's sidebar and Mail's, and matching it is what makes the
    /// column read as part of the OS rather than as a web page.
    static let rowMinHeight: CGFloat = 28
    /// A direct-message row: an avatar, a name with whatever style its owner
    /// chose, and a line for what they are doing.
    ///
    /// **One height whether or not there is a second line**, for the reason the
    /// roster's is one — see `MemberRowGeometry.rowHeight`. A list whose rows
    /// change height as people start and stop doing things reflows under the
    /// reader, and a nameplate fitted to the row's height would be fitted two
    /// different ways in one column.
    static let directMessageRowHeight: CGFloat = 46

    /// A category disclosure header. Shorter than a row: it is a label, not a
    /// destination.
    static let categoryMinHeight: CGFloat = 24

    /// Circular glass buttons in the toolbar and in floating clusters.
    static let control: CGFloat = 28

    /// The smaller circles inside the now bar, which share a capsule with each
    /// other and must not out-weigh the identity beside them.
    static let compactControl: CGFloat = 26

    /// A control in the full profile's floating action dock: the friend pill's
    /// height and the two circles beside it.
    ///
    /// **One number for all three**, because the dock is one object and a pill
    /// two points taller than the circle next to it is the kind of thing nobody
    /// can name and everybody sees. 46 in the design handoff, at its 1,280-point
    /// sheet; this column is 0.797 of that.
    static let profileDockControl: CGFloat = 37

    /// The now bar's own height — the floating identity capsule at the foot of
    /// the sidebar.
    static let nowBarHeight: CGFloat = 46

    /// The composer's text box. Its capsule adds `Spacing.tight` above and
    /// below, so the row measures `composerControlHeight`; that, not this, is
    /// what the controls flanking it match.
    static let composerFieldMinHeight: CGFloat = 30

    /// The composer row's **outside** height: the field's capsule, and every
    /// circle beside it.
    static let composerControlHeight: CGFloat = composerFieldMinHeight + Spacing.tight * 2

    /// The composer stops growing here and starts scrolling internally.
    static let composerMaxLines = 12

    // MARK: Avatars

    /// The guild rail's tiles.
    static let guildTile: CGFloat = 44
    /// Member rows, DM rows, the now bar.
    static let avatarRow: CGFloat = 26
    /// The message author gutter.
    static let avatarMessage: CGFloat = 38
    /// Inline in a reply quote or a preview.
    static let avatarInline: CGFloat = 16
    /// The profile card's hero.
    static let avatarProfile: CGFloat = 80

    /// Avatar decorations draw at this multiple of the avatar's diameter and are
    /// *not* clipped by the avatar's circular mask.
    static let decorationScale: CGFloat = 1.2

    // MARK: Content

    /// The tallest a single attachment is drawn in a transcript. A cap on
    /// HEIGHT only — width is whatever the message column can spare, which is
    /// what makes a wide screenshot readable. Without it a 3:4 phone photo takes
    /// the whole viewport and the transcript becomes a slideshow.
    static let attachmentMaxHeight: CGFloat = 350

    /// Each thumbnail when one message carries several.
    static let attachmentThumbnail: CGFloat = 170

    /// The picture block on a forum post's gallery card.
    ///
    /// Fixed rather than aspect-derived: a grid whose cards are each as tall as
    /// their own screenshot is a grid with ragged rows, and the picture is a
    /// hint about the post rather than the post.
    static let forumCardArtHeight: CGFloat = 150
    /// The narrowest a gallery card is allowed to get before the grid drops a
    /// column. Wide enough for a two-line title and three tag chips.
    static let forumCardMinimum: CGFloat = 260

    /// The picture on a forum post's row.
    ///
    /// Square, and small enough that the title beside it still gets two lines at
    /// the narrowest the column goes to — the picture is a hint about the post,
    /// not the post.
    static let forumThumbnail: CGFloat = 64

    /// The widest an embed card is drawn. Capped rather than full-width: an
    /// embed is a card *inside* a message, and one that runs the whole column
    /// reads as the message rather than as something attached to it.
    static let embedMaxWidth: CGFloat = 432

    /// A custom emoji inlined in a run of text. Sized to sit on a body line
    /// rather than to the asset's own resolution.
    static let inlineEmojiSide: CGFloat = 20

    /// A sticker drawn inside a message. Not a thumbnail of anything larger —
    /// this *is* the sticker's size.
    static let stickerInline: CGFloat = 160

    // MARK: Discovery

    /// The narrowest a discovery card is drawn before the grid drops a column.
    ///
    /// Wide enough for a two-line server name over a three-line description with
    /// the counts under it — which is what a card carries, and what decides
    /// whether a grid of them is scannable or a wall.
    static let discoveryCardWidth: CGFloat = 300
    /// The wide artwork across a card's head. Two to one, which is the shape
    /// every `discovery_splash` in the captures is authored at.
    static let discoveryCardArt: CGFloat = discoveryCardWidth / 2
    /// The server's own mark, overlapping the artwork's foot.
    ///
    /// A squircle rather than a circle: this is a *server*, and every other
    /// place in the app that draws one — the rail, the forward sheet, the tag
    /// card — draws it as a rounded square.
    static let discoveryCardIcon: CGFloat = 44

    // MARK: Activities

    /// An app's icon on a launcher list row.
    /// The application mark beside a command row, and in the composer's command
    /// chip. Smaller than a directory row's: this is a list of *commands*, and
    /// the icon is there to say whose rather than to be looked at.
    static let commandRowIcon: CGFloat = 22

    /// A command or argument chip in the composer. Two points inside the text
    /// field's own minimum, so a bar holding chips is exactly as tall as one
    /// holding a caret and the composer does not jump when a command starts.
    static let commandChipHeight: CGFloat = composerFieldMinHeight - 4

    static let activityRowIcon: CGFloat = 34
    /// An app's icon in the Recents strip. Larger than a list row's, because
    /// the icon is the only thing that row carries — there is no name beside it.
    static let activityRecentIcon: CGFloat = 40
    /// The game's mark on the preview's return bar.
    ///
    /// **The same square asset the board rows use, drawn larger.** Discord does
    /// the same thing on this bar rather than shipping a second rendition, and
    /// a mark is authored to read at a glance — it survives the scale where a
    /// slice of portrait box art would not.
    static let previewReturnIcon: CGFloat = 34
    /// One featured tile's artwork, two across the flyout's inner width.
    static let activityTileWidth: CGFloat = 168
    /// That artwork's height. 16:9, which is the shape every `embedded_cover`
    /// in the captured shelf is drawn at.
    static let activityTileArt: CGFloat = activityTileWidth * 9 / 16
    /// The icon over the top of an app's own page, overlapping its hero.
    static let activityHeaderIcon: CGFloat = 64
    /// The app icon on an invitation card in the transcript.
    static let activityInviteIcon: CGFloat = 64
}

// MARK: - Proportions
//
// Column geometry, expressed as the triple the split view actually wants.
// Hardcoding a sidebar width and enforcing it by hand is what `pane-model`
// warns against; these are advisory numbers handed to the system, which holds
// them because the detail column never changes type.

nonisolated enum Proportions {
    /// The guild rail. Fixed: it holds one column of 44pt tiles and has no
    /// reason to be resizable.
    static let railWidth: CGFloat = 68

    /// The channel column beside the rail, as min/ideal/max. The sidebar column
    /// the split view owns is the rail plus this.
    ///
    /// **Deliberately narrow.** The sidebar is a *table of contents*, not a
    /// second reading surface: every point it takes comes out of the transcript,
    /// which is the thing the window exists to show. 220 fits the longest
    /// channel names people actually use and truncates the rest, which is the
    /// correct trade — a column wide enough for the worst name is a column
    /// mostly full of empty space. The reference clients land at the same place;
    /// this totals 288 against their ~298.
    static let channelColumnMin: CGFloat = 180
    static let channelColumnIdeal: CGFloat = 220
    static let channelColumnMax: CGFloat = 300

    static var sidebarMin: CGFloat { railWidth + channelColumnMin }
    static var sidebarIdeal: CGFloat { railWidth + channelColumnIdeal }
    static var sidebarMax: CGFloat { railWidth + channelColumnMax }

    static let memberColumnIdeal: CGFloat = 236

    /// The thread panel beside a transcript.
    ///
    /// Wider than the roster, because this column holds a *conversation* rather
    /// than a list of names: message text at the roster's width wraps every four
    /// or five words, which reads as a column of fragments. Narrower than the
    /// transcript it sits beside, so it stays legible as the secondary of the
    /// two.
    static let threadColumnIdeal: CGFloat = 340

    /// The same panel, when what is in it is a forum post.
    ///
    /// **Wider, because the roles are reversed.** Beside a transcript the thread
    /// is the aside and the conversation is the page; beside a *board* the post
    /// is the page and the list is the index you came in through. It gets the
    /// room accordingly — the board still shows a readable row at what is left.
    static let postColumnIdeal: CGFloat = 460

    /// The profile column beside a direct message.
    ///
    /// The pane insets its rounded box by `Spacing.base` on every side, so the
    /// column it occupies is this plus twice that — see
    /// `DirectMessageProfilePane`.
    ///
    /// Wider than the member list because it holds one person rather than a
    /// list of names: a banner, an avatar with its decoration, a bio and a role
    /// flow all need room the roster's 236 does not have, and a profile squeezed
    /// into a roster's width is a column of two-word lines.
    static let profileColumnIdeal: CGFloat = 288

    /// Channels & Roles, which is the one server page with something beside its
    /// content: the reader's own profile as that server sees them.
    ///
    /// **Both of its tabs use it**, though only one has the aside. A measure
    /// that changed between tabs would move the floating bar and the headings
    /// under it every time somebody switched, which reads as the page being
    /// rebuilt rather than as one page with two halves.
    static let surfaceColumnWide: CGFloat = 940

    /// The profile aside inside that measure. Narrow on purpose: it is a
    /// summary of a person, not a profile card — the card is one click away on
    /// the now bar and has room for the rest.
    static let surfaceAsideWidth: CGFloat = 236

    /// The channel preview beside a server's own page.
    ///
    /// Wider than the roster and narrower than a reading column: it holds a
    /// transcript, which needs room for an avatar gutter and a line of prose,
    /// and it is a *peek* — a preview that takes half the window has replaced
    /// the page it was meant to sit beside.
    static let previewColumnIdeal: CGFloat = 340

    /// The search panel's column.
    ///
    /// **Wider than the roster and than a thread**, because it holds real
    /// messages: a hit can be an embed, and an embed is laid out against
    /// `Metrics.embedMaxWidth` — a narrower column squeezes every card on the
    /// page. The same reasoning as the pinned pane's 400, plus the page bar.
    static let searchColumnIdeal: CGFloat = 420

    /// The widest a server's own page is drawn — the guide, the channel
    /// browser, the game servers.
    ///
    /// **A measure, not the column's width.** These pages are read rather than
    /// scanned, and at 1500 points a full-bleed paragraph is a line nobody can
    /// track back to the start of. The column is centred in whatever the detail
    /// column has, so a narrow window loses the margins rather than the text.
    static let surfaceColumnMax: CGFloat = 680

    /// The smallest window that still shows all three columns with a readable
    /// transcript between them. Handed to `.frame(minWidth:minHeight:)` at the
    /// window root and nowhere else.
    static let windowMinWidth: CGFloat = 880
    static let windowMinHeight: CGFloat = 560
}

// MARK: - Typography
//
// Every token is a *relative* text style, so the user's text-size setting scales
// all of it. There is no `.system(size:)` with a fixed point value anywhere in
// this app.

nonisolated enum Typeface {
    /// Channel rows, member rows, DM rows.
    static let rowTitle = Font.system(.body)
    /// The same row when it is unread. Weight, not a second mark.
    static let rowTitleUnread = Font.system(.body, weight: .semibold)
    /// A message preview, a custom status, an activity line.
    static let rowSubtitle = Font.system(.caption)
    /// Timestamps and other trailing metadata.
    static let metadata = Font.system(.caption)
    /// Message body text.
    static let messageBody = Font.system(.body)
    /// A message author's name.
    static let messageAuthor = Font.system(.body, weight: .semibold)
    /// Glyphs inside circular glass controls.
    static let controlGlyph = Font.system(.body, weight: .medium)
    /// Section headers in the member list and in settings.
    static let sectionHeader = Font.system(.caption, weight: .semibold)
    /// A category disclosure header in the channel list.
    static let categoryHeader = Font.system(.caption2, weight: .bold)
    /// Unread counts. Monospaced digits so a badge does not jitter in width as
    /// the count ticks.
    static let badge = Font.system(.caption2, weight: .bold).monospacedDigit()
    /// Code blocks and inline code.
    static let code = Font.system(.callout, design: .monospaced)
}

// MARK: - Hex convenience

extension Color {
    /// Builds a colour from a 24-bit RGB literal, e.g. `Color(hex: 0x0A0A0C)`.
    ///
    /// sRGB: the palette is achromatic near-black, so there is nothing to gain
    /// from a wider space, and sRGB keeps these values inspectable against a
    /// screenshot.
    ///
    /// `nonisolated` because the target defaults to main-actor isolation and the
    /// palette constants that call this are themselves nonisolated, so they can
    /// be read from a painter running off the main actor.
    nonisolated init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - Presence colours
//
// `nonisolated` because the member-list painter draws a presence dot off the
// main actor. An extension declared without it inherits the target's main-actor
// default, which makes the painter's read a compile error — and the fix that
// looks obvious there (hopping to the main actor to read a colour) would put an
// actor hop inside a draw loop.

nonisolated extension PresenceStatus {
    var tint: Color {
        switch self {
        case .online: Palette.presenceOnline
        case .idle: Palette.presenceIdle
        case .doNotDisturb: Palette.presenceDoNotDisturb
        case .offline, .invisible: Palette.presenceOffline
        }
    }
}
