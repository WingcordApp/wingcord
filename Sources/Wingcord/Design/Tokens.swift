import SwiftUI
import WingcordCore

// MARK: - Palette
//
// One theme: True Black. There is deliberately no theme system, no alternate
// palettes and no protocol to swap them. If a second palette is ever wanted it
// is a new decision, not a slot waiting to be filled.
//
// Every pixel of *colour* in Wingcord comes from user content — avatars,
// banners, role colours, media, server icons. The chrome is achromatic glass
// over near-black, and accent is spent sparingly.
//
// THE ONE MACOS DIFFERENCE, and it decides where these may be used:
// `NavigationSplitView`'s sidebar column is painted by AppKit with behind-window
// vibrancy. That vibrancy IS the bleed — the wallpaper and the menu-bar accent
// coming through the leading columns. Painting `canvas` over the sidebar throws
// it away. So `canvas` belongs to the DETAIL column and to floating panels; the
// rail and the channel list get no background at all.

nonisolated enum Palette {
    /// The reading surface. #0A0A0C — near-black, deliberately not pure black,
    /// because Liquid Glass needs something behind it to lens and refract. Pure
    /// #000 makes every glass surface read as a flat grey panel.
    ///
    /// Applied to the detail column only. See the note above.
    static let canvas = Color(hex: 0x0A0A0C)

    /// Structural, non-floating surfaces: panel grounds, grouped row
    /// backgrounds, the opaque layer that scrolls *underneath* glass.
    static let surface = Color(hex: 0x141417)

    /// A slightly lifted structural surface, for a grouped row inside `surface`.
    static let surfaceRaised = Color(hex: 0x1C1C20)

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

    /// The single accent. System blue, so it tracks the user's chosen accent
    /// colour in System Settings and Increase Contrast. Used only for: primary
    /// buttons, the send arrow, focus rings. Nothing else in the chrome.
    static let accent = Color.accentColor

    /// Destructive actions only — Delete, Block, Leave, Disconnect.
    static let destructive = Color.red

    /// Affirmative call actions only (Accept).
    static let affirmative = Color.green

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

    /// A category disclosure header. Shorter than a row: it is a label, not a
    /// destination.
    static let categoryMinHeight: CGFloat = 24

    /// Circular glass buttons in the toolbar and in floating clusters.
    static let control: CGFloat = 28

    /// The smaller circles inside the now bar, which share a capsule with each
    /// other and must not out-weigh the identity beside them.
    static let compactControl: CGFloat = 26

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

    /// The member inspector.
    static let memberColumnMin: CGFloat = 200
    static let memberColumnIdeal: CGFloat = 236
    static let memberColumnMax: CGFloat = 300

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
    /// The server-name pill, and any page title in a floating capsule.
    static let pageTitle = Font.system(.headline, weight: .semibold)
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
