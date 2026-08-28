import SwiftUI

// MARK: - The flyout's outline
//
// A rounded rectangle with a tail blown out of one edge, as ONE closed path.
// One path rather than a body plus an overlaid triangle, because the rim is a
// single stroke: two shapes drawn separately leave a seam across the tail's base
// that no amount of colour matching hides.
//
// Three measured features, and none of them is a plain triangle:
//
//   - The sides run at 45°. The reference's measured slope is 0.983 over
//     fourteen rows, which is 45° and a rounding error.
//   - The tip is a fillet of 5.5, not a point.
//   - The base FLARES, over a six-point fillet. That corner is REFLEX — the
//     shape's interior angle there is 225°, not 135° — so the tangent arc
//     bulges away from the corner and *adds* material, which is what makes the
//     tail read as blown out of the panel rather than stuck on to it. The same
//     call at the tip, where the corner is convex, cuts into it instead.
//
// The tail is unioned into the body rather than overlaid on it, so the rim can
// be one stroke around one outline.

nonisolated struct HotkeyFlyoutShape: Shape {

    /// Which edge the tail leaves from. `.top` when the flyout hangs below its
    /// control, `.bottom` when it has been flipped above it.
    var tailEdge: VerticalEdge = .top

    /// The tail's centre, as a fraction of the width. Always 0.5 in this app —
    /// the panel is centred on its control — but expressed rather than assumed,
    /// because a flyout clamped against a screen edge would need to slide it.
    var tailPosition: CGFloat = 0.5

    func path(in rect: CGRect) -> Path {
        // `rect` is the whole panel. The visible body is inset by the shadow's
        // margin on every side and the tail is drawn up into the top one, which
        // is why the panel is 346x196 for a flyout that is 320x170.
        //
        // Everything is built with the tail on top, then flipped once at the
        // end. Writing both orientations twice is how the two drift apart.
        let body = rect.insetBy(dx: HotkeyMetrics.shadowMargin, dy: HotkeyMetrics.shadowMargin)
        let bodyPath = RoundedRectangle(
            cornerRadius: HotkeyMetrics.cornerRadius,
            style: .continuous
        ).path(in: body).cgPath

        let path = bodyPath.union(tail(over: body), using: .winding)
        guard tailEdge == .bottom else { return Path(path) }
        // Mirror vertically about the rect's centre. A transform, not a second
        // construction.
        var flip = CGAffineTransform(translationX: 0, y: rect.midY * 2)
            .scaledBy(x: 1, y: -1)
        return Path(path.copy(using: &flip) ?? path)
    }

    /// The tail, as a closed region whose lower edge sits well inside the body
    /// so the union has something to swallow.
    private func tail(over body: CGRect) -> CGPath {
        let cx = body.minX + body.width * tailPosition
        let top = body.minY
        let half = HotkeyMetrics.tailHalfWidth
        let apex = CGPoint(x: cx, y: top - HotkeyMetrics.tailHeight)
        let leftCorner = CGPoint(x: cx - half, y: top)
        let rightCorner = CGPoint(x: cx + half, y: top)
        // How far along the body's edge the base fillets reach. Generous — the
        // arcs decide where they actually stop, and a start point short of that
        // would put a kink in the outline.
        let run = HotkeyMetrics.tailBaseRadius * 2 + 4

        let p = CGMutablePath()
        p.move(to: CGPoint(x: leftCorner.x - run, y: top))
        // Three tangent arcs and nothing else: the two base fillets, which bulge
        // OUT of the corner because it is reflex, and the tip, which cuts into
        // its own because it is not.
        p.addArc(tangent1End: leftCorner, tangent2End: apex, radius: HotkeyMetrics.tailBaseRadius)
        p.addArc(tangent1End: apex, tangent2End: rightCorner, radius: HotkeyMetrics.tailTipRadius)
        p.addArc(
            tangent1End: rightCorner,
            tangent2End: CGPoint(x: rightCorner.x + run, y: top),
            radius: HotkeyMetrics.tailBaseRadius
        )
        p.addLine(to: CGPoint(x: rightCorner.x + run, y: top))
        // Down into the body far enough that the union cannot leave a sliver,
        // and no further — a region that reached the divider would be a region
        // the boolean op has to trim against the body's corners.
        p.addLine(to: CGPoint(x: rightCorner.x + run, y: top + HotkeyMetrics.cornerRadius))
        p.addLine(to: CGPoint(x: leftCorner.x - run, y: top + HotkeyMetrics.cornerRadius))
        p.closeSubpath()
        return p
    }
}

/// Which edge of the panel the tail leaves from.
nonisolated enum VerticalEdge: Equatable, Hashable, Sendable {
    case top, bottom
}
