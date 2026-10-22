import CoreGraphics
import Foundation

// MARK: - The soundboard wheel's geometry
//
// docs/CLIPS-PRESENCE.md, Phase 6 (D20). Discord's wheel, read out of build
// 643186 (`026ef0ca9206d4ba.js`): eight places round a ring, a page of eight
// at a time with the scroll wheel turning pages ("Scroll for more"), 96 × 52
// sounds, a dead zone in the middle a tenth of the wheel across, and the sound
// chosen by the *direction* the pointer has moved from the centre rather than
// by what it is over — so a flick picks a sound without aiming at it.
//
// The eight places, as Discord writes them, top first and clockwise:
//
//   (.5, .05) (.95, .2) (1, .5) (.95, .8) (.5, .95) (.05, .8) (0, .5) (.05, .2)
//
// Discord casts a ray from the centre through the pointer and takes the box it
// crosses; over these eight boxes that is the slot whose bearing is nearest,
// which is what this computes and what a test can state.

public enum SoundboardWheelLayout {
    /// Sounds on one page.
    public static let pageSize = 8

    /// Each place, as a point in the unit square — top left (0, 0).
    public static let slots: [CGPoint] = [
        CGPoint(x: 0.5, y: 0.05), CGPoint(x: 0.95, y: 0.2), CGPoint(x: 1, y: 0.5),
        CGPoint(x: 0.95, y: 0.8), CGPoint(x: 0.5, y: 0.95), CGPoint(x: 0.05, y: 0.8),
        CGPoint(x: 0, y: 0.5), CGPoint(x: 0.05, y: 0.2),
    ]

    /// A sound's size, and the wheel's, in points — Discord's.
    public static let itemSize = CGSize(width: 96, height: 52)
    public static let wheelSide: CGFloat = 288

    /// The dead zone's radius as a fraction of the wheel's side: 28.8 of 288.
    public static let deadZone: CGFloat = 0.1

    /// Where the item for `slot` sits on a wheel of `side` points: Discord's
    /// placement — left-aligned on the left half, right-aligned on the right,
    /// centred on the axis — so every sound stays inside the wheel.
    public static func frame(of slot: Int, side: CGFloat = wheelSide, item: CGSize = itemSize) -> CGRect {
        let point = slots[slot % slots.count]
        func place(_ unit: CGFloat, along length: CGFloat, size: CGFloat) -> CGFloat {
            let at = unit * length
            if unit > 0.5 { return at - size }
            if unit < 0.5 { return at }
            return at - size / 2
        }
        return CGRect(
            x: place(point.x, along: side, size: item.width),
            y: place(point.y, along: side, size: item.height),
            width: item.width,
            height: item.height
        )
    }

    /// The bearing of each place from the centre, in radians clockwise from
    /// straight up.
    public static let bearings: [Double] = slots.map { point in
        bearing(dx: Double(point.x - 0.5), dy: Double(point.y - 0.5))
    }

    /// Clockwise from straight up, in 0..<2π. `dy` grows downwards.
    public static func bearing(dx: Double, dy: Double) -> Double {
        let angle = atan2(dx, -dy)
        return angle < 0 ? angle + 2 * .pi : angle
    }

    /// The place the pointer is choosing, or nil inside the dead zone.
    ///
    /// - Parameters:
    ///   - offset: the pointer's offset from the wheel's centre, in points,
    ///     y growing downwards.
    ///   - side: the wheel's side, in points.
    ///   - count: how many sounds this page holds; a bearing towards an empty
    ///     place chooses nothing.
    public static func slot(at offset: CGVector, side: CGFloat = wheelSide, count: Int = pageSize) -> Int? {
        let distance = hypot(offset.dx, offset.dy)
        guard distance > side * deadZone, count > 0 else { return nil }
        let bearing = bearing(dx: Double(offset.dx), dy: Double(offset.dy))
        var best = 0
        var bestGap = Double.infinity
        for (index, target) in bearings.enumerated() {
            var gap = abs(bearing - target)
            if gap > .pi { gap = 2 * .pi - gap }
            if gap < bestGap {
                bestGap = gap
                best = index
            }
        }
        return best < count ? best : nil
    }

    /// The sounds split into pages of eight.
    public static func pages<T>(of items: [T]) -> [[T]] {
        stride(from: 0, to: items.count, by: pageSize).map {
            Array(items[$0 ..< min($0 + pageSize, items.count)])
        }
    }
}
