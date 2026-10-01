import AppKit
import CoreGraphics
import Foundation
import WingcordCore

/// An invite posted in a message, laid out — Discord's invite embed.
///
/// **Drawn, like every card in the transcript.** One per invite link in the
/// message, in the order they appear, under the embeds. Everything the painter
/// needs is measured here; the only paint-time decision is whether the invite
/// is already *settled* — the reader in the server, in the group, friends with
/// the person — which swaps the button's face without a relayout.
///
/// **Two of Discord's cards.** A server whose invite carries its profile gets
/// the profile card (`ct`, `guild_invite_v2`): banner, the icon cut into it,
/// the name and its mark, the counts, the year, what the server says about
/// itself, and one full-width button. Everything else — a group, a friend link,
/// an invite that is gone, a server with no profile — gets the classic card
/// (`o2`, `oq`, `oX`, `ci`).
nonisolated struct InviteCardSlot: Sendable {
    var rect: CGRect
    var code: String
    var card: InviteCard?
    var body: Body
    /// The one control, or nil for an invite that is gone.
    var button: Button?
    /// The server's mark and its box, whose flyout says what it means.
    var mark: GuildMark?
    var markRect: CGRect
    var fold: Fold

    enum Body: Sendable {
        case classic(Classic)
        case profile(Profile)
    }

    /// How a profile card taller than Discord's 292 points is shown.
    enum Fold: Sendable {
        /// Short enough to show whole.
        case none
        /// Cut at 292 with the button floating over a fade; the card itself is
        /// the control that opens it.
        case collapsed(fade: CGRect)
        /// Opened, with Discord's Hide Details above the button.
        case expanded(hide: CGRect, label: TimelineTextBlock, labelOrigin: CGPoint)
    }

    struct Button: Sendable {
        var rect: CGRect
        /// Before the invite is settled, and after.
        var pending: Face
        var settled: Face
        /// Your own friend link: drawn, and not a control.
        var isEnabled: Bool

        struct Face: Sendable {
            var label: TimelineTextBlock
            var labelOrigin: CGPoint
            /// Discord's `active` is its affirmative green; `secondary` a quiet
            /// plate.
            var isProminent: Bool
        }
    }

    struct Classic: Sendable {
        var header: TimelineTextBlock
        var headerOrigin: CGPoint
        var splashURL: URL?
        var splashRect: CGRect
        var iconURL: URL?
        var iconRect: CGRect
        /// A server's icon is a rounded square; a person's and a group's a circle.
        var iconIsCircle: Bool
        /// An invite that is gone: Discord's red tile with an envelope in it in
        /// place of an icon, and the title in the same red (`guildIconExpired`,
        /// `inviteDestinationExpired`).
        var isExpired: Bool
        var monogram: TimelineTextBlock
        var monogramOrigin: CGPoint
        var title: TimelineTextBlock
        var titleOrigin: CGPoint
        var detail: TimelineTextBlock?
        var detailOrigin: CGPoint
        /// The green and grey marks before "Online" and "Members".
        var onlineDot: CGRect?
        var membersDot: CGRect?
        var inviter: Inviter?
    }

    struct Profile: Sendable {
        var bannerRect: CGRect
        /// The server's own header artwork — a discoverable server's custom
        /// banner — or nil for Discord's gradient.
        var bannerURL: URL?
        /// The gradient's colour: the server's brand colour, or its icon's.
        /// Nil for Discord's neutral default.
        var bannerColor: UInt32?
        var iconFrame: CGRect
        var iconRect: CGRect
        var iconURL: URL?
        var monogram: TimelineTextBlock
        var monogramOrigin: CGPoint
        var title: TimelineTextBlock
        var titleOrigin: CGPoint
        var counts: [Count]
        var established: TimelineTextBlock
        var establishedOrigin: CGPoint
        var description: TimelineTextBlock?
        var descriptionOrigin: CGPoint
        var traits: [Trait]
        var inviter: Inviter?

        struct Count: Sendable {
            var dot: CGRect
            var isOnline: Bool
            var label: TimelineTextBlock
            var labelOrigin: CGPoint
        }

        /// One of the words a server describes itself with, in its chip.
        struct Trait: Sendable {
            var rect: CGRect
            var glyph: TimelineTextBlock?
            var glyphOrigin: CGPoint
            var emojiURL: URL?
            var emojiRect: CGRect
            var label: TimelineTextBlock
            var labelOrigin: CGPoint
        }
    }

    /// Who sent it: their face and name.
    struct Inviter: Sendable {
        var avatarURL: URL?
        var avatarRect: CGRect
        var text: TimelineTextBlock
        var textOrigin: CGPoint
    }

    /// Every picture on the card with the box it is drawn in — the one list the
    /// prefetch and the painter both key from, so the two can never ask for a
    /// different size of the same picture.
    var pictures: [(url: URL, rect: CGRect)] {
        var out: [(URL, CGRect)] = []
        switch body {
        case .classic(let classic):
            if let url = classic.splashURL { out.append((url, classic.splashRect)) }
            if let url = classic.iconURL { out.append((url, classic.iconRect)) }
            if let inviter = classic.inviter, let url = inviter.avatarURL { out.append((url, inviter.avatarRect)) }
        case .profile(let profile):
            if let url = profile.bannerURL { out.append((url, profile.bannerRect)) }
            if let url = profile.iconURL { out.append((url, profile.iconRect)) }
            for trait in profile.traits { if let url = trait.emojiURL { out.append((url, trait.emojiRect)) } }
            if let inviter = profile.inviter, let url = inviter.avatarURL { out.append((url, inviter.avatarRect)) }
        }
        return out
    }

    static func imageKey(_ url: URL, in rect: CGRect, scale: CGFloat) -> ImageStore.Key {
        ImageStore.Key(url: url, maximumPixelSize: Int((max(rect.width, rect.height) * scale).rounded(.up)))
    }

    /// Where the card opens or closes, when it folds: the whole card while it
    /// is collapsed, Hide Details once it is open.
    var foldTarget: CGRect? {
        switch fold {
        case .none: nil
        case .collapsed: rect
        case .expanded(let hide, _, _): hide
        }
    }
}

