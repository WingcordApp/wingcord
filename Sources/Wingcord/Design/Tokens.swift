import AppKit
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
// over a backdrop picture, which is a ground this app does not choose. **On a
// light theme they are black, a step lighter-handed** — the surface *minus*
// light — resolved per view by `Color.relative`, so a surface that pins its own
// appearance still gets the right one.
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
    ///
    /// **Black at 9% on a light ground** — the same relationship said the other
    /// way round: on white, the only way to mark a surface is to take light out.
    static let selectionFill = Color.relative(dark: 0.15, light: 0.09)

    /// A row under the pointer, before it is selected. Half the selection's
    /// weight: a hover must be legible as *not yet chosen*.
    static let hoverFill = Color.relative(dark: 0.07, light: 0.05)

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

    /// What clear glass over media is tinted with.
    ///
    /// **Clear glass over near-black has nothing to refract and disappears** —
    /// §4 — so a control over a dark photo, a banner or a video's black frame
    /// needs a value of its own to be seen at rest. (Over the transcript a
    /// surface takes regular glass and needs none of this.) Kept low: past about
    /// a tenth the surface stops lensing what passes beneath and starts reading
    /// as a painted panel, which is the thing it is being rescued from.
    ///
    /// A shade of black on a light ground, for the same reason: clear glass over
    /// near-white has as little to refract as over near-black.
    static let flyoutTint = Color.relative(dark: 0.08, light: 0.035)

    /// The dimming behind a clear-glass layer in the window that holds text —
    /// the quick switcher, a topic's panel.
    ///
    /// **What makes clear glass legible without a presentation's backdrop.**
    /// Walked up on the quick switcher, not picked: at 0.45 a message body and
    /// a blue link read plainly through the rows and the footer was illegible;
    /// at 0.62 a heading over a paragraph still competed. 0.78 leaves the
    /// window's shapes showing through the glass and its text as a ghost, which
    /// is what a lensing material over a dimmed window should look like. One
    /// value, because two layers of the same kind dimmed differently would read
    /// as two different kinds of layer.
    static let modalScrim = Color.black.opacity(0.78)

    /// A grouped container *inside* a presentation — the inbox's channel cards.
    ///
    /// **A flat fill, and deliberately not `.structuralSurface()`.** That
    /// modifier is `.ultraThinMaterial`, which is right on the opaque reading
    /// surface where the discovery cards live and wrong here for two reasons:
    /// a popover already paints a material behind the whole of its content
    /// (§1), so a second one is two in series; and a material inside a subtree
    /// an animation rasterises paints black (§1.5), which a scrolling list of
    /// hoverable cards is a good way to discover.
    ///
    /// Below `hoverFill` (0.07) on purpose, so hovering a card still reads as a
    /// step up from its own ground rather than as a change of shade.
    static let groupedFill = Color.relative(dark: 0.04, light: 0.03)

    /// The hairline round a card on the ground, at rest and under the pointer.
    static let hairline = Color.relative(dark: 0.05, light: 0.08)
    static let hairlineHovered = Color.relative(dark: 0.10, light: 0.14)

    /// A heavier edge — an unchecked box, a resting chip's ring — that has to
    /// read as a control rather than as a division, at rest and under the
    /// pointer.
    static let edge = Color.relative(dark: 0.09, light: 0.12)
    static let edgeStrong = Color.relative(dark: 0.20, light: 0.22)

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
    /// **Opaque, and it used to be 0.92.** Discord's bubble is a solid plate —
    /// it sits over a banner, which is arbitrary artwork, and eight per cent of
    /// somebody's photograph coming through a speech bubble is the one place
    /// this app's translucency had nothing to gain. It also reads as a bug when
    /// the bubble expands under the pointer and the picture moves inside it.
    static var statusBubble: Color { surface }

    /// Muted conversations render badges in this instead of `unreadBadge`, so a
    /// muted unread never competes with a live one.
    static let mutedBadge = Color(hex: 0x6E6E76)

    /// Every unread badge in the app. Discord's own red rather than
    /// `destructive` — nothing is being destroyed, and sharing the token would
    /// make the two impossible to retune apart.
    static let unreadBadge = Color(hex: 0xF23F43)

    /// Discord's "NEW" on a forum post: `--brand-260` behind `--brand-560`,
    /// the same pair in both themes (`hsl(235.2 86.2% 88.6%)` and
    /// `hsl(234.7 51.4% 52.4%)`).
    static let newBadgeFill = Color(hex: 0xC9CDFB)
    static let newBadgeInk = Color(hex: 0x4752C4)

    /// Discord's `--text-feedback-warning` — the amber of a line that failed
    /// and can be tried again.
    static let feedbackWarning = Color(hex: 0xF0B232)

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
// **Brighter than the system's own ramp, on purpose** (REDESIGN.md R13). The
// system's secondary label is about 55% white in a dark room and its tertiary
// about 25%, and this app used them for primary content — read channel names,
// previews, the activity line — which is what read as pale and grey over the
// themes' colour and over glass. Hierarchy here is carried by a gentler ramp
// plus weight and size, the way Messages and Noodle carry it:
//
//   primary 94% · secondary 74% · tertiary 55% · quaternary 34% (dark room)
//   primary 88% · secondary 66% · tertiary 50% · quaternary 30% (light room)
//
// Increase Contrast raises every rung. Fixed alphas rather than the vibrant
// hierarchical styles: over a picture vibrancy composites against whatever the
// photograph is, and the point of this ramp is that it does not.

