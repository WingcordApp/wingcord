import AppKit
import CoreGraphics
import Foundation
import WingcordCore

/// An activity invitation, measured.
///
/// **The whole card is drawn from two fields.** The launch message carries no
/// content, no embed and no component — only `application` and
/// `activity_instance` — so unlike an embed there is nothing here that was sent
/// as text. Everything below is composed by this client.
nonisolated struct ActivityInviteSlot: Sendable {
    var rect: CGRect
    /// What the card was built from. Carried so the prefetch pass — the one
    /// place that knows a card is actually on screen — can ask for its colour
    /// without going back to the message.
    var source: ActivityInvite
    var iconURL: URL?
    var iconRect: CGRect
    var monogram: TimelineTextBlock
    var monogramOrigin: CGPoint
    var title: TimelineTextBlock
    var titleOrigin: CGPoint
    /// Where the live status line is drawn, and how wide it may run.
    ///
    /// **The line itself is NOT here.** It comes from presence, which changes
    /// constantly, and a layout is cached until the channel is switched — so a
    /// status laid out here was frozen at whatever it said when the transcript
    /// was last measured. The slot is reserved and the text is painted; see
    /// `TimelineRowPainter.State.activityInviteStatus`.
    ///
    /// Reserving it costs nothing: the two lines total about 34 points against
    /// a 40-point icon, so the card's height is the icon's either way.
    var statusOrigin: CGPoint
    var statusWidth: CGFloat
    /// The one control. See `ActivityInviteLayoutEngine` for why it is never
    /// absent and never disabled.
    var buttonRect: CGRect
    var buttonLabel: TimelineTextBlock
    var buttonLabelOrigin: CGPoint
}