nonisolated enum InviteCardLayoutEngine {

    // MARK: Discord's measurements

    /// The profile card: `.guildInviteContainer{width:300px;border-radius:16px}`.
    static let profileWidth: CGFloat = 300
    static let profileCorner: CGFloat = 16
    static let bannerHeight: CGFloat = 72
    /// The icon's plate is 70, the icon in it 64, and it rises 34 into the banner.
    static let iconFrameSide: CGFloat = 70
    static let iconSide: CGFloat = 64
    static let iconRise: CGFloat = 34
    /// Taller than this and the card folds, with the button over a 48-point fade.
    static let foldHeight: CGFloat = 292
    static let fadeHeight: CGFloat = 48
    static let inset: CGFloat = 16
    static let markSide: CGFloat = 18

    /// The classic card's own.
    static let classicPadding: CGFloat = 14
    static let classicIconSide: CGFloat = 48
    static let classicIconCorner: CGFloat = 14
    static let splashHeight: CGFloat = 64
    static let classicButtonWidth: CGFloat = 96
    static let gutter: CGFloat = 12

    static let buttonHeight: CGFloat = 32
    static let buttonCorner: CGFloat = 8
    static let hideHeight: CGFloat = 28
    static let inviterSide: CGFloat = 16

    static func layout(
        code: String,
        lookup: InviteLookup,
        sentByReader: Bool,
        selfIDs: Set<UInt64>,
        isExpanded: Bool,
        palettes: [URL: [UInt32]],
        origin: CGPoint,
        availableWidth: CGFloat,
        style: MessageTextStyle
    ) -> InviteCardSlot {
        guard case .resolved(let card) = lookup else {
            return classic(code: code, card: nil, sentByReader: sentByReader, selfIDs: selfIDs,
                           origin: origin, availableWidth: availableWidth, style: style)
        }
        if card.kind == .server, let profile = card.profile {
            return profileCard(code: code, card: card, profile: profile, isExpanded: isExpanded,
                               palettes: palettes, origin: origin, availableWidth: availableWidth, style: style)
        }
        return classic(code: code, card: card, sentByReader: sentByReader, selfIDs: selfIDs,
                       origin: origin, availableWidth: availableWidth, style: style)
    }

    /// The icon a card's banner colour is read from — see
    /// `GuildBannerArt.paletteURL`.
    static func paletteIconURL(for card: InviteCard) -> URL? {
        guard let guildID = card.guildID, let hash = card.profile?.iconHash ?? card.iconHash else { return nil }
        return GuildBannerArt.paletteURL(guildID: guildID, iconHash: hash)
    }

    // MARK: The profile card

    private static func profileCard(
        code: String,
        card: InviteCard,
        profile: GuildProfile,
        isExpanded: Bool,
        palettes: [URL: [UInt32]],
        origin: CGPoint,
        availableWidth: CGFloat,
        style: MessageTextStyle
    ) -> InviteCardSlot {
        let width = min(profileWidth, availableWidth)
        let contentX = origin.x + inset
        let contentWidth = width - inset * 2
        let guildID = card.guildID ?? profile.id

        // Discord's `_3`: the custom banner only for a server that is
        // discoverable, and the gradient otherwise.
        let bannerRect = CGRect(x: origin.x, y: origin.y, width: width, height: bannerHeight)
        let bannerURL = GuildBannerArt.artworkURL(
            guildID: guildID, customBannerHash: profile.customBannerHash,
            features: profile.features, width: width
        )
        let bannerColor = profile.brandColorPrimary
            ?? paletteIconURL(for: card).flatMap { palettes[$0]?.first }

        let iconFrame = CGRect(
            x: contentX, y: bannerRect.maxY - iconRise, width: iconFrameSide, height: iconFrameSide
        )
        let iconRect = iconFrame.insetBy(dx: (iconFrameSide - iconSide) / 2, dy: (iconFrameSide - iconSide) / 2)
        let iconURL = (profile.iconHash ?? card.iconHash).flatMap {
            CDN.guildIcon(guildID: guildID, hash: $0, side: iconSide)
        }
        let monogram = centred(
            Guild.monogram(of: profile.name.isEmpty ? card.name : profile.name),
            font: NSFont.systemFont(ofSize: 22, weight: .medium),
            color: style.secondaryColor, width: iconSide, style: style
        )

        // The header: name and mark, the counts, the year.
        var y = iconFrame.maxY + 8
        let mark = card.mark ?? profile.mark
        let markRoom: CGFloat = mark == nil ? 0 : markSide + 4
        let nameFont = NSFont.systemFont(ofSize: style.bodyFont.pointSize, weight: .semibold)
        let title = block(profile.name.isEmpty ? card.name : profile.name, font: nameFont,
                          color: style.primaryColor, width: contentWidth - markRoom, style: style)
        let titleOrigin = CGPoint(x: contentX, y: y)
        let markRect = mark == nil ? .zero : CGRect(
            x: contentX + title.size.width + 4,
            y: y + (title.size.height - markSide) / 2,
            width: markSide, height: markSide
        )
        y += title.size.height

        let detailFont = style.metadataFont
        var counts: [InviteCardSlot.Profile.Count] = []
        var countX = contentX
        var countsHeight: CGFloat = 0
        let online = profile.onlineCount ?? card.onlineCount
        let members = profile.memberCount ?? card.memberCount
        for (value, isOnline) in [(online, true), (members, false)] {
            guard let value else { continue }
            let text = isOnline
                ? "\(value.formatted()) Online"
                : "\(value.formatted()) \(value == 1 ? "Member" : "Members")"
            let label = block(text, font: detailFont, color: style.secondaryColor,
                              width: contentWidth, style: style)
            let dot = CGRect(x: countX, y: y + (label.size.height - 8) / 2, width: 8, height: 8)
            counts.append(.init(dot: dot, isOnline: isOnline, label: label,
                                labelOrigin: CGPoint(x: dot.maxX + 4, y: y)))
            countX = dot.maxX + 4 + label.size.width + 8
            countsHeight = max(countsHeight, label.size.height)
        }
        y += countsHeight

        let established = block(
            "Est. \(guildID.timestamp.formatted(.dateTime.month(.abbreviated).year()))",
            font: detailFont, color: style.secondaryColor, width: contentWidth, style: style
        )
        let establishedOrigin = CGPoint(x: contentX, y: y)
        y += established.size.height + 8

        // The body: what the server says, and its traits. Discord leaves an
        // eight-point gap where there is neither.
        var description: TimelineTextBlock?
        var descriptionOrigin = CGPoint.zero
        var traits: [InviteCardSlot.Profile.Trait] = []
        let words = profile.description.flatMap { $0.isEmpty ? nil : $0 }
        let labels = profile.traits.filter { !$0.label.isEmpty }
        if words != nil || !labels.isEmpty {
            if let words {
                let text = block(words, font: detailFont, color: style.secondaryColor,
                                 width: contentWidth, style: style, wraps: true)
                description = text
                descriptionOrigin = CGPoint(x: contentX, y: y)
                y += text.size.height
            }
            if !labels.isEmpty {
                if words != nil { y += 16 }
                let laid = traitChips(labels, originX: contentX, y: y, width: contentWidth,
                                      font: detailFont, style: style)
                traits = laid.chips
                y = laid.bottom
            }
            y += 16
        } else {
            y += 8
        }

        // Who sent it — the one line this card adds to Discord's.
        var inviter: InviteCardSlot.Inviter?
        if let name = card.inviterName {
            let line = inviterLine(name: name, card: card, x: contentX, y: y, width: contentWidth,
                                   font: detailFont, style: style)
            inviter = line
            y = line.avatarRect.maxY + 12
        }
        let contentBottom = y

        // The fold, and the button under it.
        let contentHeight = contentBottom - origin.y
        let folds = contentHeight > foldHeight
        let fold: InviteCardSlot.Fold
        let buttonY: CGFloat
        let cardHeight: CGFloat
        if folds && !isExpanded {
            cardHeight = foldHeight
            buttonY = origin.y + foldHeight - inset - buttonHeight
            fold = .collapsed(fade: CGRect(
                x: origin.x, y: buttonY - 8 - fadeHeight, width: width, height: fadeHeight
            ))
        } else if folds {
            let hide = CGRect(x: contentX, y: contentBottom, width: contentWidth, height: hideHeight)
            let label = centred("Hide Details", font: NSFont.systemFont(ofSize: detailFont.pointSize - 1,
                                                                        weight: .medium),
                                color: style.primaryColor, width: hide.width, style: style)
            fold = .expanded(hide: hide, label: label,
                             labelOrigin: CGPoint(x: hide.minX, y: hide.midY - label.size.height / 2))
            buttonY = hide.maxY + 8
            cardHeight = buttonY + buttonHeight + inset - origin.y
        } else {
            fold = .none
            buttonY = contentBottom
            cardHeight = buttonY + buttonHeight + inset - origin.y
        }

        let buttonRect = CGRect(x: contentX, y: buttonY, width: contentWidth, height: buttonHeight)
        let button = self.button(
            in: buttonRect,
            pending: card.joinsByApplication ? "Apply to Join" : "Join",
            pendingProminent: true,
            settled: "Go to Server",
            settledProminent: true,
            isEnabled: true,
            style: style
        )

        return InviteCardSlot(
            rect: CGRect(x: origin.x, y: origin.y, width: width, height: cardHeight),
            code: code,
            card: card,
            body: .profile(.init(
                bannerRect: bannerRect,
                bannerURL: bannerURL,
                bannerColor: bannerColor,
                iconFrame: iconFrame,
                iconRect: iconRect,
                iconURL: iconURL,
                monogram: monogram,
                monogramOrigin: CGPoint(
                    x: iconRect.midX - monogram.size.width / 2, y: iconRect.midY - monogram.size.height / 2
                ),
                title: title,
                titleOrigin: titleOrigin,
                counts: counts,
                established: established,
                establishedOrigin: establishedOrigin,
                description: description,
                descriptionOrigin: descriptionOrigin,
                traits: traits,
                inviter: inviter
            )),
            button: button,
            mark: mark,
            markRect: markRect,
            fold: fold
        )
    }

    /// Discord's trait chips: a hairline pill, the emoji and the word, four
    /// points apart, two lines at most — what does not fit becomes a `+N` chip
    /// at the end of the second line (`maxLines: 2` in its overflow list).
    private static func traitChips(
        _ traits: [GuildTrait],
        originX: CGFloat,
        y top: CGFloat,
        width: CGFloat,
        font: NSFont,
        style: MessageTextStyle
    ) -> (chips: [InviteCardSlot.Profile.Trait], bottom: CGFloat) {
        let emojiSide: CGFloat = 16, gap: CGFloat = 4, padX: CGFloat = 8, padY: CGFloat = 4
        let maxChip: CGFloat = 268
        let right = originX + width

        struct Content {
            var label: TimelineTextBlock
            var glyph: TimelineTextBlock?
            var emojiURL: URL?
            var size: CGSize
        }
        func content(_ label: TimelineTextBlock, glyph: TimelineTextBlock? = nil, emojiURL: URL? = nil) -> Content {
            let hasEmoji = glyph != nil || emojiURL != nil
            let height = max(label.size.height, hasEmoji ? emojiSide : 0) + padY * 2
            let width = padX * 2 + (hasEmoji ? emojiSide + gap : 0) + label.size.width
            return Content(label: label, glyph: glyph, emojiURL: emojiURL,
                           size: CGSize(width: min(width, maxChip), height: height))
        }
        let contents = traits.map { trait in
            content(
                block(trait.label, font: font, color: style.primaryColor,
                      width: maxChip - padX * 2 - emojiSide - gap, style: style),
                glyph: trait.glyph.map {
                    block($0, font: NSFont.systemFont(ofSize: 13), color: style.primaryColor,
                          width: emojiSide + 4, style: style)
                },
                emojiURL: trait.emojiID.flatMap { CDN.emoji(id: $0, animated: trait.emojiAnimated, side: emojiSide) }
            )
        }

        // Greedy lines, stopping where a third would begin.
        var origins: [CGPoint] = []
        var lineTops: [CGFloat] = [top]
        var lineHeights: [CGFloat] = [0]
        var x = originX
        for item in contents {
            if x > originX, x + item.size.width > right {
                guard lineTops.count < 2 else { break }
                lineTops.append(lineTops[lineTops.count - 1] + lineHeights[lineHeights.count - 1] + gap)
                lineHeights.append(0)
                x = originX
            }
            origins.append(CGPoint(x: x, y: lineTops[lineTops.count - 1]))
            lineHeights[lineHeights.count - 1] = max(lineHeights[lineHeights.count - 1], item.size.height)
            x += item.size.width + gap
        }

        // The count of the rest, which gives up chips from the end until it fits.
        var overflow: Content?
        if origins.count < contents.count {
            var hidden = contents.count - origins.count
            while true {
                let chip = content(block("+\(hidden)", font: font, color: style.primaryColor, width: 60, style: style))
                let after = origins.last.map { $0.x + contents[origins.count - 1].size.width + gap } ?? originX
                if after + chip.size.width <= right || origins.isEmpty {
                    overflow = chip
                    break
                }
                origins.removeLast()
                hidden += 1
            }
        }

        var chips: [InviteCardSlot.Profile.Trait] = []
        func place(_ item: Content, at origin: CGPoint) {
            let rect = CGRect(origin: origin, size: item.size)
            let hasEmoji = item.glyph != nil || item.emojiURL != nil
            let emojiRect = CGRect(x: rect.minX + padX, y: rect.midY - emojiSide / 2, width: emojiSide, height: emojiSide)
            chips.append(.init(
                rect: rect,
                glyph: item.glyph,
                glyphOrigin: CGPoint(x: emojiRect.midX - (item.glyph?.size.width ?? 0) / 2,
                                     y: emojiRect.midY - (item.glyph?.size.height ?? 0) / 2),
                emojiURL: item.emojiURL,
                emojiRect: emojiRect,
                label: item.label,
                labelOrigin: CGPoint(x: rect.minX + padX + (hasEmoji ? emojiSide + gap : 0),
                                     y: rect.midY - item.label.size.height / 2)
            ))
        }
        for (index, origin) in origins.enumerated() { place(contents[index], at: origin) }
        if let overflow {
            let at = origins.last.map {
                CGPoint(x: $0.x + contents[origins.count - 1].size.width + gap, y: $0.y)
            } ?? CGPoint(x: originX, y: top)
            place(overflow, at: at)
        }
        let bottom = (chips.map(\.rect.maxY).max() ?? top)
        return (chips, bottom)
    }

    // MARK: The classic card

    private static func classic(
        code: String,
        card: InviteCard?,
        sentByReader: Bool,
        selfIDs: Set<UInt64>,
        origin: CGPoint,
        availableWidth: CGFloat,
        style: MessageTextStyle
    ) -> InviteCardSlot {
        let width = min(Metrics.embedMaxWidth, availableWidth)
        let contentX = origin.x + classicPadding
        let contentRight = origin.x + width - classicPadding
        var y = origin.y + classicPadding

        // A friend link's header is about whose link it is; the others' about
        // who posted it.
        let isOwnFriendLink = card?.kind == .friend
            && card?.inviterID.map { selfIDs.contains($0.rawValue) } == true
        let headerText: String = if let card {
            card.header(sentByReader: card.kind == .friend ? isOwnFriendLink : sentByReader)
        } else {
            sentByReader ? "You sent an invite, but" : "You've been invited, but"
        }
        let header = block(headerText, font: style.metadataFont, color: style.secondaryColor,
                           width: contentRight - contentX, style: style)
        let headerOrigin = CGPoint(x: contentX, y: y)
        y += header.size.height + 8

        var splashRect = CGRect.zero
        var splashURL: URL?
        if let card, let guildID = card.guildID, let hash = card.splashHash {
            splashURL = CDN.guildSplash(guildID: guildID, hash: hash, width: width)
            splashRect = CGRect(x: contentX, y: y, width: contentRight - contentX, height: splashHeight)
            y = splashRect.maxY + 10
        }

        let iconRect = CGRect(x: contentX, y: y, width: classicIconSide, height: classicIconSide)
        let buttonRect = CGRect(
            x: contentRight - classicButtonWidth,
            y: iconRect.midY - buttonHeight / 2,
            width: classicButtonWidth,
            height: buttonHeight
        )
        let textX = iconRect.maxX + gutter
        let textWidth = max(40, (card == nil ? contentRight : buttonRect.minX - gutter) - textX)

        // Discord drops a gone invite's title to medium (`heading-md/medium`)
        // and gives it four points under it rather than two.
        let titleFont = NSFont.systemFont(
            ofSize: style.bodyFont.pointSize * 1.1, weight: card == nil ? .medium : .semibold
        )
        let titleGap: CGFloat = card == nil ? 4 : 2
        let titleText: String = switch card?.kind {
        case .friend: card?.inviterUsername ?? card?.name ?? ""
        case .server, .groupDirectMessage: card?.name ?? ""
        case nil: "Invalid Invite"
        }
        let title = block(titleText, font: titleFont,
                          color: card == nil ? .systemRed : style.primaryColor,
                          width: textWidth, style: style)

        // The line under the name: live counts for a server big enough to have
        // them (Discord's own threshold: five members, or anybody on), the
        // channel otherwise; a group's size; the way back for an invite that is
        // gone.
        let detailFont = style.metadataFont
        var detailText: String?
        var hasCounts = false
        if let card {
            switch card.kind {
            case .server:
                if (card.memberCount ?? 0) >= 5 || (card.onlineCount ?? 0) > 0 {
                    hasCounts = true
                    let online = (card.onlineCount ?? 0).formatted()
                    let members = (card.memberCount ?? 0).formatted()
                    detailText = "\(online) Online      \(members) \(card.memberCount == 1 ? "Member" : "Members")"
                } else if let channel = card.channelName {
                    detailText = "#\(channel)"
                }
            case .groupDirectMessage:
                detailText = card.memberCount.map { "\($0.formatted()) \($0 == 1 ? "Member" : "Members")" }
            case .friend:
                // Discord's second line is the tag, which for every account on
                // the new names is the handle already above it.
                detailText = nil
            }
        } else {
            detailText = sentByReader ? "Try sending a new invite" : "Ask for a new invite"
        }
        let detail = detailText.map {
            block($0, font: detailFont, color: style.secondaryColor, width: textWidth, style: style)
        }
        let dotInset: CGFloat = hasCounts ? 11 : 0
        let textHeight = title.size.height + (detail.map { titleGap + $0.size.height } ?? 0)
        let titleOrigin = CGPoint(x: textX, y: iconRect.midY - textHeight / 2)
        let detailOrigin = CGPoint(x: textX + dotInset, y: titleOrigin.y + title.size.height + titleGap)
        var onlineDot: CGRect?
        var membersDot: CGRect?
        if hasCounts, let detail, let card {
            let dotSide: CGFloat = 8
            let midY = detailOrigin.y + detail.size.height / 2
            onlineDot = CGRect(x: textX, y: midY - dotSide / 2, width: dotSide, height: dotSide)
            // The second mark sits in the gap the sentence left for it.
            let lead = "\((card.onlineCount ?? 0).formatted()) Online   "
            let offset = (lead as NSString).size(withAttributes: [.font: detailFont]).width
            membersDot = CGRect(x: detailOrigin.x + offset, y: midY - dotSide / 2, width: dotSide, height: dotSide)
        }

        // **Centred by paragraph style, not by origin.** A block's width is the
        // width it was given — `INVARIANTS.md` §4.85 — so placing this one at
        // `midX - width / 2` put the letter against the tile's leading edge.
        let monogram = centred(
            String((card?.name ?? "").prefix(1)).uppercased(),
            font: NSFont.systemFont(ofSize: classicIconSide * 0.4, weight: .semibold),
            color: style.secondaryColor, width: classicIconSide, style: style
        )
        y = max(iconRect.maxY, titleOrigin.y + textHeight)

        // Who sent it — not for a friend link, which IS the person.
        var inviter: InviteCardSlot.Inviter?
        if let card, card.kind != .friend, let name = card.inviterName {
            y += 10
            let line = inviterLine(name: name, card: card, x: contentX, y: y,
                                   width: contentRight - contentX, font: detailFont, style: style)
            inviter = line
            y = line.avatarRect.maxY
        }

        var button: InviteCardSlot.Button?
        if let card {
            let (pending, pendingProminent, settled, settledProminent) = classicWords(for: card)
            button = self.button(
                in: buttonRect,
                pending: isOwnFriendLink ? "Add Friend" : pending,
                pendingProminent: pendingProminent && !isOwnFriendLink,
                settled: settled,
                settledProminent: settledProminent,
                isEnabled: !isOwnFriendLink,
                style: style
            )
        }

        return InviteCardSlot(
            rect: CGRect(x: origin.x, y: origin.y, width: width, height: y - origin.y + classicPadding),
            code: code,
            card: card,
            body: .classic(.init(
                header: header,
                headerOrigin: headerOrigin,
                splashURL: splashURL,
                splashRect: splashRect,
                iconURL: card.flatMap(classicIconURL(for:)),
                iconRect: iconRect,
                iconIsCircle: card != nil && card?.kind != .server,
                isExpired: card == nil,
                monogram: monogram,
                monogramOrigin: CGPoint(
                    x: iconRect.midX - monogram.size.width / 2, y: iconRect.midY - monogram.size.height / 2
                ),
                title: title,
                titleOrigin: titleOrigin,
                detail: detail,
                detailOrigin: detailOrigin,
                onlineDot: onlineDot,
                membersDot: membersDot,
                inviter: inviter
            )),
            button: button,
            mark: nil,
            markRect: .zero,
            fold: .none
        )
    }

    /// Discord's words and variants for the classic card's button, before and
    /// after: a server is `Join`/`Joined`, both green (`o2`); a group `Join
    /// Group DM` in green, then a quiet `Joined` (`oq`); a friend link `Add
    /// Friend` in green, then a quiet `Send a Message` (`oX`).
    private static func classicWords(for card: InviteCard) -> (String, Bool, String, Bool) {
        switch card.kind {
        case .server: ("Join", true, "Joined", true)
        case .groupDirectMessage: ("Join Group DM", true, "Joined", false)
        case .friend: ("Add Friend", true, "Send a Message", false)
        }
    }

    private static func classicIconURL(for card: InviteCard) -> URL? {
        switch card.kind {
        case .server:
            guard let guildID = card.guildID, let hash = card.iconHash else { return nil }
            return CDN.guildIcon(guildID: guildID, hash: hash, side: classicIconSide)
        case .groupDirectMessage:
            guard let channelID = card.channelID, let hash = card.iconHash else { return nil }
            return CDN.channelIcon(channelID: channelID, hash: hash, side: classicIconSide)
        case .friend:
            guard let id = card.inviterID, let hash = card.inviterAvatarHash else { return nil }
            return CDN.avatar(userID: id, hash: hash, side: classicIconSide)
        }
    }

    // MARK: Shared parts

    private static func inviterLine(
        name: String,
        card: InviteCard,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        font: NSFont,
        style: MessageTextStyle
    ) -> InviteCardSlot.Inviter {
        let avatarRect = CGRect(x: x, y: y, width: inviterSide, height: inviterSide)
        let text = block("Invited by \(name)", font: font, color: style.secondaryColor,
                         width: width - inviterSide - 6, style: style)
        return InviteCardSlot.Inviter(
            avatarURL: card.inviterID.flatMap { id in
                card.inviterAvatarHash.flatMap { CDN.avatar(userID: id, hash: $0, side: inviterSide) }
            },
            avatarRect: avatarRect,
            text: text,
            textOrigin: CGPoint(x: avatarRect.maxX + 6, y: avatarRect.midY - text.size.height / 2)
        )
    }

    private static func button(
        in rect: CGRect,
        pending: String,
        pendingProminent: Bool,
        settled: String,
        settledProminent: Bool,
        isEnabled: Bool,
        style: MessageTextStyle
    ) -> InviteCardSlot.Button {
        let font = NSFont.systemFont(ofSize: style.bodyFont.pointSize, weight: .semibold)
        func face(_ words: String, prominent: Bool) -> InviteCardSlot.Button.Face {
            let label = centred(words, font: font, color: prominent ? .white : style.primaryColor,
                                width: rect.width, style: style)
            return .init(label: label, labelOrigin: CGPoint(x: rect.minX, y: rect.midY - label.size.height / 2),
                         isProminent: prominent)
        }
        return InviteCardSlot.Button(
            rect: rect,
            pending: face(pending, prominent: pendingProminent),
            settled: face(settled, prominent: settledProminent),
            isEnabled: isEnabled
        )
    }

    private static func block(
        _ text: String,
        font: NSFont,
        color: NSColor,
        width: CGFloat,
        style: MessageTextStyle,
        wraps: Bool = false
    ) -> TimelineTextBlock {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        return TimelineTextBlock(
            text: .plain(NSAttributedString(
                string: text,
                attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            )),
            width: width,
            style: style
        )
    }

    private static func centred(
        _ text: String,
        font: NSFont,
        color: NSColor,
        width: CGFloat,
        style: MessageTextStyle
    ) -> TimelineTextBlock {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return TimelineTextBlock(
            text: .plain(NSAttributedString(
                string: text,
                attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            )),
            width: width,
            style: style
        )
    }
}

/// One invite card's fold, by the message it sits in and its code: the same
/// link posted twice is two cards, each opened on its own.
nonisolated struct InviteCardFold: Hashable, Sendable {
    var message: MessageID
    var code: String
}
