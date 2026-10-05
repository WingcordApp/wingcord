import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import WingcordCore

/// AutoMod's picture, the one Discord gives it (`3451`'s static
/// `32336875baac6ac1.png`), from the bundle — the transcript's faces are
/// fetched by URL, and a file URL goes through the same store.
nonisolated enum AutoModArt {
    static let avatarURL: URL? = Bundle.module.url(forResource: "automod", withExtension: "png", subdirectory: "Art")
}

nonisolated extension TimelineLayoutEngine {

    /// AutoMod's message, as Discord draws one (`n0`, `iu`): its face, its
    /// name in the brand ink beside ✓ OFFICIAL and Discord's sentence, then
    /// the card, and the reactions under everything.
    ///
    /// **None of the ordinary header is used**, because the message's own
    /// author is the member AutoMod acted on: a face in the gutter would open
    /// the member's profile from AutoMod's picture. The member is inside the
    /// card, where Discord puts them.
    static func autoModRow(
        _ item: TimelineMessage,
        _ autoMod: AutoModMessage,
        input: Input,
        parser: MarkdownParser
    ) -> MessageRow {
        let message = item.message
        let style = input.style
        let margin = TimelineMetrics.horizontalMargin
        let contentX = TimelineMetrics.contentInset
        let contentWidth = max(160, input.width - contentX - margin)
        let top = input.settings.runSpacing
        var writer = DrawnCardWriter(style: style)

        writer.card.parts.append(.avatar(
            AutoModArt.avatarURL,
            monogram: "A",
            CGRect(x: margin, y: top, width: Metrics.avatarMessage, height: Metrics.avatarMessage)
        ))
        let header = autoModHeader(
            autoMod, message: message, x: contentX, y: top, width: contentWidth,
            input: input, parser: parser, writer: &writer
        )

        // `.embedCard { margin-top: 4px }`, both cards.
        let cardOrigin = CGPoint(x: contentX, y: header.bottom + 4)
        let bottom: CGFloat
        var spoken = [header.spoken]
        switch autoMod {
        case .alert(let alert):
            let card = alertCard(
                alert, message: message, origin: cardOrigin, width: contentWidth,
                input: input, parser: parser, writer: &writer
            )
            spoken.append(card.spoken)
            bottom = actionBar(
                alert, message: message, top: card.bottom, x: contentX, width: contentWidth,
                input: input, writer: &writer
            )
        case .notification(let notice):
            let card = noticeCard(
                notice, message: message, origin: cardOrigin, width: contentWidth,
                input: input, writer: &writer
            )
            spoken.append(card.spoken)
            // `.embedCard { margin-bottom: 12px }`, the notice's alone.
            bottom = card.bottom + 12
        }
        writer.card.rect = CGRect(x: margin, y: top, width: input.width - margin * 2, height: bottom - top)

        // A moderator's tick on an alert is how a team marks it handled, and
        // the payload carries it like any message's.
        var reactions: [ReactionSlot] = []
        var reactionControls: [ReactionControlSlot] = []
        _ = Self.layoutReactions(
            message.reactions,
            contentX: contentX,
            y: bottom,
            width: contentWidth,
            style: style,
            offersBookmark: true,
            into: &reactions,
            controls: &reactionControls
        )

        return MessageRow(
            id: message.id,
            authorID: message.authorID,
            hasAuthorLine: false,
            mentionsMe: item.flags.contains(.mentionsMe),
            isPending: false,
            isFailed: false,
            avatarRect: nil,
            avatarURL: nil,
            avatarMonogram: "",
            decorationURL: nil,
            authorName: "AutoMod",
            authorColor: nil,
            authorRect: CGRect(x: contentX, y: top, width: 0, height: 0),
            timestampText: "",
            timestampRect: .zero,
            // AutoMod's face is in the gutter: no time is revealed over it.
            gutterTimestampText: "",
            textBlock: nil,
            textOrigin: CGPoint(x: contentX, y: top),
            attachments: [],
            stickers: [],
            embeds: [],
            components: [],
            poll: nil,
            activityInvite: nil,
            reactions: reactions,
            reactionControls: reactionControls,
            card: writer.card,
            accessibilityLabel: spoken.filter { !$0.isEmpty }.joined(separator: ". ")
        )
    }

    // MARK: The header

    /// "AutoMod", ✓ OFFICIAL, Discord's sentence and the time — beside the tag
    /// while the sentence fits there, and on a line of its own when it does
    /// not, as Discord's wrapping row moves the whole sentence down.
    private static func autoModHeader(
        _ autoMod: AutoModMessage,
        message: Message,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        input: Input,
        parser: MarkdownParser,
        writer: inout DrawnCardWriter
    ) -> (bottom: CGFloat, spoken: String) {
        let style = input.style
        let band = TimelineMetrics.headerHeight
        // `.username { font-weight: semibold }` in `--text-brand`.
        let name = writer.block("AutoMod", font: style.authorFont, color: .controlAccentColor, width: width)
        writer.text(name, at: CGPoint(x: x, y: y + ((band - name.size.height) / 2).rounded()))
        let tag = CGRect(x: x + name.size.width + 4, y: y + 3, width: AuthorTagChip.width(.official), height: 14)
        writer.card.parts.append(.tag(.official, tag))

        let sentence = autoModSentence(autoMod, message: message, input: input, parser: parser)
        let after = tag.maxX + 4
        let inline = TimelineTextBlock(text: sentence, width: max(1, x + width - after), style: style, hugsText: true)
        let spoken = "AutoMod, \(AuthorTag.official.spokenLabel), \(sentence.plainLabel)"
        if inline.lineCount <= 1 {
            writer.text(inline, at: CGPoint(x: after, y: y + ((band - inline.size.height) / 2).rounded()))
            return (y + max(band, inline.size.height), spoken)
        }
        let below = TimelineTextBlock(text: sentence, width: width, style: style)
        writer.text(below, at: CGPoint(x: x, y: y + band))
        return (y + band + below.size.height, spoken)
    }

    /// Discord's sentence (`fu`) — the channel as its chip, the people as their
    /// names — then the time in the metadata ink, as a header's is.
    private static func autoModSentence(
        _ autoMod: AutoModMessage,
        message: Message,
        input: Input,
        parser: MarkdownParser
    ) -> MessageText {
        let style = input.style
        let body: [NSAttributedString.Key: Any] = [.font: style.bodyFont, .foregroundColor: style.primaryColor]
        let bold: [NSAttributedString.Key: Any] = [.font: style.boldFont, .foregroundColor: style.primaryColor]
        func plain(_ string: String, _ attributes: [NSAttributedString.Key: Any]) -> MessageText {
            .plain(NSAttributedString(string: string, attributes: attributes))
        }
        var pieces: [MessageText] = []
        switch autoMod {
        case .alert(let alert):
            let knowsViewer = alert.interactionUserID.map { input.authors[$0] != nil } ?? false
            for run in alert.headline(knowsInteractionUser: knowsViewer) {
                switch run {
                case .text(let words):
                    pieces.append(plain(words, body))
                case .bold(let words):
                    pieces.append(plain(words, bold))
                case .channel:
                    // A channel this client cannot name is Discord's bold
                    // "unknown-channel", not a chip to nowhere.
                    if let channelID = alert.channelID, input.mentions.channels[channelID] != nil {
                        pieces.append(MessageTextBuilder.build(
                            document: parser.parse("<#\(channelID.rawValue)>"),
                            context: input.mentions,
                            style: style
                        ))
                    } else {
                        pieces.append(plain("unknown-channel", bold))
                    }
                case .author:
                    pieces.append(personName(message.authorID, input: input))
                case .interactionUser:
                    if let viewer = alert.interactionUserID { pieces.append(personName(viewer, input: input)) }
                }
            }
        case .notification(let notice):
            if notice.saysSafetyAlert { pieces.append(plain("safety alert!", body)) }
        }
        let time = input.settings.timestampLabel(message.sentAt, calendar: input.calendar)
        pieces.append(plain(
            (pieces.isEmpty ? "" : "  ") + time,
            [.font: style.metadataFont, .foregroundColor: style.tertiaryColor]
        ))
        return MessageText.joined(pieces)
    }

    /// Somebody's name in their colour, opening their profile — Discord's
    /// username node in the sentence (`nM.tO`).
    private static func personName(_ userID: UserID, input: Input) -> MessageText {
        let author = input.authors[userID]
        let name = NSAttributedString(string: author?.name ?? "Unknown", attributes: [
            .font: input.style.boldFont,
            .foregroundColor: author?.colorValue.map { NSColor(Color(hex: $0)) } ?? input.style.primaryColor,
        ])
        return .plain(name, links: [.init(range: NSRange(location: 0, length: name.length), target: .user(userID))])
    }

    // MARK: The alert

    /// The member's message, as Discord shows it inside the alert (`ny`): their
    /// face and name, the words with what the rule matched lit, the line of
    /// what matched and why, and the decision's reason on its own plate. The
    /// card opens the message where it still exists.
    private static func alertCard(
        _ alert: AutoModAlert,
        message: Message,
        origin: CGPoint,
        width: CGFloat,
        input: Input,
        parser: MarkdownParser,
        writer: inout DrawnCardWriter
    ) -> (bottom: CGFloat, spoken: String) {
        let style = input.style
        let pad = DrawnCardMetrics.padding
        let groundIndex = writer.card.parts.count
        let author = input.authors[message.authorID]
        let name = author?.name ?? "Unknown"
        let side = Metrics.avatarMessage
        let face = CGRect(x: origin.x + pad, y: origin.y + pad, width: side, height: side)
        writer.card.parts.append(.avatar(author?.avatarURL, monogram: author?.monogram ?? "?", face))
        writer.card.controls.append(.init(action: .person(message.authorID), rect: face, accessibilityLabel: name))

        let innerX = face.maxX + TimelineMetrics.avatarGap
        let innerWidth = max(40, origin.x + width - pad - innerX)
        let band = TimelineMetrics.headerHeight
        let nameBlock = TimelineTextBlock(
            text: .plain(NSAttributedString(string: name, attributes: [
                .font: author?.nameFace ?? style.authorFont,
                .foregroundColor: author?.colorValue.map { NSColor(Color(hex: $0)) } ?? style.primaryColor,
            ])),
            width: innerWidth,
            style: style,
            hugsText: true
        )
        let nameOrigin = CGPoint(x: innerX, y: face.minY + ((band - nameBlock.size.height) / 2).rounded())
        writer.text(nameBlock, at: nameOrigin)
        writer.card.controls.append(.init(
            action: .person(message.authorID),
            rect: CGRect(origin: nameOrigin, size: nameBlock.size),
            accessibilityLabel: name
        ))
        var y = face.minY + band + TimelineMetrics.headerGap
        var spoken = [name]

        if !alert.content.isEmpty {
            let built = MessageTextBuilder.build(document: parser.parse(alert.content), context: input.mentions, style: style)
            // Lit in the words as drawn, by the rule's own test — the matched
            // text is plain words, which markdown leaves as they were typed.
            let rendered = built.attributed.string
            let lit = alert.keywordMatchedContent.map { AutoModAlert.highlightRanges(of: $0, in: rendered) } ?? []
            let block = TimelineTextBlock(
                text: built.highlighting(lit.map { NSRange($0, in: rendered) }),
                width: innerWidth,
                style: style
            )
            writer.text(block, at: CGPoint(x: innerX, y: y))
            y += block.size.height
            spoken.append(built.plainLabel)
        }

        // Keyword · Rule · Timeout · Reason, in Discord's order.
        let notes = [
            alert.keyword.map { "Keyword: \($0)" },
            alert.ruleName.map { "Rule: \($0)" },
            alert.timeoutLabel.map { "Timeout: \($0)" },
            alert.quarantineReason.map { "Reason: \($0)" },
        ].compactMap { $0 }
        if !notes.isEmpty {
            let blocks = notes.map { writer.block($0, font: writer.smallMedium, color: style.tertiaryColor, width: innerWidth) }
            y = writer.dotted(blocks, from: CGPoint(x: innerX, y: y + 4), maxX: innerX + innerWidth, gap: 8)
            spoken += notes
        }

        // `.annotationRow`: its own plate, 4 8 6 inside, 4 above.
        if let reason = alert.decisionReason {
            let block = writer.block(
                reason, font: writer.smallMedium, color: style.primaryColor, width: innerWidth - 16, hugs: false
            )
            let plate = CGRect(x: innerX, y: y + 4, width: innerWidth, height: 4 + block.size.height + 6)
            writer.ground(plate, .plate, .all, under: writer.card.parts.count, radius: 4)
            writer.text(block, at: CGPoint(x: innerX + 8, y: plate.minY + 4))
            y = plate.maxY
            spoken.append(reason)
        }

        let card = CGRect(x: origin.x, y: origin.y, width: width, height: max(y, face.maxY) + pad - origin.y)
        writer.ground(card, .card, .top, under: groundIndex)
        // Last, so the face and the name inside it answer first.
        if let flagged = alert.flaggedMessageID, let channelID = alert.channelID,
           input.mentions.channels[channelID] != nil
        {
            writer.card.controls.append(.init(
                action: .openFlaggedMessage(flagged, in: channelID),
                rect: card,
                accessibilityLabel: ""
            ))
        }
        return (card.maxY, spoken.joined(separator: ". "))
    }

    /// The bar joined under an alert (`nX`): AutoMod's shield and Actions,
    /// Jump to Surrounding, Delete User's Message, with Discord's dots between
    /// and the marks of what moderators did at its far end. It wraps where
    /// Discord's would overflow.
    ///
    /// Discord's Report Issues is not here: its feedback reaches Discord only
    /// through the client's analytics, which this client does not send.
    private static func actionBar(
        _ alert: AutoModAlert,
        message: Message,
        top: CGFloat,
        x: CGFloat,
        width: CGFloat,
        input: Input,
        writer: inout DrawnCardWriter
    ) -> CGFloat {
        let groundIndex = writer.card.parts.count
        let pad = DrawnCardMetrics.actionPadding
        let icon = DrawnCardMetrics.icon
        let font = writer.small
        let accent = NSColor.controlAccentColor

        var items: [(title: String, action: DrawnCardAction, shield: Bool)] = [
            ("Actions", .moderate(message.authorID), true),
        ]
        if let channelID = alert.channelID {
            items.append(("Jump to Surrounding", .jumpToSurrounding(channelID), false))
        }
        if input.canManageMessages, alert.flaggedMessageID != nil, !alert.deletedFlaggedMessage {
            items.append(("Delete User's Message", .deleteFlaggedMessage, false))
        }

        // `padding: 2px 18px 4px`, the row pulled back by its `-8px`.
        let left = x + 18 - pad
        let marks = alert.executedActions.filter { $0.kind != .unsetCompleted }
        let marksWidth = marks.isEmpty ? 0 : CGFloat(marks.count) * (icon + 6)
        let right = x + width - 18 - marksWidth
        let labelHeight = writer.block("Actions", font: font, color: accent, width: width).size.height
        let lineHeight = pad * 2 + max(icon, labelHeight)
        let firstLine = top + 2
        var lineTop = firstLine
        var cursor = left

        for (index, item) in items.enumerated() {
            let label = writer.block(item.title, font: font, color: accent, width: width)
            let box = pad + (item.shield ? icon + 4 : 0) + label.size.width + pad
            if index > 0 {
                if cursor + DrawnCardMetrics.dot + box > right {
                    lineTop += lineHeight
                    cursor = left
                } else {
                    writer.card.parts.append(.dot(CGRect(
                        x: cursor,
                        y: lineTop + (lineHeight - DrawnCardMetrics.dot) / 2,
                        width: DrawnCardMetrics.dot,
                        height: DrawnCardMetrics.dot
                    )))
                    cursor += DrawnCardMetrics.dot
                }
            }
            var labelX = cursor + pad
            if item.shield {
                writer.card.parts.append(.symbol(
                    "shield.fill",
                    CGRect(x: labelX, y: lineTop + (lineHeight - icon) / 2, width: icon, height: icon),
                    .accent
                ))
                labelX += icon + 4
            }
            writer.button(
                item.title,
                action: item.action,
                at: CGPoint(x: labelX, y: lineTop + ((lineHeight - label.size.height) / 2).rounded()),
                font: font,
                color: accent
            )
            cursor += box
        }

        // `.alertActionsIconContainer { margin-inline-start: auto }`.
        var markX = x + width - 18 - marksWidth + 6
        for action in marks {
            let rect = CGRect(x: markX, y: firstLine + (lineHeight - icon) / 2, width: icon, height: icon)
            let (symbol, tint): (String, DrawnCard.Tint) = switch action.kind {
            case .deleteUserMessage: ("trash", .muted)
            case .setCompleted: ("checkmark", .positive)
            default: ("flag", .muted)
            }
            writer.card.parts.append(.symbol(symbol, rect, tint))
            writer.card.tips.append(.init(rect: rect, action: action))
            markX += icon + 6
        }

        let bar = CGRect(x: x, y: top, width: width, height: lineTop + lineHeight + 4 - top)
        writer.ground(bar, .bar, .bottom, under: groundIndex)
        return bar.maxY
    }

    // MARK: The notice

    /// A notice about the whole server (`id`): a coloured header with its
    /// glyph, a line of particulars, Discord's paragraph, and — for a mention
    /// raid — the footer with Remove Restrictions and Configure Settings.
    ///
    /// A raid's own footer, Actions and Mark as resolved, belongs to Discord's
    /// incident actions, which this client does not have; Discord draws none
    /// either where they are not offered.
    private static func noticeCard(
        _ notice: AutoModNotification,
        message: Message,
        origin: CGPoint,
        width: CGFloat,
        input: Input,
        writer: inout DrawnCardWriter
    ) -> (bottom: CGFloat, spoken: String) {
        let style = input.style
        let pad = DrawnCardMetrics.padding
        let icon = DrawnCardMetrics.icon
        let groundIndex = writer.card.parts.count
        let inner = max(40, width - pad * 2)
        let critical = style.criticalColor
        let positive = NSColor(Palette.presenceOnline)
        let now = Date.now

        let (symbol, tint, title, color): (String, DrawnCard.Tint, String, NSColor) = switch notice.kind {
        case .raid(let isDirectMessageRaid):
            isDirectMessageRaid
                ? ("exclamationmark.circle.fill", .critical, "Unusual DM Activity Detected", critical)
                : ("exclamationmark.bubble.fill", .critical, "Unusual Join Activity Detected", critical)
        case .mentionRaid:
            ("exclamationmark.circle.fill", .critical, "Unusual Mention Activity Detected", critical)
        case .activityAlertsEnabled:
            ("gearshape.fill", .positive, "Activity Alerts Enabled", positive)
        case .interactionBlocked:
            ("exclamationmark.circle.fill", .primary, "App Action Blocked", style.primaryColor)
        case .unsupported:
            ("exclamationmark.circle.fill", .primary, "Unsupported Message", style.primaryColor)
        }
        var spoken = [title]

        // `.cardHeader`: the glyph, 4, the title.
        var y = origin.y + pad
        let titleBlock = writer.block(title, font: writer.semibold, color: color, width: inner - icon - 4)
        let headerHeight = max(icon, titleBlock.size.height)
        writer.card.parts.append(.symbol(
            symbol, CGRect(x: origin.x + pad, y: y + (headerHeight - icon) / 2, width: icon, height: icon), tint
        ))
        writer.text(titleBlock, at: CGPoint(
            x: origin.x + pad + icon + 4, y: y + ((headerHeight - titleBlock.size.height) / 2).rounded()
        ))
        y += headerHeight

        // `.subheader`, 2 under the header: Discord's particulars, 4 apart,
        // with its dot before the time.
        var line = NoticeLine(x: origin.x + pad, maxX: origin.x + pad + inner, top: y + 2)
        let small = writer.smallMedium
        func words(_ string: String, color: NSColor = style.primaryColor) -> TimelineTextBlock {
            writer.block(string, font: small, color: color, width: inner)
        }
        switch notice.kind {
        case .raid:
            if let joins = notice.joinAttempts { line.add(words("~\(joins.formatted()) Joins Actioned"), to: &writer) }
            if let sent = notice.directMessagesSent { line.add(words("~\(sent.formatted()) DMs Detected"), to: &writer) }
            if let date = notice.raidDate {
                line.addDot(to: &writer)
                line.add(words(MomentRelativeTime.fromNow(date, now: now)), to: &writer)
            }
        case .mentionRaid:
            if let date = notice.raidDate { line.add(words(MomentRelativeTime.fromNow(date, now: now)), to: &writer) }
        case .activityAlertsEnabled:
            // "Enabled by", the face and the @name — only for somebody this
            // client knows, as Discord draws them only for a member it has.
            if let enabler = notice.actionByUserID, let person = input.authors[enabler] {
                line.add(words("Enabled by"), to: &writer)
                line.addFace(
                    person.avatarURL,
                    monogram: person.monogram,
                    name: words(
                        " @\(person.username ?? person.name)",
                        color: person.colorValue.map { NSColor(Color(hex: $0)) } ?? style.primaryColor
                    ),
                    userID: enabler,
                    to: &writer
                )
                line.addDot(to: &writer)
            }
            line.add(words(MomentRelativeTime.fromNow(message.sentAt, now: now)), to: &writer)
        case .interactionBlocked, .unsupported:
            break
        }
        if line.hasContent {
            y = line.bottom
            spoken.append(line.spoken)
        }

        // The paragraph, 8 under — Discord's `gap: 8px`.
        let paragraph: String? = switch notice.kind {
        case .raid:
            notice.raidDate.map {
                "Activity began on \(Self.raidDateText($0)). Discord is serving CAPTCHA to all joiners and "
                    + "blocks suspicious joins and DMs. Enable security actions and review members, if needed."
            }
        case .mentionRaid:
            "We're restricting some messages due to a potential mention raid."
        case .activityAlertsEnabled:
            "New and improved Activity Alerts are monitoring your server safety. AutoMod will send a message "
                + "here if there is any DM or join activity that exceed what is normal for your server."
        case .interactionBlocked:
            "The application's response contained content blocked by this server."
        case .unsupported:
            "Your Discord client doesn\u{2019}t support this message type. Please update it to see this message."
        }
        if let paragraph {
            let block = writer.block(paragraph, font: style.bodyFont, color: style.secondaryColor, width: inner, hugs: false)
            writer.text(block, at: CGPoint(x: origin.x + pad, y: y + 8))
            y += 8 + block.size.height
            spoken.append(paragraph)
        }
        y += pad

        // A mention raid's footer (`.cardFooter`): 4 inside, Discord's text
        // buttons 8 inside that, a dot between.
        if case .mentionRaid = notice.kind {
            let footerIndex = writer.card.parts.count
            let accent = NSColor.controlAccentColor
            let buttonPad = DrawnCardMetrics.actionPadding
            let height = writer.block("Remove Restrictions", font: small, color: accent, width: inner).size.height
            let labelTop = y + 4 + buttonPad
            let remove = writer.button(
                "Remove Restrictions",
                action: .removeMentionRestrictions(decisionID: notice.decisionID),
                at: CGPoint(x: origin.x + 4 + buttonPad, y: labelTop),
                font: small,
                color: accent
            )
            let dotX = remove.maxX + buttonPad
            writer.card.parts.append(.dot(CGRect(
                x: dotX, y: labelTop + (height - DrawnCardMetrics.dot) / 2,
                width: DrawnCardMetrics.dot, height: DrawnCardMetrics.dot
            )))
            writer.button(
                "Configure Settings",
                action: .configureAutoMod,
                at: CGPoint(x: dotX + DrawnCardMetrics.dot + buttonPad, y: labelTop),
                font: small,
                color: accent
            )
            let footer = CGRect(x: origin.x, y: y, width: width, height: 4 + buttonPad * 2 + height + 4)
            writer.ground(footer, .plate, .bottom, under: footerIndex)
            y = footer.maxY
        }

        let card = CGRect(x: origin.x, y: origin.y, width: width, height: y - origin.y)
        writer.ground(card, .card, .all, under: groundIndex)
        return (card.maxY, spoken.joined(separator: ". "))
    }

    /// Discord's `{month: "numeric", day: "numeric", hour: "numeric",
    /// minute: "2-digit"}` — "10/5, 4:21 AM".
    static func raidDateText(_ date: Date) -> String {
        date.formatted(.dateTime.month(.defaultDigits).day().hour().minute(.twoDigits))
    }

    // MARK: Safety notices

    /// Discord's safety card in its system DM (`sh`, `sC`): a glyph and a
    /// header, how many days ago, the paragraph, and the footer — a policy
    /// notice's red one with Learn more, a system notification's with its
    /// links. A policy notice opens as a whole, as Discord's does.
    static func safetyCard(
        _ notice: SafetyNotice,
        origin: CGPoint,
        width: CGFloat,
        style: MessageTextStyle
    ) -> DrawnCard {
        var writer = DrawnCardWriter(style: style)
        let pad = DrawnCardMetrics.padding
        let icon = DrawnCardMetrics.safetyIcon
        let inner = max(40, width - pad * 2)

        let header: String
        let body: String
        let date: Date
        let glyph: (String, DrawnCard.Tint)?
        switch notice {
        case .policy(_, let incident):
            header = "You broke Discord's community guidelines"
            body = "We've taken action that affects your account."
            date = incident
            glyph = ("exclamationmark.triangle.fill", .critical)
        case .system(let system):
            header = system.header
            body = system.body
            date = system.date
            glyph = switch system.icon {
            case .danger: ("exclamationmark.triangle.fill", .critical)
            case .default: ("info.circle.fill", .link)
            case nil: nil
            }
        }

        var y = origin.y + pad
        let indent = glyph == nil ? 0 : icon + 4
        let title = writer.block(header, font: writer.semibold, color: style.primaryColor, width: inner - indent, hugs: false)
        let rowHeight = max(glyph == nil ? 0 : icon, title.size.height)
        if let glyph {
            writer.card.parts.append(.symbol(
                glyph.0, CGRect(x: origin.x + pad, y: y + (rowHeight - icon) / 2, width: icon, height: icon), glyph.1
            ))
        }
        writer.text(title, at: CGPoint(x: origin.x + pad + indent, y: y + ((rowHeight - title.size.height) / 2).rounded()))
        y += rowHeight

        // `.incidentTiming { margin-top: 4px }`, `.noticeBody { margin-top: 8px }`.
        let when = SafetyNotice.daysAgo(since: date)
        let timing = writer.block(when, font: writer.smallMedium, color: style.tertiaryColor, width: inner)
        writer.text(timing, at: CGPoint(x: origin.x + pad, y: y + 4))
        y += 4 + timing.size.height
        let paragraph = writer.block(body, font: style.bodyFont, color: style.secondaryColor, width: inner, hugs: false)
        writer.text(paragraph, at: CGPoint(x: origin.x + pad, y: y + 8))
        y += 8 + paragraph.size.height + pad

        let footerIndex = writer.card.parts.count
        let footerTop = y
        switch notice {
        case .policy:
            // `padding: 8px 12px`; Discord's secondary text button.
            let learn = writer.button(
                "Learn more",
                action: .accountStanding,
                at: CGPoint(x: origin.x + pad, y: footerTop + 8),
                font: NSFont.systemFont(ofSize: style.bodyFont.pointSize, weight: .medium),
                color: style.primaryColor
            )
            y = learn.maxY + 8
            writer.ground(CGRect(x: origin.x, y: footerTop, width: width, height: y - footerTop), .critical, .bottom, under: footerIndex)
        case .system(let system):
            // Discord's links, `margin-inline: 8px; padding: 8px 0`.
            var x = origin.x + 8
            var bottom = footerTop
            for link in system.links {
                let (title, action): (String, DrawnCardAction) = switch link {
                case .details: ("See Details", .accountStanding)
                case .learnMore(let url): ("Learn More", .openURL(url))
                }
                let rect = writer.button(title, action: action, at: CGPoint(x: x, y: footerTop + 8), font: style.bodyFont, color: style.linkColor)
                x = rect.maxX + 16
                bottom = max(bottom, rect.maxY + 8)
            }
            y = bottom
            if let theme = system.theme, y > footerTop {
                writer.ground(
                    CGRect(x: origin.x, y: footerTop, width: width, height: y - footerTop),
                    theme == .danger ? .critical : .plate,
                    .bottom,
                    under: footerIndex
                )
            }
        }

        let card = CGRect(x: origin.x, y: origin.y, width: width, height: y - origin.y)
        writer.ground(card, .card, .all, under: 0)
        if case .policy = notice {
            writer.card.controls.append(.init(action: .accountStanding, rect: card, accessibilityLabel: ""))
        }
        writer.card.rect = card
        return writer.card
    }
}

