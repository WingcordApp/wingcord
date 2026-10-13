import AppKit
import SwiftUI

// MARK: - Settings metrics
//
// The settings panes are the one surface in Wingcord whose geometry was
// *measured* rather than designed: every number below came out of a live
// reference window — the system's own Settings — read from its accessibility
// frames and from captures of the window composited over five known backdrops.
// Nothing here was eyeballed from a screenshot, and nothing here should be
// "tidied" toward a rounder number — the halves are real and the rhythm only
// reads correctly when the whole set is kept.
//
// The window around the panes is the system's now (DESIGN-NOTES decision 16):
// its sidebar, toolbar and title take the system's own metrics, so the numbers
// that used to hand-build them are gone.
//
// The tokens in `Tokens.swift` deliberately do NOT cover this: those describe the
// workspace, which is a denser surface with its own scale. A settings pane is
// read, not scanned, and it is laid out on a wider grid.

nonisolated enum SettingsMetrics {

    // MARK: Columns

    /// The sidebar's width when the window first opens — the reference's. The
    /// reader can drag the split between the limits below.
    static let sidebarWidth: CGFloat = 208.5
    /// Narrower than this and a row is an icon and a truncated word.
    static let sidebarMinWidth: CGFloat = 168
    static let sidebarMaxWidth: CGFloat = 320

    /// The coloured tile carrying each section's symbol in the sidebar.
    static let sidebarIconSide: CGFloat = 20
    static let sidebarIconRadius: CGFloat = 5

    /// A search field inside a pane.
    static let searchFieldHeight: CGFloat = 30

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
// Every fill in a pane is defined *relative to what is behind it* — a white or a
// black at an opacity — so a card is one step off the window's own background,
// whatever the appearance and whatever theme the reader chose.
//
// The opacities are solved values, not guesses — each was recovered by capturing
// the reference window over black, grey, white, red and blue and fitting the
// compositing equation. All five backdrops agreed to within a least significant
// bit, which is what says the model is right. That reference window was
// translucent and this one is not, so the steps are the measured ones over a
// different ground: the window's background is now the system's opaque one.
//
// **The light-theme halves are NOT measured.** They are first values, set by
// the system's own light settings window rather than fitted against a capture,
// and they are the ones to tune.

nonisolated enum SettingsSurface {

    /// A card, lifted off the pane.
    ///
    /// **Still white under a light theme, and much more of it**: a light card is
    /// lifted by being brighter than its pane, not by being shaded.
    static let card = Color.adaptive(
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.027),
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.55)
    )

    /// The trough a segmented control sits in, over a card.
    static let controlTrough = Color.relative(dark: 0.034, light: 0.05)

    /// The selected cell of a segmented control, over the trough.
    static let controlSelected = Color.adaptive(
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.200),
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.90)
    )

    /// A row of a card under the pointer.
    static let rowHover = Color.relative(dark: 0.055, light: 0.04)

    /// The hairline between two rows of a card.
    static let hairline = Color.relative(dark: 0.099, light: 0.08)

    /// The hairline between two cells of a segmented control. Fractionally
    /// lighter-handed than the card's, because it sits on the control's trough
    /// rather than on the card, and the trough is already a step up.
    static let controlHairline = Color.relative(dark: 0.084, light: 0.07)

    /// The switch, when it is on.
    ///
    /// Neutral, not the accent — `Palette.accent` is spent on primary buttons,
    /// the send arrow and focus rings, and a window of eleven blue switches has
    /// no accent left to spend. Opaque rather than a white at low opacity: a
    /// switch is a control, and a control that changes value with the wallpaper
    /// behind it is one you cannot read at a glance.
    ///
    /// Darker in a light room — a light grey switch on a light pane is no
    /// switch at all. The light value is an estimate; see the note at the top.
    static let switchOn = Color.adaptive(
        dark: NSColor(white: 0.675, alpha: 1),
        light: NSColor(white: 0.40, alpha: 1)
    )
}

// MARK: - Shapes

extension Shape where Self == RoundedRectangle {
    /// Every rounded rect in a settings pane is continuous. The reference's
    /// corners were matched against rendered candidates rather than guessed, and
    /// circular corners at these radii are visibly tighter at the shoulder.
    static func settingsRect(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}
