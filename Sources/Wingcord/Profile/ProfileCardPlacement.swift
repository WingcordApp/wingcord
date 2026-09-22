import CoreGraphics
import Foundation
import SwiftUI

/// Where the profile card sits, given the row that opened it.
///
/// **This is the arithmetic a popover used to do, and it is here because the
/// card stopped being one.** A profile frame's artwork hangs past the card by
/// design, and a system presentation cannot show that: it is an `NSWindow`, a
/// window cannot draw outside itself, and it paints its own backdrop behind the
/// whole of its content — so reserving room for the overhang produced a grey
/// panel around the card rather than roses over the transcript. See
/// `INVARIANTS.md`.
///
/// What a popover gave for free, and where each part went:
///
/// | popover did | now |
/// |---|---|
/// | anchor to a rect | this type |
/// | keep itself on screen | this type |
/// | dismiss on outside click | a button behind the card |
/// | dismiss on Escape | `.keyboardShortcut(.cancelAction)` on that button |
/// | its own window | nothing — one fewer window per card |
///
/// **Split by axis, because the two are known at different moments.** The
/// horizontal answer needs only the card's width, which is a constant; the
/// vertical one needs its height, which is its content's — a bio and a role
/// flow that arrive over the network. Solving them together would mean either
/// measuring the height into `@State`, which costs a layout pass and leaves a
/// number that outlives the card, or pretending to know it. Neither is needed:
/// `cardY(forHeight:)` is called from an alignment guide, which is handed the
/// height *during* the layout pass that uses it.
///
/// **A pure value with no view in it**, so every window size and every anchor
/// can be checked without running the app. That matters more here than it
/// looks: the failure mode is a card that opens somewhere believable and wrong,
/// which is the exact defect `NSView.anchorInHostingRoot` exists to prevent one
/// coordinate space earlier.
nonisolated struct ProfileCardPlacement: Equatable, Sendable {
    /// Where the card's own leading edge goes, in the SwiftUI root's space.
    ///
    /// The **card's**, not the artwork's: the caller offsets by the overhang
    /// itself, so a frame resolving a beat after the card opened cannot shift
    /// the card out from under the pointer.
    let cardX: CGFloat
    /// Which corner the card grows from, so it materialises out of the thing
    /// that summoned it — §3's spatial symmetry, and the one thing a popover
    /// did for free that was worth keeping.
    let growthAnchor: UnitPoint

    private let anchor: CGRect
    private let side: Side
    private let overhang: EdgeInsets
    private let container: CGSize

    /// Between the card's edge and the row it belongs to.
    static let gap: CGFloat = 8
    /// The least space kept between the *artwork* and the window's edge.
    static let margin: CGFloat = 8

    /// - Parameters:
    ///   - anchor: the trigger's frame, in the root's space.
    ///   - cardWidth: the card alone, without any frame artwork.
    ///   - overhang: how far that artwork runs past each edge. Zero for the
    ///     overwhelming majority of profiles, which is what keeps a frame from
    ///     being a cost everybody pays.
    ///   - container: the root's size.
    /// Which way the card leaves its trigger.
    ///
    /// **A row is flanked; a bar is stood on.** A member row sits in the middle
    /// of a tall column, so its card belongs beside it, centred on it. The now
    /// bar is pinned to the window's foot: there is no "beside" — the card has
    /// to rise out of it, left edges aligned, the way the bar's own menu did.
    /// Centring on it and clamping to the window is what laid the card *over*
    /// the bar that opened it.
    enum Side {
        case beside
        case above
    }

    init(
        anchor: CGRect,
        cardWidth: CGFloat,
        overhang: EdgeInsets,
        container: CGSize,
        side: Side = .beside
    ) {
        self.anchor = anchor
        self.side = side
        self.overhang = overhang
        self.container = container

        // **Leading first, matching what the popover did**, so a card keeps
        // appearing on the same side of a member row as it always has. It flips
        // only when there is genuinely no room, which means a narrow window
        // rather than a preference.
        let artworkWidth = cardWidth + overhang.leading + overhang.trailing
        // Standing on the trigger, the card's leading edge is the trigger's —
        // which is what makes it read as growing out of the bar rather than as
        // appearing next to it.
        let leading = side == .above
            ? anchor.minX
            : anchor.minX - Self.gap - cardWidth
        let trailing = anchor.maxX + Self.gap
        let fitsLeading = leading - overhang.leading >= Self.margin
        let placedLeading = side == .above
            || fitsLeading
            || trailing + artworkWidth > container.width

        // Clamped on the ARTWORK, not on the card. A frame is what reaches the
        // window's edge first, and clamping the card alone puts the roses half
        // outside the window.
        let lowest = Self.margin + overhang.leading
        let highest = container.width - Self.margin - overhang.trailing - cardWidth
        let wanted = placedLeading ? leading : trailing
        cardX = highest >= lowest ? min(max(wanted, lowest), highest) : lowest

        growthAnchor = UnitPoint(
            // Out of the bar's own corner when it stands on one.
            x: side == .above ? 0 : (placedLeading ? 1 : 0),
            // The half of the window the row is in, rather than the half of the
            // card — the card's height is not known here, and the window's
            // halves are the stable answer a transition wants.
            y: anchor.midY < container.height / 2 ? 0 : 1
        )
    }

    /// Where the card's own top edge goes, once its height is known.
    ///
    /// Centred on the row, which is what makes the card read as belonging to it
    /// rather than dropping from it, then clamped so the artwork stays inside
    /// the window.
    func cardY(forHeight cardHeight: CGFloat) -> CGFloat {
        let wanted = side == .above
            // Its foot a gap above the trigger's head, so the two never overlap
            // however tall the card turns out to be.
            ? anchor.minY - Self.gap - cardHeight
            : anchor.midY - cardHeight / 2
        let lowest = Self.margin + overhang.top
        let highest = container.height - Self.margin - overhang.bottom - cardHeight
        return highest >= lowest ? min(max(wanted, lowest), highest) : lowest
    }
}