nonisolated enum Ink {
    /// Names, message bodies, primary labels.
    static let primary = InkRamp.color(.primary)
    /// Timestamps, message previews, secondary metadata — and read channel names.
    static let secondary = InkRamp.color(.secondary)
    /// Placeholder text, disabled glyphs, the least important line in a row.
    static let tertiary = InkRamp.color(.tertiary)
    /// Separators and the faintest structural marks — never text a reader needs.
    static let quaternary = InkRamp.color(.quaternary)
}

/// The ramp behind `Ink` and `InkColor`, resolved per appearance and contrast.
nonisolated enum InkRamp {
    enum Level {
        case primary, secondary, tertiary, quaternary
    }

    /// White at these alphas in a dark room.
    private static func darkAlpha(_ level: Level, increased: Bool) -> CGFloat {
        switch level {
        case .primary: increased ? 1.00 : 0.94
        case .secondary: increased ? 0.86 : 0.74
        case .tertiary: increased ? 0.70 : 0.55
        case .quaternary: increased ? 0.48 : 0.34
        }
    }

    /// Black at these alphas in a light room.
    private static func lightAlpha(_ level: Level, increased: Bool) -> CGFloat {
        switch level {
        case .primary: increased ? 1.00 : 0.88
        case .secondary: increased ? 0.78 : 0.66
        case .tertiary: increased ? 0.62 : 0.50
        case .quaternary: increased ? 0.42 : 0.30
        }
    }

    static func nsColor(_ level: Level) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [
                .darkAqua, .aqua,
                .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua,
            ])
            switch match {
            case .accessibilityHighContrastDarkAqua:
                return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: darkAlpha(level, increased: true))
            case .accessibilityHighContrastAqua:
                return NSColor(srgbRed: 0, green: 0, blue: 0, alpha: lightAlpha(level, increased: true))
            case .aqua:
                return NSColor(srgbRed: 0, green: 0, blue: 0, alpha: lightAlpha(level, increased: false))
            default:
                return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: darkAlpha(level, increased: false))
            }
        }
    }

    static func color(_ level: Level) -> Color {
        Color(nsColor: nsColor(level))
    }
}

