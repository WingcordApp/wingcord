import CoreGraphics
import Foundation

/// The arithmetic of the viewer's flights — a picture growing out of its
/// thumbnail as the viewer opens, and shrinking back into it as it closes (a
/// shared element transition; REDESIGN.md D8).
///
/// **A flight morphs two rectangles at once.** The *clip* is the window the
/// picture is seen through — the thumbnail's rounded box at home, the picture's
/// own frame on stage — and the *content* is the picture itself: aspect-filled
/// into the box at home, exactly as the transcript crops it into a mosaic cell,
/// and fitted to the stage when open. Interpolating both, with the corners and
/// the opacity, is what makes the picture land in its cell without a jump in
/// its crop.
///
/// Pure, so `MediaFlightTests` can hold it to its ends: the canvas animates two
/// springs (the content's centre, and a morph from 0 to 1 for everything else)
/// and asks this for the frame at each step.
nonisolated struct MediaFlight: Equatable, Sendable {

    /// One end of a flight, in the stage's coordinates.
    struct Frame: Equatable, Sendable {
        /// What the picture is seen through.
        var clip: CGRect
        /// Where the whole picture is, which the clip may crop.
        var content: CGRect
        var cornerRadius: CGFloat
        var alpha: CGFloat = 1
    }

    var from: Frame
    var to: Frame

    /// The frame with the morph at `progress` (0 is `from`, 1 is `to`) and the
    /// content's centre wherever its own spring has it — the two move apart so
    /// a throw's sideways speed is kept, not flattened onto the path.
    func frame(progress: CGFloat, contentCenter: CGPoint) -> Frame {
        let size = Self.lerp(from.content.size, to.content.size, progress)
        let content = CGRect(
            x: contentCenter.x - size.width / 2,
            y: contentCenter.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        // The clip keeps its place relative to the picture, moving between
        // where it sat at either end.
        let offset = Self.lerp(
            CGPoint(x: from.clip.midX - from.content.midX, y: from.clip.midY - from.content.midY),
            CGPoint(x: to.clip.midX - to.content.midX, y: to.clip.midY - to.content.midY),
            progress
        )
        let clipSize = Self.lerp(from.clip.size, to.clip.size, progress)
        let clip = CGRect(
            x: contentCenter.x + offset.x - clipSize.width / 2,
            y: contentCenter.y + offset.y - clipSize.height / 2,
            width: clipSize.width,
            height: clipSize.height
        )
        return Frame(
            clip: clip,
            content: content,
            cornerRadius: max(0, from.cornerRadius + (to.cornerRadius - from.cornerRadius) * progress),
            alpha: min(1, max(0, from.alpha + (to.alpha - from.alpha) * progress))
        )
    }

    /// The picture in a thumbnail's box: filling it and cropped, as a mosaic
    /// cell draws it, or fitted, as a lone picture is (its box already has the
    /// picture's shape, so the two agree).
    static func home(box: CGRect, cornerRadius: CGFloat, pictureSize: CGSize, cropsToFill: Bool) -> Frame {
        Frame(
            clip: box,
            content: cropsToFill ? aspectFill(pictureSize, in: box) : aspectFit(pictureSize, in: box),
            cornerRadius: cornerRadius
        )
    }

    /// The picture at rest on the stage: its own frame, uncropped.
    static func stage(content: CGRect) -> Frame {
        Frame(clip: content, content: content, cornerRadius: 0)
    }

    /// Where a flight with no thumbnail to come from or go to begins or ends:
    /// the picture a little smaller, and gone — the materialise every other
    /// surface arrives with, for a picture whose cell is off screen.
    static func dissolve(content: CGRect) -> Frame {
        let shrunk = content.insetBy(dx: content.width * 0.04, dy: content.height * 0.04)
        return Frame(clip: shrunk, content: shrunk, cornerRadius: 0, alpha: 0)
    }

    static func aspectFill(_ size: CGSize, in box: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = max(box.width / size.width, box.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: box.midX - fitted.width / 2, y: box.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    static func aspectFit(_ size: CGSize, in box: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: box.midX - fitted.width / 2, y: box.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    /// How far the scrim and the chrome are in: 0 at home, 1 on stage.
    static func presence(progress: CGFloat, isOpening: Bool) -> Double {
        Double(min(1, max(0, isOpening ? progress : 1 - progress)))
    }

    private static func lerp(_ a: CGSize, _ b: CGSize, _ t: CGFloat) -> CGSize {
        CGSize(width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}

/// A gesture's speed from its recent samples — the last ~80 ms, not the last
/// event, whose delta over its own interval is whatever the event loop was
/// doing at that instant (§3).
nonisolated struct GestureVelocity: Sendable {
    private var samples: [(time: TimeInterval, value: CGPoint)] = []
    private static let window: TimeInterval = 0.08

    mutating func reset() { samples.removeAll(keepingCapacity: true) }

    mutating func add(_ value: CGPoint, at time: TimeInterval) {
        samples.append((time, value))
        while let first = samples.first, time - first.time > Self.window, samples.count > 2 {
            samples.removeFirst()
        }
    }

    /// Points per second.
    var velocity: CGPoint {
        guard let first = samples.first, let last = samples.last else { return .zero }
        let interval = last.time - first.time
        guard interval > 0.004 else { return .zero }
        return CGPoint(x: (last.value.x - first.value.x) / interval, y: (last.value.y - first.value.y) / interval)
    }
}

/// Which way a two-finger gesture at fit has committed to, once it has moved
/// far enough to say: sideways pages, up or down takes the picture away.
nonisolated enum GestureAxis: Equatable, Sendable {
    case undecided
    case paging
    case dismissing

    /// The ~10 points of hysteresis before a direction is chosen — apple-design
    /// §10 — and the dominant axis after it.
    static func resolve(_ translation: CGPoint, hysteresis: CGFloat = 10) -> GestureAxis {
        guard hypot(translation.x, translation.y) >= hysteresis else { return .undecided }
        return abs(translation.x) > abs(translation.y) ? .paging : .dismissing
    }
}

/// The gallery's paging decision: which neighbour a released swipe lands on.
nonisolated enum MediaPaging {
    /// -1 for the previous picture, 1 for the next, 0 to stay — from where the
    /// swipe is *going* (`Motion.projectedPosition`), never where it let go, so
    /// a short fast flick turns the page and a long slow drag that comes back
    /// does not.
    static func landing(offset: CGFloat, velocity: CGFloat, pageWidth: CGFloat, canPage: Bool) -> Int {
        guard canPage, pageWidth > 0 else { return 0 }
        // The system's own deceleration: at the snappier 0.99 a quick flick
        // projects a ninth as far and never turns the page.
        let projected = Motion.projectedPosition(from: offset, velocity: velocity)
        if projected <= -pageWidth / 2 { return 1 }
        if projected >= pageWidth / 2 { return -1 }
        return 0
    }
}
