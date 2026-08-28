import SwiftUI

// MARK: - Settings metrics
//
// The settings window is the one surface in Wingcord whose geometry was
// *measured* rather than designed: every number below came out of a live
// reference window, read from its accessibility frames and from captures of the
// window composited over five known backdrops. Nothing here was eyeballed from a
// screenshot, and nothing here should be "tidied" toward a rounder number — the
// halves are real (the reference lays its columns out on a half-point grid) and
// the rhythm only reads correctly when the whole set is kept.
//
// The tokens in `Tokens.swift` deliberately do NOT cover this: those describe the
// workspace, which is a denser surface with its own scale. A settings pane is
// read, not scanned, and it is laid out on a wider grid.

nonisolated enum SettingsMetrics {

    // MARK: Columns

    /// The source list's width. Fixed rather than a min/ideal/max triple: the
    /// rows are a fixed-width icon plus a short label, so there is nothing for a
    /// resize to reveal, and a settings window that can be dragged into an
    /// unreadable shape is a settings window that will be.
    static let sidebarWidth: CGFloat = 208.5

    /// The detail pane's inset inside the window — top, bottom and trailing. The
    /// leading edge is flush against the source list.
    static let paneInset: CGFloat = 10

    /// The detail pane's corner. Continuous, like every rounded rect here.
    static let paneRadius: CGFloat = 16

    /// How far the pane's content is held below its top edge, so the floating
    /// toolbar has somewhere to be. Applied as a bar, never as a hand-reserved
    /// margin — see `SettingsToolbar`.
    static let toolbarBandHeight: CGFloat = 72

    // MARK: Source list

    /// The traffic lights own the top of the source list, so the search field
    /// starts below them.
    static let searchFieldTop: CGFloat = 44
    static let searchFieldHeight: CGFloat = 30

    /// Leading and trailing inset for everything in the source list — the search
    /// field and every row share it.
    static let sidebarRowInset: CGFloat = 10

    /// Gap between the search field and the first row.
    static let sidebarListTopInset: CGFloat = 12

    static let sidebarRowHeight: CGFloat = 28
    static let sidebarRowRadius: CGFloat = 7
    /// Between rows inside one group.
    static let sidebarRowSpacing: CGFloat = 1
    /// Between groups. Not a divider — the reference separates by space alone.
    static let sidebarGroupSpacing: CGFloat = 12

    /// The coloured tile carrying each section's symbol.
    static let sidebarIconSide: CGFloat = 20
    static let sidebarIconRadius: CGFloat = 5
    /// Tile to label.
    static let sidebarIconGap: CGFloat = 8
    /// Row edge to tile.
    static let sidebarRowLeading: CGFloat = 8

    // MARK: Cards

    /// A card's inset inside the pane.
    static let cardInset: CGFloat = 16
    static let cardRadius: CGFloat = 16
    /// Leading inset for content inside a card.
    static let cardContentInset: CGFloat = 12

    /// The rhythm between a card and the section header under it, and between
    /// that header and the next card. These two are what make the page scan as
    /// grouped rather than as a stack.
    static let cardToHeader: CGFloat = 20
    static let headerToCard: CGFloat = 10

    /// Row heights. Minimums, never fixed: a reader who has raised the system
    /// text size gets taller rows rather than clipped ones.
    static let headerRowHeight: CGFloat = 39
    static let controlRowHeight: CGFloat = 34
    static let navigationRowHeight: CGFloat = 55
    static let toggleRowHeight: CGFloat = 44

    /// A card's internal separator, and the segmented control's.
    static let hairline: CGFloat = 1

    /// The tile in a navigation row.
    static let navigationIconSide: CGFloat = 28
    static let navigationIconRadius: CGFloat = 7
    /// Card edge to tile, and tile to title.
    static let navigationIconLeading: CGFloat = 16
    static let navigationIconGap: CGFloat = 12
    /// Card edge to the trailing chevron.
    static let navigationChevronTrailing: CGFloat = 16

    /// Card edge to a trailing control (a switch, a menu).
    static let controlTrailing: CGFloat = 12

    /// The gap between a label and the info glyph that annotates it.
    static let infoGlyphGap: CGFloat = 10

    // MARK: Toolbar

    /// The paired back/forward control. Two square buttons in one capsule.
    static let toolbarButtonSide: CGFloat = 28
    /// A toolbar item carrying a label.
    static let toolbarItemHeight: CGFloat = 32

    // MARK: Window

    /// The size the window opens at the first time. The reference's own default;
    /// wide enough for a card's two-column rows to breathe and tall enough that
    /// the source list does not scroll.
    static let defaultWidth: CGFloat = 739
    static let defaultHeight: CGFloat = 699
    /// Below this the cards stop being readable and the segmented controls start
    /// truncating their labels.
    static let minWidth: CGFloat = 560
    static let minHeight: CGFloat = 420
}