/// Concrete `Color`s for text that must hold a **fixed** value regardless of
/// what is behind it — text over artwork: a banner, a cover, a video frame.
///
/// The same ramp as `Ink` now that `Ink` is fixed too; kept as its own name
/// because the call sites say *why* they need a fixed colour.
nonisolated enum InkColor {
    static let primary = InkRamp.color(.primary)
    static let secondary = InkRamp.color(.secondary)
    static let tertiary = InkRamp.color(.tertiary)

    /// Full-strength ink for text and glyphs that float over *moving* content —
    /// the composer's field, a pill over the transcript: white in a dark room,
    /// black in a light one, and never vibrant. Vibrancy resolves against
    /// whatever message happens to be scrolling underneath, which is exactly how
    /// these used to get lost; and plain white, which is what they were, is
    /// invisible on a light theme's glass.
    static let solid = Color.adaptive(dark: .white, light: .black)
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
nonisolated enum ChromeShape: String, CaseIterable, Sendable, Codable {
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
    /// Whether a bar of this shape **encloses** the round controls that flank it.
    ///
    /// **A silhouette and an arrangement are one decision, not two.** A rounded
    /// rectangle has flat sides and spare corners, so `+` and the send arrow sit
    /// inside it as regions cut into its material, with a hairline separating
    /// the send from the row — one panel holding everything. A capsule's ends
    /// *are* circles, and a circle enclosed in one collides with the rounded
    /// end; so the pill keeps its two circular controls as glass bodies of their
    /// own, beside the plate. Discord's own composer is a rounded rect for
    /// exactly this reason.
    ///
    /// One property rather than a flag beside the shape, because the two can
    /// then never be chosen independently — a pill that swallowed its send
    /// button is a drawing nobody asked for.
    var enclosesFlankingControls: Bool { self == .boxy }

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

    /// How far the strip of people under a voice channel is indented.
    ///
    /// Lined up so a face sits under the *name* rather than under the speaker
    /// glyph: the row's own leading padding plus the glyph's slot. A strip
    /// indented to the glyph reads as a second column of icons.
    static let voiceStripInset: CGFloat = 22

    /// One person in the strip under a voice channel. Tight against the 20-point
    /// face it holds: the strip is a nested list and every point of slack in it
    /// is a point the channel rows above are pushed apart by.
    static let voiceMemberRowHeight: CGFloat = 24

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

    /// A row's content in the system sidebar list.
    ///
    /// **Measured, not chosen** (macOS 27 SDK, 2026-10-05, offscreen probe of a
    /// `.sidebar` `List`): the list adds `sidebarRowInset` above and below a
    /// row's content and keeps a 32-point minimum, so 24 of content is the
    /// system's own row height.
    static let sidebarRowContent: CGFloat = 24

    /// What the system sidebar list adds above and below a row's content. Its
    /// selection highlight sits half of this inside the row, and 6 points
    /// wider than the content on each side — `SidebarRowGeometry`.
    static let sidebarRowInset: CGFloat = 4

    /// A call control's disc in the HUD: five across the sidebar's narrowest
    /// width with room between them, and over the HIG's 28-point default.
    static let callControl: CGFloat = 36

    /// A labelled call control's capsule, in the call band.
    static let callControlLabeled: CGFloat = 32

    /// The composer's text box. Its capsule adds `Spacing.tight` above and
    /// below, so the row measures `composerControlHeight`; that, not this, is
    /// what the controls flanking it match.
    static let composerFieldMinHeight: CGFloat = 30

    /// The composer row's **outside** height: the field's capsule, and every
    /// circle beside it.
    static let composerControlHeight: CGFloat = composerFieldMinHeight + Spacing.tight * 2

    /// The composer stops growing here and starts scrolling internally.
    static let composerMaxLines = 12

    /// One control at the composer's trailing end — GIF, sticker, emoji, apps.
    ///
    /// **Bigger than `compactControl`, and that is the point.** These used to be
    /// 26-point boxes carrying a 10-point word and a `.body` glyph in
    /// `Ink.secondary`, which over the composer's glass read as four grey marks
    /// somebody had left in the corner. A 32-point target with a 19-point glyph
    /// in white is the size the rest of this platform gives a control that opens
    /// a picker, and it is what makes the row read as four controls rather than
    /// as decoration on the end of the field.
    ///
    /// It fits *inside* the bar rather than setting its height: 32 in 38 leaves
    /// `composerControlInset` above and below.
    static let composerControl: CGFloat = 32

    /// What is left beside a trailing control once it is centred in the bar.
    ///
    /// The composer's trailing padding, so the last control's own air is the
    /// same on both of its sides. Derived, because the two numbers it comes from
    /// are the ones a reader would actually change.
    static let composerControlInset: CGFloat = (composerControlHeight - composerControl) / 2

    // MARK: Avatars

    /// The guild rail's tiles.
    static let guildTile: CGFloat = 44
    /// Member rows, the now bar.
    static let avatarRow: CGFloat = 26
    /// A direct message's face — Discord's 32 against its 16-point name, the
    /// proportion the DM list reads at.
    static let avatarDirectMessage: CGFloat = 32
    /// The message author gutter.
    static let avatarMessage: CGFloat = 38
    /// Inline in a reply quote or a preview.
    static let avatarInline: CGFloat = 16
    /// A face in the strip of people under a voice channel. Between the inline
    /// mark and a row's own avatar: the strip is a list of *people*, so it needs
    /// more than a glyph, and it is nested under a row, so it must not out-weigh
    /// the channel it belongs to.
    static let avatarVoiceRow: CGFloat = 20
    /// The mark of the game somebody in a voice channel is playing, at the end
    /// of their row. Square, and the same height as the microphone glyph beside
    /// it so the trailing cluster sits on one line.
    static let voiceGameMark: CGFloat = 16
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

    /// The picture on a forum post's row: Discord's `ef` and `ej`.
    ///
    /// Square, and small enough that the title beside it still gets two lines at
    /// the narrowest the column goes to — the picture is a hint about the post,
    /// not the post.
    static let forumThumbnail: CGFloat = 72

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
    /// An app's own mark on a directory tile. Smaller than a server's, because
    /// an app icon is a logo rather than a picture and it sits over a banner.
    static let discoveryAppIcon: CGFloat = 40
    /// The banner across a tile's head. **16:9, not the server card's 2:1**:
    /// every `activity_preview_video` in the captures is 16:9, and the loop that
    /// replaces this on hover has to land in the box the still left.
    static let discoveryAppArt: CGFloat = (discoveryCardWidth * 9 / 16).rounded()

    /// The widest discovery's own column is drawn.
    ///
    /// **Derived from the grid rather than chosen: four cards at their own
    /// minimum with the grid's own gaps.**
    static let discoveryColumn: CGFloat =
        discoveryCardWidth * 4 + Spacing.margin * 3
    /// The search field on discovery's bar, once it has opened. The same width as
    /// the search it opens like in servers and conversations.
    static let discoverySearchField: CGFloat = 240

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
    /// An app's own page, when it is a page rather than the composer's flyout.
    ///
    /// **Wider than the 680 a page of prose takes**, because this page is not
    /// only prose: it carries a permission grid three columns across, a facts
    /// panel two across, and a 16:9 picture on top of both. At 680 the grid fell
    /// to two columns and the languages line ran to five. What it must not be is
    /// the detail column's whole width, where the hero became a thousand-point
    /// banner with the app's name below the fold — the ratio has no ceiling of
    /// its own, so the column is the ceiling.
    static let appPageColumn: CGFloat = 760
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
    /// column it occupies is this plus twice that — and, for somebody wearing a
    /// profile frame, plus its two side overhangs, because the box keeps this
    /// width and the column grows around it. See `DirectMessageProfilePane`.
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
    /// A direct message's name, in points: Discord's 16 against its 13-point
    /// body, taken as a ratio of the system's own body so it still follows the
    /// reader's text size. No text style on this platform lands on it — the
    /// subheadline the row used was 11, a name dwarfed by its own row.
    @MainActor static var directMessageNameSize: CGFloat {
        NSFont.preferredFont(forTextStyle: .body).pointSize * 16 / 13
    }
    /// Somebody's name in the strip under a voice channel. One step down from a
    /// row title, because the strip is nested inside a row and must not compete
    /// with the channel it belongs to.
    static let voiceMemberName = Font.system(.subheadline)
    /// A voice channel's own status line, and the clock beside it. The clock is
    /// monospaced so a running second does not shift the row.
    static let voiceChannelStatus = Font.system(.caption)
    static let voiceChannelClock = Font.system(.caption2, weight: .semibold).monospacedDigit()
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
    /// One colour under a dark appearance and another under a light one,
    /// resolved wherever it is drawn.
    ///
    /// **Resolved by the view's own appearance, not the theme's.** A surface
    /// that pins its own — a profile card over dark artwork forces dark — gets
    /// the dark answer inside a light window, which is exactly right: the fill
    /// belongs to what is under it.
    nonisolated static func adaptive(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua ? light : dark
        })
    }

    /// The surface *plus light* on a dark ground, *minus light* on a light one:
    /// white at `dark`, black at `light`. What every relative fill in `Palette`
    /// is made of.
    nonisolated static func relative(dark: Double, light: Double) -> Color {
        adaptive(
            dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: dark),
            light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: light)
        )
    }

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
        case .offline, .invisible, .unknown: Palette.presenceOffline
        }
    }
}