nonisolated enum ActivityInviteLayoutEngine {

    static let padding: CGFloat = 14
    static let iconSide: CGFloat = 40
    static let iconCorner: CGFloat = 13
    static let buttonHeight: CGFloat = 34
    static let buttonCorner: CGFloat = 8
    static let gutter: CGFloat = 12
    /// The coloured rule down the leading edge.
    ///
    /// **This app's own idiom for "this belongs to somebody", not Discord's.**
    /// The reference client floods the whole card with a gradient of the app's
    /// colour; an embed here already says the same thing with a bar, and one
    /// vocabulary for one idea is worth more than a resemblance. It also keeps
    /// the card legible on every theme, which a full-bleed fill does not.
    static let rule: CGFloat = 4

    /// **No colour here, deliberately.** The card's accent is quantised from
    /// the app's icon asynchronously, and a colour taken at layout time is a
    /// colour that arrives after the row is already cached — the layout only
    /// re-runs on a presentation or items change, so the card kept the neutral
    /// fallback for the life of the channel. The geometry does not depend on
    /// the colour, so the colour belongs on the paint path, where it costs a
    /// redraw instead of a re-measure.
    static func layout(
        _ invite: ActivityInvite,
        origin: CGPoint,
        availableWidth: CGFloat,
        style: MessageTextStyle
    ) -> ActivityInviteSlot {
        let cardWidth = min(Metrics.embedMaxWidth, availableWidth)
        let contentX = origin.x + rule + padding
        let contentRight = origin.x + cardWidth - padding
        var y = origin.y + padding

        let iconRect = CGRect(x: contentX, y: y, width: iconSide, height: iconSide)
        let textX = iconRect.maxX + gutter
        let textWidth = max(40, contentRight - textX)

        let title = block(
            invite.name,
            font: NSFont.systemFont(ofSize: style.bodyFont.pointSize, weight: .semibold),
            color: style.primaryColor,
            width: textWidth,
            style: style
        )
        // The second line's slot, always reserved. See the note on
        // `statusOrigin` for why the text is not measured here.
        let statusFont = style.metadataFont
        let statusHeight = statusFont.ascender - statusFont.descender
        let textHeight = title.size.height + 2 + statusHeight
        let textTop = iconRect.midY - textHeight / 2
        let titleOrigin = CGPoint(x: textX, y: textTop)
        let statusOrigin = CGPoint(x: textX, y: textTop + title.size.height + 2)

        // The monogram stands in until the icon lands, in the icon's own box.
        let monogram = block(
            String(invite.name.prefix(1)).uppercased(),
            font: NSFont.systemFont(ofSize: iconSide * 0.4, weight: .semibold),
            color: style.secondaryColor,
            width: iconSide,
            style: style
        )

        y = max(iconRect.maxY, textTop + textHeight) + padding

        let buttonRect = CGRect(
            x: contentX,
            y: y,
            width: max(60, contentRight - contentX),
            height: buttonHeight
        )
        // **Centred by its paragraph style, not by its origin.** The block is
        // laid out at the button's full width, so its own `size.width` IS that
        // width — centring the origin against it puts the label back at the
        // left edge, which is exactly what it did.
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        let buttonLabel = TimelineTextBlock(
            text: .plain(NSAttributedString(
                // **"Play" always, in the LAYOUT.** Whether the reader is in
                // the instance comes from presence and changes without a
                // re-measure, so the word is painted rather than laid out —
                // see `TimelineRowPainter.State.activityInviteIsJoined`. The
                // block is laid out at the button's full width and centred by
                // paragraph style, so a different word of the same size lands
                // in the same place.
                string: "Play",
                attributes: [
                    .font: NSFont.systemFont(
                        ofSize: style.bodyFont.pointSize, weight: .semibold
                    ),
                    .foregroundColor: style.primaryColor,
                    .paragraphStyle: centred,
                ]
            )),
            width: buttonRect.width,
            style: style
        )
        y = buttonRect.maxY

        return ActivityInviteSlot(
            rect: CGRect(
                x: origin.x, y: origin.y, width: cardWidth, height: y - origin.y + padding
            ),
            source: invite,
            iconURL: invite.iconHash.flatMap {
                CDN.applicationIcon(id: invite.applicationID, hash: $0, side: iconSide)
            },
            iconRect: iconRect,
            monogram: monogram,
            monogramOrigin: CGPoint(
                x: iconRect.midX - monogram.size.width / 2,
                y: iconRect.midY - monogram.size.height / 2
            ),
            title: title,
            titleOrigin: titleOrigin,
            statusOrigin: statusOrigin,
            statusWidth: textWidth,
            buttonRect: buttonRect,
            buttonLabel: buttonLabel,
            buttonLabelOrigin: CGPoint(
                x: buttonRect.minX,
                y: buttonRect.midY - buttonLabel.size.height / 2
            )
        )
    }

    /// "00:08 · Adding videos · 1 Playing", with only the parts that are known.
    ///
    /// **Joined rather than stacked**, because the card is one row of text
    /// beside a 40-point icon and three lines would make it taller than the
    /// message it belongs to. The clock is `mm:ss` under an hour and `h:mm:ss`
    /// over it — a two-hour session reading "127:14" is a number nobody parses.
    static func statusLine(_ state: ActivityInviteState) -> String? {
        // **Said only where absence is evidence.** See
        // `ActivityInviteState.hasEnded` — in a server this is never set,
        // because nothing here can tell an empty instance from one whose
        // players' presences never reached this client.
        if state.hasEnded { return "Nobody is playing right now" }
        var parts: [String] = []
        if let startedAt = state.startedAt {
            let elapsed = max(0, Int(Date.now.timeIntervalSince(startedAt)))
            let seconds = elapsed % 60, minutes = (elapsed / 60) % 60, hours = elapsed / 3600
            parts.append(
                hours > 0
                    ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
                    : String(format: "%02d:%02d", minutes, seconds)
            )
        }
        if let detail = state.detail, !detail.isEmpty { parts.append(detail) }
        if let count = state.playerCount, count > 0 {
            parts.append(count == 1 ? "1 playing" : "\(count) playing")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    /// See `PollLayoutEngine.block` — the same helper, for the same reason.
    private static func block(
        _ string: String,
        font: NSFont,
        color: NSColor,
        width: CGFloat,
        style: MessageTextStyle
    ) -> TimelineTextBlock {
        TimelineTextBlock(
            text: .plain(NSAttributedString(
                string: string,
                attributes: [.font: font, .foregroundColor: color]
            )),
            width: width,
            style: style
        )
    }
}