// MARK: - Surfaces
//
// Every fill in this window is defined *relative to what is behind it*, because
// what is behind it is the user's desktop coming through a translucent window.
// An absolute hex cannot stay correct here: it would be one specific grey over
// one specific wallpaper, and wrong over every other.
//
// The opacities are solved values, not guesses — each was recovered by capturing
// the reference window over black, grey, white, red and blue and fitting the
// compositing equation. All five backdrops agreed to within a least significant
// bit, which is what says the model is right.

nonisolated enum SettingsSurface {

    /// The scrim that turns the window's material into the reading pane. The
    /// source list is the bare material; the pane is the material *minus light*.
    ///
    /// **Not valid under Reduce Transparency** — use `pane(reducingTransparency:)`.
    /// The system substitutes an opaque material for the glass underneath, and a
    /// scrim measured against a translucent ground then lands on top of an
    /// already-dark solid and takes the pane most of the way to black.
    private static let paneScrim = Color.black.opacity(0.333)

    /// What goes behind the detail pane's content.
    ///
    /// A scrim over the window's glass normally; the app's own reading surface
    /// when the reader has asked for less transparency, because at that point
    /// there is nothing to see through and the relationship the scrim expresses
    /// — pane darker than source list — has to be stated outright instead.
    static func pane(reducingTransparency: Bool) -> Color {
        reducingTransparency ? Palette.canvas : paneScrim
    }

    /// The whole window's ground, behind both columns.
    ///
    /// Opaque under Reduce Transparency. `Palette.surface` rather than a value
    /// invented here: the sidebar is the lighter of the two surfaces and the pane
    /// the darker, which is the same relationship the measured translucent pair
    /// has, said in the app's own tokens.
    static let opaqueGround = Palette.surface

    /// A card, lifted off the pane.
    static let card = Color.white.opacity(0.027)

    /// The trough a segmented control sits in, over a card.
    static let controlTrough = Color.white.opacity(0.034)

    /// The selected cell of a segmented control, over the trough.
    static let controlSelected = Color.white.opacity(0.200)

    /// The search field, over the bare material.
    static let searchField = Color.white.opacity(0.061)

    /// A selected row in the source list, over the bare material.
    static let rowSelected = Color.white.opacity(0.104)

    /// The selected row while the list owns the arrow keys.
    ///
    /// Brighter than the resting selection rather than a ring around the column:
    /// a source list's focus belongs on the row a key press will move from, and
    /// the default focus effect draws a rectangle around the whole column.
    static let rowFocused = Color.white.opacity(0.165)

    /// A row under the pointer. Deliberately not half the selection's weight the
    /// way the workspace's is — over a translucent ground a hover that faint is
    /// invisible on a bright wallpaper and shouting on a dark one, so it is a
    /// little more than half.
    static let rowHover = Color.white.opacity(0.055)

    /// The hairline between two rows of a card.
    static let hairline = Color.white.opacity(0.099)

    /// The hairline between two cells of a segmented control. Fractionally
    /// lighter-handed than the card's, because it sits on the control's trough
    /// rather than on the card, and the trough is already a step up.
    static let controlHairline = Color.white.opacity(0.084)

    /// The switch, when it is on.
    ///
    /// Neutral, not the accent — `Palette.accent` is spent on primary buttons,
    /// the send arrow and focus rings, and a window of eleven blue switches has
    /// no accent left to spend. Opaque rather than a white at low opacity: a
    /// switch is a control, and a control that changes value with the wallpaper
    /// behind it is one you cannot read at a glance.
    static let switchOn = Color(white: 0.675)
}
