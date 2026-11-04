import AppKit
import CoreGraphics
import SwiftUI

/// What sits in front of Active Now, Online and Offline in the member list.
///
/// **Discord's own outlines** (`tU` in `763349`, `214947` and `845311`), their arcs
/// resolved to the absolute cubics `VectorPath` takes, as `AppsGlyph`'s are. No SF
/// Symbol is a game pad's four lobes, and a plain `person.fill` with a dot laid on
/// it wouldn't have the hole the dot sits in.
nonisolated enum MemberSectionGlyphs {

    // MARK: Active Now

    /// Which lobe is dim, step by step, while the pointer is in the list: a run of
    /// d-pad presses, 150 ms a step, or nothing under Reduce Motion — Discord's `tz`.
    static let danceSteps: [Int?] = [nil, nil, nil, 0, 0, 2, 2, 1, 3, 1, 3].flatMap { [$0, nil] }
    static let danceInterval: TimeInterval = 0.15

    /// Top, left, bottom and right, on a 14-unit grid.
    private nonisolated(unsafe) static let lobes: [CGPath] = [
        """
        M8.276 4.057 C8.526 3.807 8.667 3.468 8.667 3.114 L8.667 1.333 C8.667 0.597 8.07 0 7.333 0 L6 0 \
        C5.264 0 4.667 0.597 4.667 1.333 L4.667 3.114 C4.667 3.468 4.807 3.807 5.057 4.057 L6.195 5.195 \
        C6.456 5.456 6.878 5.456 7.138 5.195 L8.276 4.057 Z
        """,
        """
        M4.057 5.057 C3.807 4.807 3.468 4.667 3.114 4.667 L1.333 4.667 C0.597 4.667 0 5.264 0 6 L0 7.333 \
        C0 8.07 0.597 8.667 1.333 8.667 L3.114 8.667 C3.468 8.667 3.807 8.526 4.057 8.276 L5.195 7.138 \
        C5.456 6.878 5.456 6.456 5.195 6.195 L4.057 5.057 Z
        """,
        """
        M5.057 9.276 C4.807 9.526 4.667 9.865 4.667 10.219 L4.667 12 C4.667 12.736 5.264 13.333 6 13.333 \
        L7.333 13.333 C8.07 13.333 8.667 12.736 8.667 12 L8.667 10.219 C8.667 9.865 8.526 9.526 8.276 9.276 \
        L7.138 8.138 C6.878 7.878 6.456 7.878 6.195 8.138 L5.057 9.276 Z
        """,
        """
        M10.219 4.667 C9.865 4.667 9.526 4.807 9.276 5.057 L8.138 6.195 C7.878 6.456 7.878 6.878 8.138 7.138 \
        L9.276 8.276 C9.526 8.526 9.865 8.667 10.219 8.667 L12 8.667 C12.736 8.667 13.333 8.07 13.333 7.333 \
        L13.333 6 C13.333 5.264 12.736 4.667 12 4.667 L10.219 4.667 Z
        """,
    ].compactMap(VectorPath.parse)

    /// Four lobes at 16 points, centred in `box`: green, Discord's
    /// `--icon-voice-connected`, with one of them at half strength mid-dance.
    static func drawActiveNow(in box: CGRect, dimmedLobe: Int?, context: CGContext) {
        let side: CGFloat = 16
        let scale = side / 14
        // `VectorPath` doesn't care which way up its grid is, and neither do the
        // lobes: the canvas is flipped, as the SVG's own space is.
        let green = NSColor(Palette.presenceOnline)
        for (index, lobe) in lobes.enumerated() {
            var place = CGAffineTransform(
                translationX: box.midX - side / 2, y: box.midY - side / 2
            ).scaledBy(x: scale, y: scale)
            guard let path = lobe.copy(using: &place) else { continue }
            context.setFillColor(green.withAlphaComponent(index == dimmedLobe ? 0.5 : 1).cgColor)
            context.addPath(path)
            context.fillPath()
        }
    }

    // MARK: Online

    /// Discord's friends icon, on a 24-unit grid.
    private nonisolated(unsafe) static let person: CGPath? = VectorPath.parse(
        """
        M13 10 C15.209 10 17 8.209 17 6 C17 3.791 15.209 2 13 2 C10.791 2 9 3.791 9 6 C9 8.209 10.791 10 13 10 Z \
        M3 5 L3 4.25 C3 3.56 3.56 3 4.25 3 C4.94 3 5.49 3.56 5.58 4.25 C6.12 8.65 9.46 12 13 12 L14 12 \
        C18.418 12 22 15.582 22 20 C22 21.105 21.105 22 20 22 C19.908 21.999 19.826 21.939 19.8 21.85 \
        C19.497 21.012 19.051 20.234 18.48 19.55 C18.33 19.35 18.06 19.49 18.09 19.72 L18.34 21.72 \
        C18.36 21.87 18.24 22 18.09 22 L9 22 C7.895 22 7 21.105 7 20 L7 17.78 C7 16.21 6.33 14.73 5.47 13.41 \
        C3.872 10.895 3.016 7.98 3 5 Z
        """
    )

    /// That icon at 16 points with a real hole for a 6-point green dot — Discord's
    /// `.icon`, `.mask` and `.onlineDot` (`205781`): the dot's centre 3 in from the
    /// trailing edge and 4 up from the foot, the hole 2 wider than it all round.
    static func drawOnline(in box: CGRect, ink: NSColor, context: CGContext) {
        let side: CGFloat = 16
        let origin = CGPoint(x: box.midX - side / 2, y: box.midY - side / 2)
        let centre = CGPoint(x: origin.x + side - 3, y: origin.y + side - 4)
        if let person {
            var place = CGAffineTransform(translationX: origin.x, y: origin.y)
                .scaledBy(x: side / 24, y: side / 24)
            if let path = person.copy(using: &place) {
                context.saveGState()
                context.addRect(CGRect(origin: origin, size: CGSize(width: side, height: side)).insetBy(dx: -2, dy: -2))
                context.addEllipse(in: CGRect(x: centre.x - 5, y: centre.y - 5, width: 10, height: 10))
                context.clip(using: .evenOdd)
                context.setFillColor(ink.cgColor)
                context.addPath(path)
                context.fillPath()
                context.restoreGState()
            }
        }
        context.setFillColor(NSColor(Palette.presenceOnline).cgColor)
        context.fillEllipse(in: CGRect(x: centre.x - 3, y: centre.y - 3, width: 6, height: 6))
    }

    // MARK: Offline

    /// The status ring at 12 points.
    static func drawOffline(in box: CGRect, context: CGContext) {
        let side: CGFloat = 12
        let width: CGFloat = 3
        context.setStrokeColor(NSColor(Palette.presenceOffline).cgColor)
        context.setLineWidth(width)
        context.strokeEllipse(in: CGRect(
            x: box.midX - side / 2 + width / 2,
            y: box.midY - side / 2 + width / 2,
            width: side - width,
            height: side - width
        ))
    }
}