/// A notice's line of particulars: words, a face, Discord's dots, 4 apart.
private nonisolated struct NoticeLine {
    let x: CGFloat
    let maxX: CGFloat
    let top: CGFloat
    private var cursor: CGFloat
    private var lineTop: CGFloat
    private var lineHeight: CGFloat = 0
    private(set) var spoken = ""
    private(set) var hasContent = false
    private static let gap: CGFloat = 4
    private static let face: CGFloat = 16

    init(x: CGFloat, maxX: CGFloat, top: CGFloat) {
        self.x = x
        self.maxX = maxX
        self.top = top
        cursor = x
        lineTop = top
    }

    var bottom: CGFloat { lineTop + lineHeight }

    /// Where the next piece of `width` starts, wrapping first if it would not fit.
    private mutating func place(_ width: CGFloat, height: CGFloat) -> CGFloat {
        if hasContent {
            if cursor + Self.gap + width > maxX, cursor > x {
                lineTop += lineHeight + 2
                cursor = x
                lineHeight = 0
            } else {
                cursor += Self.gap
            }
        }
        defer {
            cursor += width
            lineHeight = max(lineHeight, height)
            hasContent = true
        }
        return cursor
    }

    mutating func add(_ block: TimelineTextBlock, to writer: inout DrawnCardWriter) {
        let at = place(block.size.width, height: block.size.height)
        writer.text(block, at: CGPoint(x: at, y: lineTop))
        spoken += (spoken.isEmpty ? "" : " ") + block.text.plainLabel
    }

    mutating func addDot(to writer: inout DrawnCardWriter) {
        let height = max(lineHeight, DrawnCardMetrics.dot)
        let at = place(DrawnCardMetrics.dot, height: 0)
        writer.card.parts.append(.dot(CGRect(
            x: at, y: lineTop + (height - DrawnCardMetrics.dot) / 2,
            width: DrawnCardMetrics.dot, height: DrawnCardMetrics.dot
        )))
    }

    /// A face and the name after it, together one control.
    mutating func addFace(
        _ url: URL?,
        monogram: String,
        name: TimelineTextBlock,
        userID: UserID,
        to writer: inout DrawnCardWriter
    ) {
        let width = Self.face + name.size.width
        let at = place(width, height: max(Self.face, name.size.height))
        let faceRect = CGRect(x: at, y: lineTop + (name.size.height - Self.face) / 2, width: Self.face, height: Self.face)
        writer.card.parts.append(.avatar(url, monogram: monogram, faceRect))
        writer.text(name, at: CGPoint(x: faceRect.maxX, y: lineTop))
        writer.card.controls.append(.init(
            action: .person(userID),
            rect: CGRect(x: at, y: lineTop, width: width, height: name.size.height),
            accessibilityLabel: name.text.plainLabel
        ))
        spoken += (spoken.isEmpty ? "" : " ") + name.text.plainLabel
    }
}
