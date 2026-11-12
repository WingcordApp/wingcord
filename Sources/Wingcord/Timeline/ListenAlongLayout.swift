import AppKit
import WingcordCore

/// A listen-along invitation's card, as geometry.
///
/// **Only the box is laid out; what it says is painted.** The track, the cover,
/// the clock and who is listening all come from the host's presence and move
/// without the row being measured again — see
/// `TimelineRowPainter.State.listenAlong`. The one fact the layout takes is
/// whether the party is still on: Discord's ended card ("The listening party
/// is over!") has no button, so it is a different height.
nonisolated struct ListenAlongSlot: Sendable {
    var rect: CGRect
    var source: ListenAlongInvite
    var isLive: Bool
    /// "Invite to Listen Along on Spotify".
    var headerOrigin: CGPoint
    var artRect: CGRect
    /// The text column beside the cover: its left edge and width, and its
    /// three lines' tops — the title, then the clock and the listeners on a
    /// live card; the title and "The listening party is over!" on an ended one.
    var textX: CGFloat
    var textWidth: CGFloat
    var lineTops: [CGFloat]
    /// The track's progress line, on a live card.
    var progressRect: CGRect?
    var buttonRect: CGRect?
}

nonisolated enum ListenAlongLayoutEngine {
    static let padding: CGFloat = ActivityInviteLayoutEngine.padding
    /// The cover is the card's subject, so it is the biggest thing on it.
    static let artSide: CGFloat = 72
    static let artCorner: CGFloat = 12
    static let gutter: CGFloat = 14
    static let lineGap: CGFloat = 5
    static let faceSide: CGFloat = 18
    /// The mark beside "Listen Along on Spotify".
    static let markSide: CGFloat = 15
    /// The track's progress, under the cover's row.
    static let progressHeight: CGFloat = 4

    static func layout(
        _ invite: ListenAlongInvite,
        isLive: Bool,
        origin: CGPoint,
        availableWidth: CGFloat,
        style: MessageTextStyle
    ) -> ListenAlongSlot {
        let cardWidth = min(ActivityInviteLayoutEngine.maxWidth, availableWidth)
        let contentX = origin.x + padding
        let contentRight = origin.x + cardWidth - padding
        var y = origin.y + padding

        let headerOrigin = CGPoint(x: contentX, y: y)
        y += max(markSide, lineHeight(ActivityInviteLayoutEngine.eyebrowFont(style)))
            + ActivityInviteLayoutEngine.rowGap

        let artRect = CGRect(x: contentX, y: y, width: artSide, height: artSide)
        let textX = artRect.maxX + gutter
        let titleHeight = lineHeight(NSFont.systemFont(ofSize: style.bodyFont.pointSize + 1, weight: .semibold))
        let detailHeight = max(lineHeight(style.metadataFont), faceSide)
        // The track, the clock, and who is listening — or, once it is over,
        // the service and the one line that says so.
        let lines: [CGFloat] = isLive ? [titleHeight, detailHeight, detailHeight] : [titleHeight, detailHeight]
        let textHeight = lines.reduce(0, +) + lineGap * CGFloat(lines.count - 1)
        var lineTop = artRect.midY - textHeight / 2
        var lineTops: [CGFloat] = []
        for height in lines {
            lineTops.append(lineTop)
            lineTop += height + lineGap
        }
        y = max(artRect.maxY, lineTop - lineGap)

        var progressRect: CGRect?
        var buttonRect: CGRect?
        if isLive {
            y += ActivityInviteLayoutEngine.rowGap
            let progress = CGRect(
                x: contentX, y: y, width: max(60, contentRight - contentX), height: progressHeight
            )
            progressRect = progress
            y = progress.maxY + ActivityInviteLayoutEngine.rowGap
            let rect = CGRect(
                x: contentX,
                y: y,
                width: max(60, contentRight - contentX),
                height: ActivityInviteLayoutEngine.buttonHeight
            )
            buttonRect = rect
            y = rect.maxY
        }

        return ListenAlongSlot(
            rect: CGRect(x: origin.x, y: origin.y, width: cardWidth, height: y - origin.y + padding),
            source: invite,
            isLive: isLive,
            headerOrigin: headerOrigin,
            artRect: artRect,
            textX: textX,
            textWidth: max(40, contentRight - textX),
            lineTops: lineTops,
            progressRect: progressRect,
            buttonRect: buttonRect
        )
    }

    static func lineHeight(_ font: NSFont) -> CGFloat {
        (font.ascender - font.descender + font.leading).rounded(.up)
    }

    /// The clock beside the note: `m:ss`, and `h:mm:ss` past the hour —
    /// Discord's elapsed timer.
    static func clock(since start: Date, now: Date) -> String {
        clock(seconds: Int(now.timeIntervalSince(start)))
    }

    static func clock(seconds: Int) -> String {
        let elapsed = max(0, seconds)
        let seconds = elapsed % 60, minutes = (elapsed / 60) % 60, hours = elapsed / 3600
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
