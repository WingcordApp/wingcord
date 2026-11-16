import CoreGraphics
import Foundation
import WingcordCore

/// One run's face in the transcript's bubbles, read from the laid-out rows:
/// what it shows, where it belongs, and how far up it may ride.
///
/// Telegram's arrangement (Alex, 2026-11-16, his Images 6 and 7; decisions in
/// BETA2 §7): the face sits beside the run's last bubble, and while that bubble
/// is below the readable bottom the face rides the bottom of the transcript, up
/// to the run's first bubble and no further.
nonisolated struct StickyFaceRun: Equatable, Sendable {
    /// The run's first message: the face keeps its layer while the run grows.
    var headID: MessageID
    /// The run's last message, whose row carries the face.
    var tailID: MessageID
    var authorID: UserID
    var isCrosspost: Bool
    var avatarURL: URL?
    var monogram: String
    var decorationURL: URL?
    /// The face on its last bubble's foot, in document space.
    var natural: CGRect
    /// The top of the run's first bubble: the face never rides higher.
    var top: CGFloat

    /// The face's top for a readable bottom (the transcript's bottom edge less
    /// the composer over it): its own place, or riding the bottom while its own
    /// place is below that, never above the run's first bubble.
    func y(readableBottom: CGFloat) -> CGFloat {
        let ceiling = min(top, natural.minY)
        return max(ceiling, min(natural.minY, readableBottom - natural.height))
    }

    /// Every run in `rows` that has a face, in document order. `offsets[i]` is
    /// row `i`'s top, as the canvas keeps it.
    ///
    /// A face is on the run's last row (`MessageRow.avatarRect`, bubbles only).
    /// Its run reaches back over the same author's rows to the one that opens
    /// with the name, or to the first that isn't part of it: another author,
    /// something that isn't a message, or an earlier run's last row.
    static func runs(in rows: [TimelineRow], offsets: [CGFloat]) -> [StickyFaceRun] {
        var runs: [StickyFaceRun] = []
        for (index, row) in rows.enumerated() {
            guard case .message(let tail) = row.kind, tail.bubbles != nil,
                  let avatar = tail.avatarRect, index < offsets.count
            else { continue }
            var headIndex = index
            while case .message(let current) = rows[headIndex].kind, !current.hasAuthorLine, headIndex > 0,
                  case .message(let previous) = rows[headIndex - 1].kind,
                  previous.authorID == tail.authorID, previous.bubbles != nil, previous.avatarRect == nil {
                headIndex -= 1
            }
            guard case .message(let head) = rows[headIndex].kind else { continue }
            // The first bubble's top; a first message drawn bare (a sticker,
            // emoji on their own) starts under its name.
            let headTop = head.bubbles?.bubble?.rect.minY ?? (head.hasAuthorLine ? head.authorRect.maxY : 0)
            runs.append(StickyFaceRun(
                headID: head.id,
                tailID: tail.id,
                authorID: tail.authorID,
                isCrosspost: tail.isCrosspost,
                avatarURL: tail.avatarURL,
                monogram: tail.avatarMonogram,
                decorationURL: tail.decorationURL,
                natural: avatar.offsetBy(dx: 0, dy: offsets[index]),
                top: offsets[headIndex] + headTop
            ))
        }
        return runs
    }
}
