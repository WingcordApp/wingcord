import AppKit
import CoreGraphics

// MARK: - Bubbles
//
// The transcript's second arrangement: the reader's messages on the trailing
// side in the accent, everybody else's on the leading side in a neutral
// bubble — the way Messages draws a conversation. Discord has no such mode;
// it is the app's own, behind Appearance → Bubbles.
//
// Everything here is geometry the layout engine and the painter share, in
// `nonisolated` types for §4.87's reason: both run off the main actor, and a
// padding kept in two places is a bubble whose words sit a point off centre.

/// How a transcript arranges its messages.
nonisolated enum MessageArrangement: Sendable, Equatable {
    /// Every message in a column beside its author's face — Discord's.
    case columns
    /// The reader's messages trailing in an accent bubble, everybody else's
    /// leading in a neutral one.
    ///
    /// - Parameter namesAuthors: whether other people's runs carry a name over
    ///   their first bubble and a face beside their last. False in a
    ///   one-to-one conversation, where there is only ever one other person.
    case bubbles(namesAuthors: Bool)
}

/// Where one message's content may go, across its row.
///
/// **One value for every piece of a row**, so the bubble, the pictures under
/// it and the reactions under those cannot disagree about which side they hug.
nonisolated struct MessageLane: Sendable, Equatable {
    var minX: CGFloat
    var width: CGFloat
    /// Whether content hugs the trailing edge — the reader's own, in bubbles.
    var isTrailing: Bool

    var maxX: CGFloat { minX + width }

    /// Where something `elementWidth` wide starts on this lane.
    func x(forWidth elementWidth: CGFloat) -> CGFloat {
        isTrailing ? maxX - elementWidth : minX
    }

    /// Discord's column: everything after the author gutter.
    static func column(rowWidth: CGFloat) -> MessageLane {
        let minX = TimelineMetrics.contentInset
        return MessageLane(
            minX: minX,
            width: max(80, rowWidth - minX - TimelineMetrics.horizontalMargin),
            isTrailing: false
        )
    }

    /// A bubble's lane, on its own side of the row.
    ///
    /// - Parameter indent: room kept at the leading margin for the faces of a
    ///   conversation that names its authors. Zero on the reader's side, which
    ///   never draws one.
    static func bubble(rowWidth: CGFloat, side: BubbleRow.Side, indent: CGFloat) -> MessageLane {
        let margin = TimelineMetrics.horizontalMargin
        let column = max(80, rowWidth - margin * 2 - indent)
        // A share of the column, but never so narrow on a small window that a
        // sentence breaks every few words.
        let width = min(column, max((column * BubbleMetrics.laneFraction).rounded(.down), BubbleMetrics.minimumLane))
        return switch side {
        case .leading: MessageLane(minX: margin + indent, width: width, isTrailing: false)
        case .trailing: MessageLane(minX: rowWidth - margin - width, width: width, isTrailing: true)
        }
    }
}

/// A message row's place in the bubble arrangement. Nil on every row of
/// Discord's columns.
nonisolated struct BubbleRow: @unchecked Sendable {
    enum Side: Sendable, Equatable {
        case leading
        case trailing
    }

    var side: Side
    /// The words' bubble. Nil for a message drawn bare — emoji on their own, a
    /// sticker, a picture, a card.
    var bubble: MessageBubble?
    /// Where the time sits: beside the content, on the side it leaves open.
    /// Drawn under the pointer, or always with the setting that asks for it.
    var timeRect: CGRect
}

/// One bubble: its body, and the outline the painter fills.
nonisolated struct MessageBubble: @unchecked Sendable {
    enum Ground: Sendable, Equatable {
        /// The reader's own words, in the accent.
        case accent
        /// Everybody else's, and a send Discord refused.
        case neutral
    }

    /// The body, in row space. A tail reaches past it, into the margin.
    var rect: CGRect
    var ground: Ground
    /// The last bubble of its run, which wears the tail.
    var hasTail: Bool
    /// Body and tail, in row space. **Built once, at layout** — a fill is all
    /// a repaint pays for.
    var path: CGPath
}

nonisolated enum BubbleMetrics {
    /// Between the words and the bubble's sides.
    static let horizontalPadding: CGFloat = 12
    /// Between the words and the bubble's top and bottom.
    static let verticalPadding: CGFloat = 7
    /// How far a tail reaches past the body, at the reference corner.
    static let tailReach: CGFloat = 6
    /// The share of the column a bubble may take — Messages' proportion.
    static let laneFraction: CGFloat = 0.7
    /// The narrowest a lane is made where the column has the room.
    static let minimumLane: CGFloat = 280
    /// The face beside the last bubble of somebody's run, and the air after it.
    static let avatarSide: CGFloat = 28
    static let avatarGap: CGFloat = 8
    /// Between the content and the time beside it.
    static let timeGap: CGFloat = 8

    /// A bubble's corner for words in `font`: half a one-line bubble's height,
    /// so one line is a capsule and a paragraph keeps the same corner.
    static func cornerRadius(for font: NSFont) -> CGFloat {
        (ceil(font.ascender - font.descender + font.leading) + verticalPadding * 2) / 2
    }
}