extension Color {
    /// This colour, floored so it can be read as text on the app's near-black
    /// canvas.
    ///
    /// **A surface colour is not an ink colour**, and the two are the same
    /// value often enough that the distinction has to be made somewhere. A
    /// person's derived theme is the dominant colour of their avatar: over the
    /// canvas at a third opacity it is a ground, and set straight into a `Text`
    /// it is whatever their avatar happened to be — black, for a dark one.
    ///
    /// Brightness is floored and saturation capped, so what comes back is a
    /// pastel of the original: still recognisably their colour, and legible
    /// whatever it started as. Already-light colours pass through unchanged.
    ///
    /// `NSColor` rather than arithmetic on components, because a `Color` can be
    /// a catalog colour or a gradient's resolved value and only the bridge
    /// knows how to ask it for a hue.
    nonisolated func liftedForInk(
        minimumBrightness: CGFloat = 0.72,
        maximumSaturation: CGFloat = 0.55
    ) -> Color {
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return self }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        srgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        guard brightness < minimumBrightness || saturation > maximumSaturation else {
            return self
        }
        return Color(
            nsColor: NSColor(
                hue: hue,
                saturation: min(saturation, maximumSaturation),
                brightness: max(brightness, minimumBrightness),
                alpha: alpha
            )
        )
    }
}
