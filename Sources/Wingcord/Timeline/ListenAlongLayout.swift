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
    var buttonRect: CGRect?
}

nonisolated enum ListenAlongLayoutEngine {
    static let padding: CGFloat = 14
    static let artSide: CGFloat = 64
    static let artCorner: CGFloat = 10
    static let gutter: CGFloat = 12
    static let lineGap: CGFloat = 4
    /// The faces beside "N Listening".
    static let faceSide: CGFloat = 16
    /// The colored rule down the leading edge — the activity invitation's own
    /// idiom (`ActivityInviteLayoutEngine.rule`), in Spotify's green.
    static let rule: CGFloat = ActivityInviteLayoutEngine.rule

    static func layout(
        _ invite: ListenAlongInvite,
        isLive: Bool,
        origin: CGPoint,
        availableWidth: CGFloat,
        style: MessageTextStyle
    ) -> ListenAlongSlot {
        let cardWidth = min(Metrics.embedMaxWidth, availableWidth)
        let contentX = origin.x + rule + padding
        let contentRight = origin.x + cardWidth - padding
        var y = origin.y + padding

        let headerOrigin = CGPoint(x: contentX, y: y)
        y += lineHeight(style.metadataFont) + padding * 0.75

        let artRect = CGRect(x: contentX, y: y, width: artSide, height: artSide)
        let textX = artRect.maxX + gutter
        let titleHeight = lineHeight(NSFont.systemFont(ofSize: style.bodyFont.pointSize, weight: .semibold))
        let detailHeight = max(lineHeight(style.metadataFont), faceSide)
        let lines: [CGFloat] = isLive ? [titleHeight, detailHeight, detailHeight] : [titleHeight, detailHeight]
        let textHeight = lines.reduce(0, +) + lineGap * CGFloat(lines.count - 1)
        var lineTop = artRect.midY - textHeight / 2
        var lineTops: [CGFloat] = []
        for height in lines {
            lineTops.append(lineTop)
            lineTop += height + lineGap
        }
        y = max(artRect.maxY, lineTop - lineGap)

        var buttonRect: CGRect?
        if isLive {
            y += padding
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
            buttonRect: buttonRect
        )
    }

    static func lineHeight(_ font: NSFont) -> CGFloat {
        (font.ascender - font.descender + font.leading).rounded(.up)
    }

    /// The clock beside the note: `m:ss`, and `h:mm:ss` past the hour —
    /// Discord's elapsed timer.
    static func clock(since start: Date, now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(start)))
        let seconds = elapsed % 60, minutes = (elapsed / 60) % 60, hours = elapsed / 3600
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