nonisolated enum BubbleShape {
    /// The corner the tail's proportions were drawn at. A bigger corner scales
    /// the tail with it, so a reader's larger text keeps Messages' silhouette.
    private static let referenceRadius: CGFloat = 15

    /// A bubble's outline: a rounded body, and — on a run's last bubble —
    /// Messages' tail curling out of the bottom corner on `tail`'s side.
    ///
    /// In y-down space, the canvases' own. The tail is drawn trailing and
    /// mirrored for the other side, so both are one curve.
    static func path(body: CGRect, radius: CGFloat, tail: BubbleRow.Side?) -> CGPath {
        let r = min(radius, body.height / 2, body.width / 2)
        guard let tail else {
            return CGPath(roundedRect: body, cornerWidth: r, cornerHeight: r, transform: nil)
        }
        let k = r / referenceRadius
        let left = body.minX, right = body.maxX, top = body.minY, bottom = body.maxY

        let path = CGMutablePath()
        // The bottom edge, from where the tail's underside meets it.
        path.move(to: CGPoint(x: right - 15 * k, y: bottom))
        path.addLine(to: CGPoint(x: left + r, y: bottom))
        path.addArc(tangent1End: CGPoint(x: left, y: bottom), tangent2End: CGPoint(x: left, y: bottom - r), radius: r)
        path.addLine(to: CGPoint(x: left, y: top + r))
        path.addArc(tangent1End: CGPoint(x: left, y: top), tangent2End: CGPoint(x: left + r, y: top), radius: r)
        path.addLine(to: CGPoint(x: right - r, y: top))
        path.addArc(tangent1End: CGPoint(x: right, y: top), tangent2End: CGPoint(x: right, y: top + r), radius: r)
        // Down the trailing side to where the tail flares out of it…
        path.addLine(to: CGPoint(x: right, y: bottom - 12 * k))
        path.addCurve(
            to: CGPoint(x: right + 5 * k, y: bottom),
            control1: CGPoint(x: right, y: bottom - k),
            control2: CGPoint(x: right + 5 * k, y: bottom)
        )
        path.addLine(to: CGPoint(x: right + BubbleMetrics.tailReach * k, y: bottom))
        // …and its underside, curling back up into the body and down to the edge.
        path.addCurve(
            to: CGPoint(x: right - 7 * k, y: bottom - 4 * k),
            control1: CGPoint(x: right + k, y: bottom + k),
            control2: CGPoint(x: right - 3 * k, y: bottom - k)
        )
        path.addCurve(
            to: CGPoint(x: right - 15 * k, y: bottom),
            control1: CGPoint(x: right - 10 * k, y: bottom),
            control2: CGPoint(x: right - 15 * k, y: bottom)
        )
        path.closeSubpath()

        guard tail == .leading else { return path }
        var mirror = CGAffineTransform(translationX: left + right, y: 0).scaledBy(x: -1, y: 1)
        return path.copy(using: &mirror) ?? path
    }
}

/// Where the action pill hangs beside a bubble row.
///
/// **Beside the bubble, on the side the row leaves open, beyond the time and
/// level with its first line** — over the row's trailing end, where Discord's
/// goes, it would sit on the reader's own bubbles. In whatever space the row it
/// came from is in.
nonisolated struct ActionPillAnchor: Hashable, Sendable {
    enum Edge: Hashable, Sendable {
        /// The pill ends at `x` — beside the reader's own messages.
        case trailing
        /// The pill starts at `x` — beside everybody else's.
        case leading
    }

    var edge: Edge
    var x: CGFloat
    /// The line the pill centres on: the bubble's first, where its time is.
    var midY: CGFloat

    func offsetBy(dx: CGFloat, dy: CGFloat) -> ActionPillAnchor {
        ActionPillAnchor(edge: edge, x: x + dx, midY: midY + dy)
    }
}

extension BubbleRow {
    /// Where this row's pill hangs, in row space. Nil for a row with nothing
    /// to hang it beside, which then takes Discord's place for it.
    var pillAnchor: ActionPillAnchor? {
        guard !timeRect.isEmpty else { return nil }
        return switch side {
        case .trailing: ActionPillAnchor(edge: .trailing, x: timeRect.minX - BubbleMetrics.timeGap, midY: timeRect.midY)
        case .leading: ActionPillAnchor(edge: .leading, x: timeRect.maxX + BubbleMetrics.timeGap, midY: timeRect.midY)
        }
    }
}
